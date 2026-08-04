#!/usr/bin/env python3
"""Deterministic specialist selection and review-output normalization."""

from __future__ import annotations

import argparse
import fnmatch
import importlib.util
import json
import re
import shlex
import sys
from datetime import datetime, timezone
from pathlib import Path


SEVERITY = {"note": 1, "warn": 2, "block": 3}


def load_validator(shipyard: Path):
    path = shipyard / "agents/specialist/validate-manifest.py"
    spec = importlib.util.spec_from_file_location("shipyard_specialist_manifest", path)
    if spec is None or spec.loader is None:
        raise ValueError("specialist manifest validator is unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def normalize_diff_path(raw: str, project: Path) -> str:
    path = raw
    if path.startswith(("a/", "b/")):
        path = path[2:]
    lexical = project.absolute().as_posix()
    resolved = project.resolve().as_posix()
    absolute_candidates = {lexical, resolved}
    # macOS resolves /var to /private/var while git's no-index header retains
    # the lexical /var spelling. Keep both forms as path identities.
    absolute_candidates.update(
        value[len("/private") :]
        for value in tuple(absolute_candidates)
        if value.startswith("/private/")
    )
    candidates = tuple(absolute_candidates) + tuple(
        value.lstrip("/") for value in absolute_candidates
    )
    for prefix in candidates:
        if path.startswith(prefix + "/"):
            return path[len(prefix) + 1 :]
    return path.lstrip("/")


def diff_sections(diff: str, project: Path) -> list[tuple[str, str, str]]:
    starts = [m.start() for m in re.finditer(r"(?m)^diff --git ", diff)]
    sections: list[tuple[str, str, str]] = []
    for index, start in enumerate(starts):
        end = starts[index + 1] if index + 1 < len(starts) else len(diff)
        section = diff[start:end].rstrip()
        header = section.splitlines()[0]
        try:
            parts = shlex.split(header[len("diff --git ") :])
        except ValueError:
            continue
        if len(parts) != 2:
            continue
        raw_path = parts[1] if parts[1] != "/dev/null" else parts[0]
        path = normalize_diff_path(raw_path, project)
        lines = section.splitlines()
        has_hunk = any(line.startswith("@@") for line in lines)
        changed = [
            line[1:]
            for line in lines
            if (line.startswith("+") and not line.startswith("+++"))
            or (line.startswith("-") and not line.startswith("---"))
        ]
        if has_hunk and changed:
            sections.append((path, section, "\n".join(changed)))
    return sections


def cmd_select(args: argparse.Namespace) -> int:
    project_input = args.project.absolute()
    project = args.project.resolve()
    manifest_dir = project / ".agents/specialists"
    if not manifest_dir.is_dir():
        print("[]")
        return 0
    validator = load_validator(args.shipyard.resolve())
    sections = diff_sections(
        args.diff_file.read_text(encoding="utf-8"), project_input
    )
    selected = []
    for manifest in sorted(manifest_dir.glob("*.toml")):
        try:
            validator.validate(project, manifest)
        except (OSError, ValueError) as exc:
            raise ValueError(f"specialist manifest invalid: {manifest.name}: {exc}") from exc
        import tomllib

        with manifest.open("rb") as handle:
            data = tomllib.load(handle)
        matched = []
        for path, hunk, changed_text in sections:
            path_match = any(
                fnmatch.fnmatchcase(path, pattern)
                for pattern in data["hunk_path_patterns"]
            )
            ticket_match = (
                "/tickets/" in f"/{path}"
                and path.endswith(".md")
                and any(
                    trigger.casefold() in changed_text.casefold()
                    for trigger in data["external_repository_triggers"]
                )
            )
            if path_match or ticket_match:
                matched.append((path, hunk))
        if not matched:
            continue
        selected.append(
            {
                "slug": data["slug"],
                "manifest": str(manifest.relative_to(project)),
                "prompt_definition": data["prompt_definition"],
                "decision_log": data["decision_log"],
                "matched_paths": [path for path, _ in matched],
                "hunks": "\n".join(hunk for _, hunk in matched),
                "hunk_path_patterns": data["hunk_path_patterns"],
                "external_repository_triggers": data[
                    "external_repository_triggers"
                ],
                "live_docs": data["live_docs"],
            }
        )
    print(json.dumps(selected, separators=(",", ":")))
    return 0


def normalized_message(message: str) -> str:
    return " ".join(message.split()).casefold()


def cmd_merge(args: argparse.Namespace) -> int:
    ordered: list[tuple[str, str, str]] = []
    positions: dict[tuple[str, str], int] = {}
    for path in args.files:
        for raw in path.read_text(encoding="utf-8").splitlines():
            parts = raw.split("|", 2)
            if len(parts) != 3 or parts[0] not in SEVERITY:
                continue
            severity, finding_path, message = (part.strip() for part in parts)
            if not finding_path or not message:
                continue
            key = (finding_path, normalized_message(message))
            if key not in positions:
                positions[key] = len(ordered)
                ordered.append((severity, finding_path, message))
            elif SEVERITY[severity] > SEVERITY[ordered[positions[key]][0]]:
                ordered[positions[key]] = (severity, finding_path, message)
    for finding in ordered:
        print("|".join(finding))
    return 0


def cmd_sources(args: argparse.Namespace) -> int:
    docs = json.loads(args.live_docs_json)
    by_url = {entry["url"]: entry for entry in docs}
    evidence = {}
    for raw in args.response_file.read_text(encoding="utf-8").splitlines():
        parts = raw.split("|", 4)
        if len(parts) != 5 or parts[0] != "source":
            continue
        _, url, retrieved_at, status, claim = (part.strip() for part in parts)
        if url not in by_url or status not in {"success", "failure", "unverified"}:
            continue
        if not retrieved_at or not claim:
            continue
        evidence.setdefault(url, (retrieved_at, status, claim))
    fallback_time = args.reviewed_at or datetime.now(timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    for url in by_url:
        retrieved_at, status, claim = evidence.get(
            url,
            (fallback_time, "unverified", "specialist returned no retrieval evidence"),
        )
        print(f"source|{url}|{retrieved_at}|{status}|{claim}")
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    select = commands.add_parser("select")
    select.add_argument("--project", type=Path, required=True)
    select.add_argument("--shipyard", type=Path, required=True)
    select.add_argument("--diff-file", type=Path, required=True)
    select.set_defaults(func=cmd_select)
    merge = commands.add_parser("merge-findings")
    merge.add_argument("files", type=Path, nargs="+")
    merge.set_defaults(func=cmd_merge)
    sources = commands.add_parser("source-evidence")
    sources.add_argument("--live-docs-json", required=True)
    sources.add_argument("--response-file", type=Path, required=True)
    sources.add_argument("--reviewed-at", default="")
    sources.set_defaults(func=cmd_sources)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        return args.func(args)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"specialist review invalid: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
