#!/usr/bin/env python3
"""Read-only Shipyard fleet inspection document builder (schema v1)."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


ROLE_ORDER = ("design", "build", "release", "medic", "scribe")
COVERAGE_ORDER = (
    "manifest",
    "config",
    "systemd",
    "doctor",
    "events",
    "events_attribution",
    "fyi",
    "usage",
    "caddy",
    "incident_state",
    "proposals",
    "decisions",
    "overseer",
    "delegation_claude",
    "delegation_codex",
    "delegation_hermes",
)
PROJECT_SOURCES = tuple(
    source for source in COVERAGE_ORDER if source not in {
        "events_attribution",
        "delegation_claude",
        "delegation_codex",
        "delegation_hermes",
    }
)
GLOBAL_SOURCES = (
    "events_attribution",
    "delegation_claude",
    "delegation_codex",
    "delegation_hermes",
)
DISCOVERY_LIMITATIONS = [
    "skills_only_checkouts_excluded",
    "byte_matching_service_spoof_indistinguishable",
    "current_user_unit_scope_only",
    "non_atomic_snapshot",
]
PHASE_ONE_LIMITATION = "adapter_not_implemented_phase_1"
ASCII_POSITIVE_INTEGER = re.compile(r"^[1-9][0-9]*$")
RFC3339 = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})$"
)


class InspectInvocationError(ValueError):
    """Malformed command input."""


def _format_utc(value: datetime) -> str:
    return value.astimezone(timezone.utc).replace(microsecond=0).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )


def inspection_clock() -> datetime:
    injected = os.environ.get("SHIPYARD_INSPECT_NOW")
    if injected is None:
        return datetime.now(timezone.utc).replace(microsecond=0)
    if not RFC3339.fullmatch(injected):
        raise InspectInvocationError(
            "SHIPYARD_INSPECT_NOW must be a timezone-aware RFC3339 timestamp"
        )
    try:
        parsed = datetime.fromisoformat(injected.replace("Z", "+00:00"))
    except ValueError as exc:
        raise InspectInvocationError(
            "SHIPYARD_INSPECT_NOW must be a timezone-aware RFC3339 timestamp"
        ) from exc
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise InspectInvocationError(
            "SHIPYARD_INSPECT_NOW must be a timezone-aware RFC3339 timestamp"
        )
    return parsed.astimezone(timezone.utc).replace(microsecond=0)


def parse_days(value: str) -> int:
    if not ASCII_POSITIVE_INTEGER.fullmatch(value):
        raise InspectInvocationError("--days must be a positive integer")
    days = int(value, 10)
    try:
        timedelta(days=days)
    except OverflowError as exc:
        raise InspectInvocationError("--days is outside the supported range") from exc
    return days


def _canonical(path: str | Path, *, strict: bool) -> str | None:
    try:
        candidate = Path(path)
        if not candidate.is_absolute():
            return None
        return str(candidate.resolve(strict=strict))
    except (OSError, RuntimeError):
        return None


def _single_value(lines: list[str], key: str) -> str | None:
    values = [line[len(key) :] for line in lines if line.startswith(key)]
    return values[0] if len(values) == 1 and values[0] else None


def _event_root_env(lines: list[str]) -> str | None:
    values: list[str] = []
    for line in lines:
        if not line.startswith("Environment="):
            continue
        try:
            tokens = shlex.split(line[len("Environment=") :], posix=True)
        except ValueError:
            return None
        for token in tokens:
            if token.startswith("QUARTET_EVENTS_DIR="):
                values.append(token.split("=", 1)[1])
    if len(values) != 1:
        return None
    return _canonical(values[0], strict=False)


def _parse_exec_project(tokens: list[str]) -> str | None:
    indexes = [index for index, token in enumerate(tokens) if token == "--project"]
    if len(indexes) != 1 or indexes[0] + 1 >= len(tokens):
        return None
    return tokens[indexes[0] + 1]


def _on_calendar(service_path: Path) -> str | None:
    timer_path = service_path.with_suffix(".timer")
    try:
        lines = timer_path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return None
    return _single_value(lines, "OnCalendar=")


def discover_manifests(core_root: str, unit_dir: str) -> list[dict[str, Any]]:
    expected_runners: dict[str, str] = {}
    for role in ROLE_ORDER:
        runner = _canonical(Path(core_root) / "agents" / role / "runner.sh", strict=True)
        if runner is not None:
            expected_runners[role] = runner

    directory = Path(unit_dir)
    try:
        service_paths = sorted(directory.glob("*.service"))
    except OSError:
        return []

    accepted: list[dict[str, Any]] = []
    for service_path in service_paths:
        try:
            lines = service_path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError):
            continue
        working_raw = _single_value(lines, "WorkingDirectory=")
        exec_raw = _single_value(lines, "ExecStart=")
        if working_raw is None or exec_raw is None:
            continue
        try:
            tokens = shlex.split(exec_raw, posix=True)
        except ValueError:
            continue
        if len(tokens) < 2 or tokens[0] != "/bin/bash":
            continue
        project_raw = _parse_exec_project(tokens)
        if project_raw is None:
            continue

        working_directory = _canonical(working_raw, strict=True)
        project_path = _canonical(project_raw, strict=True)
        runner = _canonical(tokens[1], strict=True)
        service_canonical = _canonical(service_path, strict=True)
        if (
            working_directory is None
            or project_path is None
            or runner is None
            or service_canonical is None
            or working_directory != project_path
            or not Path(project_path).is_dir()
        ):
            continue

        role = next(
            (
                candidate
                for candidate in ROLE_ORDER
                if expected_runners.get(candidate) == runner
            ),
            None,
        )
        if role is None:
            continue

        accepted.append(
            {
                "service_path": service_canonical,
                "source_service_path": str(service_path.absolute()),
                "service_stem": service_path.stem,
                "role": role,
                "project_path": project_path,
                "working_directory": working_directory,
                "runner": runner,
                "event_root_env": _event_root_env(lines),
                "on_calendar": _on_calendar(service_path),
            }
        )
    return sorted(
        accepted,
        key=lambda item: (
            item["project_path"],
            ROLE_ORDER.index(item["role"]),
            item["service_stem"],
            item["service_path"],
        ),
    )


def _canonical_operand_json(fields: dict[str, Any]) -> str:
    return json.dumps(
        fields,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    )


def _evidence_id(source_kind: str, source_ref: str, fields: dict[str, Any]) -> str:
    if "\0" in source_kind or "\0" in source_ref:
        raise ValueError("evidence source strings cannot contain NUL")
    payload = (
        source_kind + "\0" + source_ref + "\0" + _canonical_operand_json(fields)
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()[:20]


def _project_id(project_path: str) -> str:
    return hashlib.sha256(project_path.encode("utf-8")).hexdigest()[:12]


def _coverage(
    project_id: str | None,
    source: str,
    state: str,
    reason: str,
    *,
    total: int = 0,
    valid: int = 0,
    limitations: list[str] | None = None,
) -> dict[str, Any]:
    return {
        "project_id": project_id,
        "source": source,
        "state": state,
        "reason": reason,
        "newest_ts": None,
        "records_total": total,
        "records_valid": valid,
        "records_invalid": 0,
        "records_out_of_window": 0,
        "records_unattributed": 0,
        "records_ambiguous": 0,
        "limitations": limitations or [],
    }


def _manifest_evidence(manifest: dict[str, Any], project_id: str) -> dict[str, Any]:
    fields = {
        "service_stem": manifest["service_stem"],
        "role": manifest["role"],
        "project_path": manifest["project_path"],
        "working_directory": manifest["working_directory"],
        "runner": manifest["runner"],
        "event_root_env": manifest["event_root_env"],
    }
    source_ref = f"file:{manifest['service_path']}:pointer:/"
    return {
        "id": _evidence_id("manifest", source_ref, fields),
        "project_id": project_id,
        "source": "manifest",
        "claim_kind": "fact",
        "kind": "manifest_identity",
        "observed_at": None,
        "source_ref": source_ref,
        "recurrence_key": None,
        "fields": fields,
        "limitations": [],
    }


def _unit_skeleton(
    manifest: dict[str, Any], evidence_id: str
) -> dict[str, Any]:
    project_name = Path(manifest["project_path"]).name
    prefix = f"{project_name}-"
    stem = manifest["service_stem"]
    display = stem[len(prefix) :] if stem.startswith(prefix) else stem.rsplit("-", 1)[-1]
    return {
        "role": manifest["role"],
        "display": display,
        "service_unit": f"{stem}.service",
        "timer_unit": f"{stem}.timer",
        "on_calendar": manifest["on_calendar"],
        "unit_file_state": None,
        "timer_load_state": None,
        "timer_active_state": None,
        "timer_sub_state": None,
        "timer_stale_state": "unknown",
        "service_load_state": None,
        "service_active_state": None,
        "service_sub_state": None,
        "service_result": None,
        "exec_main_status": None,
        "last_trigger_at": None,
        "next_trigger_at": None,
        "evidence_ids": [evidence_id],
    }


def _pressure_skeleton(roles: list[str]) -> dict[str, Any]:
    consumers = (
        ("design_runner", "design"),
        ("build_runner", "build"),
        ("release_runner", "release"),
        ("release_shoulder_critic", "release"),
        ("medic_runner", "medic"),
        ("scribe_runner", "scribe"),
    )
    daily = []
    for consumer, role in consumers:
        if consumer == "release_shoulder_critic":
            applicability = "unknown"
        else:
            applicability = "applicable" if role in roles else "not_applicable"
        daily.append(
            {
                "consumer": consumer,
                "role": role,
                "applicability": applicability,
                "gate_scope": None,
                "event_root_state": None,
                "event_root": None,
                "attributed_tokens_today": None,
                "gate_tokens_today": None,
                "gate_records_invalid_today": None,
                "configured_daily_budget": None,
                "attributed_fraction_today": None,
                "gate_fraction_today": None,
                "evidence_ids": [],
            }
        )
    return {
        "budget_deferrals_by_consumer": {
            "design_runner": None,
            "build_runner": None,
            "release_runner": None,
            "release_shoulder_critic": None,
            "medic_runner": None,
            "scribe_runner": None,
        },
        "open_cap_deferrals": None,
        "daily_budget_consumers": daily,
        "undecided_open_proposals": None,
        "configured_max_open_proposals": None,
        "open_cap_remaining": None,
        "evidence_ids": [],
    }


def _fleet_record(
    project_path: str,
    manifests: list[dict[str, Any]],
    evidence_by_path: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    project_id = _project_id(project_path)
    first_by_role: dict[str, dict[str, Any]] = {}
    for manifest in manifests:
        first_by_role.setdefault(manifest["role"], manifest)
    roles = [role for role in ROLE_ORDER if role in first_by_role]
    units = []
    for role in roles:
        manifest = first_by_role[role]
        evidence = evidence_by_path[manifest["service_path"]]
        units.append(_unit_skeleton(manifest, evidence["id"]))
    return {
        "project_id": project_id,
        "project_name": Path(project_path).name,
        "project_path": project_path,
        "autonomous": None,
        "state": "unknown",
        "state_reason_ids": [],
        "roles": roles,
        "units": units,
        "doctor": {"state": "unavailable", "exit_code": None, "findings": []},
        "jobs": {
            "by_status": {
                "ok": 0,
                "fail": 0,
                "partial": 0,
                "abort": 0,
                "skipped": 0,
                "other": 0,
            },
            "by_reason": {},
            "last_end_at": None,
            "duration_seconds_p50": None,
            "duration_seconds_p95": None,
            "evidence_ids": [],
        },
        "incidents": [],
        "critiques": {
            "block": 0,
            "warn": 0,
            "note": 0,
            "files": 0,
            "tokens": 0,
            "spawn_failed": 0,
            "delivery_failed": 0,
            "budget_deferred": 0,
            "evidence_ids": [],
        },
        "pressure": _pressure_skeleton(roles),
        "safety": {
            "config_state": "unavailable",
            "can_merge": None,
            "allow_no_ci": None,
            "forbidden_paths": [],
            "release_verify_gate": None,
            "configured_branch": None,
            "trunk_state": "unavailable",
            "trunk": None,
            "trunk_reason": "config_unavailable",
            "test_cmd_configured": None,
            "typecheck_configured": None,
            "daily_escalation_cap": None,
            "evidence_ids": [],
        },
        "overseer": {
            "applicability": "unknown",
            "state": "unavailable",
            "reason": "config_unknown",
            "healthy": None,
            "status": None,
            "summary": None,
            "findings_count": None,
            "assessed_at": None,
            "evidence_ids": [],
            "limitations": [],
        },
        "limitations": [PHASE_ONE_LIMITATION],
    }


def build_document(
    *, core_root: str, unit_dir: str, started_at: datetime, days: int
) -> dict[str, Any] | None:
    manifests = discover_manifests(core_root, unit_dir)
    if not manifests:
        return None

    by_project: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for manifest in manifests:
        by_project[manifest["project_path"]].append(manifest)

    evidence = [
        _manifest_evidence(manifest, _project_id(manifest["project_path"]))
        for manifest in manifests
    ]
    evidence_by_path = {
        item["source_ref"][len("file:") : -len(":pointer:/")]: item
        for item in evidence
    }
    fleet = [
        _fleet_record(project_path, project_manifests, evidence_by_path)
        for project_path, project_manifests in by_project.items()
    ]
    fleet.sort(key=lambda item: item["project_id"])
    evidence.sort(key=lambda item: item["id"])

    coverage: list[dict[str, Any]] = []
    for project in fleet:
        count = len(by_project[project["project_path"]])
        coverage.append(
            _coverage(
                project["project_id"],
                "manifest",
                "available",
                "ok",
                total=count,
                valid=count,
            )
        )
        for source in PROJECT_SOURCES:
            if source == "manifest":
                continue
            coverage.append(
                _coverage(
                    project["project_id"],
                    source,
                    "unavailable",
                    "unsupported",
                    limitations=[PHASE_ONE_LIMITATION],
                )
            )
    for source in GLOBAL_SOURCES:
        coverage.append(
            _coverage(
                None,
                source,
                "unavailable",
                "unsupported",
                limitations=[PHASE_ONE_LIMITATION],
            )
        )
    source_rank = {source: index for index, source in enumerate(COVERAGE_ORDER)}
    coverage.sort(
        key=lambda item: (
            item["project_id"] is not None,
            item["project_id"] or "",
            source_rank[item["source"]],
        )
    )

    started_text = _format_utc(started_at)
    window_start = _format_utc(started_at - timedelta(days=days))
    role_count = sum(len(project["roles"]) for project in fleet)
    return {
        "schema_version": 1,
        "meta": {
            "inspection_started_at": started_text,
            "window_start_at": window_start,
            "window_end_at": started_text,
            "window_days": days,
            "core_root": core_root,
            "unit_dir": unit_dir,
            "scope": "current_user_matching_core_root",
            "rule_version": "shipyard-inspect-v1",
            "project_count": len(fleet),
            "role_count": role_count,
            "discovery_limitations": DISCOVERY_LIMITATIONS,
        },
        "coverage": coverage,
        "evidence": evidence,
        "fleet": fleet,
        "attention": [],
        "effectiveness": [],
        "priorities": [],
        "summary": {
            "fleet_state": "unknown",
            "project_state_counts": {
                "fault_observed": 0,
                "degraded_observed": 0,
                "no_fault_observed": 0,
                "unknown": len(fleet),
            },
            "attention_count": 0,
            "effectiveness_state_counts": {
                "measured": 0,
                "partial": 0,
                "unmeasured": 0,
            },
            "priority_count": 0,
            "top_priority_ids": [],
        },
    }


def render_human(document: dict[str, Any]) -> str:
    meta = document["meta"]
    lines = [
        "shipyard inspect — fleet observation",
        (
            f"window: {meta['window_start_at']} to {meta['window_end_at']} "
            f"({meta['window_days']}d, end exclusive)"
        ),
        f"fleet: {meta['project_count']} project(s), {meta['role_count']} role(s)",
        f"state: {document['summary']['fleet_state']}",
    ]
    for project in document["fleet"]:
        roles = ",".join(project["roles"])
        lines.append(
            f"  - {project['project_name']}: {project['state']} roles={roles}"
        )
    lines.append("limitations: manifest discovery only in Phase 1")
    return "\n".join(lines)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="shipyard inspect")
    parser.add_argument("--core-root", required=True)
    parser.add_argument("--unit-dir", required=True)
    parser.add_argument("--days", default="7")
    parser.add_argument("--json", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        days = parse_days(args.days)
        started_at = inspection_clock()
        # Validate the complete requested interval before fleet discovery so a
        # malformed range remains exit 2 even on a machine with no manifests.
        started_at - timedelta(days=days)
        core_root = _canonical(args.core_root, strict=True)
        unit_dir = _canonical(args.unit_dir, strict=False)
        if core_root is None or unit_dir is None:
            raise InspectInvocationError("core root and unit dir must be absolute paths")
        document = build_document(
            core_root=core_root,
            unit_dir=unit_dir,
            started_at=started_at,
            days=days,
        )
    except (InspectInvocationError, OverflowError) as exc:
        print(f"shipyard inspect: {exc}", file=sys.stderr)
        return 2
    if document is None:
        print("shipyard inspect: no eligible Shipyard installation", file=sys.stderr)
        return 3
    if args.json:
        print(
            json.dumps(
                document,
                indent=2,
                ensure_ascii=False,
                allow_nan=False,
            )
        )
    else:
        print(render_human(document))
    return 0


if __name__ == "__main__":
    sys.exit(main())
