#!/usr/bin/env python3
"""Validate a project specialist manifest without evaluating or fetching it."""

from __future__ import annotations

import argparse
import re
import sys
import tomllib
from pathlib import Path, PurePosixPath
from urllib.parse import urlsplit


TOP_LEVEL_KEYS = {
    "schema_version",
    "slug",
    "prompt_definition",
    "decision_log",
    "hunk_path_patterns",
    "ticket_triggers",
    "external_repository_triggers",
    "live_docs",
}
LIVE_DOC_KEYS = {"label", "url", "authority", "access_mode"}
SLUG_RE = re.compile(r"^[A-Za-z0-9_-]+$")


def fail(message: str) -> None:
    raise ValueError(message)


def require_string(value: object, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        fail(f"{field} must be a non-empty string")
    if "\x00" in value:
        fail(f"{field} contains a NUL byte")
    return value


def safe_relative(value: object, field: str, *, allow_glob: bool = False) -> str:
    path = require_string(value, field)
    if "\\" in path:
        fail(f"{field} must use project-relative POSIX paths")
    pure = PurePosixPath(path)
    if pure.is_absolute() or path.startswith("~") or ".." in pure.parts:
        fail(f"{field} must stay inside the project")
    if not allow_glob and any(char in path for char in "*?["):
        fail(f"{field} must not contain glob syntax")
    if str(pure) in {"", "."}:
        fail(f"{field} must name a project-relative path")
    return path


def string_list(value: object, field: str, *, paths: bool = False) -> list[str]:
    if not isinstance(value, list):
        fail(f"{field} must be an array")
    result = []
    for index, item in enumerate(value):
        name = f"{field}[{index}]"
        result.append(safe_relative(item, name, allow_glob=True) if paths else require_string(item, name))
    return result


def validate_live_docs(value: object) -> None:
    if not isinstance(value, list):
        fail("live_docs must be an array of tables")
    for index, entry in enumerate(value):
        field = f"live_docs[{index}]"
        if not isinstance(entry, dict):
            fail(f"{field} must be a table")
        if set(entry) != LIVE_DOC_KEYS:
            fail(f"{field} keys must be exactly {sorted(LIVE_DOC_KEYS)}")
        require_string(entry["label"], f"{field}.label")
        require_string(entry["authority"], f"{field}.authority")
        access_mode = require_string(entry["access_mode"], f"{field}.access_mode")
        if access_mode not in {"public", "authenticated"}:
            fail(f"{field}.access_mode must be public or authenticated")
        url = require_string(entry["url"], f"{field}.url")
        parsed = urlsplit(url)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
            fail(f"{field}.url must be an https URL without credentials")


def validate(project: Path, manifest_path: Path) -> None:
    project = project.resolve()
    manifest_path = manifest_path.resolve()
    try:
        manifest_path.relative_to(project)
    except ValueError:
        fail("manifest must stay inside the project")

    with manifest_path.open("rb") as handle:
        data = tomllib.load(handle)
    if set(data) != TOP_LEVEL_KEYS:
        fail(f"top-level keys must be exactly {sorted(TOP_LEVEL_KEYS)}")
    if type(data["schema_version"]) is not int or data["schema_version"] != 1:
        fail("schema_version must be integer 1")

    slug = require_string(data["slug"], "slug")
    if not SLUG_RE.fullmatch(slug):
        fail("slug must match [A-Za-z0-9_-]+")
    if manifest_path.stem != slug:
        fail("slug must match the manifest filename")

    for field in ("prompt_definition", "decision_log"):
        relative = safe_relative(data[field], field)
        candidate = (project / relative).resolve()
        try:
            candidate.relative_to(project)
        except ValueError:
            fail(f"{field} resolves outside the project")
        if not candidate.is_file():
            fail(f"{field} does not name an existing file")

    string_list(data["hunk_path_patterns"], "hunk_path_patterns", paths=True)
    string_list(data["ticket_triggers"], "ticket_triggers")
    string_list(data["external_repository_triggers"], "external_repository_triggers")
    validate_live_docs(data["live_docs"])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", required=True, type=Path)
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    try:
        validate(args.project, args.manifest)
    except (OSError, tomllib.TOMLDecodeError, ValueError) as exc:
        print(f"specialist manifest invalid: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
