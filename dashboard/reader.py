"""Bounded, read-only indexing for Shipyard's daily JSONL event stream.

The index retains compact normalized metadata and byte offsets, not decoded
event dictionaries.  Raw rows are reopened and decoded only when requested.
"""

from __future__ import annotations

import json
import math
import os
import stat
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Iterator, Mapping, Optional


WINDOW_SECONDS = {"24h": 24 * 60 * 60, "7d": 7 * 24 * 60 * 60, "30d": 30 * 24 * 60 * 60}
DEFAULT_LIMIT = 500
MAX_LIMIT = 2_000
DEFAULT_STALE_SECONDS = 7_200


class StaleReferenceError(RuntimeError):
    """Raised when a source file changed after its reference was indexed."""


@dataclass(frozen=True)
class EventRef:
    """Compact location and normalized filter fields for one valid row."""

    __slots__ = (
        "generation", "timestamp_us", "file_id", "byte_offset", "byte_length", "project", "role",
        "svc", "event", "status", "duration_s", "correlation_key", "correlation_label",
        "action_code",
    )

    generation: int
    timestamp_us: int
    file_id: int
    byte_offset: int
    byte_length: int
    project: str
    role: str
    svc: str
    event: str
    status: str
    duration_s: Optional[float | int]
    correlation_key: str
    correlation_label: str
    action_code: int


@dataclass(frozen=True)
class ParseProblem:
    __slots__ = ("file", "byte_offset", "message")

    file: str
    byte_offset: int
    message: str


@dataclass(frozen=True)
class IndexedFile:
    __slots__ = ("name", "path", "device", "inode", "size")

    name: str
    path: Path
    device: int
    inode: int
    size: int


@dataclass(frozen=True)
class ServiceState:
    __slots__ = (
        "project", "role", "svc", "state", "last_activity", "terminal_status",
        "duration_s", "reference",
    )

    project: str
    role: str
    svc: str
    state: str
    last_activity: str
    terminal_status: Optional[str]
    duration_s: Optional[float]
    reference: EventRef


@dataclass(frozen=True)
class ActionableItem:
    __slots__ = ("kind", "key", "reference", "identity")

    kind: str
    key: str
    reference: EventRef
    identity: Optional[tuple[str, str, str]]


class _ServiceIdentityResolver:
    """Resolve only unambiguous missing projects for derived service identity."""

    __slots__ = ("_projects",)

    def __init__(self, references: Iterable[EventRef]):
        projects: dict[tuple[str, str], Optional[str]] = {}
        for reference in references:
            if not reference.project:
                continue
            key = (reference.role, reference.svc)
            if key not in projects:
                projects[key] = reference.project
            elif projects[key] != reference.project:
                projects[key] = None
        self._projects = projects

    def key(self, reference: EventRef) -> tuple[str, str, str]:
        project = reference.project
        if not project:
            project = self._projects.get((reference.role, reference.svc)) or ""
        return (project, reference.role, reference.svc)


def _timestamp_us(value: Any) -> int:
    if not isinstance(value, str) or not value:
        raise ValueError("missing or non-string ts")
    text = value[:-1] + "+00:00" if value.endswith("Z") else value
    parsed = datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        raise ValueError("ts must include a timezone")
    utc = parsed.astimezone(timezone.utc)
    epoch = datetime(1970, 1, 1, tzinfo=timezone.utc)
    delta = utc - epoch
    return ((delta.days * 86_400 + delta.seconds) * 1_000_000) + delta.microseconds


def _timestamp_text(timestamp_us: int) -> str:
    seconds, micros = divmod(timestamp_us, 1_000_000)
    value = datetime.fromtimestamp(seconds, timezone.utc).replace(microsecond=micros)
    if micros:
        return value.isoformat(timespec="microseconds").replace("+00:00", "Z")
    return value.isoformat(timespec="seconds").replace("+00:00", "Z")


def _now_us(now: Optional[datetime | str]) -> int:
    if now is None:
        current = datetime.now(timezone.utc)
        return _timestamp_us(current.isoformat())
    if isinstance(now, datetime):
        if now.tzinfo is None:
            raise ValueError("now must include a timezone")
        return _timestamp_us(now.isoformat())
    return _timestamp_us(now)


def _text(event: Mapping[str, Any], field: str) -> str:
    value = event.get(field)
    return sys.intern(value) if isinstance(value, str) else ""


def _reject_json_constant(value: str) -> Any:
    raise ValueError(f"non-standard JSON constant: {value}")


def _decode_event(raw: bytes) -> dict[str, Any]:
    decoded = json.loads(raw, parse_constant=_reject_json_constant)
    if not isinstance(decoded, dict):
        raise ValueError("JSON row is not an object")
    return decoded


class EventReader:
    """Snapshot and query a directory of newline-delimited event files."""

    def __init__(self, event_dir: os.PathLike[str] | str, *, stale_seconds: int = DEFAULT_STALE_SECONDS):
        self.event_dir = Path(event_dir)
        if stale_seconds < 0:
            raise ValueError("stale_seconds must be non-negative")
        self.stale_seconds = stale_seconds
        self.files: list[IndexedFile] = []
        self.references: list[EventRef] = []
        self.problems: list[ParseProblem] = []
        self.incomplete_tails: list[tuple[str, int]] = []
        self.latest_timestamp: Optional[str] = None
        self._generation = 0

    @property
    def row_count(self) -> int:
        return len(self.references)

    @property
    def error_count(self) -> int:
        return len(self.problems)

    def _open_snapshot(self, path: Path) -> tuple[int, os.stat_result]:
        flags = os.O_RDONLY
        if hasattr(os, "O_CLOEXEC"):
            flags |= os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags)
        try:
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode):
                raise OSError(f"not a regular file: {path.name}")
            return descriptor, info
        except BaseException:
            os.close(descriptor)
            raise

    def _event_paths(self) -> list[Path]:
        if not self.event_dir.exists():
            return []
        paths = []
        with os.scandir(self.event_dir) as entries:
            for entry in entries:
                if not entry.name.endswith(".jsonl") or entry.is_symlink():
                    continue
                try:
                    if entry.is_file(follow_symlinks=False):
                        paths.append(Path(entry.path))
                except OSError:
                    continue
        return sorted(paths, key=lambda path: path.name)

    def refresh(self) -> "EventReader":
        """Rebuild from a stable size snapshot of each file.

        Bytes appended after a file is opened are intentionally left for the
        next refresh. Rotation and truncation therefore cannot mix generations.
        """

        files: list[IndexedFile] = []
        references: list[EventRef] = []
        problems: list[ParseProblem] = []
        incomplete: list[tuple[str, int]] = []
        generation = self._generation + 1

        for path in self._event_paths():
            try:
                descriptor, info = self._open_snapshot(path)
            except OSError as exc:
                problems.append(ParseProblem(path.name, 0, f"open failed: {exc.strerror or exc}"))
                continue
            file_id = len(files)
            files.append(IndexedFile(path.name, path, info.st_dev, info.st_ino, info.st_size))
            offset = 0
            remaining = info.st_size
            try:
                with os.fdopen(descriptor, "rb", closefd=True) as source:
                    while remaining:
                        row = source.readline(remaining)
                        if not row:
                            incomplete.append((path.name, offset))
                            break
                        row_offset = offset
                        offset += len(row)
                        remaining -= len(row)
                        if not row.endswith(b"\n"):
                            incomplete.append((path.name, row_offset))
                            break
                        try:
                            decoded = _decode_event(row)
                            ts_us = _timestamp_us(decoded.get("ts"))
                        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
                            problems.append(ParseProblem(path.name, row_offset, str(exc)))
                            continue
                        event_name = _text(decoded, "event")
                        correlation_key = ""
                        correlation_label = ""
                        action_code = 0
                        project = _text(decoded, "project")
                        role = _text(decoded, "role")
                        svc = _text(decoded, "svc")
                        raw_duration = decoded.get("duration_s")
                        duration = (
                            raw_duration
                            if isinstance(raw_duration, (int, float))
                            and not isinstance(raw_duration, bool)
                            and math.isfinite(raw_duration)
                            else None
                        )
                        scope = f"project:{project}" if project else f"service:{role}\x1f{svc}"
                        if "incident" in event_name:
                            incident_id = decoded.get("incident_id")
                            if isinstance(incident_id, str) and incident_id:
                                correlation_label = sys.intern(incident_id)
                                correlation_key = sys.intern(f"{scope}\x1eincident:{incident_id}")
                                resolved = (
                                    event_name.endswith((".resolved", ".closed", ".recovered"))
                                    or decoded.get("status") in {"ok", "resolved", "closed"}
                                    or decoded.get("outcome") in {"resolved", "closed", "recovered"}
                                )
                                action_code = 2 if resolved else 1
                        elif event_name == "notification.decision":
                            episode = decoded.get("episode")
                            alert_class = decoded.get("class")
                            outcome = decoded.get("outcome")
                            if isinstance(episode, str) and alert_class in {"actionable", "urgent"}:
                                if episode:
                                    correlation_label = sys.intern(episode)
                                    correlation_key = sys.intern(f"{scope}\x1eepisode:{episode}")
                                elif outcome == "delivered":
                                    correlation_label = sys.intern(f"@{path.name}:{row_offset}")
                                    correlation_key = sys.intern(f"{scope}\x1eunmatched:{path.name}:{row_offset}")
                                if outcome == "delivered":
                                    action_code = 3
                                elif episode and outcome in {"deduped", "resolved"}:
                                    action_code = 4
                        references.append(
                            EventRef(
                                generation,
                                ts_us,
                                file_id,
                                row_offset,
                                len(row),
                                project,
                                role,
                                svc,
                                event_name,
                                _text(decoded, "status"),
                                duration,
                                correlation_key,
                                correlation_label,
                                action_code,
                            )
                        )
            except OSError as exc:
                problems.append(ParseProblem(path.name, offset, f"read failed: {exc.strerror or exc}"))

        references.sort(
            key=lambda ref: (ref.timestamp_us, files[ref.file_id].name, ref.byte_offset),
            reverse=True,
        )
        self.files = files
        self.references = references
        self.problems = problems
        self.incomplete_tails = incomplete
        self.latest_timestamp = _timestamp_text(references[0].timestamp_us) if references else None
        self._generation = generation
        return self

    def _window_refs(self, window: str, now: Optional[datetime | str]) -> Iterator[EventRef]:
        try:
            width_us = WINDOW_SECONDS[window] * 1_000_000
        except KeyError as exc:
            raise ValueError(f"unsupported window: {window}") from exc
        end_us = _now_us(now)
        start_us = end_us - width_us
        for ref in self.references:
            if ref.timestamp_us >= end_us:
                continue
            if ref.timestamp_us < start_us:
                break
            yield ref

    def filename(self, reference: EventRef) -> str:
        return self.files[reference.file_id].name

    def order_key(self, reference: EventRef) -> tuple[int, str, int]:
        return (reference.timestamp_us, self.filename(reference), reference.byte_offset)

    def query_refs(
        self,
        *,
        window: str = "7d",
        project: Optional[str] = None,
        role: Optional[str] = None,
        status: Optional[str] = None,
        event_family: Optional[str] = None,
        limit: int = DEFAULT_LIMIT,
        now: Optional[datetime | str] = None,
    ) -> list[EventRef]:
        if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= MAX_LIMIT:
            raise ValueError(f"limit must be between 1 and {MAX_LIMIT}")
        matches: list[EventRef] = []
        for ref in self._window_refs(window, now):
            if project is not None and ref.project != project:
                continue
            if role is not None and ref.role != role:
                continue
            if status is not None and ref.status != status:
                continue
            if event_family is not None and not (
                ref.event == event_family or ref.event.startswith(event_family + ".")
            ):
                continue
            matches.append(ref)
            if len(matches) == limit:
                break
        return matches

    def read_event(self, reference: EventRef) -> dict[str, Any]:
        if reference.generation != self._generation:
            raise StaleReferenceError("event reference belongs to an earlier index generation")
        indexed = self.files[reference.file_id]
        descriptor, current = self._open_snapshot(indexed.path)
        try:
            if (current.st_dev, current.st_ino) != (indexed.device, indexed.inode):
                raise StaleReferenceError(f"event file rotated: {indexed.name}")
            if current.st_size < reference.byte_offset + reference.byte_length:
                raise StaleReferenceError(f"event file truncated: {indexed.name}")
            os.lseek(descriptor, reference.byte_offset, os.SEEK_SET)
            chunks = []
            remaining = reference.byte_length
            while remaining:
                chunk = os.read(descriptor, remaining)
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            raw = b"".join(chunks)
        finally:
            os.close(descriptor)
        if len(raw) != reference.byte_length or not raw.endswith(b"\n"):
            raise StaleReferenceError(f"event row changed: {indexed.name}:{reference.byte_offset}")
        try:
            decoded = _decode_event(raw)
            timestamp_us = _timestamp_us(decoded.get("ts"))
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            raise StaleReferenceError(
                f"event row changed: {indexed.name}:{reference.byte_offset}"
            ) from exc
        if timestamp_us != reference.timestamp_us:
            raise StaleReferenceError(f"event row changed: {indexed.name}:{reference.byte_offset}")
        return decoded

    def query_events(self, **filters: Any) -> list[dict[str, Any]]:
        return [self.read_event(ref) for ref in self.query_refs(**filters)]

    def summarize(self, *, window: str = "7d", now: Optional[datetime | str] = None) -> dict[str, Any]:
        end_us = _now_us(now)
        refs = list(self._window_refs(window, now))
        identity = _ServiceIdentityResolver(refs)
        lifecycle_keys = {
            identity.key(ref) for ref in refs if ref.event in {"job.start", "job.end"}
        }
        activity: dict[tuple[str, str, str], EventRef] = {}
        start_or_end: dict[tuple[str, str, str], EventRef] = {}
        terminals: dict[tuple[str, str, str], EventRef] = {}

        for ref in refs:
            key = identity.key(ref)
            if key not in lifecycle_keys:
                continue
            activity.setdefault(key, ref)
            if ref.event in {"job.start", "job.end"}:
                start_or_end.setdefault(key, ref)
            if ref.event == "job.end":
                terminals.setdefault(key, ref)

        states: list[ServiceState] = []
        counts = {"healthy": 0, "running": 0, "stale": 0, "failed": 0, "actionable": 0}
        for key in sorted(activity):
            activity_ref = activity[key]
            lifecycle = start_or_end.get(key)
            terminal = terminals.get(key)
            state = "unknown"
            if lifecycle is not None and lifecycle.event == "job.start":
                age_us = end_us - lifecycle.timestamp_us
                state = "stale" if age_us > self.stale_seconds * 1_000_000 else "running"
            elif terminal is not None and terminal.status == "fail":
                state = "failed"
            elif terminal is not None and terminal.status == "ok":
                state = "healthy"
            if state in counts:
                counts[state] += 1
            duration: Optional[float] = None
            terminal_status: Optional[str] = None
            evidence = lifecycle or terminal or activity_ref
            if terminal is not None:
                terminal_status = terminal.status or None
                if terminal.duration_s is not None:
                    duration = float(terminal.duration_s)
            states.append(
                ServiceState(
                    key[0], key[1], key[2], state, _timestamp_text(activity_ref.timestamp_us),
                    terminal_status, duration, evidence,
                )
            )

        actionables = self._actionables(reversed(refs), identity)
        counts["actionable"] = len(actionables)
        return {
            "counts": counts,
            "latest_timestamp": _timestamp_text(refs[0].timestamp_us) if refs else None,
            "services": states,
            "actionables": actionables,
        }

    def _actionables(
        self, chronological: Iterable[EventRef], identity: _ServiceIdentityResolver
    ) -> list[ActionableItem]:
        active: dict[tuple[str, str], ActionableItem] = {}
        for ref in chronological:
            if ref.event == "job.end":
                service_identity = identity.key(ref)
                service_key = "\x1f".join(service_identity)
                key = ("failure", service_key)
                if ref.status == "fail":
                    active[key] = ActionableItem("failure", service_key, ref, service_identity)
                else:
                    active.pop(key, None)
                continue

            if ref.action_code in {1, 2}:
                key = ("incident", ref.correlation_key)
                if ref.action_code == 2:
                    active.pop(key, None)
                else:
                    active[key] = ActionableItem("incident", ref.correlation_label, ref, None)
                continue

            if ref.action_code in {3, 4}:
                key = ("notification", ref.correlation_key)
                if ref.action_code == 3:
                    active[key] = ActionableItem("notification", ref.correlation_label, ref, None)
                else:
                    active.pop(key, None)

        return sorted(active.values(), key=lambda item: self.order_key(item.reference), reverse=True)
