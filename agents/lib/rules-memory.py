#!/usr/bin/env python3
"""Shipyard-owned Phase-1 project rules-ledger contract and CLI.

The project owns only .agents/config.toml and its JSONL ledger. This helper
owns parsing, validation, canonicalization, and machine-readable diagnostics.
It deliberately has no model, network, index, or project-specific dependency.
"""

from __future__ import annotations

import argparse
import datetime as dt
import errno
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
from typing import Any

try:
    import tomllib
except ImportError:  # pragma: no cover - Shipyard requires Python 3.11+
    import tomli as tomllib  # type: ignore[no-redef]


SCHEMA_VERSION = 1
DEFAULT_LEDGER = ".agents/rules-ledger.jsonl"
DEFAULTS: dict[str, Any] = {
    "ledger": DEFAULT_LEDGER,
    "vector_backend": "stdlib-hash-ngram-v1",
    "max_channel_candidates": 20,
    "max_fused_candidates": 12,
    "max_prompt_records": 8,
}
MEMORY_KEYS = {"mode", *DEFAULTS}
RECORD_KEYS = {
    "schema_version",
    "id",
    "occurred_at",
    "kind",
    "severity",
    "status",
    "summary",
    "mechanism",
    "rule",
    "required_evidence",
    "associations",
    "remediation",
    "sources",
    "supersedes",
}
REQUIRED_RECORD_KEYS = RECORD_KEYS - {"supersedes"}
ASSOCIATION_KEYS = {
    "paths",
    "symbols",
    "subsystems",
    "phases",
    "state_transitions",
    "error_signatures",
    "technologies",
    "tags",
}
SOURCE_KEYS = {"kind", "ref"}
ID_RE = re.compile(r"^[A-Z][A-Z0-9_-]{1,63}$")
UTC_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z$"
)
MAX_LEDGER_BYTES = 32 * 1024 * 1024
MAX_LINE_BYTES = 256 * 1024
MAX_RECORDS = 10_000
MAX_PROSE = 2_048
MAX_INERT = 256
MAX_ASSOCIATIONS = 64
MAX_SOURCES = 16
PROSE_FIELDS = (
    "summary",
    "mechanism",
    "rule",
    "required_evidence",
    "remediation",
)
# Keep these content signatures exactly aligned with scripts/leak-check.sh.
# The ledger validator cannot invoke that repository-scoped Git scanner against
# arbitrary project files, so the shared contract is mirrored deliberately.
SECRET_PATTERNS = (
    re.compile(r"\+1(?!555)[0-9]{9}"),
    re.compile(r"/home/(?!user\b|\.local)[a-z][a-z0-9_-]+"),
    re.compile(r"[a-zA-Z0-9._%+-]+@(gmail|yahoo|outlook|icloud|proton|hotmail)\.[a-z]+"),
    re.compile(r"[a-z0-9-]+\.ts\.net"),
    re.compile(r"sk-ant-[A-Za-z0-9_-]{8,}"),
    re.compile(r"sk-[A-Za-z0-9]{32,}"),
    re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"),
    re.compile(r"-----BEGIN[ A-Z]*PRIVATE KEY-----"),
    re.compile(r"sourceUuid.{0,40}[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"),
)


class Diagnostics:
    def __init__(self) -> None:
        self.errors: list[dict[str, Any]] = []

    def add(
        self,
        code: str,
        message: str,
        *,
        line: int | None = None,
        record_id: str | None = None,
    ) -> None:
        self.errors.append(
            {
                "code": code,
                "line": line,
                "message": message,
                "record_id": record_id,
            }
        )


def emit(document: dict[str, Any]) -> None:
    print(json.dumps(document, ensure_ascii=False, separators=(",", ":"), sort_keys=True))


def base_document(command: str, root: Path) -> dict[str, Any]:
    return {
        "active_count": 0,
        "command": command,
        "configured": False,
        "errors": [],
        "ledger_digest": None,
        "ledger_path": None,
        "mode": None,
        "project_root": str(root),
        "record_count": 0,
        "schema_version": SCHEMA_VERSION,
        "state": "off",
        "superseded_count": 0,
        "valid": True,
    }


def safe_relative_path(value: Any, *, allow_glob: bool = False) -> bool:
    if not isinstance(value, str) or not value or len(value) > MAX_INERT:
        return False
    if "\x00" in value or "\\" in value or value.startswith("/"):
        return False
    if value.startswith("./") or "//" in value:
        return False
    parts = PurePosixPath(value).parts
    if not parts or any(part in {"", ".", ".."} for part in parts):
        return False
    if not allow_glob and any(char in value for char in "*?[]"):
        return False
    return True


def contained_path(root: Path, relative: str) -> Path | None:
    try:
        candidate = (root / relative).resolve(strict=False)
        candidate.relative_to(root)
    except (OSError, ValueError):
        return None
    return candidate


def has_lone_surrogate(value: Any) -> bool:
    """Reject any JSON string Python could not encode as valid UTF-8."""
    pending = [value]
    while pending:
        current = pending.pop()
        if isinstance(current, str):
            if any(0xD800 <= ord(char) <= 0xDFFF for char in current):
                return True
        elif isinstance(current, dict):
            pending.extend(current.keys())
            pending.extend(current.values())
        elif isinstance(current, list):
            pending.extend(current)
    return False


def parse_memory_config(
    root: Path, diagnostics: Diagnostics
) -> tuple[bool, dict[str, Any] | None]:
    config_path = root / ".agents" / "config.toml"
    if not config_path.is_file():
        return False, None
    try:
        with config_path.open("rb") as source:
            config = tomllib.load(source)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        diagnostics.add("config_parse_error", f"cannot parse .agents/config.toml: {exc}")
        return True, None
    if "memory" not in config:
        return False, None
    memory = config["memory"]
    if not isinstance(memory, dict):
        diagnostics.add("config_memory_type", "[memory] must be a TOML table")
        return True, None

    for key in sorted(set(memory) - MEMORY_KEYS):
        diagnostics.add("config_unknown_key", f"unknown [memory] key: {key}")
    mode = memory.get("mode")
    if not isinstance(mode, str) or mode not in {"advisory", "required"}:
        diagnostics.add("config_mode", "[memory].mode must be advisory or required")
    ledger = memory.get("ledger", DEFAULTS["ledger"])
    if not safe_relative_path(ledger):
        diagnostics.add("unsafe_ledger_path", "[memory].ledger must be a safe project-relative POSIX path")
    else:
        lexical_ledger = root / ledger
        if lexical_ledger.is_symlink():
            diagnostics.add("ledger_symlink", "ledger must not be a symbolic link")
        elif contained_path(root, ledger) is None:
            diagnostics.add("unsafe_ledger_path", "[memory].ledger resolves outside the project")
    backend = memory.get("vector_backend", DEFAULTS["vector_backend"])
    if backend != "stdlib-hash-ngram-v1":
        diagnostics.add("config_vector_backend", "unsupported [memory].vector_backend")

    bounds = {
        "max_channel_candidates": memory.get(
            "max_channel_candidates", DEFAULTS["max_channel_candidates"]
        ),
        "max_fused_candidates": memory.get(
            "max_fused_candidates", DEFAULTS["max_fused_candidates"]
        ),
        "max_prompt_records": memory.get("max_prompt_records", DEFAULTS["max_prompt_records"]),
    }
    for key, value in bounds.items():
        if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 10_000:
            diagnostics.add("config_bound", f"[memory].{key} must be an integer from 1 to 10000")
    if all(isinstance(value, int) and not isinstance(value, bool) for value in bounds.values()):
        if bounds["max_fused_candidates"] > bounds["max_channel_candidates"] * 3:
            diagnostics.add(
                "config_bound_order",
                "max_fused_candidates cannot exceed three retrieval channels",
            )
        if bounds["max_prompt_records"] > bounds["max_fused_candidates"]:
            diagnostics.add(
                "config_bound_order",
                "max_prompt_records cannot exceed max_fused_candidates",
            )
    effective = {**DEFAULTS, **memory}
    return True, effective


def valid_utc_timestamp(value: Any) -> bool:
    if not isinstance(value, str) or not UTC_RE.fullmatch(value):
        return False
    try:
        parsed = dt.datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        return False
    return parsed.utcoffset() == dt.timedelta(0)


def has_secret_shape(value: str) -> bool:
    return any(pattern.search(value) for pattern in SECRET_PATTERNS)


def validate_record(
    record: dict[str, Any], line: int, diagnostics: Diagnostics
) -> str | None:
    record_id = record.get("id") if isinstance(record.get("id"), str) else None
    unknown = sorted(set(record) - RECORD_KEYS)
    missing = sorted(REQUIRED_RECORD_KEYS - set(record))
    for key in unknown:
        diagnostics.add("unknown_key", f"unknown record key: {key}", line=line, record_id=record_id)
    for key in missing:
        diagnostics.add("missing_key", f"missing required record key: {key}", line=line, record_id=record_id)

    if type(record.get("schema_version")) is not int or record.get("schema_version") != SCHEMA_VERSION:
        diagnostics.add("schema_version", "schema_version must equal 1", line=line, record_id=record_id)
    if record_id is None or not ID_RE.fullmatch(record_id):
        diagnostics.add("invalid_id", "id must match [A-Z][A-Z0-9_-]{1,63}", line=line, record_id=record_id)
    if not valid_utc_timestamp(record.get("occurred_at")):
        diagnostics.add("invalid_occurred_at", "occurred_at must be RFC 3339 UTC", line=line, record_id=record_id)
    enum_fields = {
        "kind": {"incident", "regression", "near_miss", "decision"},
        "severity": {"note", "warn", "block"},
        "status": {"active", "superseded"},
    }
    for field, choices in enum_fields.items():
        value = record.get(field)
        if not isinstance(value, str) or value not in choices:
            diagnostics.add(
                f"invalid_{field}",
                f"{field} must be one of {','.join(sorted(choices))}",
                line=line,
                record_id=record_id,
            )
    for field in PROSE_FIELDS:
        value = record.get(field)
        if not isinstance(value, str) or not value.strip() or "\x00" in value:
            diagnostics.add("invalid_prose", f"{field} must be non-empty text", line=line, record_id=record_id)
        elif len(value) > MAX_PROSE:
            diagnostics.add("prose_too_long", f"{field} exceeds {MAX_PROSE} code points", line=line, record_id=record_id)
        elif has_secret_shape(value):
            diagnostics.add("secret_shaped_content", f"{field} contains credential-shaped content", line=line, record_id=record_id)

    associations = record.get("associations")
    if not isinstance(associations, dict):
        diagnostics.add("invalid_associations", "associations must be an object", line=line, record_id=record_id)
    else:
        for key in sorted(set(associations) - ASSOCIATION_KEYS):
            diagnostics.add("unknown_association_key", f"unknown association key: {key}", line=line, record_id=record_id)
        for key, values in associations.items():
            if key not in ASSOCIATION_KEYS:
                continue
            if not isinstance(values, list):
                diagnostics.add("invalid_association_values", f"associations.{key} must be an array", line=line, record_id=record_id)
                continue
            if len(values) > MAX_ASSOCIATIONS:
                diagnostics.add("too_many_associations", f"associations.{key} exceeds {MAX_ASSOCIATIONS} values", line=line, record_id=record_id)
            seen_values: set[str] = set()
            for value in values:
                valid_scalar = isinstance(value, str) and bool(value.strip()) and len(value) <= MAX_INERT and "\x00" not in value
                if key == "paths":
                    valid_scalar = valid_scalar and safe_relative_path(value, allow_glob=True)
                if not valid_scalar:
                    code = "unsafe_association_path" if key == "paths" else "invalid_association_value"
                    diagnostics.add(code, f"invalid associations.{key} value", line=line, record_id=record_id)
                    continue
                if value in seen_values:
                    diagnostics.add("duplicate_association_value", f"duplicate associations.{key} value", line=line, record_id=record_id)
                seen_values.add(value)
                if has_secret_shape(value):
                    diagnostics.add("secret_shaped_content", f"associations.{key} contains credential-shaped content", line=line, record_id=record_id)

    sources = record.get("sources")
    if not isinstance(sources, list) or not 1 <= len(sources) <= MAX_SOURCES:
        diagnostics.add("invalid_sources", f"sources must contain 1 to {MAX_SOURCES} objects", line=line, record_id=record_id)
    else:
        for source in sources:
            if not isinstance(source, dict):
                diagnostics.add("invalid_source", "each source must be an object", line=line, record_id=record_id)
                continue
            if set(source) != SOURCE_KEYS:
                diagnostics.add("invalid_source_keys", "source keys must be exactly kind and ref", line=line, record_id=record_id)
            kind, ref = source.get("kind"), source.get("ref")
            if not isinstance(kind, str) or kind not in {"path", "commit", "ticket", "issue"}:
                diagnostics.add("invalid_source_kind", "source.kind is invalid", line=line, record_id=record_id)
            if not isinstance(ref, str) or not ref.strip() or len(ref) > MAX_INERT or "\x00" in ref:
                diagnostics.add("invalid_source_ref", "source.ref must be bounded inert text", line=line, record_id=record_id)
            elif kind == "path" and not safe_relative_path(ref):
                diagnostics.add("unsafe_source_path", "source path must be safe and project-relative", line=line, record_id=record_id)
            elif has_secret_shape(ref):
                diagnostics.add("secret_shaped_content", "source.ref contains credential-shaped content", line=line, record_id=record_id)

    supersedes = record.get("supersedes", [])
    if not isinstance(supersedes, list) or len(supersedes) > MAX_ASSOCIATIONS:
        diagnostics.add("invalid_supersedes", "supersedes must be a bounded ID array", line=line, record_id=record_id)
    else:
        seen_targets: set[str] = set()
        for target in supersedes:
            if not isinstance(target, str) or not ID_RE.fullmatch(target):
                diagnostics.add("invalid_supersedes", "supersedes contains an invalid ID", line=line, record_id=record_id)
            elif target in seen_targets:
                diagnostics.add("duplicate_supersedes", f"duplicate supersedes target: {target}", line=line, record_id=record_id)
            seen_targets.add(target) if isinstance(target, str) else None
    return record_id


def reject_json_constant(value: str) -> None:
    raise ValueError(f"invalid JSON constant: {value}")


def supersession_diagnostics(
    records: dict[str, tuple[int, dict[str, Any]]], diagnostics: Diagnostics
) -> None:
    active_superseders: dict[str, list[str]] = {}
    graph: dict[str, list[str]] = {}
    for record_id, (line, record) in records.items():
        targets = record.get("supersedes", [])
        if not isinstance(targets, list):
            targets = []
        valid_targets = [target for target in targets if isinstance(target, str) and ID_RE.fullmatch(target)]
        graph[record_id] = valid_targets
        for target in valid_targets:
            if target == record_id:
                diagnostics.add("self_supersedes", "record cannot supersede itself", line=line, record_id=record_id)
            if target not in records:
                diagnostics.add("missing_supersedes_target", f"supersedes target does not exist: {target}", line=line, record_id=record_id)
            if record.get("status") == "active":
                active_superseders.setdefault(target, []).append(record_id)
    for target, superseders in sorted(active_superseders.items()):
        if len(set(superseders)) > 1:
            first = sorted(set(superseders))[0]
            diagnostics.add(
                "multiple_active_superseders",
                f"{target} has multiple active superseders: {','.join(sorted(set(superseders)))}",
                line=records[first][0],
                record_id=first,
            )

    color: dict[str, int] = {}
    stack: list[str] = []
    reported: set[tuple[str, ...]] = set()

    def visit(node: str) -> None:
        color[node] = 1
        stack.append(node)
        for target in graph.get(node, []):
            if target not in records or target == node:
                continue
            if color.get(target, 0) == 0:
                visit(target)
            elif color.get(target) == 1:
                cycle = stack[stack.index(target) :]
                key = tuple(sorted(cycle))
                if key not in reported:
                    reported.add(key)
                    diagnostics.add(
                        "supersession_cycle",
                        f"supersession cycle: {' -> '.join(cycle + [target])}",
                        line=records[node][0],
                        record_id=node,
                    )
        stack.pop()
        color[node] = 2

    for record_id in sorted(records):
        if color.get(record_id, 0) == 0:
            visit(record_id)


def validate_ledger(
    root: Path, config: dict[str, Any], diagnostics: Diagnostics
) -> tuple[list[dict[str, Any]], str | None]:
    relative = config["ledger"]
    if not safe_relative_path(relative):
        return [], None
    lexical_ledger = root / relative
    if lexical_ledger.is_symlink():
        diagnostics.add("ledger_symlink", "ledger must not be a symbolic link")
        return [], None
    ledger = contained_path(root, relative)
    if ledger is None:
        diagnostics.add("unsafe_ledger_path", "[memory].ledger resolves outside the project")
        return [], None

    # Open, inspect, and consume one descriptor. O_NOFOLLOW closes the race
    # between the lexical symlink check above and open on platforms that expose
    # it; O_NONBLOCK lets fstat reject a FIFO without waiting for a writer.
    open_flags = os.O_RDONLY
    open_flags |= getattr(os, "O_CLOEXEC", 0)
    open_flags |= getattr(os, "O_NOFOLLOW", 0)
    open_flags |= getattr(os, "O_NONBLOCK", 0)
    try:
        ledger_fd = os.open(lexical_ledger, open_flags)
    except FileNotFoundError:
        diagnostics.add("ledger_missing", f"ledger does not exist: {relative}")
        return [], None
    except OSError as exc:
        if getattr(os, "O_NOFOLLOW", 0) and exc.errno == errno.ELOOP:
            diagnostics.add("ledger_symlink", "ledger must not be a symbolic link")
            return [], None
        diagnostics.add("ledger_unreadable", f"cannot open ledger: {exc}")
        return [], None
    try:
        ledger_stat = os.fstat(ledger_fd)
    except OSError as exc:
        os.close(ledger_fd)
        diagnostics.add("ledger_unreadable", f"cannot stat ledger: {exc}")
        return [], None
    if not stat.S_ISREG(ledger_stat.st_mode):
        os.close(ledger_fd)
        diagnostics.add("ledger_not_regular", "ledger must be a regular file")
        return [], None
    size = ledger_stat.st_size
    if size > MAX_LEDGER_BYTES:
        os.close(ledger_fd)
        diagnostics.add("ledger_too_large", f"ledger exceeds {MAX_LEDGER_BYTES} bytes")
        return [], None

    parsed: list[dict[str, Any]] = []
    records: dict[str, tuple[int, dict[str, Any]]] = {}
    try:
        with os.fdopen(ledger_fd, "rb", closefd=True) as source:
            for line_number, raw in enumerate(source, 1):
                if line_number > MAX_RECORDS:
                    diagnostics.add("too_many_records", f"ledger exceeds {MAX_RECORDS} records", line=line_number)
                    break
                if len(raw) > MAX_LINE_BYTES:
                    diagnostics.add("line_too_large", f"line exceeds {MAX_LINE_BYTES} bytes", line=line_number)
                    continue
                if b"\x00" in raw:
                    diagnostics.add("nul_byte", "line contains a NUL byte", line=line_number)
                    continue
                try:
                    text = raw.decode("utf-8")
                except UnicodeDecodeError as exc:
                    diagnostics.add("invalid_utf8", f"line is not UTF-8: {exc}", line=line_number)
                    continue
                if not text.strip():
                    diagnostics.add("blank_line", "blank JSONL lines are not allowed", line=line_number)
                    continue
                try:
                    record = json.loads(text, parse_constant=reject_json_constant)
                except (json.JSONDecodeError, ValueError, RecursionError) as exc:
                    diagnostics.add("invalid_json", f"invalid JSON object: {exc}", line=line_number)
                    continue
                if not isinstance(record, dict):
                    diagnostics.add("record_not_object", "each JSONL line must be an object", line=line_number)
                    continue
                if has_lone_surrogate(record):
                    diagnostics.add(
                        "unicode_surrogate",
                        "record contains a lone Unicode surrogate",
                        line=line_number,
                    )
                    continue
                record_id = validate_record(record, line_number, diagnostics)
                if record_id and ID_RE.fullmatch(record_id):
                    if record_id in records:
                        diagnostics.add("duplicate_id", f"duplicate record ID: {record_id}", line=line_number, record_id=record_id)
                    else:
                        records[record_id] = (line_number, record)
                parsed.append(record)
    except OSError as exc:
        diagnostics.add("ledger_unreadable", f"cannot read ledger: {exc}")
        return [], None

    supersession_diagnostics(records, diagnostics)
    if diagnostics.errors:
        return parsed, None
    canonical = b"".join(
        json.dumps(record, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8") + b"\n"
        for _, record in sorted((record["id"], record) for record in parsed)
    )
    return parsed, hashlib.sha256(canonical).hexdigest()


def inspect_project(command: str, root: Path) -> tuple[dict[str, Any], int]:
    document = base_document(command, root)
    diagnostics = Diagnostics()
    configured, config = parse_memory_config(root, diagnostics)
    document["configured"] = configured
    if not configured and not diagnostics.errors:
        return document, 0
    document["state"] = "invalid"
    document["valid"] = False
    if config is not None:
        document["mode"] = config.get("mode")
        document["ledger_path"] = config.get("ledger")
        if not diagnostics.errors:
            records, digest = validate_ledger(root, config, diagnostics)
            document["record_count"] = len(records)
            document["active_count"] = sum(record.get("status") == "active" for record in records)
            document["superseded_count"] = sum(record.get("status") == "superseded" for record in records)
            document["ledger_digest"] = digest
    document["errors"] = diagnostics.errors
    if not diagnostics.errors:
        document["state"] = "ready"
        document["valid"] = True
        return document, 0
    return document, 2


def initialize(root: Path) -> tuple[dict[str, Any], int]:
    changes = {"config_created": False, "ledger_created": False, "memory_table_added": False}
    config_path = root / ".agents" / "config.toml"
    try:
        root.mkdir(parents=True, exist_ok=True)
        config_path.parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        document = base_document("init", root)
        document.update(state="invalid", valid=False)
        document["errors"] = [{"code": "init_io_error", "line": None, "message": str(exc), "record_id": None}]
        document["changes"] = changes
        return document, 2

    if config_path.exists():
        diagnostics = Diagnostics()
        configured, config = parse_memory_config(root, diagnostics)
        if diagnostics.errors:
            document = base_document("init", root)
            document.update(configured=configured, state="invalid", valid=False)
            document["errors"] = diagnostics.errors
            document["changes"] = changes
            return document, 2
        if not configured:
            try:
                needs_newline = config_path.stat().st_size > 0 and not config_path.read_bytes().endswith(b"\n")
                with config_path.open("a", encoding="utf-8") as target:
                    if needs_newline:
                        target.write("\n")
                    target.write('\n[memory]\nmode = "advisory"\nledger = ".agents/rules-ledger.jsonl"\n')
            except OSError as exc:
                document = base_document("init", root)
                document.update(state="invalid", valid=False)
                document["errors"] = [{"code": "init_io_error", "line": None, "message": str(exc), "record_id": None}]
                document["changes"] = changes
                return document, 2
            changes["memory_table_added"] = True
            ledger_relative = DEFAULT_LEDGER
        else:
            assert config is not None
            ledger_relative = config["ledger"]
    else:
        try:
            config_path.write_text(
                '[memory]\nmode = "advisory"\nledger = ".agents/rules-ledger.jsonl"\n',
                encoding="utf-8",
            )
        except OSError as exc:
            document = base_document("init", root)
            document.update(state="invalid", valid=False)
            document["errors"] = [{"code": "init_io_error", "line": None, "message": str(exc), "record_id": None}]
            document["changes"] = changes
            return document, 2
        changes["config_created"] = True
        changes["memory_table_added"] = True
        ledger_relative = DEFAULT_LEDGER

    ledger = contained_path(root, ledger_relative)
    if ledger is None:
        document, _ = inspect_project("init", root)
        document["changes"] = changes
        return document, 2
    try:
        ledger.parent.mkdir(parents=True, exist_ok=True)
        with ledger.open("x", encoding="utf-8"):
            pass
        changes["ledger_created"] = True
    except FileExistsError:
        pass
    except OSError as exc:
        document, _ = inspect_project("init", root)
        document.update(state="invalid", valid=False)
        document["errors"] = [
            {"code": "init_io_error", "line": None, "message": str(exc), "record_id": None}
        ]
        document["changes"] = changes
        return document, 2

    document, exit_code = inspect_project("init", root)
    document["changes"] = changes
    return document, exit_code


def query_not_implemented(root: Path, scope_file: str | None, diff_file: str | None) -> tuple[dict[str, Any], int]:
    document, _ = inspect_project("query", root)
    if (scope_file is None) == (diff_file is None):
        document.update(state="invalid", valid=False)
        document["errors"] = [
            {
                "code": "query_input_count",
                "line": None,
                "message": "query accepts exactly one of --scope-file or --diff-file",
                "record_id": None,
            }
        ]
        return document, 2
    document.update(state="not_implemented", valid=False)
    document["errors"] = [
        {
            "code": "phase_2_not_implemented",
            "line": None,
            "message": "memory query retrieval is implemented in Phase 2",
            "record_id": None,
        }
    ]
    document["query_input"] = {"kind": "scope" if scope_file else "diff", "path": scope_file or diff_file}
    return document, 2


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="rules-memory.py")
    parser.add_argument("command", choices=("init", "validate", "status", "query"))
    parser.add_argument("--project", required=True)
    parser.add_argument("--scope-file")
    parser.add_argument("--diff-file")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    root = Path(args.project).expanduser().resolve()
    if args.command != "query" and (args.scope_file or args.diff_file):
        document = base_document(args.command, root)
        document.update(state="invalid", valid=False)
        document["errors"] = [
            {
                "code": "unexpected_query_input",
                "line": None,
                "message": "--scope-file/--diff-file apply only to query",
                "record_id": None,
            }
        ]
        emit(document)
        return 2
    if args.command == "init":
        document, exit_code = initialize(root)
    elif args.command == "query":
        document, exit_code = query_not_implemented(root, args.scope_file, args.diff_file)
    else:
        document, exit_code = inspect_project(args.command, root)
    emit(document)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
