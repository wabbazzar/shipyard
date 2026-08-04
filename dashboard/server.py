"""Loopback-only HTTP API for Shipyard's read-only event dashboard."""

from __future__ import annotations

import sys

# `python dashboard/server.py` otherwise leaves dashboard/ first on sys.path,
# where operator.py can shadow Python's stdlib operator module during argparse's
# import chain. Establish the package root before importing the stdlib surface.
if __package__ in {None, ""}:
    _script_directory = __file__.rpartition("/")[0]
    _package_root = _script_directory.rpartition("/")[0] or "."
    if sys.path and sys.path[0] == _script_directory:
        sys.path.pop(0)
    if _package_root not in sys.path:
        sys.path.insert(0, _package_root)

import argparse
import hashlib
import itertools
import json
import os
import re
import select
import socket
import stat
import subprocess
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable, Optional
from urllib.parse import parse_qsl, urlsplit

from dashboard.reader import DEFAULT_LIMIT, MAX_LIMIT, EventReader, StaleReferenceError
from dashboard.operator import (
    DELIVERY_EVENT_FAMILIES,
    DELIVERY_IDENTIFIER_FIELDS,
    InspectionCache,
    MAX_RUNTIME_EVENTS_PER_NODE,
    OperatorDataError,
    collect_change_metrics,
    compose_operator_document,
    load_presentation_topology,
    make_expensive_loader,
)


SCHEMA_VERSION = 1
BUILD_VERSION = "0.1.0"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8765
DEFAULT_POLL_INTERVAL = 0.5
DEFAULT_HEARTBEAT_INTERVAL = 15.0
DEFAULT_MAX_STREAM_CLIENTS = 8
SECURITY_HEADERS = {
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "Content-Security-Policy": (
        "default-src 'self'; connect-src 'self'; script-src 'self'; style-src 'self'; "
        "img-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
    ),
}
QUERY_KEYS = frozenset({"window", "project", "role", "status", "event", "limit"})
WINDOWS = frozenset({"24h", "7d", "30d"})
_VALID_PERCENT_ESCAPE = re.compile(r"%(?![0-9A-Fa-f]{2})")
STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/favicon.svg": ("favicon.svg", "image/svg+xml"),
    "/styles.css": ("styles.css", "text/css; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
}
STATIC_DIR = Path(__file__).resolve().parent / "static"
_SOURCE_DIGEST_PATHS = (
    "dashboard/operator.py",
    "dashboard/reader.py",
    "dashboard/server.py",
    "dashboard/static/app.js",
    "dashboard/static/index.html",
    "dashboard/static/styles.css",
    "skills/shipyard/shipyard.sh",
    "skills/shipyard/inspect.py",
    "scripts/delegation-report.py",
    "docs/shipyard-data.json",
)
_TERMINAL_REASONS = {"dirty", "not_trunk", "open_cap", "budget", "budget_deferred"}
MAX_RUNTIME_IDENTITIES = 512
MAX_RUNTIME_EVENTS_TOTAL = 4096
MAX_RUNTIME_SCAN_REFERENCES = 50_000
MAX_DELIVERY_SCAN_REFERENCES = 50_000
MAX_DELIVERY_READ_REFERENCES = 4_096
MAX_DELIVERY_IDENTITIES = 4_096
MAX_DELIVERY_EVENTS_TOTAL = 4_096
_DELIVERY_SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@-]{0,159}$")


class RequestError(ValueError):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


def _reject_json_constant(value: str) -> Any:
    raise ValueError(f"non-standard JSON constant: {value}")


def clean_install_events_dir(*, platform: Optional[str] = None) -> Path:
    platform = platform or sys.platform
    home = Path.home()
    if platform == "darwin":
        return home / "Library" / "Application Support" / "Shipyard" / "events"
    state_home = Path(os.environ.get("XDG_STATE_HOME", home / ".local" / "state"))
    return state_home / "shipyard" / "events"


def resolve_events_dir(cli_value: Optional[str]) -> Path:
    raw = cli_value if cli_value is not None else os.environ.get("QUARTET_EVENTS_DIR")
    candidate = Path(raw).expanduser() if raw else clean_install_events_dir()
    if candidate.is_symlink():
        raise ValueError(f"event directory must not be a symlink: {candidate}")
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as exc:
        raise ValueError(f"event directory is unavailable: {candidate}: {exc}") from exc
    if not resolved.is_dir():
        raise ValueError(f"event path is not a directory: {resolved}")
    return resolved


def parse_port(value: str | int, *, allow_zero: bool = True) -> int:
    text = str(value)
    if not text.isascii() or not text.isdigit():
        raise ValueError("port must be an integer")
    port = int(text, 10)
    minimum = 0 if allow_zero else 1
    if not minimum <= port <= 65535:
        raise ValueError(f"port must be between {minimum} and 65535")
    return port


def validate_bind_host(host: str) -> str:
    if host != DEFAULT_HOST:
        raise ValueError("dashboard host must be 127.0.0.1")
    return host


def _parse_query(raw_query: str) -> dict[str, str]:
    if _VALID_PERCENT_ESCAPE.search(raw_query):
        raise RequestError(400, "invalid_query", "query contains an invalid percent escape")
    try:
        pairs = parse_qsl(raw_query, keep_blank_values=True, strict_parsing=True, encoding="utf-8", errors="strict")
    except (UnicodeDecodeError, ValueError) as exc:
        raise RequestError(400, "invalid_query", "query string is malformed") from exc
    values: dict[str, str] = {}
    for key, value in pairs:
        if key not in QUERY_KEYS:
            raise RequestError(400, "unknown_query_key", f"unknown query key: {key or '<blank>'}")
        if key in values:
            raise RequestError(400, "repeated_query_key", f"query key appears more than once: {key}")
        if value == "":
            raise RequestError(400, "invalid_query_value", f"query value must not be blank: {key}")
        values[key] = value
    window = values.get("window", "7d")
    if window not in WINDOWS:
        raise RequestError(400, "invalid_window", "window must be one of: 24h, 7d, 30d")
    limit_text = values.get("limit", str(DEFAULT_LIMIT))
    if not limit_text.isascii() or not limit_text.isdigit():
        raise RequestError(400, "invalid_limit", f"limit must be between 1 and {MAX_LIMIT}")
    limit = int(limit_text, 10)
    if not 1 <= limit <= MAX_LIMIT:
        raise RequestError(400, "invalid_limit", f"limit must be between 1 and {MAX_LIMIT}")
    values["window"] = window
    values["limit"] = str(limit)
    return values


def _parse_operator_query(raw_query: str) -> str:
    values = _parse_query(raw_query)
    supplied = {key for key, _value in parse_qsl(raw_query, keep_blank_values=True)}
    if supplied - {"window"}:
        raise RequestError(400, "unknown_query_key", "operator accepts only window")
    if "window" not in supplied:
        raise RequestError(400, "missing_query_key", "operator requires window")
    return values["window"]


def _reference_location(reader: EventReader, reference: Any) -> dict[str, Any]:
    return {"file": reader.filename(reference), "byte_offset": reference.byte_offset}


def _source_content_digest(repo_root: Path, topology_path: Optional[Path] = None) -> str:
    """Hash every mutable producer directly, without invoking a command."""
    sources = [(relative, repo_root / relative) for relative in _SOURCE_DIGEST_PATHS]
    if topology_path is not None:
        topology = Path(topology_path)
        if all(path != topology for _label, path in sources):
            sources.append(("operator_topology", topology))
    digest = hashlib.sha256()
    for label, path in sources:
        digest.update(label.encode("utf-8"))
        digest.update(b"\0")
        try:
            digest.update(path.read_bytes())
        except OSError:
            digest.update(b"source_unavailable")
        digest.update(b"\0")
    return digest.hexdigest()


def _source_git(repo_root: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repo_root), *args],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=5,
        check=False,
    )


def capture_source_provenance(
    repo_root: Path, topology_path: Optional[Path] = None
) -> dict[str, str]:
    """Capture deployed source identity once; requests only read the snapshot."""
    revision = "unknown"
    state = "unknown"
    try:
        revision_result = _source_git(repo_root, "rev-parse", "HEAD")
        candidate = revision_result.stdout.strip()
        if revision_result.returncode == 0 and re.fullmatch(r"[0-9a-f]{40}", candidate):
            revision = candidate
        status_result = _source_git(
            repo_root, "status", "--porcelain", "--untracked-files=normal"
        )
        if status_result.returncode == 0:
            state = "modified" if status_result.stdout else "clean"
    except (OSError, subprocess.SubprocessError):
        pass

    return {
        "source_revision": revision,
        "source_state": state,
        "source_digest": _source_content_digest(repo_root, topology_path),
    }


def _summary_payload(
    reader: EventReader, window: str, *, service_limit: Optional[int] = None
) -> dict[str, Any]:
    summary = reader.summarize(window=window)
    services = []
    # Counts still describe the full window; only terminal-backed service rows
    # are materialized to the operator's existing runtime identity bound.
    summary_services = summary["services"]
    materialized_services = (
        summary_services
        if service_limit is None
        else itertools.islice(summary_services, service_limit)
    )
    for item in materialized_services:
        terminal = reader.read_event(item.reference)
        terminal_reason = terminal.get("reason")
        if terminal_reason not in _TERMINAL_REASONS:
            terminal_reason = None
        services.append(
            {
                "project": item.project,
                "role": item.role,
                "svc": item.svc,
                "state": item.state,
                "last_activity": item.last_activity,
                "terminal_status": item.terminal_status,
                "terminal_reason": terminal_reason,
                "duration_s": item.duration_s,
                **_reference_location(reader, item.reference),
            }
        )
    actionables = []
    for item in summary["actionables"]:
        row = reader.read_event(item.reference)
        payload = {"kind": item.kind, "key": item.key, "event": row, **_reference_location(reader, item.reference)}
        if item.identity is not None:
            payload["identity"] = dict(zip(("project", "role", "svc"), item.identity))
        actionables.append(payload)
    payload = {
        "window": window,
        "counts": summary["counts"],
        "latest_timestamp": summary["latest_timestamp"],
        "services": services,
        "actionables": actionables,
        "errors": [
            {"file": problem.file, "byte_offset": problem.byte_offset, "message": problem.message}
            for problem in reader.problems
        ],
    }
    if service_limit is not None and len(summary_services) > service_limit:
        payload["_services_truncated"] = True
    return payload


class RuntimeLifecycleEvents(list[dict[str, Any]]):
    """List-compatible bounded runtime page with controlled limitations."""

    def __init__(self, rows: list[dict[str, Any]], limitations: list[str]):
        super().__init__(rows)
        self.limitations = limitations


def _runtime_lifecycle_events(
    reader: EventReader, window: str, summary: dict[str, Any]
) -> RuntimeLifecycleEvents:
    """Read a globally and per-identity bounded runtime lifecycle page."""
    limitations: set[str] = set()
    identity_projects: dict[tuple[str, str], Optional[str]] = {}
    raw_services = summary.get("services", [])
    services = raw_services if isinstance(raw_services, list) else []
    if summary.get("_services_truncated") is True or len(services) > MAX_RUNTIME_IDENTITIES:
        limitations.add("runtime_identities_truncated")
    for raw in services[:MAX_RUNTIME_IDENTITIES]:
        if not isinstance(raw, dict):
            continue
        role, svc, project = raw.get("role"), raw.get("svc"), raw.get("project")
        if not all(isinstance(value, str) for value in (role, svc, project)):
            continue
        key = (role, svc)
        if key not in identity_projects:
            identity_projects[key] = project
        elif identity_projects[key] != project:
            identity_projects[key] = None
    buckets: dict[tuple[str, str, str], list[dict[str, Any]]] = {}
    scanned = 0
    retained = 0
    for reference in itertools.islice(
        reader._window_refs(window, None), MAX_RUNTIME_SCAN_REFERENCES
    ):
        scanned += 1
        if reference.event not in {"job.start", "job.end"}:
            continue
        project = reference.project or identity_projects.get((reference.role, reference.svc))
        if not project:
            continue
        key = (project, reference.role, reference.svc)
        if key not in buckets and len(buckets) >= MAX_RUNTIME_IDENTITIES:
            limitations.add("runtime_identities_truncated")
            continue
        bucket = buckets.setdefault(key, [])
        if len(bucket) >= MAX_RUNTIME_EVENTS_PER_NODE:
            if bucket:
                bucket[0]["runtime_identity_truncated"] = True
            limitations.add("runtime_identity_events_truncated")
            continue
        if retained >= MAX_RUNTIME_EVENTS_TOTAL:
            limitations.add("runtime_events_total_truncated")
            continue
        row = reader.read_event(reference)
        row["project"] = project
        row["role"] = reference.role
        row["svc"] = reference.svc
        bucket.append(row)
        retained += 1
    if scanned == MAX_RUNTIME_SCAN_REFERENCES:
        limitations.add("runtime_scan_truncated")
    if limitations:
        limitations.add("runtime_lifecycle_truncated")
    rows = [row for key in sorted(buckets) for row in buckets[key]]
    return RuntimeLifecycleEvents(rows, sorted(limitations))


class DeliveryLifecycleEvents(list[dict[str, Any]]):
    """Bounded delivery-only recovery page with controlled limitations."""

    def __init__(self, rows: list[dict[str, Any]], limitations: list[str]):
        super().__init__(rows)
        self.limitations = limitations


def _delivery_safe_text(value: Any) -> Optional[str]:
    if not isinstance(value, str) or _DELIVERY_SAFE_ID.fullmatch(value) is None:
        return None
    return value


def _delivery_lifecycle_events(
    reader: EventReader,
    window: str,
    displayed_references: Optional[list[Any]] = None,
) -> DeliveryLifecycleEvents:
    """Recover only bounded, identifier-bearing delivery rows beyond the display page."""
    displayed = set(displayed_references or [])
    limitations: set[str] = set()
    identifiers: set[tuple[str, str]] = set()
    identity_projects: dict[tuple[str, str], Optional[str]] = {}
    pending_rows: list[tuple[dict[str, Any], Optional[tuple[str, str]]]] = []
    scanned = 0
    reads = 0
    for reference in itertools.islice(
        reader._window_refs(window, None), MAX_DELIVERY_SCAN_REFERENCES
    ):
        scanned += 1
        role = _delivery_safe_text(reference.role)
        service = _delivery_safe_text(reference.svc)
        project = _delivery_safe_text(reference.project)
        identity = (role, service) if role is not None and service is not None else None
        if identity is not None and project is not None:
            if identity not in identity_projects:
                if len(identity_projects) + len(identifiers) >= MAX_DELIVERY_IDENTITIES:
                    limitations.add("delivery_identities_truncated")
                else:
                    identity_projects[identity] = project
            elif identity_projects[identity] != project:
                identity_projects[identity] = None
        if reference in displayed:
            continue
        if not any(
            reference.event == family or reference.event.startswith(family + ".")
            for family in DELIVERY_EVENT_FAMILIES
        ):
            continue
        if reads >= MAX_DELIVERY_READ_REFERENCES:
            limitations.add("delivery_reads_truncated")
            break
        raw = reader.read_event(reference)
        reads += 1
        safe_identifiers = {
            (field, value)
            for field in DELIVERY_IDENTIFIER_FIELDS
            if (value := _delivery_safe_text(raw.get(field))) is not None
        }
        if not safe_identifiers:
            continue
        if len(identity_projects) + len(identifiers | safe_identifiers) > MAX_DELIVERY_IDENTITIES:
            limitations.add("delivery_identities_truncated")
            continue
        identifiers.update(safe_identifiers)
        event: dict[str, Any] = {"event": reference.event}
        for field in (
            "ts",
            "project_id",
            "project",
            "role",
            "svc",
            "run_id",
            "work_id",
            "upstream_work_id",
            "proposal_id",
            "incident_id",
            "outcome",
            "status",
        ):
            value = _delivery_safe_text(raw.get(field))
            if value is not None:
                event[field] = value
        if "project" not in event:
            project = _delivery_safe_text(reference.project)
            if project is not None:
                event["project"] = project
        if "role" not in event:
            role = _delivery_safe_text(reference.role)
            if role is not None:
                event["role"] = role
        pending_rows.append((event, identity))
        if len(pending_rows) >= MAX_DELIVERY_EVENTS_TOTAL:
            limitations.add("delivery_events_total_truncated")
            break
    if scanned == MAX_DELIVERY_SCAN_REFERENCES:
        limitations.add("delivery_scan_truncated")
    if limitations:
        limitations.add("delivery_lifecycle_truncated")
    rows = []
    for event, identity in pending_rows:
        if "project" not in event and identity is not None:
            project = identity_projects.get(identity)
            if project is not None:
                event["project"] = project
        rows.append(event)
    return DeliveryLifecycleEvents(rows, sorted(limitations))


def _with_event_index_limitation(payload: dict[str, Any], limitation: Optional[str]) -> dict[str, Any]:
    if limitation is None:
        return payload
    response = dict(payload)
    metadata = dict(payload["metadata"])
    metadata["limitations"] = sorted(set(metadata["limitations"] + [limitation]))
    response["metadata"] = metadata
    return response


@dataclass
class TailState:
    path: Optional[Path] = None
    identity: Optional[tuple[int, int]] = None
    offset: int = 0
    remainder: bytes = b""
    initialized: bool = False
    checkpoint_start: int = 0
    checkpoint: bytes = b""


def _read_at(descriptor: int, offset: int, length: int) -> bytes:
    os.lseek(descriptor, offset, os.SEEK_SET)
    chunks = []
    remaining = length
    while remaining:
        chunk = os.read(descriptor, remaining)
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


class DashboardHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        address: tuple[str, int],
        event_dir: Path,
        *,
        poll_interval: float = DEFAULT_POLL_INTERVAL,
        heartbeat_interval: float = DEFAULT_HEARTBEAT_INTERVAL,
        max_stream_clients: int = DEFAULT_MAX_STREAM_CLIENTS,
        monotonic: Callable[[], float] = time.monotonic,
        utc_now: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
        operator_loader: Optional[Callable[[str], dict[str, Any]]] = None,
        operator_topology_path: Optional[Path] = None,
        source_provenance: Optional[dict[str, str]] = None,
    ):
        host, port = address
        validate_bind_host(host)
        if poll_interval <= 0 or heartbeat_interval <= 0 or max_stream_clients < 1:
            raise ValueError("stream timing and client limit must be positive")
        raw_event_dir = Path(event_dir)
        if raw_event_dir.is_symlink():
            raise ValueError("event directory must not be a symlink")
        self.event_dir = raw_event_dir.resolve(strict=True)
        if not self.event_dir.is_dir():
            raise ValueError("event path is not a directory")
        self.reader = EventReader(self.event_dir)
        self.reader_lock = threading.RLock()
        self._index_signature: tuple[tuple[str, int, int, int, int], ...] = ()
        self._index_refresh_in_flight = False
        self._index_refresh_failed_signature: Optional[tuple[tuple[str, int, int, int, int], ...]] = None
        # At most one bounded operator document per validated window. This is
        # enough to survive lazy-reference rotation without retaining raw rows.
        self._operator_documents: dict[str, dict[str, Any]] = {}
        with self.reader_lock:
            self._refresh_index_locked()
        self.poll_interval = poll_interval
        self.heartbeat_interval = heartbeat_interval
        self.max_stream_clients = max_stream_clients
        self.monotonic = monotonic
        self.utc_now = utc_now
        self.repo_root = Path(__file__).resolve().parents[1]
        topology_path = operator_topology_path or self.repo_root / "docs" / "shipyard-data.json"
        self._source_topology_path = Path(topology_path)
        self._source_start_digest = _source_content_digest(
            self.repo_root, self._source_topology_path
        )
        self._track_source_mutations = source_provenance is None
        self._source_provenance_lock = threading.Lock()
        self._source_changed_after_start = False
        self._source_observed_digest = self._source_start_digest
        captured_provenance = source_provenance or capture_source_provenance(
            self.repo_root, self._source_topology_path
        )
        self.source_provenance = {
            "source_revision": captured_provenance.get("source_revision", "unknown"),
            "source_state": captured_provenance.get("source_state", "unknown"),
            "source_digest": captured_provenance.get("source_digest", "unknown"),
        }
        try:
            self.operator_topology = load_presentation_topology(self._source_topology_path)
        except OperatorDataError:
            self.operator_topology = {"roles": [], "skills": [], "edges": []}
        operator_loader = operator_loader or make_expensive_loader(self.repo_root)
        if self._track_source_mutations:
            raw_loader = operator_loader

            def tracked_loader(window: str) -> dict[str, Any]:
                self._observe_source_digest()
                loaded = raw_loader(window)
                self._observe_source_digest()
                return loaded

            operator_loader = tracked_loader
        self.operator_cache = InspectionCache(
            operator_loader,
            monotonic=monotonic,
        )
        self.stream_slots = threading.BoundedSemaphore(max_stream_clients)
        self.stop_event = threading.Event()
        super().__init__((host, port), DashboardRequestHandler)

    def _observe_source_digest(self) -> None:
        current_digest = _source_content_digest(
            self.repo_root, self._source_topology_path
        )
        with self._source_provenance_lock:
            if current_digest != self._source_start_digest:
                self._source_changed_after_start = True
                self._source_observed_digest = current_digest

    def current_source_provenance(self) -> dict[str, str]:
        """Return request-time file truth without Git, a shell, or network I/O."""
        provenance = dict(self.source_provenance)
        if not self._track_source_mutations:
            return provenance
        self._observe_source_digest()
        with self._source_provenance_lock:
            if self._source_changed_after_start:
                provenance["source_state"] = "modified"
                provenance["source_digest"] = self._source_observed_digest
        return provenance

    def _event_signature(self) -> tuple[tuple[str, int, int, int, int], ...]:
        signature = []
        with os.scandir(self.event_dir) as entries:
            for entry in entries:
                if not entry.name.endswith(".jsonl") or entry.is_symlink():
                    continue
                try:
                    info = entry.stat(follow_symlinks=False)
                except OSError:
                    continue
                if stat.S_ISREG(info.st_mode):
                    signature.append((entry.name, info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns))
        return tuple(sorted(signature))

    def _refresh_index_locked(self) -> None:
        before: tuple[tuple[str, int, int, int, int], ...] = ()
        for _ in range(3):
            before = self._event_signature()
            self.reader.refresh()
            after = self._event_signature()
            if before == after:
                self._index_signature = after
                return
        # Keep the pre-refresh signature so a subsequent request observes the
        # final concurrent mutation and retries instead of treating it as read.
        self._index_signature = before

    def _build_replacement_reader(
        self,
    ) -> tuple[EventReader, tuple[tuple[str, int, int, int, int], ...]]:
        before: tuple[tuple[str, int, int, int, int], ...] = ()
        replacement = EventReader(self.event_dir)
        for _ in range(3):
            before = self._event_signature()
            replacement = EventReader(self.event_dir)
            replacement.refresh()
            after = self._event_signature()
            if before == after:
                return replacement, after
        # The reader remains a safe per-file snapshot. Keeping the signature
        # from immediately before its final build makes a later request notice
        # the concurrent mutation and schedule another replacement.
        return replacement, before

    def _refresh_index_in_background(
        self, requested_signature: tuple[tuple[str, int, int, int, int], ...]
    ) -> None:
        try:
            replacement, replacement_signature = self._build_replacement_reader()
        except Exception:
            with self.reader_lock:
                self._index_refresh_in_flight = False
                self._index_refresh_failed_signature = requested_signature
            return
        with self.reader_lock:
            self.reader = replacement
            self._index_signature = replacement_signature
            self._index_refresh_in_flight = False
            self._index_refresh_failed_signature = None

    def refresh_index_if_changed(self) -> None:
        observed_signature = self._event_signature()
        refresh_thread: Optional[threading.Thread] = None
        with self.reader_lock:
            if observed_signature == self._index_signature:
                if not self._index_refresh_in_flight:
                    self._index_refresh_failed_signature = None
                return
            if self._index_refresh_in_flight or observed_signature == self._index_refresh_failed_signature:
                return
            self._index_refresh_in_flight = True
            self._index_refresh_failed_signature = None
            refresh_thread = threading.Thread(
                target=self._refresh_index_in_background,
                args=(observed_signature,),
                name="shipyard-event-index-refresh",
                daemon=True,
            )
        try:
            refresh_thread.start()
        except RuntimeError:
            with self.reader_lock:
                self._index_refresh_in_flight = False
                self._index_refresh_failed_signature = observed_signature

    def index_refresh_limitation(self) -> Optional[str]:
        with self.reader_lock:
            if self._index_refresh_in_flight:
                return "event_index_refreshing"
            if self._index_refresh_failed_signature is not None:
                return "event_index_refresh_failed"
            return None

    def server_close(self) -> None:
        self.stop_event.set()
        super().server_close()


class DashboardRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "ShipyardDashboard/0.1"
    sys_version = ""

    @property
    def dashboard(self) -> DashboardHTTPServer:
        return self.server  # type: ignore[return-value]

    def log_message(self, format: str, *args: Any) -> None:
        sys.stderr.write("dashboard: " + (format % args) + "\n")

    def _headers(self, status: int, content_type: str, length: Optional[int] = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        for key, value in SECURITY_HEADERS.items():
            self.send_header(key, value)
        if length is not None:
            self.send_header("Content-Length", str(length))
        self.end_headers()

    def _json(self, status: int, payload: Any) -> None:
        body = json.dumps(
            payload,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
            allow_nan=False,
        ).encode("utf-8") + b"\n"
        self._headers(status, "application/json; charset=utf-8", len(body))
        self.wfile.write(body)

    def _error(self, status: int, code: str, message: str) -> None:
        self._json(status, {"error": {"code": code, "message": message}})

    def _valid_host(self) -> bool:
        hosts = self.headers.get_all("Host", failobj=[])
        if len(hosts) != 1:
            return False
        value = hosts[0]
        if not value or value.strip() != value or any(char in value for char in "/\\?#@"):
            return False
        if value.count(":") > 1:
            return False
        name, separator, port_text = value.partition(":")
        if name.lower() not in {"localhost", DEFAULT_HOST}:
            return False
        if separator:
            try:
                return parse_port(port_text, allow_zero=False) == self.dashboard.server_port
            except ValueError:
                return False
        return True

    def _validate_request(self) -> bool:
        if not self._valid_host():
            self._error(400, "invalid_host", "Host must be localhost or 127.0.0.1 with the active port")
            return False
        return True

    def do_GET(self) -> None:
        if not self._validate_request():
            return
        parsed = urlsplit(self.path)
        try:
            if parsed.path == "/api/health":
                if parsed.query:
                    raise RequestError(400, "invalid_query", "health does not accept query parameters")
                self._health()
            elif parsed.path == "/api/summary":
                query = _parse_query(parsed.query)
                extras = set(query) - {"window", "limit"}
                if extras or "limit" in dict(parse_qsl(parsed.query, keep_blank_values=True)):
                    raise RequestError(400, "unknown_query_key", "summary accepts only window")
                self._summary(query["window"])
            elif parsed.path == "/api/events":
                self._events(_parse_query(parsed.query))
            elif parsed.path == "/api/operator":
                self._operator(_parse_operator_query(parsed.query))
            elif parsed.path == "/api/stream":
                if parsed.query:
                    raise RequestError(400, "invalid_query", "stream does not accept query parameters")
                self._stream()
            elif parsed.path in STATIC_FILES:
                if parsed.query:
                    raise RequestError(400, "invalid_query", "static assets do not accept query parameters")
                self._static(parsed.path)
            else:
                self._error(404, "not_found", "resource not found")
        except RequestError as exc:
            self._error(exc.status, exc.code, exc.message)
        except StaleReferenceError:
            self._error(409, "stale_index", "event files changed; retry after the index refreshes")
        except (OSError, ValueError):
            self._error(503, "event_store_unavailable", "event directory could not be read")

    def _health(self) -> None:
        self.dashboard.refresh_index_if_changed()
        with self.dashboard.reader_lock:
            reader = self.dashboard.reader
            payload = {
                "schema_version": SCHEMA_VERSION,
                "build_version": BUILD_VERSION,
                "ready": True,
                "row_count": reader.row_count,
                "error_count": reader.error_count,
                "event_directory": str(self.dashboard.event_dir),
                "latest_timestamp": reader.latest_timestamp,
                "host": self.dashboard.server_address[0],
                "port": self.dashboard.server_port,
            }
        self._json(200, payload)

    def _summary(self, window: str) -> None:
        self.dashboard.refresh_index_if_changed()
        with self.dashboard.reader_lock:
            payload = _summary_payload(self.dashboard.reader, window)
        self._json(200, payload)

    def _events(self, query: dict[str, str]) -> None:
        self.dashboard.refresh_index_if_changed()
        with self.dashboard.reader_lock:
            refs = self.dashboard.reader.query_refs(
                window=query["window"],
                project=query.get("project"),
                role=query.get("role"),
                status=query.get("status"),
                event_family=query.get("event"),
                limit=int(query["limit"]),
            )
            events = []
            for ref in refs:
                events.append(self.dashboard.reader.read_event(ref))
        self._json(
            200,
            {"window": query["window"], "limit": int(query["limit"]), "count": len(events), "events": events},
        )

    def _operator(self, window: str) -> None:
        self.dashboard.refresh_index_if_changed()
        cached_payload: Optional[dict[str, Any]] = None
        with self.dashboard.reader_lock:
            index_refresh_limitation = self.dashboard.index_refresh_limitation()
            if index_refresh_limitation is not None:
                cached_payload = self.dashboard._operator_documents.get(window)
        if cached_payload is not None:
            self._json(200, _with_event_index_limitation(cached_payload, index_refresh_limitation))
            return
        with self.dashboard.reader_lock:
            index_refresh_limitation = self.dashboard.index_refresh_limitation()
            reader = self.dashboard.reader
            try:
                summary = _summary_payload(
                    reader, window, service_limit=MAX_RUNTIME_IDENTITIES
                )
                refs = reader.query_refs(window=window, limit=MAX_LIMIT)
                events = [reader.read_event(ref) for ref in refs]
                runtime_events = _runtime_lifecycle_events(reader, window, summary)
                event_stream_truncated = len(refs) == MAX_LIMIT
                delivery_events = (
                    _delivery_lifecycle_events(reader, window, refs)
                    if event_stream_truncated
                    else DeliveryLifecycleEvents([], [])
                )
            except StaleReferenceError:
                cached_payload = self.dashboard._operator_documents.get(window)
                if cached_payload is None:
                    raise
        if cached_payload is not None:
            self._json(200, _with_event_index_limitation(cached_payload, index_refresh_limitation))
            return
        snapshot = self.dashboard.operator_cache.get(window)
        cached = snapshot.data or {}
        inspection = cached.get("inspection")
        changes, change_limitations = collect_change_metrics(events, inspection)
        payload = compose_operator_document(
            window=window,
            generated_at=self.dashboard.utc_now(),
            summary=summary,
            events=events,
            inspection=inspection,
            relationships=cached.get("relationships"),
            topology=self.dashboard.operator_topology,
            inspection_state=snapshot.state,
            refresh_age_seconds=snapshot.age_seconds,
            refresh_limitation=snapshot.limitation,
            event_stream_truncated=event_stream_truncated,
            runtime_events=runtime_events,
            runtime_limitations=runtime_events.limitations,
            delivery_events=delivery_events,
            delivery_limitations=delivery_events.limitations,
            source_provenance=self.dashboard.current_source_provenance(),
            changes=changes,
            change_limitations=change_limitations,
        )
        with self.dashboard.reader_lock:
            if self.dashboard.reader is reader:
                self.dashboard._operator_documents[window] = payload
        self._json(200, _with_event_index_limitation(payload, index_refresh_limitation))

    def _static(self, request_path: str) -> None:
        name, content_type = STATIC_FILES[request_path]
        path = STATIC_DIR / name
        try:
            if path.is_symlink():
                raise OSError("static asset is a symlink")
            flags = os.O_RDONLY
            if hasattr(os, "O_CLOEXEC"):
                flags |= os.O_CLOEXEC
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            descriptor = os.open(path, flags)
            try:
                info = os.fstat(descriptor)
                if not stat.S_ISREG(info.st_mode):
                    raise OSError("static asset is not a regular file")
                body = b""
                while len(body) < info.st_size:
                    chunk = os.read(descriptor, info.st_size - len(body))
                    if not chunk:
                        break
                    body += chunk
            finally:
                os.close(descriptor)
        except OSError:
            self._error(404, "not_found", "resource not found")
            return
        self._headers(200, content_type, len(body))
        self.wfile.write(body)

    def _stream(self) -> None:
        if not self.dashboard.stream_slots.acquire(blocking=False):
            self._error(
                503,
                "stream_capacity",
                f"at most {self.dashboard.max_stream_clients} stream clients may connect",
            )
            return
        try:
            state = TailState()
            self._tail_rows(state)
            self._headers(200, "text/event-stream; charset=utf-8")
            self.wfile.flush()
            last_write = self.dashboard.monotonic()
            while not self.dashboard.stop_event.wait(self.dashboard.poll_interval):
                if self._client_disconnected():
                    break
                rows = self._tail_rows(state)
                now = self.dashboard.monotonic()
                if rows:
                    for row in rows:
                        self.wfile.write(b"event: shipyard\n")
                        self.wfile.write(b"data: " + row + b"\n\n")
                    self.wfile.flush()
                    last_write = now
                elif now - last_write >= self.dashboard.heartbeat_interval:
                    self.wfile.write(b": heartbeat\n\n")
                    self.wfile.flush()
                    last_write = now
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, socket.timeout):
            pass
        finally:
            self.close_connection = True
            self.dashboard.stream_slots.release()

    def _client_disconnected(self) -> bool:
        try:
            readable, _, _ = select.select([self.connection], [], [], 0)
            if not readable:
                return False
            return self.connection.recv(1, socket.MSG_PEEK) == b""
        except (BlockingIOError, InterruptedError):
            return False
        except OSError:
            return True

    def _tail_rows(self, state: TailState) -> list[bytes]:
        current = self.dashboard.utc_now().astimezone(timezone.utc).strftime("%Y-%m-%d.jsonl")
        path = self.dashboard.event_dir / current
        flags = os.O_RDONLY
        if hasattr(os, "O_CLOEXEC"):
            flags |= os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor: Optional[int] = None
        try:
            descriptor = os.open(path, flags)
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode):
                os.close(descriptor)
                descriptor = None
                return []
        except OSError:
            if descriptor is not None:
                os.close(descriptor)
            state.path = path
            state.identity = None
            state.offset = 0
            state.remainder = b""
            state.checkpoint_start = 0
            state.checkpoint = b""
            state.initialized = True
            return []
        try:
            identity = (info.st_dev, info.st_ino)
            changed = state.path != path or state.identity != identity or info.st_size < state.offset
            if not state.initialized:
                state.path = path
                state.identity = identity
                state.offset = info.st_size
                state.remainder = b""
                state.initialized = True
                state.checkpoint_start = max(0, state.offset - 64)
                if state.offset:
                    state.checkpoint = _read_at(
                        descriptor, state.checkpoint_start, state.offset - state.checkpoint_start
                    )
                return []
            if not changed and state.checkpoint:
                changed = _read_at(descriptor, state.checkpoint_start, len(state.checkpoint)) != state.checkpoint
            if changed:
                state.path = path
                state.identity = identity
                state.offset = 0
                state.remainder = b""
            if info.st_size <= state.offset:
                return []
            appended = _read_at(descriptor, state.offset, info.st_size - state.offset)
            state.offset += len(appended)
            chunks = (state.remainder + appended).split(b"\n")
            state.remainder = chunks.pop()
            state.checkpoint_start = max(0, state.offset - 64)
            state.checkpoint = _read_at(descriptor, state.checkpoint_start, state.offset - state.checkpoint_start)
        finally:
            os.close(descriptor)
        rows = []
        for raw in chunks:
            try:
                value = json.loads(raw, parse_constant=_reject_json_constant)
            except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
                continue
            if isinstance(value, dict):
                rows.append(
                    json.dumps(
                        value,
                        sort_keys=True,
                        separators=(",", ":"),
                        ensure_ascii=True,
                        allow_nan=False,
                    ).encode("utf-8")
                )
        return rows

    def _mutation(self) -> None:
        if not self._validate_request():
            return
        self.send_response(HTTPStatus.METHOD_NOT_ALLOWED)
        self.send_header("Allow", "GET")
        body = json.dumps(
            {"error": {"code": "method_not_allowed", "message": "dashboard endpoints are read-only"}},
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
            allow_nan=False,
        ).encode("utf-8") + b"\n"
        self.send_header("Content-Type", "application/json; charset=utf-8")
        for key, value in SECURITY_HEADERS.items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    do_POST = _mutation
    do_PUT = _mutation
    do_PATCH = _mutation
    do_DELETE = _mutation
    do_OPTIONS = _mutation
    do_HEAD = _mutation


def write_port_file(path: Path, port: int) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        os.write(descriptor, f"{port}\n".encode("ascii"))
    finally:
        os.close(descriptor)


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--events-dir")
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", default=os.environ.get("SHIPYARD_DASHBOARD_PORT", str(DEFAULT_PORT)))
    parser.add_argument("--port-file", type=Path)
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    parser = make_parser()
    args = parser.parse_args(argv)
    try:
        host = validate_bind_host(args.host)
        port = parse_port(args.port)
        event_dir = resolve_events_dir(args.events_dir)
    except ValueError as exc:
        parser.error(str(exc))
    server = DashboardHTTPServer((host, port), event_dir)
    print(f"events_dir={event_dir}", flush=True)
    print(f"listen=http://{host}:{server.server_port}", flush=True)
    if args.port_file is not None:
        try:
            write_port_file(args.port_file, server.server_port)
        except OSError as exc:
            server.server_close()
            parser.error(f"could not write port file: {exc}")
    try:
        server.serve_forever(poll_interval=0.1)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
