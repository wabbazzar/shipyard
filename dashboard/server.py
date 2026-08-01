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
import json
import os
import re
import select
import socket
import stat
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
    InspectionCache,
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


def _summary_payload(reader: EventReader, window: str) -> dict[str, Any]:
    summary = reader.summarize(window=window)
    services = [
        {
            "project": item.project,
            "role": item.role,
            "svc": item.svc,
            "state": item.state,
            "last_activity": item.last_activity,
            "terminal_status": item.terminal_status,
            "duration_s": item.duration_s,
            **_reference_location(reader, item.reference),
        }
        for item in summary["services"]
    ]
    actionables = []
    for item in summary["actionables"]:
        row = reader.read_event(item.reference)
        payload = {"kind": item.kind, "key": item.key, "event": row, **_reference_location(reader, item.reference)}
        if item.identity is not None:
            payload["identity"] = dict(zip(("project", "role", "svc"), item.identity))
        actionables.append(payload)
    return {
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
        with self.reader_lock:
            self._refresh_index_locked()
        self.poll_interval = poll_interval
        self.heartbeat_interval = heartbeat_interval
        self.max_stream_clients = max_stream_clients
        self.monotonic = monotonic
        self.utc_now = utc_now
        self.repo_root = Path(__file__).resolve().parents[1]
        topology_path = operator_topology_path or self.repo_root / "docs" / "shipyard-data.json"
        try:
            self.operator_topology = load_presentation_topology(topology_path)
        except OperatorDataError:
            self.operator_topology = {"roles": [], "skills": [], "edges": []}
        self.operator_cache = InspectionCache(
            operator_loader or make_expensive_loader(self.repo_root),
            monotonic=monotonic,
        )
        self.stream_slots = threading.BoundedSemaphore(max_stream_clients)
        self.stop_event = threading.Event()
        super().__init__((host, port), DashboardRequestHandler)

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

    def refresh_index_if_changed(self) -> None:
        with self.reader_lock:
            if self._event_signature() != self._index_signature:
                self._refresh_index_locked()

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
        with self.dashboard.reader_lock:
            summary = _summary_payload(self.dashboard.reader, window)
            refs = self.dashboard.reader.query_refs(window=window, limit=MAX_LIMIT)
            events = [self.dashboard.reader.read_event(ref) for ref in refs]
            event_stream_truncated = len(refs) == MAX_LIMIT
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
            changes=changes,
            change_limitations=change_limitations,
        )
        self._json(200, payload)

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
