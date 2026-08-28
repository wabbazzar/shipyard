#!/usr/bin/env python3
"""Shipyard-owned project rules-ledger contract, index, and retrieval CLI.

The project owns only .agents/config.toml and its JSONL ledger. This helper
owns parsing, validation, canonicalization, local hybrid retrieval, and
machine-readable diagnostics. It deliberately has no model, network, native,
or project-specific dependency.
"""

from __future__ import annotations

import argparse
import datetime as dt
import errno
import fcntl
import fnmatch
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import sqlite3
import stat
import sys
import tempfile
import time
from typing import Any
import unicodedata

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
MAX_QUERY_BYTES = 4 * 1024 * 1024
MAX_QUERY_TERMS = 512
MAX_QUERY_FEATURE_VALUES = 256
MAX_VECTOR_CODEPOINTS = 128 * 1024
MAX_STATUS_CACHE_ENTRIES = 1_024
MAX_STATUS_RECEIPTS = 256
MAX_STATUS_RUNTIME_ENTRIES = 1_024
MAX_STATUS_RECEIPT_BYTES = 1024 * 1024
MAX_STATUS_IDENTITY_BYTES = 4 * 1024 * 1024
INDEX_SCHEMA_VERSION = 1
INDEX_LOCK_SECONDS = 10.0
NORMALIZER_VERSION = "rules-memory-document-v1"
SHIPYARD_INDEX_VERSION = "rules-memory-phase2-v1"
VECTOR_BACKEND = "stdlib-hash-ngram-v1"
VECTOR_DIMENSIONS = 2_048
BM25_BACKEND = "python-bm25-v1"
FTS5_BACKEND = "sqlite-fts5-v1"
CACHE_MARKER = ".shipyard-rules-memory-v1"
CACHE_MARKER_CONTENT = "shipyard-rules-memory-v1\n"
TOKEN_RE = re.compile(r"\w+", re.UNICODE)
SEVERITY_RANK = {"note": 0, "warn": 1, "block": 2}
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


class ValidatedRecords(list[dict[str, Any]]):
    """Validated records plus their exact ledger provenance."""

    def __init__(
        self,
        values: list[dict[str, Any]],
        source_lines: dict[str, int],
        original_lines: dict[str, bytes],
        ledger_bytes: bytes,
    ) -> None:
        super().__init__(values)
        self.source_lines = source_lines
        self.original_lines = original_lines
        self.ledger_bytes = ledger_bytes


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
    original_lines: dict[str, bytes] = {}
    raw_lines: list[bytes] = []
    try:
        with os.fdopen(ledger_fd, "rb", closefd=True) as source:
            for line_number, raw in enumerate(source, 1):
                raw_lines.append(raw)
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
                        original_lines[record_id] = raw
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
    validated = ValidatedRecords(
        parsed,
        {record_id: line for record_id, (line, _) in records.items()},
        original_lines,
        b"".join(raw_lines),
    )
    return validated, hashlib.sha256(canonical).hexdigest()


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
            if command == "status" and digest is not None and not diagnostics.errors:
                document.update(runtime_status(root, config, records, digest))
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


def normalized_text(value: str) -> str:
    """Canonical text form shared by documents, queries, and vectors."""
    return " ".join(unicodedata.normalize("NFKC", value).casefold().split())


def lexical_tokens(value: str, *, limit: int | None = None) -> list[str]:
    tokens = TOKEN_RE.findall(normalized_text(value))
    if limit is None:
        return tokens
    seen: set[str] = set()
    bounded: list[str] = []
    for token in tokens:
        if token not in seen:
            seen.add(token)
            bounded.append(token)
            if len(bounded) >= limit:
                break
    return bounded


def vector_sample(value: str) -> tuple[str, bool]:
    value = normalized_text(value)
    if len(value) <= MAX_VECTOR_CODEPOINTS:
        return value, False
    half = MAX_VECTOR_CODEPOINTS // 2
    return value[:half] + " " + value[-half:], True


def hash_ngram_vector(value: str) -> tuple[dict[int, float], bool]:
    """Return a stable sparse signed feature-hash vector and truncation flag."""
    text, truncated = vector_sample(value)
    words = TOKEN_RE.findall(text)
    features: list[str] = [f"w1:{word}" for word in words]
    features.extend(f"w2:{left}\x1f{right}" for left, right in zip(words, words[1:]))
    compact = " ".join(words)
    for width in range(3, 6):
        features.extend(f"c{width}:{compact[start:start + width]}" for start in range(max(0, len(compact) - width + 1)))

    buckets: dict[int, float] = {}
    for feature in features:
        digest = hashlib.blake2b(feature.encode("utf-8"), digest_size=8).digest()
        bucket = int.from_bytes(digest[:4], "big") % VECTOR_DIMENSIONS
        sign = 1.0 if digest[4] & 1 else -1.0
        buckets[bucket] = buckets.get(bucket, 0.0) + sign
    norm = math.sqrt(sum(value * value for value in buckets.values()))
    if norm:
        buckets = {bucket: value / norm for bucket, value in buckets.items() if value}
    return buckets, truncated


def cosine(left: dict[int, float], right: dict[int, float]) -> float:
    if len(left) > len(right):
        left, right = right, left
    return sum(value * right.get(bucket, 0.0) for bucket, value in left.items())


def canonical_retrieval_document(record: dict[str, Any]) -> str:
    parts = [f"id: {record['id']}"]
    for field in PROSE_FIELDS:
        parts.append(f"{field}: {record[field]}")
    associations = record.get("associations", {})
    for key in sorted(ASSOCIATION_KEYS):
        values = associations.get(key, []) if isinstance(associations, dict) else []
        if values:
            parts.append(f"{key}: {' '.join(values)}")
    for source in record.get("sources", []):
        parts.append(f"source {source['kind']}: {source['ref']}")
    return normalized_text("\n".join(parts))


def normalized_records(
    records: list[dict[str, Any]], ledger_path: str
) -> list[dict[str, Any]]:
    documents: list[dict[str, Any]] = []
    for line, record in enumerate(records, 1):
        if record.get("status") != "active":
            continue
        source_line = getattr(records, "source_lines", {}).get(record["id"], line)
        document = canonical_retrieval_document(record)
        vector, vector_truncated = hash_ngram_vector(document)
        documents.append(
            {
                "associations": record["associations"],
                "citation": {
                    "ledger_path": ledger_path,
                    "line": source_line,
                    "sources": record["sources"],
                },
                "document": document,
                "id": record["id"],
                "occurred_at": record["occurred_at"],
                "original": getattr(records, "original_lines", {}).get(record["id"], b""),
                "record": record,
                "vector": vector,
                "vector_truncated": vector_truncated,
            }
        )
    return documents


def read_query_input(path_value: str, diagnostics: Diagnostics) -> tuple[bytes | None, str | None]:
    path = Path(path_value).expanduser()
    if path.is_symlink():
        diagnostics.add("query_input_symlink", "query input must not be a symbolic link")
        return None, None
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_NONBLOCK", 0)
    try:
        descriptor = os.open(path, flags)
    except FileNotFoundError:
        diagnostics.add("query_input_missing", f"query input does not exist: {path}")
        return None, None
    except OSError as exc:
        if getattr(os, "O_NOFOLLOW", 0) and exc.errno == errno.ELOOP:
            diagnostics.add("query_input_symlink", "query input must not be a symbolic link")
        else:
            diagnostics.add("query_input_unreadable", f"cannot open query input: {exc}")
        return None, None
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            diagnostics.add("query_input_not_regular", "query input must be a regular file")
            return None, None
        if metadata.st_size > MAX_QUERY_BYTES:
            diagnostics.add("query_input_too_large", f"query input exceeds {MAX_QUERY_BYTES} bytes")
            return None, None
        with os.fdopen(descriptor, "rb", closefd=False) as source:
            raw = source.read(MAX_QUERY_BYTES + 1)
        if len(raw) > MAX_QUERY_BYTES:
            diagnostics.add("query_input_too_large", f"query input exceeds {MAX_QUERY_BYTES} bytes")
            return None, None
    except OSError as exc:
        diagnostics.add("query_input_unreadable", f"cannot read query input: {exc}")
        return None, None
    finally:
        os.close(descriptor)
    if b"\x00" in raw:
        diagnostics.add("query_input_nul", "query input contains a NUL byte")
        return None, None
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        diagnostics.add("query_input_utf8", f"query input is not UTF-8: {exc}")
        return None, None
    return raw, text


def extract_query_features(text: str, kind: str) -> dict[str, Any]:
    normalized = normalized_text(text)
    paths: set[str] = set()
    if kind == "diff":
        for match in re.finditer(r"^(?:\+\+\+|---) [ab]/([^\t\n ]+)", text, re.MULTILINE):
            if match.group(1) != "/dev/null" and safe_relative_path(match.group(1)):
                paths.add(match.group(1))
        for match in re.finditer(r"^diff --git a/([^\s]+) b/([^\s]+)$", text, re.MULTILINE):
            for value in match.groups():
                if safe_relative_path(value):
                    paths.add(value)
    else:
        for match in re.finditer(r"(?<![\w./-])([\w.-]+(?:/[\w.*?\[\]-]+)+)", text):
            if safe_relative_path(match.group(1), allow_glob=True):
                paths.add(match.group(1))

    symbols = set(
        value
        for match in re.finditer(
            r"\b(?:def|class|function)\s+([A-Za-z_][A-Za-z0-9_]*)|^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{",
            text,
            re.MULTILINE,
        )
        for value in match.groups()
        if value
    )
    # Named ledger symbols are often call sites, so bounded identifiers are
    # retained as extraction features in addition to declarations.
    symbols.update(re.findall(r"\b[A-Za-z_][A-Za-z0-9_]{2,63}\b", text)[:MAX_QUERY_FEATURE_VALUES])
    imports = set(re.findall(r"(?:^|\n)[+ -]*(?:from|import|require)\s*[(']*([\w./-]+)", text))
    tests = set(re.findall(r"\b(?:test_[A-Za-z0-9_]+|[A-Za-z0-9_]+_test)\b", text))
    transitions = set(re.findall(r"\b[a-z][a-z0-9_-]{1,63}(?:-to-|\s+to\s+|\s*->\s*)[a-z][a-z0-9_-]{1,63}\b", normalized))
    status_terms = set(
        token for token in lexical_tokens(normalized, limit=MAX_QUERY_TERMS)
        if any(marker in token for marker in ("error", "fail", "stale", "invalid", "pending", "deliver", "status"))
    )

    def bounded(values: set[str]) -> list[str]:
        return sorted(values)[:MAX_QUERY_FEATURE_VALUES]

    return {
        "imports": bounded(imports),
        "paths": bounded(paths),
        "status_terms": bounded(status_terms),
        "symbols": bounded(symbols),
        "test_names": bounded(tests),
        "terms": lexical_tokens(normalized, limit=MAX_QUERY_TERMS),
        "transitions": bounded(transitions),
    }


def platform_cache_root() -> Path:
    configured = os.environ.get("XDG_CACHE_HOME")
    if configured:
        return Path(configured).expanduser()
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Caches"
    if os.name == "nt" and os.environ.get("LOCALAPPDATA"):
        return Path(os.environ["LOCALAPPDATA"])
    return Path.home() / ".cache"


def project_cache_identity(root: Path) -> str:
    return hashlib.sha256(os.fsencode(str(root.resolve()))).hexdigest()


def fts_backend() -> str:
    if os.environ.get("SHIPYARD_MEMORY_DISABLE_FTS5") == "1":
        return BM25_BACKEND
    probe = sqlite3.connect(":memory:")
    try:
        probe.execute("create virtual table probe_fts using fts5(content)")
    except sqlite3.DatabaseError:
        return BM25_BACKEND
    finally:
        probe.close()
    return FTS5_BACKEND


def index_identity(
    ledger_digest: str, source_layout_digest: str, selected_fts: str
) -> dict[str, str]:
    return {
        "fts_backend": selected_fts,
        "index_schema_version": str(INDEX_SCHEMA_VERSION),
        "ledger_digest": ledger_digest,
        "normalizer_version": NORMALIZER_VERSION,
        "shipyard_version": SHIPYARD_INDEX_VERSION,
        "source_layout_digest": source_layout_digest,
        "vector_backend": VECTOR_BACKEND,
    }


def index_digest(identity: dict[str, str], documents: list[dict[str, Any]]) -> str:
    payload = {
        "identity": identity,
        "records": [
            {
                "citation": document["citation"],
                "document": document["document"],
                "id": document["id"],
                "original_sha256": hashlib.sha256(document["original"]).hexdigest(),
                "associations": document["associations"],
                "occurred_at": document["occurred_at"],
                "record": document["record"],
                "severity": document.get("severity", document["record"]["severity"]),
                "vector": sorted(document["vector"].items()),
            }
            for document in sorted(documents, key=lambda item: item["id"])
        ],
    }
    canonical = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def readonly_database(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    return connection


def private_owned_regular(path: Path) -> bool:
    try:
        metadata = path.lstat()
    except OSError:
        return False
    return (
        stat.S_ISREG(metadata.st_mode)
        and metadata.st_uid == os.getuid()
        and stat.S_IMODE(metadata.st_mode) & 0o077 == 0
        and not stat.S_ISLNK(metadata.st_mode)
    )


def open_current_index(
    path: Path, expected: dict[str, str], record_count: int
) -> tuple[sqlite3.Connection, dict[str, str]] | None:
    if not private_owned_regular(path):
        return None
    connection: sqlite3.Connection | None = None
    try:
        connection = readonly_database(path)
        if connection.execute("pragma quick_check").fetchone()[0] != "ok":
            raise sqlite3.DatabaseError("quick_check failed")
        metadata = dict(connection.execute("select key,value from metadata"))
        if any(metadata.get(key) != value for key, value in expected.items()):
            raise ValueError("index identity mismatch")
        if metadata.get("state") != "complete" or len(metadata.get("index_digest", "")) != 64:
            raise ValueError("index is incomplete")
        indexed_records = load_index_records(connection)
        if len(indexed_records) != record_count or metadata.get("record_count") != str(record_count):
            raise ValueError("index row count mismatch")
        if index_digest(expected, indexed_records) != metadata["index_digest"]:
            raise ValueError("index row digest mismatch")
        if expected["fts_backend"] == FTS5_BACKEND:
            fts_rows = [tuple(row) for row in connection.execute(
                "select id,document from records_fts order by id"
            )]
            record_rows = [(record["id"], record["document"]) for record in indexed_records]
            if fts_rows != record_rows:
                raise ValueError("FTS row mismatch")
        return connection, metadata
    except (OSError, sqlite3.DatabaseError, ValueError, TypeError, json.JSONDecodeError):
        if connection is not None:
            connection.close()
        return None


def current_index(path: Path, expected: dict[str, str], record_count: int) -> dict[str, str] | None:
    opened = open_current_index(path, expected, record_count)
    if opened is None:
        return None
    connection, metadata = opened
    connection.close()
    return metadata


def status_action(message: str | None) -> str | None:
    """Keep status remediation bounded and free of ledger/reviewer prose."""
    return message


def inspect_index_status(
    root: Path,
    config: dict[str, Any],
    records: ValidatedRecords,
    ledger_digest: str,
) -> tuple[dict[str, Any], str | None]:
    documents = normalized_records(records, config["ledger"])
    backend = fts_backend()
    result: dict[str, Any] = {
        "state": "not_applicable" if not documents else "absent",
        "cache_key": project_cache_identity(root),
        "expected_digest": None,
        "actual_digest": None,
        "schema_version": INDEX_SCHEMA_VERSION,
        "normalizer_version": NORMALIZER_VERSION,
        "shipyard_version": SHIPYARD_INDEX_VERSION,
        "vector_backend": VECTOR_BACKEND,
        "fts_backend": backend,
        "action": None,
    }
    if not documents:
        return result, None

    source_layout_digest = hashlib.sha256(records.ledger_bytes).hexdigest()
    identity = index_identity(ledger_digest, source_layout_digest, backend)
    expected_digest = index_digest(identity, documents)
    result["expected_digest"] = expected_digest
    base = platform_cache_root().expanduser().absolute()
    cache_key = result["cache_key"]
    cache_dir = base / "shipyard" / "memory" / str(cache_key)
    index_path = cache_dir / f"index-{expected_digest}.sqlite3"
    rebuild = status_action("run a bounded shipyard memory query to rebuild the derived index")
    try:
        validate_cache_ancestors(base)
        if not base.exists():
            result["action"] = rebuild
            return result, expected_digest
        reject_symlink_components(base)
        if not owned_directory(base, private=False) or group_world_writable(base):
            raise OSError("cache root is not a private owned directory")
        shipyard_root = base / "shipyard"
        memory_root = shipyard_root / "memory"
        if not shipyard_root.exists() or not memory_root.exists():
            result["action"] = rebuild
            return result, expected_digest
        reject_symlink_components(memory_root)
        if (
            not owned_directory(shipyard_root, private=True)
            or not owned_directory(memory_root, private=True)
            or not valid_cache_marker(memory_root / CACHE_MARKER)
        ):
            raise OSError("Shipyard memory cache ownership marker is invalid")
        if not cache_dir.exists():
            result["action"] = rebuild
            return result, expected_digest
        reject_symlink_components(cache_dir)
        if not owned_directory(cache_dir, private=True):
            raise OSError("project memory cache directory is unsafe")
        with os.scandir(cache_dir) as scan:
            entries = [
                Path(entry.path)
                for _, entry in zip(range(MAX_STATUS_CACHE_ENTRIES + 1), scan)
            ]
        if len(entries) > MAX_STATUS_CACHE_ENTRIES:
            raise OSError("project memory cache entry bound exceeded")
        partials = [
            item
            for item in entries
            if item.name.startswith(".index-")
            or (
                item.name.startswith("index-")
                and item.suffix not in {".sqlite3", ".lock"}
            )
        ]
        if partials:
            raise OSError("partial memory index artifact is present")
        if index_path.exists() or index_path.is_symlink():
            reject_symlink_components(index_path)
            metadata = current_index(index_path, identity, len(documents))
            if metadata is None:
                raise OSError("expected memory index is corrupt or mismatched")
            result.update(
                state="fresh",
                actual_digest=metadata.get("index_digest"),
                action=None,
            )
            return result, expected_digest
        stale = [
            item
            for item in entries
            if item.name.startswith("index-") and item.name.endswith(".sqlite3")
        ]
        if stale:
            result.update(state="stale", action=rebuild)
        else:
            result["action"] = rebuild
        return result, expected_digest
    except (OSError, ValueError, sqlite3.DatabaseError):
        result.update(
            state="invalid",
            action=status_action(
                "move the unsafe/corrupt derived cache aside, then run a bounded shipyard memory query"
            ),
            error_code="index_invalid",
        )
        return result, expected_digest


def read_status_receipt(path: Path) -> tuple[dict[str, Any], os.stat_result]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_NONBLOCK", 0)
    descriptor = os.open(path, flags)
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) & 0o077
            or metadata.st_size > MAX_STATUS_RECEIPT_BYTES
        ):
            raise OSError("receipt must be a private bounded regular file")
        raw = bytearray()
        while len(raw) <= MAX_STATUS_RECEIPT_BYTES:
            chunk = os.read(descriptor, min(65536, MAX_STATUS_RECEIPT_BYTES + 1 - len(raw)))
            if not chunk:
                break
            raw.extend(chunk)
        if len(raw) > MAX_STATUS_RECEIPT_BYTES:
            raise OSError("receipt size bound exceeded")
        value = json.loads(bytes(raw).decode("utf-8"))
        if not isinstance(value, dict):
            raise ValueError("receipt must contain one JSON object")
        return value, metadata
    finally:
        os.close(descriptor)


def status_file_identity(path: Path) -> dict[str, Any]:
    """Return the receipt identity shape without following or reading unbounded files."""
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_NONBLOCK", 0)
    try:
        descriptor = os.open(path, flags)
    except FileNotFoundError:
        return {"state": "missing", "digest": None, "bytes": None}
    except OSError:
        return {"state": "unsafe", "digest": None, "bytes": None}
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > MAX_STATUS_IDENTITY_BYTES:
            return {"state": "unsafe", "digest": None, "bytes": None}
        digest = hashlib.sha256()
        consumed = 0
        while consumed <= MAX_STATUS_IDENTITY_BYTES:
            chunk = os.read(descriptor, min(65536, MAX_STATUS_IDENTITY_BYTES + 1 - consumed))
            if not chunk:
                break
            consumed += len(chunk)
            digest.update(chunk)
        if consumed > MAX_STATUS_IDENTITY_BYTES:
            return {"state": "unsafe", "digest": None, "bytes": None}
        return {
            "state": "present",
            "digest": digest.hexdigest(),
            "bytes": consumed,
        }
    except OSError:
        return {"state": "unsafe", "digest": None, "bytes": None}
    finally:
        os.close(descriptor)


def receipt_text(value: Any, *, maximum: int = MAX_PROSE) -> bool:
    return isinstance(value, str) and bool(value.strip()) and len(value) <= maximum


def receipt_hex(value: Any) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def receipt_timestamp(value: Any) -> bool:
    return isinstance(value, str) and valid_utc_timestamp(value)


def receipt_ids(value: Any, *, maximum: int = MAX_RECORDS) -> bool:
    if (
        not isinstance(value, list)
        or len(value) > maximum
        or not all(isinstance(item, str) and ID_RE.fullmatch(item) for item in value)
    ):
        return False
    return len(set(value)) == len(value)


def valid_receipt_identity(value: Any) -> bool:
    if not isinstance(value, dict) or set(value) != {"state", "digest", "bytes"}:
        return False
    if value["state"] == "missing":
        return value["digest"] is None and value["bytes"] is None
    return (
        value["state"] == "present"
        and receipt_hex(value["digest"])
        and isinstance(value["bytes"], int)
        and not isinstance(value["bytes"], bool)
        and 0 <= value["bytes"] <= MAX_STATUS_IDENTITY_BYTES
    )


def valid_receipt_query_features(value: Any) -> bool:
    if not isinstance(value, dict):
        return False
    allowed = {
        "imports",
        "paths",
        "status_terms",
        "symbols",
        "test_names",
        "term_count",
        "transitions",
        "vector_text_truncated",
    }
    if not set(value) <= allowed or not isinstance(value.get("term_count"), int):
        return False
    if isinstance(value.get("term_count"), bool) or not 0 <= value["term_count"] <= MAX_QUERY_TERMS:
        return False
    if "vector_text_truncated" in value and not isinstance(value["vector_text_truncated"], bool):
        return False
    for key in allowed - {"term_count", "vector_text_truncated"}:
        items = value.get(key, [])
        if (
            not isinstance(items, list)
            or len(items) > MAX_QUERY_FEATURE_VALUES
            or any(not isinstance(item, str) or len(item) > MAX_INERT for item in items)
        ):
            return False
    return True


def valid_receipt_limits(value: Any) -> bool:
    keys = {"max_channel_candidates", "max_fused_candidates", "max_prompt_records"}
    if not isinstance(value, dict) or set(value) != keys:
        return False
    if any(
        isinstance(value[key], bool)
        or not isinstance(value[key], int)
        or not 1 <= value[key] <= 10_000
        for key in keys
    ):
        return False
    return (
        value["max_fused_candidates"] <= value["max_channel_candidates"] * 3
        and value["max_prompt_records"] <= value["max_fused_candidates"]
    )


def valid_receipt_reviewer_request(value: Any) -> bool:
    keys = {
        "harness",
        "model",
        "provider",
        "model_explicit",
        "provider_explicit",
        "contract_version",
    }
    if not isinstance(value, dict) or set(value) != keys:
        return False
    if value["contract_version"] != "rules-memory-review-v1":
        return False
    if not all(receipt_text(value[key], maximum=MAX_INERT) for key in ("harness", "model", "provider")):
        return False
    if not isinstance(value["model_explicit"], bool) or not isinstance(value["provider_explicit"], bool):
        return False
    return (
        value["model_explicit"] == (value["model"] != "<implicit-unresolved>")
        and value["provider_explicit"] == (value["provider"] != "<implicit-unresolved>")
    )


def valid_receipt_candidate(value: Any) -> bool:
    keys = {"id", "severity", "status", "citation", "sources", "channels", "excerpt"}
    if not isinstance(value, dict) or set(value) != keys:
        return False
    if not isinstance(value["id"], str) or not ID_RE.fullmatch(value["id"]):
        return False
    if value["severity"] not in SEVERITY_RANK or value["status"] != "active":
        return False
    citation = value["citation"]
    if not receipt_text(citation, maximum=MAX_INERT) or re.fullmatch(r"[^:\x00]+:[1-9][0-9]*", citation) is None:
        return False
    sources = value["sources"]
    if not isinstance(sources, list) or len(sources) > MAX_SOURCES:
        return False
    if any(
        not isinstance(source, dict)
        or set(source) != SOURCE_KEYS
        or source.get("kind") not in {"path", "commit", "ticket", "issue"}
        or not receipt_text(source.get("ref"), maximum=MAX_INERT)
        for source in sources
    ):
        return False
    channels = value["channels"]
    if (
        not isinstance(channels, dict)
        or not channels
        or not set(channels) <= {"exact", "fts", "vector"}
        or any(not isinstance(explanation, dict) for explanation in channels.values())
    ):
        return False
    excerpt = value["excerpt"]
    return (
        isinstance(excerpt, dict)
        and set(excerpt) == set(PROSE_FIELDS)
        and all(receipt_text(excerpt[field]) for field in PROSE_FIELDS)
    )


def validate_receipt_schema(receipt: dict[str, Any]) -> bool:
    """Validate the bounded Phase-4 receipt as a self-consistent document."""
    state = receipt.get("state")
    common = {
        "schema_version",
        "binding",
        "retrieved_ids",
        "review_set_ids",
        "omitted_ids",
        "candidate_evidence",
        "prompt_digest",
        "reviewer",
        "state",
        "coverage",
        "dispositions",
        "findings",
        "verdict",
        "findings_digest",
        "delivery",
    }
    receipt_keys = set(receipt)
    review_evidence = state == "complete" or (
        state == "degraded" and receipt.get("coverage") in {"full", "bounded"}
    )
    valid_keys = (
        receipt_keys == common | {"response_digest", "reviewed_at"}
        if state == "complete"
        else receipt_keys
        == common
        | (
            {"error", "response_digest", "reviewed_at"}
            if review_evidence
            else {"error"}
        )
        if state == "degraded"
        else False
    )
    if receipt.get("schema_version") != 1 or not valid_keys:
        return False
    binding = receipt.get("binding")
    binding_keys = {
        "project_root",
        "project_identity",
        "diff_digest",
        "base_identity",
        "diff_mode",
        "ledger_digest",
        "source_layout_digest",
        "index_digest",
        "index_schema_version",
        "normalizer_version",
        "vector_backend",
        "config_identity",
        "config_digest",
        "config_state",
        "gates_identity",
        "gates_digest",
        "gates_state",
        "policy_mode",
        "query_features",
        "limits",
        "reviewer",
    }
    if (
        not isinstance(binding, dict)
        or set(binding) not in (
            binding_keys | {"ledger_line_count"},
            binding_keys if state == "degraded" else set(),
        )
    ):
        return False
    if (
        not receipt_text(binding["project_root"], maximum=4096)
        or not receipt_hex(binding["project_identity"])
        or not receipt_hex(binding["diff_digest"])
        or not receipt_text(binding["base_identity"], maximum=MAX_INERT)
        or binding["diff_mode"] not in {"branch", "staged"}
        or binding["policy_mode"] not in {"advisory", "required"}
        or not valid_receipt_identity(binding["config_identity"])
        or not valid_receipt_identity(binding["gates_identity"])
        or binding["config_digest"] != binding["config_identity"]["digest"]
        or binding["config_state"] != binding["config_identity"]["state"]
        or binding["gates_digest"] != binding["gates_identity"]["digest"]
        or binding["gates_state"] != binding["gates_identity"]["state"]
        or not valid_receipt_reviewer_request(binding["reviewer"])
    ):
        return False
    digest_fields = ("ledger_digest", "source_layout_digest", "index_digest")
    if any(value is not None and not receipt_hex(value) for value in (binding[key] for key in digest_fields)):
        return False
    index_fields = (
        binding["index_digest"],
        binding["index_schema_version"],
        binding["normalizer_version"],
        binding["vector_backend"],
    )
    if any(item is None for item in index_fields) != all(item is None for item in index_fields):
        return False
    if binding["index_digest"] is not None and (
        binding["index_schema_version"] != INDEX_SCHEMA_VERSION
        or binding["normalizer_version"] != NORMALIZER_VERSION
        or binding["vector_backend"] != VECTOR_BACKEND
    ):
        return False
    ledger_line_count = binding.get("ledger_line_count")
    if ledger_line_count is not None and (
        isinstance(ledger_line_count, bool)
        or not isinstance(ledger_line_count, int)
        or not 0 <= ledger_line_count <= MAX_RECORDS
    ):
        return False
    if review_evidence and (
        any(binding[key] is None for key in digest_fields)
        or ledger_line_count is None
        or not valid_receipt_query_features(binding["query_features"])
        or not valid_receipt_limits(binding["limits"])
    ):
        return False
    if state == "degraded" and (
        binding["query_features"] is not None
        and not valid_receipt_query_features(binding["query_features"])
        or binding["limits"] is not None
        and not valid_receipt_limits(binding["limits"])
    ):
        return False

    retrieved = receipt.get("retrieved_ids")
    review_set = receipt.get("review_set_ids")
    omitted = receipt.get("omitted_ids")
    candidates = receipt.get("candidate_evidence")
    if not all(receipt_ids(value) for value in (retrieved, review_set, omitted)):
        return False
    if review_set + omitted != retrieved:
        return False
    if not isinstance(candidates, list) or len(candidates) != len(retrieved):
        return False
    if any(not valid_receipt_candidate(item) for item in candidates):
        return False
    if [item["id"] for item in candidates] != retrieved or not receipt_hex(receipt.get("prompt_digest")):
        return False
    limits = binding.get("limits")
    if isinstance(limits, dict) and (
        len(retrieved) > limits["max_fused_candidates"]
        or len(review_set) > limits["max_prompt_records"]
    ):
        return False

    reviewer = receipt.get("reviewer")
    if not isinstance(reviewer, dict) or set(reviewer) != {"requested", "resolved", "invocation"}:
        return False
    if reviewer["requested"] != binding["reviewer"]:
        return False
    resolved, invocation = reviewer["resolved"], reviewer["invocation"]
    invocation_keys = {"state", "identity", "started_at", "ended_at", "tokens", "rc", "identity_source"}
    if not isinstance(resolved, dict) or set(resolved) != {"model", "provider"}:
        return False
    if not isinstance(invocation, dict) or set(invocation) != invocation_keys:
        return False
    if review_evidence:
        requested = reviewer["requested"]
        if not all(
            receipt_text(resolved.get(key), maximum=MAX_INERT)
            for key in ("model", "provider")
        ):
            return False
        for key, explicit_key in (
            ("model", "model_explicit"),
            ("provider", "provider_explicit"),
        ):
            if requested[explicit_key] and resolved[key] != requested[key]:
                return False
            if not requested[explicit_key]:
                if review_set and resolved[key] == "<implicit-unresolved>":
                    return False
                if not review_set and resolved[key] != "<implicit-unresolved>":
                    return False
        if review_set:
            if (
                invocation["state"] != "complete"
                or not receipt_hex(invocation["identity"])
                or not receipt_timestamp(invocation["started_at"])
                or not receipt_timestamp(invocation["ended_at"])
                or invocation["started_at"] > invocation["ended_at"]
                or isinstance(invocation["tokens"], bool)
                or not isinstance(invocation["tokens"], int)
                or invocation["tokens"] < 0
                or invocation["rc"] != 0
                or invocation["identity_source"] != "spawn-dispatcher-v1"
            ):
                return False
        elif invocation != {
            "state": "not_required",
            "identity": "rules-memory-zero-candidate-v1",
            "started_at": None,
            "ended_at": None,
            "tokens": 0,
            "rc": None,
            "identity_source": "not_applicable",
        }:
            return False
    elif (
        resolved != {"model": None, "provider": None}
        or invocation
        != {
            "state": "not_started",
            "identity": None,
            "started_at": None,
            "ended_at": None,
            "tokens": 0,
            "rc": None,
            "identity_source": None,
        }
    ):
        return False

    by_id = {item["id"]: item for item in candidates}
    dispositions = receipt.get("dispositions")
    findings = receipt.get("findings")
    if not isinstance(dispositions, list) or not isinstance(findings, list):
        return False
    if state == "degraded":
        error = receipt.get("error")
        if (
            not isinstance(error, dict)
            or set(error) != {"code", "message"}
            or not receipt_text(error.get("code"), maximum=MAX_INERT)
            or not isinstance(error.get("message"), str)
            or len(error["message"]) > 512
        ):
            return False
    if not review_evidence:
        if (
            receipt.get("coverage") != "incomplete"
            or receipt.get("verdict") != "incomplete"
            or dispositions != []
            or findings != []
            or receipt.get("findings_digest") is not None
        ):
            return False
    else:
        if len(dispositions) != len(review_set):
            return False
        disposition_ids: list[str] = []
        disposition_by_id: dict[str, dict[str, Any]] = {}
        for item in dispositions:
            if not isinstance(item, dict) or set(item) != {"id", "state", "path", "citation", "evidence"}:
                return False
            rule_id = item["id"]
            if (
                rule_id not in by_id
                or rule_id in disposition_by_id
                or item["state"] not in {"applies", "requires_evidence", "falsified", "informational", "superseded"}
                or not safe_relative_path(item["path"])
                or item["citation"] != by_id[rule_id]["citation"]
                or not receipt_text(item["evidence"])
            ):
                return False
            disposition_ids.append(rule_id)
            disposition_by_id[rule_id] = item
        if disposition_ids != review_set:
            return False
        finding_by_id: dict[str, dict[str, Any]] = {}
        for item in findings:
            if not isinstance(item, dict) or set(item) != {"severity", "path", "id", "message"}:
                return False
            rule_id = item["id"]
            disposition = disposition_by_id.get(rule_id)
            if (
                disposition is None
                or rule_id in finding_by_id
                or item["severity"] != by_id[rule_id]["severity"]
                or item["path"] != disposition["path"]
                or not receipt_text(item["message"])
            ):
                return False
            finding_by_id[rule_id] = item
        for rule_id, disposition in disposition_by_id.items():
            applicable = disposition["state"] in {"applies", "requires_evidence"}
            if applicable != (rule_id in finding_by_id):
                return False
        expected_verdict = max(
            (item["severity"] for item in findings),
            key=lambda item: SEVERITY_RANK[item],
            default="clean",
        )
        if (
            receipt.get("coverage") != ("bounded" if omitted else "full")
            or receipt.get("verdict") != expected_verdict
            or not receipt_hex(receipt.get("findings_digest"))
            or not receipt_timestamp(receipt.get("reviewed_at"))
            or (
                receipt.get("response_digest") is not None
                and not receipt_hex(receipt.get("response_digest"))
            )
            or (bool(review_set) != (receipt.get("response_digest") is not None))
        ):
            return False

    delivery = receipt.get("delivery")
    allowed_delivery = {
        "pending", "delivery", "deferred", "deposited", "failed", "expired", "not_delivered"
    }
    if not isinstance(delivery, dict) or not set(delivery) <= {"status", "updated_at"}:
        return False
    if set(delivery) not in ({"status"}, {"status", "updated_at"}) or delivery.get("status") not in allowed_delivery:
        return False
    if delivery["status"] == "not_delivered" and state != "degraded":
        return False
    if "updated_at" in delivery and not receipt_timestamp(delivery["updated_at"]):
        return False
    if delivery["status"] not in {"pending", "not_delivered"} and "updated_at" not in delivery:
        return False
    return True


def inspect_receipt_status(
    root: Path,
    config: dict[str, Any],
    records: ValidatedRecords,
    ledger_digest: str,
    expected_index_digest: str | None,
) -> dict[str, Any]:
    absent = {
        "state": "absent",
        "count": 0,
        "coverage": None,
        "verdict": None,
        "reviewed_at": None,
        "delivery": None,
        "diff_freshness": "unverified",
        "error_code": None,
        "action": None,
    }
    receipt_dir = root / "tmp"
    if not receipt_dir.exists():
        return absent
    if receipt_dir.is_symlink() or not receipt_dir.is_dir():
        return {
            **absent,
            "state": "invalid",
            "error_code": "receipt_directory_unsafe",
            "action": "repair the project runtime directory before the next exact-diff review",
        }
    try:
        receipt_dir.resolve().relative_to(root.resolve())
    except ValueError:
        return {
            **absent,
            "state": "invalid",
            "error_code": "receipt_directory_escape",
            "action": "repair the project runtime directory before the next exact-diff review",
        }
    try:
        with os.scandir(receipt_dir) as scan:
            runtime_entries = [
                entry
                for _, entry in zip(range(MAX_STATUS_RUNTIME_ENTRIES + 1), scan)
            ]
    except OSError:
        return {
            **absent,
            "state": "invalid",
            "error_code": "receipt_directory_unreadable",
            "action": "repair the project runtime directory before the next exact-diff review",
        }
    if len(runtime_entries) > MAX_STATUS_RUNTIME_ENTRIES:
        return {
            **absent,
            "state": "invalid",
            "error_code": "receipt_directory_bound_exceeded",
            "action": "archive old runtime artifacts outside the project and rerun exact-diff review",
        }
    candidates = [
        Path(entry.path)
        for entry in runtime_entries
        if entry.name.startswith("critic-memory-receipt-") and entry.name.endswith(".json")
    ]
    if len(candidates) > MAX_STATUS_RECEIPTS:
        return {
            **absent,
            "state": "invalid",
            "count": len(candidates),
            "error_code": "receipt_bound_exceeded",
            "action": "archive old runtime receipts outside the project and rerun exact-diff review",
        }
    if not candidates:
        return absent
    try:
        latest: tuple[int, str, Path] | None = None
        for path in candidates:
            metadata = path.lstat()
            candidate = (metadata.st_mtime_ns, path.name, path)
            if latest is None or candidate[:2] > latest[:2]:
                latest = candidate
        assert latest is not None
        receipt, _ = read_status_receipt(latest[2])
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
        return {
            **absent,
            "state": "invalid",
            "count": len(candidates),
            "error_code": "receipt_invalid",
            "action": "move the invalid runtime receipt aside and rerun exact-diff review",
        }
    result = {**absent, "count": len(candidates)}
    if not validate_receipt_schema(receipt):
        return {
            **result,
            "state": "invalid",
            "error_code": "receipt_schema_invalid",
            "action": "move the invalid runtime receipt aside and rerun exact-diff review",
        }
    binding = receipt.get("binding")
    state = receipt.get("state")
    coverage = receipt.get("coverage")
    verdict = receipt.get("verdict")
    delivery = receipt.get("delivery")
    error = receipt.get("error")
    assert isinstance(binding, dict) and isinstance(delivery, dict)
    config_identity = status_file_identity(root / ".agents" / "config.toml")
    gates_identity = status_file_identity(root / ".agents" / "gates.md")
    source_layout_digest = hashlib.sha256(records.ledger_bytes).hexdigest()
    project_root = str(root.resolve())
    project_identity = hashlib.sha256(project_root.encode()).hexdigest()
    expected = {
        "project_root": project_root,
        "project_identity": project_identity,
        "config_identity": config_identity,
        "config_digest": config_identity["digest"],
        "config_state": config_identity["state"],
        "gates_identity": gates_identity,
        "gates_digest": gates_identity["digest"],
        "gates_state": gates_identity["state"],
        "policy_mode": config.get("mode"),
    }
    if any(binding.get(key) != value for key, value in expected.items()):
        return {
            **result,
            "state": "stale",
            "coverage": coverage,
            "verdict": verdict,
            "reviewed_at": receipt.get("reviewed_at"),
            "delivery": delivery.get("status"),
            "error_code": "receipt_binding_stale",
            "action": "run a fresh exact-diff review",
        }
    historical_expected = {
        "ledger_digest": ledger_digest,
        "source_layout_digest": source_layout_digest,
        "ledger_line_count": len(records),
        "index_digest": expected_index_digest,
        "index_schema_version": INDEX_SCHEMA_VERSION if expected_index_digest else None,
        "normalizer_version": NORMALIZER_VERSION if expected_index_digest else None,
        "vector_backend": VECTOR_BACKEND if expected_index_digest else None,
    }
    if state == "complete":
        stale_binding = any(
            binding.get(key) != value for key, value in historical_expected.items()
        )
    else:
        stale_binding = any(
            binding.get(key) is not None and binding.get(key) != value
            for key, value in historical_expected.items()
        )
    current_limits = {
        "max_channel_candidates": config["max_channel_candidates"],
        "max_fused_candidates": config["max_fused_candidates"],
        "max_prompt_records": config["max_prompt_records"],
    }
    if binding.get("limits") is not None and binding.get("limits") != current_limits:
        stale_binding = True
    if stale_binding:
        return {
            **result,
            "state": "stale",
            "coverage": coverage,
            "verdict": verdict,
            "reviewed_at": receipt.get("reviewed_at"),
            "delivery": delivery.get("status"),
            "error_code": "receipt_binding_stale",
            "action": "run a fresh exact-diff review",
        }

    active_records = {
        record["id"]: record for record in records if record.get("status") == "active"
    }
    for candidate in receipt["candidate_evidence"]:
        record = active_records.get(candidate["id"])
        expected_line = records.source_lines.get(candidate["id"])
        if (
            record is None
            or candidate["severity"] != record["severity"]
            or candidate["sources"] != record["sources"]
            or candidate["citation"] != f"{config['ledger']}:{expected_line}"
        ):
            return {
                **result,
                "state": "invalid",
                "error_code": "receipt_evidence_invalid",
                "action": "move the invalid runtime receipt aside and rerun exact-diff review",
            }
    if state == "complete" and delivery.get("status") != "deposited":
        return {
            **result,
            "state": "stale",
            "coverage": coverage,
            "verdict": verdict,
            "reviewed_at": receipt.get("reviewed_at"),
            "delivery": delivery.get("status"),
            "error_code": "receipt_delivery_incomplete",
            "action": "finish delivery or run a fresh exact-diff review",
        }
    result.update(
        state=state,
        coverage=coverage,
        verdict=verdict,
        reviewed_at=receipt.get("reviewed_at"),
        delivery=delivery.get("status"),
        error_code=(error.get("code") if isinstance(error, dict) else None),
        action=(
            "resolve the recorded runtime error and rerun exact-diff review"
            if state == "degraded"
            else None
        ),
    )
    return result


def runtime_status(
    root: Path,
    config: dict[str, Any],
    records: ValidatedRecords,
    ledger_digest: str,
) -> dict[str, Any]:
    try:
        index, expected_digest = inspect_index_status(root, config, records, ledger_digest)
    except (OSError, ValueError, sqlite3.DatabaseError):
        index = {
            "state": "invalid",
            "action": "repair the derived cache and rerun a bounded shipyard memory query",
            "error_code": "index_status_failed",
        }
        expected_digest = None
    try:
        receipt = inspect_receipt_status(root, config, records, ledger_digest, expected_digest)
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
        receipt = {
            "state": "invalid",
            "count": 0,
            "coverage": None,
            "verdict": None,
            "reviewed_at": None,
            "delivery": None,
            "diff_freshness": "unverified",
            "error_code": "receipt_status_failed",
            "action": "repair runtime receipt state and rerun exact-diff review",
        }
    return {
        "embedding": {
            "available": config.get("vector_backend") == VECTOR_BACKEND,
            "backend": config.get("vector_backend"),
            "dimensions": VECTOR_DIMENSIONS,
        },
        "index": index,
        "receipt": receipt,
    }


def build_index(path: Path, identity: dict[str, str], documents: list[dict[str, Any]]) -> None:
    connection = sqlite3.connect(path)
    try:
        connection.execute("pragma journal_mode=delete")
        connection.execute("pragma synchronous=full")
        connection.execute("pragma temp_store=memory")
        connection.execute("create table metadata (key text primary key, value text not null)")
        connection.execute(
            "create table records ("
            "id text primary key, occurred_at text not null, severity text not null, "
            "document text not null, associations text not null, citation text not null, "
            "original blob not null, record text not null, vector text not null)"
        )
        if identity["fts_backend"] == FTS5_BACKEND:
            connection.execute("create virtual table records_fts using fts5(id unindexed, document)")
        for document in documents:
            record = document["record"]
            connection.execute(
                "insert into records values (?,?,?,?,?,?,?,?,?)",
                (
                    document["id"],
                    document["occurred_at"],
                    record["severity"],
                    document["document"],
                    json.dumps(document["associations"], ensure_ascii=False, separators=(",", ":"), sort_keys=True),
                    json.dumps(document["citation"], ensure_ascii=False, separators=(",", ":"), sort_keys=True),
                    document["original"],
                    json.dumps(record, ensure_ascii=False, separators=(",", ":"), sort_keys=True),
                    json.dumps(sorted(document["vector"].items()), separators=(",", ":")),
                ),
            )
            if identity["fts_backend"] == FTS5_BACKEND:
                connection.execute("insert into records_fts(id,document) values (?,?)", (document["id"], document["document"]))
        metadata = {
            **identity,
            "index_digest": index_digest(identity, documents),
            "record_count": str(len(documents)),
            "state": "complete",
        }
        connection.executemany("insert into metadata(key,value) values (?,?)", sorted(metadata.items()))
        connection.commit()
        if connection.execute("pragma integrity_check").fetchone()[0] != "ok":
            raise sqlite3.DatabaseError("new memory index failed integrity_check")
    finally:
        connection.close()
    os.chmod(path, 0o600)
    with path.open("rb") as source:
        os.fsync(source.fileno())


def path_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def reject_symlink_components(path: Path) -> None:
    absolute = path.expanduser().absolute()
    current = Path(absolute.anchor)
    for part in absolute.parts[1:]:
        current /= part
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            continue
        # Platform aliases such as macOS /var -> /private/var are root-owned
        # and unavoidable. A user-owned symlink in the configured cache path
        # is mutable by the caller and therefore rejected.
        if stat.S_ISLNK(metadata.st_mode) and metadata.st_uid != 0:
            raise OSError(f"memory cache path contains symlink component: {current}")


def validate_cache_ancestors(path: Path) -> None:
    """Reject ancestors another non-root principal can replace."""
    reject_symlink_components(path)
    for ancestor in reversed(path.expanduser().absolute().parents):
        try:
            metadata = ancestor.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(metadata.st_mode):
            # Root-owned platform aliases were accepted by the symlink check.
            continue
        if not stat.S_ISDIR(metadata.st_mode):
            raise OSError(f"memory cache ancestor is not a directory: {ancestor}")
        writable = bool(stat.S_IMODE(metadata.st_mode) & 0o022)
        root_sticky = metadata.st_uid == 0 and bool(metadata.st_mode & stat.S_ISVTX)
        if writable and not root_sticky:
            raise OSError(
                f"memory cache ancestor is replaceable through a non-sticky writable directory: {ancestor}"
            )


def owned_directory(path: Path, *, private: bool) -> bool:
    try:
        metadata = path.lstat()
    except OSError:
        return False
    return (
        stat.S_ISDIR(metadata.st_mode)
        and not stat.S_ISLNK(metadata.st_mode)
        and metadata.st_uid == os.getuid()
        and (not private or stat.S_IMODE(metadata.st_mode) & 0o077 == 0)
    )


def group_world_writable(path: Path) -> bool:
    return bool(stat.S_IMODE(path.lstat().st_mode) & 0o022)


def valid_cache_marker(path: Path) -> bool:
    if not private_owned_regular(path):
        return False
    try:
        return path.read_text(encoding="ascii") == CACHE_MARKER_CONTENT
    except (OSError, UnicodeError):
        return False


def privatize_marked_shipyard_root(shipyard_root: Path) -> None:
    """Descriptor-validate a marked tree, tighten it, then verify its pathname."""
    directory_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    directory_flags |= getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    root_descriptor = os.open(shipyard_root, directory_flags)
    memory_descriptor: int | None = None
    marker_descriptor: int | None = None
    try:
        root_metadata = os.fstat(root_descriptor)
        if not stat.S_ISDIR(root_metadata.st_mode) or root_metadata.st_uid != os.getuid():
            raise OSError("Shipyard cache root is not an owned real directory")
        memory_descriptor = os.open("memory", directory_flags, dir_fd=root_descriptor)
        memory_metadata = os.fstat(memory_descriptor)
        if not stat.S_ISDIR(memory_metadata.st_mode) or memory_metadata.st_uid != os.getuid():
            raise OSError("rules-memory cache root is not an owned real directory")
        marker_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        marker_flags |= getattr(os, "O_NONBLOCK", 0)
        marker_descriptor = os.open(CACHE_MARKER, marker_flags, dir_fd=memory_descriptor)
        marker_metadata = os.fstat(marker_descriptor)
        marker_content = os.read(marker_descriptor, len(CACHE_MARKER_CONTENT.encode("ascii")) + 1)
        if (
            not stat.S_ISREG(marker_metadata.st_mode)
            or marker_metadata.st_uid != os.getuid()
            or stat.S_IMODE(marker_metadata.st_mode) & 0o077
            or marker_content != CACHE_MARKER_CONTENT.encode("ascii")
        ):
            raise OSError("rules-memory cache marker is missing or invalid")
        os.fchmod(root_descriptor, 0o700)
        current = shipyard_root.lstat()
        after = os.fstat(root_descriptor)
        if (
            (current.st_dev, current.st_ino) != (after.st_dev, after.st_ino)
            or not stat.S_ISDIR(current.st_mode)
            or current.st_uid != os.getuid()
            or stat.S_IMODE(current.st_mode) & 0o077
        ):
            raise OSError("Shipyard cache root changed while being privatized")
    finally:
        if marker_descriptor is not None:
            os.close(marker_descriptor)
        if memory_descriptor is not None:
            os.close(memory_descriptor)
        os.close(root_descriptor)


def prepare_cache_directory(root: Path, cache_key: str) -> Path:
    base = platform_cache_root().expanduser().absolute()
    validate_cache_ancestors(base)
    project = root.resolve()
    resolved_base = base.resolve(strict=False)
    if path_within(resolved_base, project):
        raise OSError("memory cache root must be outside the project worktree")
    base.mkdir(mode=0o700, parents=True, exist_ok=True)
    reject_symlink_components(base)
    if not owned_directory(base, private=False):
        raise OSError("memory cache root must be an owned real directory")
    if group_world_writable(base):
        raise OSError("memory cache root must not be group/world-writable")

    shipyard_root = base / "shipyard"
    shipyard_existed = shipyard_root.exists()
    memory_root = shipyard_root / "memory"
    marker = memory_root / CACHE_MARKER
    if shipyard_existed:
        if not owned_directory(shipyard_root, private=False):
            raise OSError("Shipyard cache node must be an owned real directory")
        if group_world_writable(shipyard_root):
            try:
                privatize_marked_shipyard_root(shipyard_root)
            except FileNotFoundError as exc:
                raise OSError("unmarked Shipyard cache root is group/world-writable") from exc
    shipyard_root.mkdir(mode=0o700, exist_ok=True)
    if not owned_directory(shipyard_root, private=False):
        raise OSError("Shipyard cache node must be an owned real directory")
    created_memory_root = not memory_root.exists()
    memory_root.mkdir(mode=0o700, exist_ok=True)
    if not owned_directory(memory_root, private=False):
        raise OSError("rules-memory cache root is unsafe")

    if created_memory_root:
        try:
            descriptor = os.open(
                marker,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
                0o600,
            )
        except FileExistsError:
            descriptor = None
        if descriptor is not None:
            try:
                os.write(descriptor, CACHE_MARKER_CONTENT.encode("ascii"))
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
    for _ in range(50):
        if private_owned_regular(marker):
            try:
                if marker.read_text(encoding="ascii") == CACHE_MARKER_CONTENT:
                    break
            except OSError:
                pass
        time.sleep(0.01)
    if not valid_cache_marker(marker):
        raise OSError("rules-memory cache marker is missing or invalid")
    # A valid private marker proves this subtree was created by Shipyard; only
    # then may a prior Shipyard version's permissive mode be repaired.
    os.chmod(shipyard_root, 0o700)
    os.chmod(memory_root, 0o700)

    cache_dir = memory_root / cache_key
    cache_dir.mkdir(mode=0o700, exist_ok=True)
    if not owned_directory(cache_dir, private=False):
        raise OSError("project memory cache node must be an owned real directory")
    os.chmod(cache_dir, 0o700)
    reject_symlink_components(cache_dir)
    if not path_within(cache_dir.resolve(), memory_root.resolve()):
        raise OSError("project memory cache escapes the Shipyard cache root")
    return cache_dir


def ensure_index(
    root: Path,
    ledger_digest: str,
    source_layout_digest: str,
    documents: list[dict[str, Any]],
) -> tuple[Path, sqlite3.Connection, dict[str, str], bool, str]:
    cache_key = project_cache_identity(root)
    cache_dir = prepare_cache_directory(root, cache_key)
    selected_fts = fts_backend()
    expected = index_identity(ledger_digest, source_layout_digest, selected_fts)
    desired_digest = index_digest(expected, documents)
    index_path = cache_dir / f"index-{desired_digest}.sqlite3"
    opened = open_current_index(index_path, expected, len(documents))
    if opened is not None:
        connection, metadata = opened
        return index_path, connection, metadata, False, cache_key

    lock_path = cache_dir / f"index-{desired_digest}.lock"
    lock_flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    lock_descriptor = os.open(lock_path, lock_flags, 0o600)
    temporary_path: Path | None = None
    acquired = False
    try:
        lock_metadata = os.fstat(lock_descriptor)
        if not stat.S_ISREG(lock_metadata.st_mode) or lock_metadata.st_uid != os.getuid():
            raise OSError("memory index lock is not a private owned regular file")
        os.fchmod(lock_descriptor, 0o600)
        deadline = time.monotonic() + INDEX_LOCK_SECONDS
        while True:
            try:
                fcntl.flock(lock_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("timed out waiting for memory index builder")
                time.sleep(0.02)
        opened = open_current_index(index_path, expected, len(documents))
        if opened is not None:
            connection, metadata = opened
            return index_path, connection, metadata, False, cache_key

        temporary_descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".index-{desired_digest}.tmp-", dir=cache_dir
        )
        os.close(temporary_descriptor)
        temporary_path = Path(temporary_name)
        build_index(temporary_path, expected, documents)
        opened = open_current_index(temporary_path, expected, len(documents))
        if opened is None:
            raise sqlite3.DatabaseError("new memory index did not validate")
        temporary_connection, _ = opened
        temporary_connection.close()
        os.replace(temporary_path, index_path)
        temporary_path = None
        directory_descriptor = os.open(cache_dir, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
        opened = open_current_index(index_path, expected, len(documents))
        if opened is None:
            raise sqlite3.DatabaseError("published memory index did not validate")
        connection, metadata = opened
        return index_path, connection, metadata, True, cache_key
    finally:
        if temporary_path is not None:
            try:
                temporary_path.unlink()
            except FileNotFoundError:
                pass
        if acquired:
            fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
        os.close(lock_descriptor)


def load_index_records(connection: sqlite3.Connection) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for row in connection.execute(
        "select id,occurred_at,severity,document,associations,citation,original,record,vector "
        "from records order by id"
    ):
        records.append(
            {
                "associations": json.loads(row["associations"]),
                "citation": json.loads(row["citation"]),
                "document": row["document"],
                "id": row["id"],
                "occurred_at": row["occurred_at"],
                "original": bytes(row["original"]),
                "record": json.loads(row["record"]),
                "severity": row["severity"],
                "vector": {int(bucket): float(value) for bucket, value in json.loads(row["vector"])},
            }
        )
    return records


def exact_channel(
    records: list[dict[str, Any]], text: str, features: dict[str, Any], limit: int
) -> list[tuple[str, float, dict[str, Any]]]:
    normalized = normalized_text(text)
    query_paths = features["paths"]
    ranked: list[tuple[str, float, dict[str, Any]]] = []
    for record in records:
        matches: list[dict[str, str]] = []
        for key, values in sorted(record["associations"].items()):
            for value in values:
                matched = False
                if key == "paths":
                    matched = any(fnmatch.fnmatchcase(path, value) for path in query_paths)
                else:
                    matched = normalized_text(value) in normalized
                if matched:
                    matches.append({"key": key, "value": value})
        if normalized_text(record["id"]) in normalized:
            matches.append({"key": "id", "value": record["id"]})
        if matches:
            matches.sort(key=lambda item: (item["key"], item["value"]))
            ranked.append((record["id"], float(len(matches)), {"matches": matches}))
    ranked.sort(key=lambda item: (-item[1], item[0]))
    return ranked[:limit]


def python_bm25_channel(
    records: list[dict[str, Any]], query_terms: list[str], limit: int
) -> list[tuple[str, float, dict[str, Any]]]:
    if not records or not query_terms:
        return []
    tokenized = {record["id"]: lexical_tokens(record["document"]) for record in records}
    document_frequency = {
        term: sum(term in set(tokens) for tokens in tokenized.values()) for term in query_terms
    }
    average_length = sum(len(tokens) for tokens in tokenized.values()) / len(records)
    ranked: list[tuple[str, float, dict[str, Any]]] = []
    for record in records:
        tokens = tokenized[record["id"]]
        counts: dict[str, int] = {}
        for token in tokens:
            counts[token] = counts.get(token, 0) + 1
        terms = sorted(term for term in query_terms if counts.get(term))
        score = 0.0
        for term in terms:
            frequency = counts[term]
            frequency_docs = document_frequency[term]
            inverse = math.log(1.0 + (len(records) - frequency_docs + 0.5) / (frequency_docs + 0.5))
            denominator = frequency + 1.2 * (1.0 - 0.75 + 0.75 * len(tokens) / max(average_length, 1.0))
            score += inverse * frequency * 2.2 / denominator
        if score > 0:
            ranked.append((record["id"], score, {"backend": BM25_BACKEND, "terms": terms[:32]}))
    ranked.sort(key=lambda item: (-item[1], item[0]))
    return ranked[:limit]


def fts_channel(
    connection: sqlite3.Connection,
    records: list[dict[str, Any]],
    query_terms: list[str],
    backend: str,
    limit: int,
) -> list[tuple[str, float, dict[str, Any]]]:
    if backend == BM25_BACKEND:
        return python_bm25_channel(records, query_terms, limit)
    if not query_terms:
        return []
    expression = " OR ".join(f'"{term}"' for term in query_terms)
    rows = connection.execute(
        "select id,bm25(records_fts) as raw_score from records_fts "
        "where records_fts match ? order by raw_score asc,id asc limit ?",
        (expression, limit),
    ).fetchall()
    by_id = {record["id"]: record for record in records}
    ranked: list[tuple[str, float, dict[str, Any]]] = []
    for row in rows:
        document_terms = set(lexical_tokens(by_id[row["id"]]["document"]))
        terms = sorted(set(query_terms) & document_terms)[:32]
        ranked.append(
            (row["id"], -float(row["raw_score"]), {"backend": FTS5_BACKEND, "terms": terms})
        )
    return ranked


def vector_channel(
    records: list[dict[str, Any]], text: str, limit: int
) -> tuple[list[tuple[str, float, dict[str, Any]]], bool]:
    query_vector, query_truncated = hash_ngram_vector(text)
    ranked: list[tuple[str, float, dict[str, Any]]] = []
    for record in records:
        score = cosine(query_vector, record["vector"])
        if score > 0:
            ranked.append(
                (
                    record["id"],
                    score,
                    {
                        "adapter": VECTOR_BACKEND,
                        "explanation": "signed hash-ngram cosine similarity",
                    },
                )
            )
    ranked.sort(key=lambda item: (-item[1], item[0]))
    return ranked[:limit], query_truncated


PROSE_SUFFIXES = {".adoc", ".md", ".mdx", ".rst", ".txt"}
GENERATED_BASENAMES = {
    "cargo.lock",
    "go.sum",
    "package-lock.json",
    "pnpm-lock.yaml",
    "poetry.lock",
    "uv.lock",
    "yarn.lock",
}
GENERATED_PARTS = {"build", "coverage", "dist", "node_modules", "vendor"}


def diff_path_requires_exact_only(path: str) -> bool:
    """Keep prose/generated-only edits out of similarity-only review."""
    normalized = path.casefold()
    pure = PurePosixPath(normalized)
    name = pure.name
    return (
        pure.suffix in PROSE_SUFFIXES
        or name in GENERATED_BASENAMES
        or name.endswith((".generated.js", ".generated.ts", ".min.css", ".min.js", ".map"))
        or bool(set(pure.parts) & GENERATED_PARTS)
    )


def excerpt(record: dict[str, Any]) -> dict[str, str]:
    return {field: record[field] for field in PROSE_FIELDS}


def fuse_channels(
    records: list[dict[str, Any]], channels: dict[str, list[tuple[str, float, dict[str, Any]]]], limit: int
) -> list[dict[str, Any]]:
    by_id = {record["id"]: record for record in records}
    fused: dict[str, dict[str, Any]] = {}
    for channel, ranked in channels.items():
        for rank, (record_id, score, explanation) in enumerate(ranked, 1):
            candidate = fused.setdefault(record_id, {"channels": {}, "score": 0.0})
            candidate["score"] += 1.0 / (60 + rank)
            candidate["channels"][channel] = {
                **explanation,
                "rank": rank,
                "score": round(score, 12),
            }

    def occurred(record: dict[str, Any]) -> float:
        return dt.datetime.fromisoformat(record["occurred_at"][:-1] + "+00:00").timestamp()

    ordered = sorted(
        fused,
        key=lambda record_id: (
            -fused[record_id]["score"],
            -SEVERITY_RANK[by_id[record_id]["severity"]],
            -occurred(by_id[record_id]),
            record_id,
        ),
    )[:limit]
    results: list[dict[str, Any]] = []
    for record_id in ordered:
        record = by_id[record_id]
        results.append(
            {
                "channels": fused[record_id]["channels"],
                "citation": record["citation"],
                "excerpt": excerpt(record["record"]),
                "fused_score": round(fused[record_id]["score"], 12),
                "id": record_id,
                "kind": record["record"]["kind"],
                "occurred_at": record["occurred_at"],
                "severity": record["severity"],
                "status": record["record"]["status"],
            }
        )
    return results


def query_memory(
    root: Path, scope_file: str | None, diff_file: str | None
) -> tuple[dict[str, Any], int]:
    document = base_document("query", root)
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

    kind = "scope" if scope_file is not None else "diff"
    path_value = scope_file if scope_file is not None else diff_file
    assert path_value is not None
    diagnostics = Diagnostics()
    raw, text = read_query_input(path_value, diagnostics)
    configured, config = parse_memory_config(root, diagnostics)
    document["configured"] = configured
    document["query_input"] = {"kind": kind, "path": str(Path(path_value).expanduser().absolute())}
    if not configured and not diagnostics.errors:
        document["candidates"] = []
        document["candidate_count"] = 0
        document["index"] = None
        return document, 0
    document.update(state="invalid", valid=False)
    if config is not None:
        document["mode"] = config.get("mode")
        document["ledger_path"] = config.get("ledger")
    if diagnostics.errors or config is None or raw is None or text is None:
        document["errors"] = diagnostics.errors
        return document, 2

    records, ledger_digest = validate_ledger(root, config, diagnostics)
    document["record_count"] = len(records)
    document["active_count"] = sum(record.get("status") == "active" for record in records)
    document["superseded_count"] = sum(record.get("status") == "superseded" for record in records)
    document["ledger_digest"] = ledger_digest
    document["errors"] = diagnostics.errors
    document["query_input"].update(
        {"bytes": len(raw), "digest": hashlib.sha256(raw).hexdigest()}
    )
    if diagnostics.errors or ledger_digest is None:
        return document, 2

    features = extract_query_features(text, kind)
    document["query_features"] = {
        key: value for key, value in features.items() if key != "terms"
    }
    document["query_features"]["term_count"] = len(features["terms"])
    limits = {
        "max_channel_candidates": config["max_channel_candidates"],
        "max_fused_candidates": config["max_fused_candidates"],
        "max_prompt_records": config["max_prompt_records"],
    }
    document["limits"] = limits
    documents = normalized_records(records, config["ledger"])
    if not documents:
        document.update(state="ready", valid=True)
        document["candidates"] = []
        document["candidate_count"] = 0
        document["index"] = None
        return document, 0

    try:
        source_layout_digest = hashlib.sha256(
            getattr(records, "ledger_bytes", b"")
        ).hexdigest()
        path, connection, metadata, rebuilt, cache_key = ensure_index(
            root, ledger_digest, source_layout_digest, documents
        )
        try:
            indexed_records = load_index_records(connection)
            channel_limit = limits["max_channel_candidates"]
            exact = exact_channel(indexed_records, text, features, channel_limit)
            exact_only = (
                kind == "diff"
                and bool(features["paths"])
                and all(diff_path_requires_exact_only(path) for path in features["paths"])
            )
            if exact_only:
                full_text = []
                vectors = []
                vector_truncated = False
            else:
                full_text = fts_channel(
                    connection,
                    indexed_records,
                    features["terms"],
                    metadata["fts_backend"],
                    channel_limit,
                )
                vectors, vector_truncated = vector_channel(
                    indexed_records, text, channel_limit
                )
            candidates = fuse_channels(
                indexed_records,
                {"exact": exact, "fts": full_text, "vector": vectors},
                limits["max_fused_candidates"],
            )
        finally:
            connection.close()
    except (OSError, TimeoutError, sqlite3.DatabaseError, ValueError, TypeError, json.JSONDecodeError) as exc:
        diagnostics.add("index_error", f"memory index/query failed: {exc}")
        document["errors"] = diagnostics.errors
        return document, 2

    document.update(state="ready", valid=True)
    document["candidates"] = candidates
    document["candidate_count"] = len(candidates)
    document["index"] = {
        "cache_key": cache_key,
        "digest": metadata["index_digest"],
        "fts_backend": metadata["fts_backend"],
        "normalizer_version": metadata["normalizer_version"],
        "rebuilt": rebuilt,
        "schema_version": int(metadata["index_schema_version"]),
        "shipyard_version": metadata["shipyard_version"],
        "source_layout_digest": metadata["source_layout_digest"],
        "vector_backend": metadata["vector_backend"],
    }
    document["query_features"]["vector_text_truncated"] = vector_truncated
    document["errors"] = []
    return document, 0


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
        document, exit_code = query_memory(root, args.scope_file, args.diff_file)
    else:
        document, exit_code = inspect_project(args.command, root)
    emit(document)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
