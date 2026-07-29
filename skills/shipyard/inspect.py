#!/usr/bin/env python3
"""Read-only Shipyard fleet inspection document builder (schema v1)."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shlex
import shutil
import subprocess
import sys
import tomllib
from collections import defaultdict
from concurrent.futures import Future, ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit


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
LATER_PHASE_LIMITATION = "adapter_not_implemented_later_phase"
ASCII_POSITIVE_INTEGER = re.compile(r"^[1-9][0-9]*$")
ASCII_NONNEGATIVE_INTEGER = re.compile(r"^[0-9]+$")
RFC3339 = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})$"
)
ASCII_DECIMAL_MICROSECONDS = re.compile(r"^[0-9]+$")
CONSUMERS = (
    ("design_runner", "design"),
    ("build_runner", "build"),
    ("release_runner", "release"),
    ("release_shoulder_critic", "release"),
    ("medic_runner", "medic"),
    ("scribe_runner", "scribe"),
)
PRIORITY_CATEGORIES = (
    "confirmed_failure",
    "human_gate",
    "recurring_failure",
    "evidenced_opportunity",
    "instrumentation_gap",
    "hygiene",
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
    invalid: int = 0,
    out_of_window: int = 0,
    unattributed: int = 0,
    ambiguous: int = 0,
    newest_ts: str | None = None,
    limitations: list[str] | None = None,
) -> dict[str, Any]:
    return {
        "project_id": project_id,
        "source": source,
        "state": state,
        "reason": reason,
        "newest_ts": newest_ts,
        "records_total": total,
        "records_valid": valid,
        "records_invalid": invalid,
        "records_out_of_window": out_of_window,
        "records_unattributed": unattributed,
        "records_ambiguous": ambiguous,
        "limitations": limitations or [],
    }


def _coverage_evidence(record: dict[str, Any]) -> dict[str, Any]:
    fields = {
        "project_id": record["project_id"],
        "source": record["source"],
        "state": record["state"],
        "reason": record["reason"],
        "records_total": record["records_total"],
        "records_valid": record["records_valid"],
        "records_invalid": record["records_invalid"],
        "records_out_of_window": record["records_out_of_window"],
        "records_unattributed": record["records_unattributed"],
        "records_ambiguous": record["records_ambiguous"],
    }
    owner = record["project_id"] if record["project_id"] is not None else "global"
    source_ref = f"derived:coverage:{owner}:{record['source']}"
    return {
        "id": _evidence_id("coverage", source_ref, fields),
        "project_id": record["project_id"],
        "source": record["source"],
        "claim_kind": "derived",
        "kind": "coverage_gap",
        "observed_at": record["newest_ts"],
        "source_ref": source_ref,
        "recurrence_key": f"coverage:{record['source']}:{record['reason']}",
        "fields": fields,
        "limitations": list(record["limitations"]),
    }


def _budget_value(value: Any) -> int:
    if isinstance(value, bool):
        return 1_000_000
    if isinstance(value, int) and value >= 0:
        return value
    if isinstance(value, str) and ASCII_NONNEGATIVE_INTEGER.fullmatch(value):
        return int(value, 10)
    return 1_000_000


def _max_open_value(value: Any) -> int:
    if isinstance(value, bool):
        return 1
    if isinstance(value, int) and value >= 0:
        return value
    if isinstance(value, str) and ASCII_NONNEGATIVE_INTEGER.fullmatch(value):
        return int(value, 10)
    return 1


def _nested(config: dict[str, Any], section: str, key: str, default: Any) -> Any:
    table = config.get(section)
    if not isinstance(table, dict):
        return default
    return table.get(key, default)


def _available_config(
    project: dict[str, Any], config_path: Path, config: dict[str, Any]
) -> tuple[dict[str, Any], dict[str, Any]]:
    autonomous = config.get("autonomous", False)
    if not isinstance(autonomous, bool):
        raise ValueError("autonomous must be a boolean")

    can_merge = _nested(config, "medic", "can_merge", False)
    can_merge = can_merge if isinstance(can_merge, bool) else False
    allow_no_ci = _nested(config, "build", "allow_no_ci", False)
    allow_no_ci = allow_no_ci if isinstance(allow_no_ci, bool) else False
    forbidden_raw = _nested(config, "build", "forbidden_paths", [])
    forbidden_paths = (
        sorted({item for item in forbidden_raw if isinstance(item, str)})
        if isinstance(forbidden_raw, list)
        else []
    )
    verify_gate = _nested(config, "release", "verify_gate", False)
    verify_gate = verify_gate if isinstance(verify_gate, bool) else False
    daily_cap = _nested(config, "medic", "daily_escalation_cap", 5)
    if isinstance(daily_cap, bool) or not isinstance(daily_cap, int):
        daily_cap = 5

    branch_raw = config.get("branch")
    configured_branch = (
        branch_raw if isinstance(branch_raw, str) and branch_raw else None
    )
    release = config.get("release")
    release = release if isinstance(release, dict) else {}
    test_configured = (
        isinstance(release.get("test_cmd"), str) and bool(release["test_cmd"])
    )
    typecheck_configured = (
        isinstance(release.get("typecheck"), str) and bool(release["typecheck"])
    )
    budgets = {
        role: _budget_value(_nested(config, role, "budget_tokens_daily", None))
        for role in ROLE_ORDER
    }
    design = config.get("design")
    design = design if isinstance(design, dict) else {}
    max_open = _max_open_value(design.get("max_open_proposals"))
    shoulder = config.get("shoulder")
    shoulder = shoulder if isinstance(shoulder, dict) else {}
    shoulder_auto = shoulder.get("auto_wire", False)
    shoulder_auto = shoulder_auto if isinstance(shoulder_auto, bool) else False

    safety = {
        "config_state": "available",
        "can_merge": can_merge,
        "allow_no_ci": allow_no_ci,
        "forbidden_paths": forbidden_paths,
        "release_verify_gate": verify_gate,
        "configured_branch": configured_branch,
        "trunk_state": "configured" if configured_branch else "unavailable",
        "trunk": configured_branch,
        "trunk_reason": (
            "explicit_config"
            if configured_branch
            else "remote_resolution_not_attempted"
        ),
        "test_cmd_configured": test_configured,
        "typecheck_configured": typecheck_configured,
        "daily_escalation_cap": daily_cap,
        "evidence_ids": [],
    }
    fields = {
        "autonomous": autonomous,
        "can_merge": can_merge,
        "allow_no_ci": allow_no_ci,
        "forbidden_paths": forbidden_paths,
        "release_verify_gate": verify_gate,
        "configured_branch": configured_branch,
        "test_cmd_configured": test_configured,
        "typecheck_configured": typecheck_configured,
        "daily_escalation_cap": daily_cap,
        "budget_tokens_daily_by_role": budgets,
        "max_open_proposals": max_open,
        "shoulder_auto_wire": shoulder_auto,
    }
    source_ref = f"file:{config_path}:pointer:/"
    evidence = {
        "id": _evidence_id("config", source_ref, fields),
        "project_id": project["project_id"],
        "source": "config",
        "claim_kind": "fact",
        "kind": "config_posture",
        "observed_at": None,
        "source_ref": source_ref,
        "recurrence_key": None,
        "fields": fields,
        "limitations": [],
    }
    safety["evidence_ids"] = [evidence["id"]]
    project["autonomous"] = autonomous
    configured_name = config.get("project_name")
    if isinstance(configured_name, str) and configured_name:
        project["project_name"] = configured_name
    project["safety"] = safety
    project["pressure"]["configured_max_open_proposals"] = max_open
    project["overseer"].update(
        {
            "applicability": "applicable" if autonomous else "not_applicable",
            "state": "absent",
            "reason": "no_result" if autonomous else "not_autonomous",
        }
    )
    role_budget = {
        "design_runner": "design",
        "build_runner": "build",
        "release_runner": "release",
        "release_shoulder_critic": "release",
        "medic_runner": "medic",
        "scribe_runner": "scribe",
    }
    for consumer in project["pressure"]["daily_budget_consumers"]:
        consumer["configured_daily_budget"] = budgets[role_budget[consumer["consumer"]]]
    return evidence, _coverage(
        project["project_id"], "config", "available", "ok", total=1, valid=1
    )


def _load_config_adapter(
    project: dict[str, Any],
) -> tuple[dict[str, Any] | None, dict[str, Any], dict[str, Any] | None]:
    config_path = Path(project["project_path"]) / ".agents" / "config.toml"
    if not config_path.exists():
        return (
            None,
            _coverage(project["project_id"], "config", "unavailable", "missing"),
            None,
        )
    try:
        with config_path.open("rb") as handle:
            config = tomllib.load(handle)
        if not isinstance(config, dict):
            raise ValueError("config root must be a table")
        evidence, coverage = _available_config(
            project, config_path.resolve(strict=True), config
        )
        return config, coverage, evidence
    except PermissionError:
        reason = "unreadable"
        state = "unavailable"
    except (OSError, UnicodeError):
        reason = "unreadable"
        state = "unavailable"
    except (tomllib.TOMLDecodeError, ValueError):
        reason = "malformed"
        state = "error"
    project["autonomous"] = None
    project["safety"].update({"config_state": state})
    return (
        None,
        _coverage(project["project_id"], "config", state, reason, total=1, invalid=1),
        None,
    )


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


def _systemd_property_evidence(
    project_id: str, role: str, unit: str, prop: str, value: Any
) -> dict[str, Any]:
    fields = {"unit": unit, "role": role, "property": prop, "value": value}
    source_ref = f"unit:{unit}:property:{prop}"
    return {
        "id": _evidence_id("systemd", source_ref, fields),
        "project_id": project_id,
        "source": "systemd",
        "claim_kind": "fact",
        "kind": "unit_property",
        "observed_at": value if prop in {
            "LastTriggerUSec", "NextElapseUSecRealtime"
        } else None,
        "source_ref": source_ref,
        "recurrence_key": None,
        "fields": fields,
        "limitations": [],
    }


def _parse_systemd_output(
    output: str, expected: tuple[str, ...]
) -> tuple[dict[str, str], int]:
    properties: dict[str, str] = {}
    invalid = 0
    expected_set = set(expected)
    for line in output.splitlines():
        if "=" not in line:
            if line:
                invalid += 1
            continue
        key, value = line.split("=", 1)
        if not key or key not in expected_set or key in properties:
            invalid += 1
            continue
        properties[key] = value
    return properties, invalid


def _parse_timer_timestamp(value: str | None) -> tuple[str | None, bool]:
    if value is None:
        return None, False
    stripped = value.strip(" \t\r\n\f\v")
    if stripped in {"", "n/a"}:
        return None, True
    try:
        parsed = datetime.strptime(
            stripped, "%a %Y-%m-%d %H:%M:%S UTC"
        ).replace(tzinfo=timezone.utc)
    except ValueError:
        return None, False
    return _format_utc(parsed), True


def _run_systemctl(unit: str, properties: tuple[str, ...]) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment.update({"LC_ALL": "C", "TZ": "UTC"})
    argv = ["systemctl", "--user", "show", unit]
    for prop in properties:
        argv.extend(["-p", prop])
    return subprocess.run(
        argv,
        text=True,
        capture_output=True,
        check=False,
        env=environment,
    )


def _missing_user_bus(result: subprocess.CompletedProcess[str]) -> bool:
    signatures = {
        "Failed to connect to bus: No medium found",
        "Failed to connect to bus: No such file or directory",
    }
    lines = {
        line.strip()
        for line in f"{result.stdout}\n{result.stderr}".splitlines()
        if line.strip()
    }
    return result.returncode != 0 and bool(lines & signatures)


def _systemd_adapter(
    project: dict[str, Any], started_at: datetime
) -> tuple[dict[str, Any], list[dict[str, Any]], list[str]]:
    timer_props = (
        "LoadState",
        "ActiveState",
        "SubState",
        "UnitFileState",
        "LastTriggerUSec",
        "NextElapseUSecRealtime",
    )
    service_props = (
        "LoadState",
        "ActiveState",
        "SubState",
        "Result",
        "ExecMainStatus",
    )
    evidence: list[dict[str, Any]] = []
    fault_ids: list[str] = []
    total = valid = invalid = 0
    command_failed = False
    unavailable = False

    for unit_record in project["units"]:
        role = unit_record["role"]
        property_ids: dict[tuple[str, str], str] = {}
        for unit, properties, target in (
            (unit_record["timer_unit"], timer_props, "timer"),
            (unit_record["service_unit"], service_props, "service"),
        ):
            try:
                result = _run_systemctl(unit, properties)
            except FileNotFoundError:
                return (
                    _coverage(
                        project["project_id"],
                        "systemd",
                        "unavailable",
                        "missing_dependency",
                        total=valid + invalid,
                        valid=valid,
                        invalid=invalid,
                    ),
                    evidence,
                    fault_ids,
                )
            if _missing_user_bus(result):
                unavailable = True
                continue
            parsed, malformed_lines = _parse_systemd_output(
                result.stdout, properties
            )
            invalid += malformed_lines
            if result.returncode != 0:
                command_failed = True

            for prop in properties:
                raw = parsed.get(prop)
                value: Any
                property_valid = True
                if prop in {"LastTriggerUSec", "NextElapseUSecRealtime"}:
                    value, property_valid = _parse_timer_timestamp(raw)
                elif prop == "ExecMainStatus":
                    if raw is None or not re.fullmatch(r"-?[0-9]+", raw):
                        value = None
                        property_valid = False
                    else:
                        value = int(raw, 10)
                else:
                    if raw is None:
                        value = None
                        property_valid = False
                    else:
                        value = raw if raw != "" else None
                if property_valid:
                    valid += 1
                    item = _systemd_property_evidence(
                        project["project_id"], role, unit, prop, value
                    )
                    evidence.append(item)
                    property_ids[(unit, prop)] = item["id"]
                    unit_record["evidence_ids"].append(item["id"])
                else:
                    invalid += 1

                if target == "timer":
                    mapping = {
                        "LoadState": "timer_load_state",
                        "ActiveState": "timer_active_state",
                        "SubState": "timer_sub_state",
                        "UnitFileState": "unit_file_state",
                        "LastTriggerUSec": "last_trigger_at",
                        "NextElapseUSecRealtime": "next_trigger_at",
                    }
                else:
                    mapping = {
                        "LoadState": "service_load_state",
                        "ActiveState": "service_active_state",
                        "SubState": "service_sub_state",
                        "Result": "service_result",
                        "ExecMainStatus": "exec_main_status",
                    }
                unit_record[mapping[prop]] = value

        next_at = unit_record["next_trigger_at"]
        if unit_record["timer_active_state"] == "active" and next_at is not None:
            next_dt = datetime.fromisoformat(next_at.replace("Z", "+00:00"))
            grace = started_at - timedelta(seconds=300)
            unit_record["timer_stale_state"] = (
                "stale" if next_dt < grace else "fresh"
            )
        else:
            unit_record["timer_stale_state"] = "unknown"

        timer_fault_properties = []
        if unit_record["timer_load_state"] == "not-found":
            timer_fault_properties.append("LoadState")
        if unit_record["timer_active_state"] in {"inactive", "failed"}:
            timer_fault_properties.append("ActiveState")
        if unit_record["unit_file_state"] == "disabled":
            timer_fault_properties.append("UnitFileState")
        service_fault_properties = []
        if unit_record["service_active_state"] == "failed":
            service_fault_properties.append("ActiveState")
        if unit_record["service_result"] == "failed":
            service_fault_properties.append("Result")
        for prop in timer_fault_properties:
            evidence_id = property_ids.get((unit_record["timer_unit"], prop))
            if evidence_id is not None:
                fault_ids.append(evidence_id)
        for prop in service_fault_properties:
            evidence_id = property_ids.get((unit_record["service_unit"], prop))
            if evidence_id is not None:
                fault_ids.append(evidence_id)

    if unavailable:
        state, reason = "unavailable", "systemd_unavailable"
    elif command_failed:
        state, reason = "error", "command_failed"
    elif invalid:
        state, reason = "partial", "malformed"
    else:
        state, reason = "available", "ok"
    return (
        _coverage(
            project["project_id"],
            "systemd",
            state,
            reason,
            total=valid + invalid,
            valid=valid,
            invalid=invalid,
        ),
        evidence,
        sorted(set(fault_ids)),
    )


def _doctor_adapter(
    project: dict[str, Any],
    core_root: str,
    config_usable: bool,
    config_reason: str,
) -> tuple[dict[str, Any], dict[str, Any], list[dict[str, Any]]]:
    if not config_usable:
        return (
            {"state": "unavailable", "exit_code": None, "findings": []},
            _coverage(
                project["project_id"],
                "doctor",
                "unavailable",
                config_reason,
            ),
            [],
        )
    try:
        result = subprocess.run(
            [
                "bash",
                str(Path(core_root) / "install.sh"),
                "--doctor",
                "--project",
                project["project_path"],
            ],
            text=True,
            capture_output=True,
            check=False,
        )
    except FileNotFoundError:
        return (
            {"state": "unavailable", "exit_code": None, "findings": []},
            _coverage(
                project["project_id"],
                "doctor",
                "unavailable",
                "missing_dependency",
            ),
            [],
        )

    dependency_missing = any(
        re.fullmatch(
            r"missing dependency: (git|gh|claude|jq|python3|systemctl) "
            r"\(see README Requirements\)",
            line,
        )
        for line in result.stderr.splitlines()
    )
    parsed_findings: list[tuple[str, str]] = []
    for line in result.stdout.splitlines():
        match = re.fullmatch(r"DOCTOR ([^:]+): (.+)", line)
        if match:
            parsed_findings.append((match.group(1), match.group(2)))

    if dependency_missing:
        state, coverage_state, reason = "unavailable", "unavailable", "missing_dependency"
    elif result.returncode == 0:
        state, coverage_state, reason = "clean", "available", "ok"
    elif result.returncode == 1 and parsed_findings:
        state, coverage_state, reason = "drift", "available", "ok"
    else:
        state, coverage_state, reason = "error", "error", "command_failed"

    evidence: list[dict[str, Any]] = []
    findings: list[dict[str, Any]] = []
    for ordinal, (finding_class, detail) in enumerate(parsed_findings, 1):
        fields = {"class": finding_class, "detail": detail}
        source_ref = (
            f"command:doctor:{project['project_id']}:finding:{ordinal}"
        )
        item = {
            "id": _evidence_id("doctor", source_ref, fields),
            "project_id": project["project_id"],
            "source": "doctor",
            "claim_kind": "fact",
            "kind": "doctor_finding",
            "observed_at": None,
            "source_ref": source_ref,
            "recurrence_key": f"doctor:{finding_class}",
            "fields": fields,
            "limitations": [],
        }
        evidence.append(item)
        findings.append(
            {
                "class": finding_class,
                "detail": detail,
                "evidence_id": item["id"],
            }
        )
    doctor = {
        "state": state,
        "exit_code": result.returncode,
        "findings": findings,
    }
    coverage = _coverage(
        project["project_id"],
        "doctor",
        coverage_state,
        reason,
        total=len(parsed_findings),
        valid=len(parsed_findings),
    )
    return doctor, coverage, evidence


class _StrictJSONError(ValueError):
    """A JSON record violates schema-v1 parsing rules."""


def _reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise _StrictJSONError(f"duplicate key: {key}")
        result[key] = value
    return result


def _reject_constant(value: str) -> Any:
    raise _StrictJSONError(f"non-finite constant: {value}")


def _strict_json(text: str) -> Any:
    try:
        return json.loads(
            text,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=_reject_constant,
        )
    except (json.JSONDecodeError, _StrictJSONError) as exc:
        raise _StrictJSONError(str(exc)) from exc


def _strict_object(text: str) -> dict[str, Any]:
    value = _strict_json(text)
    if not isinstance(value, dict):
        raise _StrictJSONError("record is not an object")
    return value


def _parse_rfc3339(value: Any) -> datetime | None:
    if not isinstance(value, str) or not RFC3339.fullmatch(value):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        return None
    return parsed.astimezone(timezone.utc)


def _finite_nonnegative(value: Any) -> int | float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if not math.isfinite(value) or value < 0:
        return None
    return value


def _string(value: Any) -> str | None:
    return value if isinstance(value, str) else None


def _nonempty_string(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def _path_without_query(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    parsed = urlsplit(value)
    path = parsed.path
    return path or "/"


def _file_evidence(
    *,
    source_kind: str,
    project_id: str,
    source: str,
    kind: str,
    observed_at: str | None,
    source_ref: str,
    recurrence_key: str | None,
    fields: dict[str, Any],
    limitations: list[str] | None = None,
) -> dict[str, Any]:
    return {
        "id": _evidence_id(source_kind, source_ref, fields),
        "project_id": project_id,
        "source": source,
        "claim_kind": "fact",
        "kind": kind,
        "observed_at": observed_at,
        "source_ref": source_ref,
        "recurrence_key": recurrence_key,
        "fields": fields,
        "limitations": limitations or [],
    }


def _dated_paths(root: Path, start: datetime, end: datetime) -> list[Path]:
    day = start.date()
    final_day = end.date()
    paths: list[Path] = []
    while day <= final_day:
        paths.append(root / f"{day.isoformat()}.jsonl")
        day += timedelta(days=1)
    return paths


def _jq_gate_filter(consumer: str) -> str:
    if consumer == "design_runner":
        return (
            '[.[] | select((.event // "") | startswith("design.")) | '
            "(.tokens // 0)] | add // 0"
        )
    if consumer == "release_shoulder_critic":
        return (
            '[.[] | select(.event=="release.critique") | '
            "(.tokens // 0)] | add // 0"
        )
    return (
        '[.[] | select(.svc==$svc and .event=="job.end") | '
        "(.tokens // 0)] | add // 0"
    )


def _gate_decode_cache_key(path: str | Path) -> str:
    target = Path(path)
    try:
        return str(target.resolve(strict=False))
    except (OSError, RuntimeError):
        return str(target)


def _compute_gate_decode(
    path: str | Path,
) -> tuple[str, str | None, str | None]:
    target = Path(path)
    if not target.is_file():
        return "zero", None, None
    jq = shutil.which("jq")
    if jq is None:
        return "missing_dependency", None, None
    try:
        raw = target.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return "zero", None, None
    first = subprocess.run(
        [jq, "-R", "fromjson?"],
        input=raw,
        text=True,
        capture_output=True,
        check=False,
    )
    if first.returncode != 0:
        return "zero", None, None
    return "decoded", jq, first.stdout


def compute_gate_operand(
    path: str | Path,
    consumer: str,
    svc: str,
    decode_cache: dict[str, tuple[str, str | None, str | None]] | None = None,
) -> int | None:
    """Reproduce the runners' two-stage jq budget operand without shell source."""
    if decode_cache is None:
        state, jq, decoded = _compute_gate_decode(path)
    else:
        cache_key = _gate_decode_cache_key(path)
        if cache_key not in decode_cache:
            decode_cache[cache_key] = _compute_gate_decode(path)
        state, jq, decoded = decode_cache[cache_key]
    if state == "zero":
        return 0
    if state == "missing_dependency":
        return None
    if jq is None or decoded is None:
        raise AssertionError("decoded jq gate state is incomplete")
    argv = [jq, "-s"]
    if consumer not in {"design_runner", "release_shoulder_critic"}:
        argv.extend(["--arg", "svc", svc])
    argv.append(_jq_gate_filter(consumer))
    second = subprocess.run(
        argv,
        input=decoded,
        text=True,
        capture_output=True,
        check=False,
    )
    if second.returncode != 0:
        return 0
    normalized = second.stdout.rstrip("\n")
    if not ASCII_NONNEGATIVE_INTEGER.fullmatch(normalized):
        return 0
    return int(normalized, 10)


def _cached_gate_operand(
    path: str | Path,
    consumer: str,
    svc: str,
    cache: dict[tuple[str, str, str], int | None],
    decode_cache: dict[str, tuple[str, str | None, str | None]],
) -> int | None:
    selector = (
        consumer
        if consumer in {"design_runner", "release_shoulder_critic"}
        else "exact_service"
    )
    service_key = "" if selector != "exact_service" else svc
    key = (str(Path(path)), selector, service_key)
    if key not in cache:
        cache[key] = compute_gate_operand(
            path, consumer, svc, decode_cache=decode_cache
        )
    return cache[key]


def _strict_gate_invalid_count(path: Path) -> tuple[int | None, bool]:
    if not path.is_file():
        return 0, False
    invalid = 0
    parser_difference = False
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return 0, False
    for line in lines:
        try:
            record = _strict_object(line)
        except _StrictJSONError:
            invalid += 1
            try:
                json.loads(line)
            except (json.JSONDecodeError, ValueError):
                pass
            else:
                parser_difference = True
            continue
        role = _string(record.get("role"))
        if role not in ROLE_ORDER:
            role = "design"
        route = _event_route(record, role)
        if (
            _parse_rfc3339(record.get("ts")) is None
            or _nonempty_string(record.get("svc")) is None
            or (route is not None and route[3])
        ):
            invalid += 1
            parser_difference = True
    return invalid, parser_difference


def _cached_strict_gate_invalid_count(
    path: str | Path,
    cache: dict[str, tuple[int | None, bool]],
) -> tuple[int | None, bool]:
    key = str(Path(path))
    if key not in cache:
        cache[key] = _strict_gate_invalid_count(Path(path))
    return cache[key]


def _event_route(
    record: dict[str, Any], role: str
) -> tuple[str, dict[str, Any], str | None, bool] | None:
    event = _string(record.get("event"))
    reason = _string(record.get("reason"))
    numeric_invalid = False

    def number(key: str) -> int | float | None:
        nonlocal numeric_invalid
        value = record.get(key)
        parsed = _finite_nonnegative(value)
        if key in record and parsed is None:
            numeric_invalid = True
        return parsed

    if event == "job.end":
        status = _string(record.get("status"))
        fields = {
            "svc": _string(record.get("svc")),
            "role": role,
            "status": status,
            "reason": reason,
            "mode": _string(record.get("mode")),
            "duration_s": number("duration_s"),
            "tokens": number("tokens"),
        }
        return (
            "job_end",
            fields,
            f"job:{role}:{status or ''}:{reason or ''}",
            numeric_invalid,
        )

    incident_events = {
        "medic.incident",
        "medic.incident.detected",
        "medic.incident.classified",
        "medic.incident.frozen",
        "medic.incident.resolved",
        "medic.incident.repair_proposed",
        "medic.action.restart",
    }
    if event in incident_events:
        incident_id = _nonempty_string(record.get("incident_id"))
        fields = {
            "incident_id": incident_id,
            "event": event,
            "source": _string(record.get("source")),
            "surface": _string(record.get("surface")),
            "probe": _string(record.get("probe")),
            "http_status": number("http_status"),
            "restart_action": _string(record.get("restart_action")),
            "outcome": _string(record.get("outcome")),
            "summary_present": bool(
                isinstance(record.get("summary"), str) and record["summary"]
            ),
        }
        return "incident_event", fields, None, numeric_invalid or incident_id is None

    critique_events = {
        "release.critique",
        "release.critique.delivery_failed",
        "release.critique.spawn_failed",
    }
    if event in critique_events:
        fields = {
            "svc": _string(record.get("svc")),
            "event": event,
            "source": _string(record.get("source")),
            "block": number("block"),
            "warn": number("warn"),
            "note": number("note"),
            "files": number("files"),
            "tokens": number("tokens"),
            "reason": reason,
            "attempts": number("attempts"),
        }
        return (
            "critique_event",
            fields,
            f"critic:{event}:{reason or ''}",
            numeric_invalid,
        )

    if event == "design.proposal.opened" or (
        event == "design.proposal.skipped" and reason == "open_cap"
    ):
        fields = {
            "svc": _string(record.get("svc")),
            "event": event,
            "proposal_id": _string(record.get("proposal_id")),
            "type": _string(record.get("type")),
            "severity": _string(record.get("severity")),
            "reason": reason,
            "tokens": number("tokens"),
            "tokens_used": number("tokens_used"),
            "budget": number("budget"),
            "open": number("open"),
            "cap": number("cap"),
        }
        return "design_control_event", fields, None, numeric_invalid

    budget_routes = {
        ("design.proposal.skipped", "budget", None): "design_runner",
        ("build.skipped", "budget", None): "build_runner",
        ("release.skipped", "budget", None): "release_runner",
        (
            "release.critique.skipped",
            "budget",
            "shoulder",
        ): "release_shoulder_critic",
        ("medic.skipped", "budget", None): "medic_runner",
        ("scribe.skipped", "budget", None): "scribe_runner",
    }
    source = _string(record.get("source"))
    consumer = budget_routes.get((event, reason, source))
    if consumer is None and event != "release.critique.skipped":
        consumer = budget_routes.get((event, reason, None))
    if consumer is not None:
        fields = {
            "svc": _string(record.get("svc")),
            "event": event,
            "source": source,
            "consumer": consumer,
            "reason": reason,
            "tokens_used": number("tokens_used"),
            "budget": number("budget"),
        }
        return "budget_control_event", fields, None, numeric_invalid
    return None


def _scan_root(
    root: Path, window_start: datetime, started_at: datetime
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "root": root,
        "state": "available",
        "reason": "ok",
        "records": [],
        "strict_invalid": 0,
    }
    if not root.is_dir():
        result.update({"state": "unavailable", "reason": "missing"})
        return result
    for path in _dated_paths(root, window_start, started_at):
        if not path.exists():
            continue
        if not path.is_file():
            result.update({"state": "unavailable", "reason": "unreadable"})
            continue
        try:
            canonical_path = str(path.resolve(strict=True))
            with path.open("r", encoding="utf-8") as handle:
                for line_number, physical in enumerate(handle, 1):
                    text = physical.rstrip("\r\n")
                    item: dict[str, Any] = {
                        "path": canonical_path,
                        "line": line_number,
                        "object": None,
                        "timestamp": None,
                        "observed_at": None,
                        "strict_error": False,
                    }
                    try:
                        record = _strict_object(text)
                    except _StrictJSONError:
                        item["strict_error"] = True
                        result["strict_invalid"] += 1
                    else:
                        item["object"] = record
                        timestamp = _parse_rfc3339(record.get("ts"))
                        item["timestamp"] = timestamp
                        if timestamp is not None:
                            item["observed_at"] = _format_utc(timestamp)
                    result["records"].append(item)
        except (OSError, UnicodeError):
            result.update({"state": "unavailable", "reason": "unreadable"})
    return result


def _resolve_project_event_roots(
    by_project: dict[str, list[dict[str, Any]]], core_root: str
) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    fallback = str((Path(core_root) / "data" / "events").resolve(strict=False))
    for project_path, manifests in by_project.items():
        explicit = sorted(
            {
                manifest["event_root_env"]
                for manifest in manifests
                if manifest["event_root_env"]
            }
        )
        if len(explicit) > 1:
            result[project_path] = {
                "state": "mixed",
                "root": None,
                "explicit": True,
            }
        elif explicit:
            result[project_path] = {
                "state": "runner_manifest",
                "root": explicit[0],
                "explicit": True,
            }
        else:
            result[project_path] = {
                "state": "core_fallback",
                "root": fallback,
                "explicit": False,
            }
    return result


def _apply_event_evidence(
    project: dict[str, Any],
    item: dict[str, Any],
    route: tuple[str, dict[str, Any], str | None, bool],
    role: str,
) -> tuple[dict[str, Any], bool, bool]:
    kind, fields, recurrence, invalid = route
    source_ref = f"file:{item['path']}:line:{item['line']}"
    evidence = _file_evidence(
        source_kind="event",
        project_id=project["project_id"],
        source="events",
        kind=kind,
        observed_at=item["observed_at"],
        source_ref=source_ref,
        recurrence_key=recurrence,
        fields=fields,
    )
    fault = False
    pressure = False
    if kind == "job_end":
        status = fields["status"]
        bucket = status if status in {
            "ok", "fail", "partial", "abort", "skipped"
        } else "other"
        project["jobs"]["by_status"][bucket] += 1
        if fields["reason"]:
            project["jobs"]["by_reason"][fields["reason"]] = (
                project["jobs"]["by_reason"].get(fields["reason"], 0) + 1
            )
        project["jobs"]["last_end_at"] = max(
            filter(
                None,
                [project["jobs"]["last_end_at"], item["observed_at"]],
            ),
            default=None,
        )
        if fields["duration_s"] is not None:
            project.setdefault("_durations", []).append(fields["duration_s"])
        project["jobs"]["evidence_ids"].append(evidence["id"])
        fault = status in {"fail", "partial"}
    elif kind == "incident_event":
        incident_id = fields["incident_id"]
        if incident_id is not None:
            incidents = project.setdefault("_incident_map", {})
            aggregate = incidents.setdefault(
                incident_id,
                {
                    "incident_id": incident_id,
                    "first_observed_at": item["observed_at"],
                    "last_observed_at": item["observed_at"],
                    "latest_event": fields["event"],
                    "probe": fields["probe"],
                    "http_status": fields["http_status"],
                    "restart_action": fields["restart_action"],
                    "outcome": fields["outcome"],
                    "summary_present": fields["summary_present"],
                    "evidence_ids": [],
                },
            )
            if item["observed_at"] is not None:
                if (
                    aggregate["first_observed_at"] is None
                    or item["observed_at"] < aggregate["first_observed_at"]
                ):
                    aggregate["first_observed_at"] = item["observed_at"]
                if (
                    aggregate["last_observed_at"] is None
                    or item["observed_at"] >= aggregate["last_observed_at"]
                ):
                    aggregate.update(
                        {
                            "last_observed_at": item["observed_at"],
                            "latest_event": fields["event"],
                            "probe": fields["probe"],
                            "http_status": fields["http_status"],
                            "restart_action": fields["restart_action"],
                            "outcome": fields["outcome"],
                        }
                    )
            aggregate["summary_present"] = (
                aggregate["summary_present"] or fields["summary_present"]
            )
            aggregate["evidence_ids"].append(evidence["id"])
        fault = (
            fields["event"] == "medic.action.restart"
            and fields["outcome"] in {"fail", "failed"}
        )
    elif kind == "critique_event":
        for key in ("block", "warn", "note", "files", "tokens"):
            if fields[key] is not None:
                project["critiques"][key] += fields[key]
        event = fields["event"]
        if event == "release.critique.spawn_failed":
            project["critiques"]["spawn_failed"] += 1
            fault = True
        elif event == "release.critique.delivery_failed":
            project["critiques"]["delivery_failed"] += 1
            fault = True
        project["critiques"]["evidence_ids"].append(evidence["id"])
    elif kind == "design_control_event":
        if role == "design" and fields["event"] == "design.proposal.skipped":
            project["pressure"]["open_cap_deferrals"] = (
                (project["pressure"]["open_cap_deferrals"] or 0) + 1
            )
            pressure = True
            project["pressure"]["evidence_ids"].append(evidence["id"])
    elif kind == "budget_control_event":
        consumer = fields["consumer"]
        expected_role = {
            "design_runner": "design",
            "build_runner": "build",
            "release_runner": "release",
            "release_shoulder_critic": "release",
            "medic_runner": "medic",
            "scribe_runner": "scribe",
        }[consumer]
        if role == expected_role:
            current = project["pressure"]["budget_deferrals_by_consumer"][consumer]
            project["pressure"]["budget_deferrals_by_consumer"][consumer] = (
                (current or 0) + 1
            )
            if consumer == "release_shoulder_critic":
                project["critiques"]["budget_deferred"] += 1
            project["pressure"]["evidence_ids"].append(evidence["id"])
            pressure = True
    return evidence, fault, pressure


def _finish_event_aggregates(project: dict[str, Any]) -> None:
    durations = sorted(project.pop("_durations", []))
    if durations:
        project["jobs"]["duration_seconds_p50"] = durations[
            math.ceil(0.50 * len(durations)) - 1
        ]
        project["jobs"]["duration_seconds_p95"] = durations[
            math.ceil(0.95 * len(durations)) - 1
        ]
    incidents = list(project.pop("_incident_map", {}).values())
    for incident in incidents:
        incident["evidence_ids"] = sorted(set(incident["evidence_ids"]))
    incidents.sort(key=lambda item: item["incident_id"])
    incidents.sort(
        key=lambda item: (
            item["last_observed_at"] is not None,
            item["last_observed_at"] or "",
        ),
        reverse=True,
    )
    project["incidents"] = incidents


def _events_adapter(
    *,
    fleet: list[dict[str, Any]],
    by_project: dict[str, list[dict[str, Any]]],
    core_root: str,
    window_start: datetime,
    started_at: datetime,
) -> tuple[
    dict[tuple[str | None, str], dict[str, Any]],
    list[dict[str, Any]],
    dict[str, list[str]],
    dict[str, list[str]],
    dict[str, dict[str, Any]],
    dict[str, dict[str, Any]],
]:
    project_by_path = {project["project_path"]: project for project in fleet}
    roots = _resolve_project_event_roots(by_project, core_root)
    usable_roots = sorted(
        {info["root"] for info in roots.values() if info["root"] is not None}
    )
    scans = {
        root: _scan_root(Path(root), window_start, started_at)
        for root in usable_roots
    }
    root_projects: dict[str, list[str]] = defaultdict(list)
    for project_path, info in roots.items():
        if info["root"] is not None:
            root_projects[info["root"]].append(project_path)

    counters: dict[str, dict[str, int]] = {
        project_path: {
            "total": 0,
            "valid": 0,
            "invalid": 0,
            "out": 0,
        }
        for project_path in by_project
    }
    newest: dict[str, str | None] = {path: None for path in by_project}
    global_counts = {
        "total": 0,
        "valid": 0,
        "invalid": 0,
        "out": 0,
        "unattributed": 0,
        "ambiguous": 0,
    }
    evidence: list[dict[str, Any]] = []
    fault_ids: dict[str, list[str]] = defaultdict(list)
    pressure_ids: dict[str, list[str]] = defaultdict(list)
    attributed: dict[str, list[dict[str, Any]]] = defaultdict(list)

    for root, scan in scans.items():
        candidates = root_projects[root]
        stem_roles: dict[str, list[tuple[str, str]]] = defaultdict(list)
        for project_path in candidates:
            for manifest in by_project[project_path]:
                stem_roles[manifest["service_stem"]].append(
                    (project_path, manifest["role"])
                )
        for item in scan["records"]:
            global_counts["total"] += 1
            if item["strict_error"]:
                global_counts["invalid"] += 1
                continue
            record = item["object"]
            timestamp = item["timestamp"]
            svc = _nonempty_string(record.get("svc"))
            if timestamp is None or svc is None:
                global_counts["invalid"] += 1
                continue
            matches = stem_roles.get(svc, [])
            if not (window_start <= timestamp < started_at):
                global_counts["out"] += 1
                if len(matches) == 1:
                    project_path, _ = matches[0]
                    counters[project_path]["total"] += 1
                    counters[project_path]["out"] += 1
                continue
            if not matches:
                global_counts["unattributed"] += 1
                continue
            if len(matches) > 1:
                global_counts["ambiguous"] += 1
                continue
            project_path, role = matches[0]
            project = project_by_path[project_path]
            global_counts["valid"] += 1
            counters[project_path]["total"] += 1
            attributed[project_path].append(item)
            newest[project_path] = max(
                filter(None, [newest[project_path], item["observed_at"]]),
                default=None,
            )
            route = _event_route(record, role)
            if route is None:
                counters[project_path]["valid"] += 1
                continue
            event_evidence, fault, pressure = _apply_event_evidence(
                project, item, route, role
            )
            evidence.append(event_evidence)
            if route[3]:
                counters[project_path]["invalid"] += 1
            else:
                counters[project_path]["valid"] += 1
            if fault:
                fault_ids[project["project_id"]].append(event_evidence["id"])
            if pressure:
                pressure_ids[project["project_id"]].append(event_evidence["id"])

    coverage: dict[tuple[str | None, str], dict[str, Any]] = {}
    any_missing = False
    any_malformed = False
    for project_path, info in roots.items():
        project = project_by_path[project_path]
        project_id = project["project_id"]
        if info["state"] == "mixed":
            coverage[(project_id, "events")] = _coverage(
                project_id, "events", "error", "mixed"
            )
            continue
        scan = scans[info["root"]]
        any_missing = any_missing or scan["state"] != "available"
        any_malformed = any_malformed or scan["strict_invalid"] > 0
        if scan["state"] != "available":
            state, reason = "unavailable", scan["reason"]
        elif scan["strict_invalid"] or counters[project_path]["invalid"]:
            state, reason = "partial", "malformed"
        else:
            state, reason = "available", "ok"
        count = counters[project_path]
        coverage[(project_id, "events")] = _coverage(
            project_id,
            "events",
            state,
            reason,
            total=count["total"],
            valid=count["valid"],
            invalid=count["invalid"],
            out_of_window=count["out"],
            newest_ts=newest[project_path],
        )
        _finish_event_aggregates(project)
    if any_missing:
        global_state, global_reason = "unavailable", "missing"
    elif any_malformed or global_counts["invalid"]:
        global_state, global_reason = "partial", "malformed"
    else:
        global_state, global_reason = "available", "ok"
    coverage[(None, "events_attribution")] = _coverage(
        None,
        "events_attribution",
        global_state,
        global_reason,
        total=global_counts["total"],
        valid=global_counts["valid"],
        invalid=global_counts["invalid"],
        out_of_window=global_counts["out"],
        unattributed=global_counts["unattributed"],
        ambiguous=global_counts["ambiguous"],
    )
    return coverage, evidence, fault_ids, pressure_ids, roots, attributed


def _bounded_jsonl_adapter(
    *,
    project: dict[str, Any],
    source: str,
    paths: list[Path],
    window_start: datetime,
    started_at: datetime,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    if not paths:
        return (
            _coverage(
                project["project_id"], source, "unavailable", "missing"
            ),
            [],
        )
    total = valid = invalid = out = 0
    newest: str | None = None
    evidence: list[dict[str, Any]] = []
    unreadable = False
    for path in sorted(paths):
        try:
            canonical = str(path.resolve(strict=True))
            with path.open("r", encoding="utf-8") as handle:
                for line_number, physical in enumerate(handle, 1):
                    total += 1
                    try:
                        record = _strict_object(physical.rstrip("\r\n"))
                    except _StrictJSONError:
                        invalid += 1
                        continue
                    timestamp = _parse_rfc3339(record.get("ts"))
                    if timestamp is None:
                        invalid += 1
                        continue
                    if not (window_start <= timestamp < started_at):
                        out += 1
                        continue
                    observed_at = _format_utc(timestamp)
                    newest = max(
                        filter(None, [newest, observed_at]), default=None
                    )
                    if source == "fyi":
                        fields = {
                            "id": _string(record.get("id")),
                            "ts": observed_at,
                            "text_present": bool(
                                isinstance(record.get("text"), str)
                                and record["text"]
                            ),
                        }
                        kind = "fyi_request"
                    else:
                        fields = {
                            "ts": observed_at,
                            "action": _string(record.get("action")),
                            "path": _path_without_query(record.get("path")),
                        }
                        kind = "usage_beacon"
                    source_ref = f"file:{canonical}:line:{line_number}"
                    evidence.append(
                        _file_evidence(
                            source_kind=source,
                            project_id=project["project_id"],
                            source=source,
                            kind=kind,
                            observed_at=observed_at,
                            source_ref=source_ref,
                            recurrence_key=None,
                            fields=fields,
                        )
                    )
                    valid += 1
        except (OSError, UnicodeError):
            unreadable = True
    if unreadable:
        state, reason = "unavailable", "unreadable"
    elif invalid:
        state, reason = "partial", "malformed"
    else:
        state, reason = "available", "ok"
    return (
        _coverage(
            project["project_id"],
            source,
            state,
            reason,
            total=total,
            valid=valid,
            invalid=invalid,
            out_of_window=out,
            newest_ts=newest,
        ),
        evidence,
    )


def _fyi_usage_adapters(
    project: dict[str, Any], window_start: datetime, started_at: datetime
) -> tuple[dict[str, dict[str, Any]], list[dict[str, Any]]]:
    project_path = Path(project["project_path"])
    fyi_path = project_path / "data" / "fyi-requests.jsonl"
    usage_dir = project_path / "data" / "usage"
    fyi_paths = [fyi_path] if fyi_path.is_file() else []
    try:
        usage_paths = sorted(usage_dir.glob("*.jsonl")) if usage_dir.is_dir() else []
    except OSError:
        usage_paths = []
    fyi_coverage, fyi_evidence = _bounded_jsonl_adapter(
        project=project,
        source="fyi",
        paths=fyi_paths,
        window_start=window_start,
        started_at=started_at,
    )
    usage_coverage, usage_evidence = _bounded_jsonl_adapter(
        project=project,
        source="usage",
        paths=usage_paths,
        window_start=window_start,
        started_at=started_at,
    )
    return (
        {"fyi": fyi_coverage, "usage": usage_coverage},
        fyi_evidence + usage_evidence,
    )


def _incident_state_adapter(
    project: dict[str, Any], config: dict[str, Any] | None
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    result_dir = "tmp"
    if isinstance(config, dict):
        paths = config.get("paths")
        if isinstance(paths, dict):
            configured = paths.get("result_dir")
            if isinstance(configured, str) and configured:
                result_dir = configured
    path = Path(project["project_path"]) / result_dir / "medic-incidents-current.json"
    if not path.exists():
        return (
            _coverage(
                project["project_id"],
                "incident_state",
                "unavailable",
                "missing",
            ),
            [],
        )
    try:
        canonical = str(path.resolve(strict=True))
        value = _strict_json(path.read_text(encoding="utf-8"))
        if not isinstance(value, list):
            raise _StrictJSONError("current incident state is not an array")
    except PermissionError:
        return (
            _coverage(
                project["project_id"],
                "incident_state",
                "unavailable",
                "unreadable",
                total=1,
                invalid=1,
            ),
            [],
        )
    except (OSError, UnicodeError):
        return (
            _coverage(
                project["project_id"],
                "incident_state",
                "unavailable",
                "unreadable",
                total=1,
                invalid=1,
            ),
            [],
        )
    except _StrictJSONError:
        return (
            _coverage(
                project["project_id"],
                "incident_state",
                "error",
                "malformed",
                total=1,
                invalid=1,
            ),
            [],
        )

    valid = invalid = 0
    newest: str | None = None
    evidence: list[dict[str, Any]] = []
    incident_map = {item["incident_id"]: item for item in project["incidents"]}
    for index, record in enumerate(value):
        if not isinstance(record, dict):
            invalid += 1
            continue
        incident_id = _nonempty_string(record.get("incident_id"))
        if incident_id is None:
            invalid += 1
            continue
        timestamp = _parse_rfc3339(
            record.get("detected_at")
            if record.get("detected_at") is not None
            else record.get("ts")
        )
        observed_at = _format_utc(timestamp) if timestamp is not None else None
        http_status = _finite_nonnegative(record.get("http_status"))
        numeric_invalid = (
            "http_status" in record and http_status is None
        )
        if observed_at is None or numeric_invalid:
            invalid += 1
        else:
            valid += 1
            newest = max(
                filter(None, [newest, observed_at]), default=None
            )
        summary_present = bool(
            isinstance(record.get("summary"), str) and record["summary"]
        )
        fields = {
            "incident_id": incident_id,
            "source": _string(record.get("source")),
            "surface": _string(record.get("surface")),
            "detected_at": observed_at,
            "probe": _string(record.get("probe")),
            "http_status": http_status,
            "restart_action": _string(record.get("restart_action")),
            "outcome": _string(record.get("outcome")),
            "summary_present": summary_present,
        }
        source_ref = f"file:{canonical}:pointer:/{index}"
        item = _file_evidence(
            source_kind="incident_state",
            project_id=project["project_id"],
            source="incident_state",
            kind="incident_state",
            observed_at=observed_at,
            source_ref=source_ref,
            recurrence_key=None,
            fields=fields,
            limitations=["incident_summary_redacted"] if summary_present else [],
        )
        evidence.append(item)
        if summary_present:
            project["limitations"].append("incident_summary_redacted")
        aggregate = incident_map.setdefault(
            incident_id,
            {
                "incident_id": incident_id,
                "first_observed_at": observed_at,
                "last_observed_at": observed_at,
                "latest_event": "incident_state",
                "probe": fields["probe"],
                "http_status": fields["http_status"],
                "restart_action": fields["restart_action"],
                "outcome": fields["outcome"],
                "summary_present": summary_present,
                "evidence_ids": [],
            },
        )
        if observed_at is not None and (
            aggregate["last_observed_at"] is None
            or observed_at >= aggregate["last_observed_at"]
        ):
            aggregate.update(
                {
                    "last_observed_at": observed_at,
                    "latest_event": "incident_state",
                    "probe": fields["probe"],
                    "http_status": fields["http_status"],
                    "restart_action": fields["restart_action"],
                    "outcome": fields["outcome"],
                }
            )
        if observed_at is not None and (
            aggregate["first_observed_at"] is None
            or observed_at < aggregate["first_observed_at"]
        ):
            aggregate["first_observed_at"] = observed_at
        aggregate["summary_present"] = (
            aggregate["summary_present"] or summary_present
        )
        aggregate["evidence_ids"].append(item["id"])
    for incident in incident_map.values():
        incident["evidence_ids"] = sorted(set(incident["evidence_ids"]))
    incidents = list(incident_map.values())
    incidents.sort(key=lambda item: item["incident_id"])
    incidents.sort(
        key=lambda item: (
            item["last_observed_at"] is not None,
            item["last_observed_at"] or "",
        ),
        reverse=True,
    )
    project["incidents"] = incidents
    state, reason = ("partial", "malformed") if invalid else ("available", "ok")
    return (
        _coverage(
            project["project_id"],
            "incident_state",
            state,
            reason,
            total=len(value),
            valid=valid,
            invalid=invalid,
            newest_ts=newest,
        ),
        evidence,
    )


def _caddy_domain(
    config: dict[str, Any] | None,
) -> tuple[str | None, bool]:
    if not isinstance(config, dict):
        return None, False
    medic = config.get("medic")
    if not isinstance(medic, dict):
        return None, False
    checks = medic.get("checks")
    if not isinstance(checks, list):
        return None, False
    for check in checks:
        if not isinstance(check, dict):
            continue
        url = check.get("url")
        if not isinstance(url, str):
            continue
        try:
            parsed = urlsplit(url)
            scheme = parsed.scheme.lower()
            hostname = parsed.hostname
        except ValueError:
            if url.lower().startswith(("http://", "https://")):
                return None, True
            continue
        if scheme in {"http", "https"}:
            if hostname:
                return hostname.lower(), False
            return None, True
    return None, False


def _caddy_adapter(
    project: dict[str, Any],
    config: dict[str, Any] | None,
    window_start: datetime,
    started_at: datetime,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    domain, malformed_domain = _caddy_domain(config)
    if malformed_domain:
        return (
            _coverage(
                project["project_id"],
                "caddy",
                "partial",
                "malformed",
                total=1,
                invalid=1,
            ),
            [],
        )
    if domain is None:
        return (
            _coverage(
                project["project_id"],
                "caddy",
                "not_applicable",
                "no_domain",
            ),
            [],
        )
    argv = [
        "journalctl",
        "--user",
        "-u",
        "caddy",
        "-o",
        "json",
        "--no-pager",
        "--output-fields=__REALTIME_TIMESTAMP,MESSAGE",
        "--since",
        _format_utc(window_start),
        "--until",
        _format_utc(started_at),
    ]
    try:
        result = subprocess.run(
            argv, text=True, capture_output=True, check=False
        )
    except FileNotFoundError:
        return (
            _coverage(
                project["project_id"],
                "caddy",
                "unavailable",
                "missing_dependency",
            ),
            [],
        )
    if result.returncode != 0:
        return (
            _coverage(
                project["project_id"],
                "caddy",
                "error",
                "command_failed",
            ),
            [],
        )
    total = valid = invalid = out = 0
    newest: str | None = None
    counts: dict[str, int] = defaultdict(int)
    for physical in result.stdout.splitlines():
        try:
            outer = _strict_object(physical)
        except _StrictJSONError:
            total += 1
            invalid += 1
            continue
        micros = outer.get("__REALTIME_TIMESTAMP")
        if not isinstance(micros, str) or not ASCII_DECIMAL_MICROSECONDS.fullmatch(
            micros
        ):
            total += 1
            invalid += 1
            continue
        try:
            timestamp = datetime.fromtimestamp(
                int(micros, 10) / 1_000_000, tz=timezone.utc
            )
        except (OverflowError, OSError, ValueError):
            total += 1
            invalid += 1
            continue
        message = outer.get("MESSAGE")
        if not isinstance(message, str):
            total += 1
            invalid += 1
            continue
        try:
            inner = _strict_object(message)
        except _StrictJSONError:
            total += 1
            invalid += 1
            continue
        request = inner.get("request")
        if not isinstance(request, dict):
            total += 1
            invalid += 1
            continue
        host = request.get("host")
        uri = request.get("uri")
        if not isinstance(host, str) or not isinstance(uri, str):
            total += 1
            invalid += 1
            continue
        try:
            hostname = urlsplit(f"//{host}").hostname
        except ValueError:
            total += 1
            invalid += 1
            continue
        if hostname is None or hostname.lower() != domain:
            continue
        total += 1
        if not (window_start <= timestamp < started_at):
            out += 1
            continue
        path = _path_without_query(uri)
        if path is None:
            invalid += 1
            continue
        counts[path] += 1
        valid += 1
        observed = _format_utc(timestamp)
        newest = max(filter(None, [newest, observed]), default=None)
    evidence: list[dict[str, Any]] = []
    for path, requests in sorted(counts.items()):
        suffix = hashlib.sha256(
            (domain + "\0" + path).encode("utf-8")
        ).hexdigest()[:12]
        fields = {
            "domain": domain,
            "path": path,
            "requests": requests,
            "window_start_at": _format_utc(window_start),
            "window_end_at": _format_utc(started_at),
        }
        source_ref = f"command:caddy:{project['project_id']}:path:{suffix}"
        evidence.append(
            _file_evidence(
                source_kind="caddy",
                project_id=project["project_id"],
                source="caddy",
                kind="caddy_path_count",
                observed_at=newest,
                source_ref=source_ref,
                recurrence_key=None,
                fields=fields,
            )
        )
    state, reason = ("partial", "malformed") if invalid else ("available", "ok")
    return (
        _coverage(
            project["project_id"],
            "caddy",
            state,
            reason,
            total=total,
            valid=valid,
            invalid=invalid,
            out_of_window=out,
            newest_ts=newest,
        ),
        evidence,
    )


def _watcher_event_root(
    lines: list[str], project_path: str
) -> tuple[str, str | None]:
    values: list[str] = []
    for line in lines:
        if not line.startswith("Environment="):
            continue
        try:
            tokens = shlex.split(line[len("Environment=") :], posix=True)
        except ValueError:
            return "unknown", None
        for token in tokens:
            if token.startswith("QUARTET_EVENTS_DIR="):
                values.append(token.split("=", 1)[1])
    if len(values) != 1 or "%" in values[0]:
        return "unknown", None
    root = _canonical(values[0], strict=False)
    if root is None:
        return "unknown", None
    project_default = str(
        (Path(project_path) / "data" / "events").resolve(strict=False)
    )
    return (
        ("project_default" if root == project_default else "configured"),
        root,
    )


def _discover_shoulders(
    *,
    core_root: str,
    unit_dir: str,
    fleet: list[dict[str, Any]],
) -> tuple[dict[str, list[dict[str, Any]]], list[dict[str, Any]]]:
    expected_runner = _canonical(
        Path(core_root) / "agents" / "release" / "critic-watch.sh",
        strict=True,
    )
    by_path: dict[str, list[dict[str, Any]]] = defaultdict(list)
    evidence: list[dict[str, Any]] = []
    if expected_runner is None:
        return by_path, evidence
    projects = {project["project_path"]: project for project in fleet}
    try:
        paths = sorted(Path(unit_dir).glob("*.service"))
    except OSError:
        return by_path, evidence
    for path in paths:
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
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
        if (
            len(tokens) != 4
            or tokens[0] != "/bin/bash"
            or tokens[2] != "--project"
        ):
            continue
        runner = _canonical(tokens[1], strict=True)
        project_path = _canonical(tokens[3], strict=True)
        working = _canonical(working_raw, strict=True)
        service_path = _canonical(path, strict=True)
        if (
            runner != expected_runner
            or project_path is None
            or project_path not in projects
            or working != project_path
            or service_path is None
        ):
            continue
        root_state, root = _watcher_event_root(lines, project_path)
        watcher = {
            "service_stem": path.stem,
            "project_path": project_path,
            "working_directory": working,
            "runner": runner,
            "event_root_state": root_state,
            "event_root": root,
            "service_path": service_path,
        }
        by_path[project_path].append(watcher)
        fields = {
            "service_stem": watcher["service_stem"],
            "project_path": project_path,
            "working_directory": working,
            "runner": runner,
            "event_root_state": root_state,
            "event_root": root,
        }
        source_ref = f"file:{service_path}:pointer:/"
        item = _file_evidence(
            source_kind="manifest",
            project_id=projects[project_path]["project_id"],
            source="manifest",
            kind="shoulder_watcher_identity",
            observed_at=None,
            source_ref=source_ref,
            recurrence_key=None,
            fields=fields,
        )
        watcher["evidence_id"] = item["id"]
        evidence.append(item)
    return by_path, evidence


def _configured_result_path(
    project: dict[str, Any], config: dict[str, Any]
) -> Path:
    paths = config.get("paths")
    paths = paths if isinstance(paths, dict) else {}
    result_dir = paths.get("result_dir", "tmp")
    if isinstance(result_dir, str):
        rendered_dir = result_dir
    elif isinstance(result_dir, bool):
        rendered_dir = "true" if result_dir else "false"
    elif isinstance(result_dir, int):
        rendered_dir = str(result_dir)
    else:
        raise ValueError("result_dir cannot be represented exactly")
    names = config.get("names")
    names = names if isinstance(names, dict) else {}
    display = names.get("design")
    if not isinstance(display, str) or not display:
        display = "design"
    filename = f"{project['project_name']}-{display}-result.json"
    # The runner uses RESULT_DIR="$PROJECT_DIR/$RESULT_DIR_REL". Preserve that
    # prefix even when the configured value begins with "/" and preserve an
    # empty value as the project root.
    result_root = Path(project["project_path"] + "/" + rendered_dir)
    return result_root / filename


def _decision_adapter(
    project: dict[str, Any],
) -> tuple[
    dict[str, Any],
    list[dict[str, Any]],
    set[str],
    dict[str, list[str]],
]:
    path = Path(project["project_path"]) / "data" / "decisions.jsonl"
    if not path.exists():
        return (
            _coverage(
                project["project_id"], "decisions", "unavailable", "missing"
            ),
            [],
            set(),
            {},
        )
    if not path.is_file():
        return (
            _coverage(
                project["project_id"], "decisions", "unavailable", "unreadable"
            ),
            [],
            set(),
            {},
        )
    try:
        canonical = path.resolve(strict=True)
        physical_lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return (
            _coverage(
                project["project_id"], "decisions", "unavailable", "unreadable"
            ),
            [],
            set(),
            {},
        )

    evidence: list[dict[str, Any]] = []
    decisions_by_id: dict[str, set[str]] = defaultdict(set)
    evidence_by_id: dict[str, list[str]] = defaultdict(list)
    valid = 0
    invalid = 0
    newest: datetime | None = None
    for line_number, text in enumerate(physical_lines, 1):
        try:
            record = _strict_object(text)
        except _StrictJSONError:
            invalid += 1
            continue
        proposal_id = _nonempty_string(record.get("proposal_id"))
        decision = _string(record.get("decision"))
        timestamp = _parse_rfc3339(record.get("ts"))
        if (
            proposal_id is None
            or decision not in {"approve", "deny"}
            or timestamp is None
        ):
            invalid += 1
            continue
        valid += 1
        newest = timestamp if newest is None else max(newest, timestamp)
        observed_at = _format_utc(timestamp)
        fields = {
            "proposal_id": proposal_id,
            "decision": decision,
            "ts": observed_at,
        }
        item = _file_evidence(
            source_kind="decision",
            project_id=project["project_id"],
            source="decisions",
            kind="decision",
            observed_at=observed_at,
            source_ref=f"file:{canonical}:line:{line_number}",
            recurrence_key=None,
            fields=fields,
        )
        evidence.append(item)
        decisions_by_id[proposal_id].add(decision)
        evidence_by_id[proposal_id].append(item["id"])

    conflicts = {
        proposal_id: sorted(set(evidence_by_id[proposal_id]))
        for proposal_id, values in decisions_by_id.items()
        if len(values) > 1
    }
    if conflicts:
        state, reason = "partial", "mixed"
    elif invalid:
        state, reason = "partial", "malformed"
    else:
        state, reason = "available", "ok"
    coverage = _coverage(
        project["project_id"],
        "decisions",
        state,
        reason,
        total=len(physical_lines),
        valid=valid,
        invalid=invalid,
        newest_ts=_format_utc(newest) if newest is not None else None,
    )
    return coverage, evidence, set(decisions_by_id), conflicts


def _proposal_adapter(
    project: dict[str, Any],
    config: dict[str, Any] | None,
    decided_ids: set[str],
) -> tuple[dict[str, Any], list[dict[str, Any]], list[dict[str, Any]]]:
    if config is None:
        return (
            _coverage(
                project["project_id"],
                "proposals",
                "unavailable",
                "malformed",
            ),
            [],
            [],
        )
    try:
        path = _configured_result_path(project, config)
    except ValueError:
        return (
            _coverage(
                project["project_id"],
                "proposals",
                "partial",
                "malformed",
                total=1,
                invalid=1,
                limitations=["result_dir_representation_unsupported"],
            ),
            [],
            [],
        )
    if not path.exists():
        return (
            _coverage(
                project["project_id"], "proposals", "unavailable", "missing"
            ),
            [],
            [],
        )
    if not path.is_file():
        return (
            _coverage(
                project["project_id"], "proposals", "unavailable", "unreadable"
            ),
            [],
            [],
        )
    try:
        canonical = path.resolve(strict=True)
        root = _strict_object(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError):
        return (
            _coverage(
                project["project_id"], "proposals", "unavailable", "unreadable"
            ),
            [],
            [],
        )
    except _StrictJSONError:
        return (
            _coverage(
                project["project_id"],
                "proposals",
                "partial",
                "malformed",
                total=1,
                invalid=1,
            ),
            [],
            [],
        )

    proposals = root.get("proposals")
    if not isinstance(proposals, list):
        return (
            _coverage(
                project["project_id"],
                "proposals",
                "partial",
                "malformed",
                total=1,
                invalid=1,
            ),
            [],
            [],
        )
    result_timestamp = _parse_rfc3339(root.get("ts"))
    if result_timestamp is None:
        rejected = max(1, len(proposals))
        return (
            _coverage(
                project["project_id"],
                "proposals",
                "partial",
                "malformed",
                total=rejected,
                invalid=rejected,
            ),
            [],
            [],
        )
    observed_at = _format_utc(result_timestamp)
    evidence: list[dict[str, Any]] = []
    open_proposals: list[dict[str, Any]] = []
    valid = 0
    invalid = 0
    for index, record in enumerate(proposals):
        if not isinstance(record, dict):
            invalid += 1
            continue
        proposal_id = _nonempty_string(record.get("id"))
        proposal_type = _string(record.get("type"))
        title = _nonempty_string(record.get("title"))
        severity = _string(record.get("severity"))
        status = _string(record.get("status"))
        signal_raw = record.get("signal_ids", [])
        signal_ids = (
            sorted(set(signal_raw))
            if isinstance(signal_raw, list)
            and all(_nonempty_string(item) is not None for item in signal_raw)
            else None
        )
        approval_raw = record.get("approval_action")
        approval_present = (
            isinstance(approval_raw, str) and bool(approval_raw)
        )
        if (
            proposal_id is None
            or proposal_type not in {"feature", "bug", "instrumentation"}
            or title is None
            or severity not in {"low", "med", "high"}
            or status != "open"
            or signal_ids is None
            or (
                "approval_action" in record
                and approval_raw is not None
                and not isinstance(approval_raw, str)
            )
        ):
            invalid += 1
            continue
        valid += 1
        if proposal_id in decided_ids:
            continue
        fields = {
            "id": proposal_id,
            "type": proposal_type,
            "title": title,
            "severity": severity,
            "status": status,
            "signal_ids": signal_ids,
            "ts": observed_at,
            "approval_action_present": approval_present,
        }
        item = _file_evidence(
            source_kind="proposal",
            project_id=project["project_id"],
            source="proposals",
            kind="open_proposal",
            observed_at=observed_at,
            source_ref=f"file:{canonical}:pointer:/proposals/{index}",
            recurrence_key=f"proposal:{proposal_type}:{proposal_id}",
            fields=fields,
        )
        item["claim_kind"] = "assessment"
        evidence.append(item)
        open_proposals.append(
            {
                "evidence_id": item["id"],
                "title": title,
                "severity": severity,
                "signal_ids": signal_ids,
                "approval_action": approval_raw if approval_present else None,
                "detected_at": observed_at,
            }
        )
    coverage = _coverage(
        project["project_id"],
        "proposals",
        "partial" if invalid else "available",
        "malformed" if invalid else "ok",
        total=len(proposals),
        valid=valid,
        invalid=invalid,
        newest_ts=observed_at if valid else None,
    )
    return coverage, evidence, open_proposals


def _overseer_adapter(
    project: dict[str, Any],
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    autonomous = project["autonomous"]
    if autonomous is False:
        return (
            _coverage(
                project["project_id"],
                "overseer",
                "not_applicable",
                "not_autonomous",
            ),
            [],
        )
    if autonomous is None:
        return (
            _coverage(
                project["project_id"],
                "overseer",
                "unavailable",
                "config_unknown",
            ),
            [],
        )
    path = Path(project["project_path"]) / "tmp" / "overseer-result.json"
    if not path.exists():
        return (
            _coverage(
                project["project_id"], "overseer", "unavailable", "no_result"
            ),
            [],
        )
    try:
        canonical = path.resolve(strict=True)
        root = _strict_object(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError):
        project["overseer"].update({"state": "unavailable", "reason": "malformed"})
        return (
            _coverage(
                project["project_id"], "overseer", "unavailable", "unreadable"
            ),
            [],
        )
    except _StrictJSONError:
        project["overseer"].update({"state": "malformed", "reason": "malformed"})
        return (
            _coverage(
                project["project_id"],
                "overseer",
                "partial",
                "malformed",
                total=1,
                invalid=1,
            ),
            [],
        )
    healthy = root.get("healthy")
    status = _nonempty_string(root.get("status"))
    findings = root.get("findings")
    timestamp = _parse_rfc3339(root.get("ts"))
    if (
        not isinstance(healthy, bool)
        or status is None
        or not isinstance(findings, list)
        or timestamp is None
    ):
        project["overseer"].update({"state": "malformed", "reason": "malformed"})
        return (
            _coverage(
                project["project_id"],
                "overseer",
                "partial",
                "malformed",
                total=1,
                invalid=1,
            ),
            [],
        )
    observed_at = _format_utc(timestamp)
    fields = {
        "healthy": healthy,
        "status": status,
        "findings_count": len(findings),
        "ts": observed_at,
        "summary_present": bool(
            isinstance(root.get("summary"), str) and root["summary"]
        ),
    }
    item = _file_evidence(
        source_kind="overseer",
        project_id=project["project_id"],
        source="overseer",
        kind="overseer_assessment",
        observed_at=observed_at,
        source_ref=f"file:{canonical}:pointer:/",
        recurrence_key=None,
        fields=fields,
    )
    item["claim_kind"] = "assessment"
    project["overseer"].update(
        {
            "state": "present",
            "reason": "ok",
            "healthy": healthy,
            "status": status,
            "summary": None,
            "findings_count": len(findings),
            "assessed_at": observed_at,
            "evidence_ids": [item["id"]],
        }
    )
    if fields["summary_present"]:
        project["overseer"]["limitations"] = ["overseer_summary_redacted"]
    return (
        _coverage(
            project["project_id"],
            "overseer",
            "available",
            "ok",
            total=1,
            valid=1,
            newest_ts=observed_at,
        ),
        [item],
    )


def _attention_id(kind: str, project_id: str, evidence_ids: list[str]) -> str:
    operands = ",".join(sorted(set(evidence_ids)))
    payload = f"{kind}\0{project_id}\0{operands}".encode("utf-8")
    return "att_" + hashlib.sha256(payload).hexdigest()[:16]


def _attention_record(
    *,
    kind: str,
    project_id: str,
    claim_kind: str,
    title: str,
    detected_at: str | None,
    severity: str | None,
    approval_action: str | None,
    evidence_ids: list[str],
    limitations: list[str],
    started_at: datetime,
) -> dict[str, Any]:
    unique_evidence = sorted(set(evidence_ids))
    detected = _parse_rfc3339(detected_at)
    age = (
        max(0, int((started_at - detected).total_seconds()))
        if detected is not None
        else None
    )
    return {
        "id": _attention_id(kind, project_id, unique_evidence),
        "project_id": project_id,
        "kind": kind,
        "claim_kind": claim_kind,
        "title": title,
        "detected_at": detected_at,
        "age_seconds": age,
        "severity_advisory": severity,
        "approval_action": approval_action,
        "evidence_ids": unique_evidence,
        "limitations": sorted(set(limitations)),
    }


def _benchmark_record(
    *,
    key: str,
    label: str,
    window_days: int,
    target_value: int | float,
    unit: str,
    components: dict[str, Any],
    evidence_ids: list[str],
    missing_link: str,
) -> dict[str, Any]:
    component_present = any(
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and value > 0
        for value in components.values()
    )
    return {
        "key": key,
        "benchmark_label": label,
        "benchmark_window_days": window_days,
        "target_operator": "gte",
        "target_value": target_value,
        "unit": unit,
        "state": "partial" if component_present else "unmeasured",
        "value": None,
        "components": components,
        "evidence_ids": sorted(set(evidence_ids)),
        "reason": missing_link if component_present else "no_component_evidence",
        "limitations": [
            "historical_benchmark_not_measured_v1",
            *([missing_link] if component_present else []),
        ],
    }


def _benchmark_effectiveness(
    evidence: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    bug_proposals = [
        item
        for item in evidence
        if item["kind"] == "open_proposal"
        and item["fields"].get("type") == "bug"
    ]
    feature_proposals = [
        item
        for item in evidence
        if item["kind"] == "open_proposal"
        and item["fields"].get("type") == "feature"
    ]
    incidents = [
        item
        for item in evidence
        if item["kind"] in {"incident_event", "incident_state"}
        and item["fields"].get("incident_id") is not None
    ]
    usage = [item for item in evidence if item["kind"] == "usage_beacon"]
    decisions = [item for item in evidence if item["kind"] == "decision"]
    approvals = [
        item for item in decisions if item["fields"].get("decision") == "approve"
    ]
    build_success = [
        item
        for item in evidence
        if item["kind"] == "job_end"
        and item["fields"].get("role") == "build"
        and item["fields"].get("status") == "ok"
    ]
    release_success = [
        item
        for item in evidence
        if item["kind"] == "job_end"
        and item["fields"].get("role") == "release"
        and item["fields"].get("status") == "ok"
    ]
    critique_events = [
        item for item in evidence if item["kind"] == "critique_event"
    ]
    critique_findings = 0
    for item in critique_events:
        finding_count = sum(
            value
            for key in ("block", "warn", "note")
            if isinstance((value := item["fields"].get(key)), (int, float))
            and not isinstance(value, bool)
            and value >= 0
        )
        critique_findings += finding_count

    bug_evidence = bug_proposals + incidents + build_success
    usage_evidence = usage
    feature_evidence = (
        feature_proposals + approvals + build_success + release_success
    )
    decision_evidence = decisions
    critique_evidence = critique_events
    five_day = "Historical 5-day trial benchmark"
    return [
        _benchmark_record(
            key="bugs_caught_and_fixed",
            label=five_day,
            window_days=5,
            target_value=1,
            unit="bugs",
            components={
                "bug_proposals": len(bug_proposals),
                "incident_signals": len(incidents),
                "successful_build_jobs": len(build_success),
            },
            evidence_ids=[item["id"] for item in bug_evidence],
            missing_link="missing_bug_fix_lineage",
        ),
        _benchmark_record(
            key="usage_assessed_projects",
            label=five_day,
            window_days=5,
            target_value=3,
            unit="projects",
            components={
                "usage_projects_observed": len(
                    {item["project_id"] for item in usage if item["project_id"]}
                ),
                "usage_records": len(usage),
            },
            evidence_ids=[item["id"] for item in usage_evidence],
            missing_link="missing_usage_assessment_lineage",
        ),
        _benchmark_record(
            key="features_shipped_end_to_end",
            label=five_day,
            window_days=5,
            target_value=1,
            unit="features",
            components={
                "feature_proposals": len(feature_proposals),
                "approve_decisions": len(approvals),
                "successful_build_jobs": len(build_success),
                "successful_release_jobs": len(release_success),
            },
            evidence_ids=[item["id"] for item in feature_evidence],
            missing_link="missing_feature_delivery_lineage",
        ),
        _benchmark_record(
            key="consequential_decisions_surfaced",
            label=five_day,
            window_days=5,
            target_value=1,
            unit="decisions",
            components={"valid_decisions": len(decisions)},
            evidence_ids=[item["id"] for item in decision_evidence],
            missing_link="missing_decision_consequence_judgment",
        ),
        _benchmark_record(
            key="critique_actionability",
            label="Historical 2-week benchmark",
            window_days=14,
            target_value=0.333333,
            unit="ratio",
            components={
                "critique_events": len(critique_events),
                "critique_findings": critique_findings,
            },
            evidence_ids=[item["id"] for item in critique_evidence],
            missing_link="missing_operator_actionability_judgment",
        ),
    ]


def _delegation_failure(
    source: str,
    *,
    coverage_state: str,
    coverage_reason: str,
    effectiveness_reason: str,
    limitations: list[str],
    total: int = 0,
    invalid: int = 0,
) -> tuple[dict[str, Any], list[dict[str, Any]], dict[str, Any]]:
    return (
        _coverage(
            None,
            f"delegation_{source}",
            coverage_state,
            coverage_reason,
            total=total,
            invalid=invalid,
            limitations=limitations,
        ),
        [],
        {
            "key": f"execute_ticket_delegation_{source}",
            "benchmark_label": "No presentation target",
            "benchmark_window_days": None,
            "target_operator": None,
            "target_value": None,
            "unit": "sessions",
            "state": "unmeasured",
            "value": None,
            "components": {},
            "evidence_ids": [],
            "reason": effectiveness_reason,
            "limitations": limitations,
        },
    )


def _delegation_adapter(
    *,
    source: str,
    core_root: str,
    window_start: datetime,
) -> tuple[dict[str, Any], list[dict[str, Any]], dict[str, Any]]:
    reporter = Path(core_root) / "scripts" / "delegation-report.py"
    if not reporter.is_file():
        return _delegation_failure(
            source,
            coverage_state="unavailable",
            coverage_reason="missing_dependency",
            effectiveness_reason="reporter_unavailable",
            limitations=["missing_dependency"],
        )
    argv = [
        sys.executable,
        str(reporter),
        "--source",
        source,
        "--since",
        _format_utc(window_start),
        "--json",
        "--tickets-dir",
        str(Path(core_root) / "docs" / "tickets"),
    ]
    try:
        result = subprocess.run(
            argv,
            cwd=core_root,
            text=True,
            capture_output=True,
            check=False,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        return _delegation_failure(
            source,
            coverage_state="error",
            coverage_reason="command_failed",
            effectiveness_reason="reporter_unavailable",
            limitations=["reporter_command_failed"],
        )
    except UnicodeDecodeError:
        return _delegation_failure(
            source,
            coverage_state="error",
            coverage_reason="malformed",
            effectiveness_reason="reporter_malformed_output",
            limitations=["reporter_malformed_output"],
            total=1,
            invalid=1,
        )
    completed_at = _format_utc(datetime.now(timezone.utc))
    if result.returncode != 0:
        root_missing = result.returncode == 2 and "transcript root at" in result.stderr
        return _delegation_failure(
            source,
            coverage_state="unavailable" if root_missing else "error",
            coverage_reason="missing" if root_missing else "command_failed",
            effectiveness_reason=(
                "reporter_root_missing" if root_missing else "reporter_unavailable"
            ),
            limitations=[
                "reporter_root_missing" if root_missing else "reporter_command_failed"
            ],
        )
    try:
        summary = _strict_object(result.stdout)
    except _StrictJSONError:
        return _delegation_failure(
            source,
            coverage_state="error",
            coverage_reason="malformed",
            effectiveness_reason="reporter_malformed_output",
            limitations=["reporter_malformed_output"],
            total=1,
            invalid=1,
        )

    required_integers = (
        "sessions",
        "turns",
        "agent_calls",
        "zero_agent_sessions",
        "malformed_timestamps",
    )
    if source == "codex":
        required_integers += ("malformed_records", "malformed_boundaries")
    invalid_summary = any(
        isinstance(summary.get(key), bool)
        or not isinstance(summary.get(key), int)
        or summary[key] < 0
        for key in required_integers
    )
    zero_agent_pct = summary.get("zero_agent_pct")
    if (
        isinstance(zero_agent_pct, bool)
        or not isinstance(zero_agent_pct, (int, float))
        or not math.isfinite(zero_agent_pct)
        or zero_agent_pct < 0
    ):
        invalid_summary = True
    if invalid_summary:
        return _delegation_failure(
            source,
            coverage_state="error",
            coverage_reason="malformed",
            effectiveness_reason="reporter_malformed_output",
            limitations=["reporter_malformed_output"],
            total=1,
            invalid=1,
        )

    malformed_records = summary.get("malformed_records", 0)
    malformed_boundaries = summary.get("malformed_boundaries", 0)
    malformed_timestamps = summary["malformed_timestamps"]
    fields = {
        "source": source,
        "sessions": summary["sessions"],
        "turns": summary["turns"],
        "agent_calls": summary["agent_calls"],
        "zero_agent_sessions": summary["zero_agent_sessions"],
        "zero_agent_pct": zero_agent_pct,
        "malformed_records": malformed_records,
        "malformed_boundaries": malformed_boundaries,
        "malformed_timestamps": malformed_timestamps,
        "reporter_completed_at": completed_at,
    }
    source_ref = f"command:delegation:{source}:aggregate"
    item = {
        "id": _evidence_id("delegation", source_ref, fields),
        "project_id": None,
        "source": f"delegation_{source}",
        "claim_kind": "fact",
        "kind": "delegation_cohort",
        "observed_at": completed_at,
        "source_ref": source_ref,
        "recurrence_key": None,
        "fields": fields,
        "limitations": [],
    }
    malformed_total = (
        malformed_records + malformed_boundaries + malformed_timestamps
    )
    limitations = [
        "exclusive_upper_bound_unsupported",
        "records_at_or_after_inspection_started_at_may_be_included",
    ]
    for count, limitation in (
        (malformed_records, "reporter_malformed_records"),
        (malformed_boundaries, "reporter_malformed_boundaries"),
        (malformed_timestamps, "reporter_malformed_timestamps"),
    ):
        if count:
            limitations.append(limitation)
    item["limitations"] = list(limitations)
    coverage = _coverage(
        None,
        f"delegation_{source}",
        "partial",
        "upper_bound_unsupported",
        total=summary["sessions"] + malformed_total,
        valid=summary["sessions"],
        invalid=malformed_total,
        newest_ts=completed_at,
        limitations=limitations,
    )
    effectiveness = {
        "key": f"execute_ticket_delegation_{source}",
        "benchmark_label": "No presentation target",
        "benchmark_window_days": None,
        "target_operator": None,
        "target_value": None,
        "unit": "sessions",
        "state": "measured",
        "value": summary["sessions"],
        "components": fields,
        "evidence_ids": [item["id"]],
        "reason": "upper_bound_unsupported",
        "limitations": limitations,
    }
    return coverage, [item], effectiveness


def _start_delegation_reporters(
    *, core_root: str, window_start: datetime
) -> tuple[
    ThreadPoolExecutor,
    dict[
        str,
        Future[
            tuple[dict[str, Any], list[dict[str, Any]], dict[str, Any]]
        ],
    ],
]:
    executor = ThreadPoolExecutor(
        max_workers=2, thread_name_prefix="shipyard-delegation"
    )
    futures = {
        source: executor.submit(
            _delegation_adapter,
            source=source,
            core_root=core_root,
            window_start=window_start,
        )
        for source in ("claude", "codex")
    }
    return executor, futures


def _delegation_effectiveness(
    *,
    executor: ThreadPoolExecutor,
    futures: dict[
        str,
        Future[
            tuple[dict[str, Any], list[dict[str, Any]], dict[str, Any]]
        ],
    ],
) -> tuple[
    dict[tuple[str | None, str], dict[str, Any]],
    list[dict[str, Any]],
    list[dict[str, Any]],
]:
    coverage: dict[tuple[str | None, str], dict[str, Any]] = {}
    evidence: list[dict[str, Any]] = []
    effectiveness: list[dict[str, Any]] = []
    try:
        for source in ("claude", "codex"):
            source_coverage, source_evidence, source_effectiveness = (
                futures[source].result()
            )
            coverage[(None, f"delegation_{source}")] = source_coverage
            evidence.extend(source_evidence)
            effectiveness.append(source_effectiveness)
    finally:
        executor.shutdown(wait=True)
    hermes_coverage, hermes_evidence, hermes_effectiveness = _delegation_failure(
        "hermes",
        coverage_state="unavailable",
        coverage_reason="unsupported",
        effectiveness_reason="unsupported",
        limitations=["unsupported_in_v1"],
    )
    coverage[(None, "delegation_hermes")] = hermes_coverage
    evidence.extend(hermes_evidence)
    effectiveness.append(hermes_effectiveness)
    return coverage, evidence, effectiveness


def _consumer_matches(
    consumer: str, record: dict[str, Any], svc: str
) -> bool:
    if _string(record.get("svc")) != svc:
        return False
    event = _string(record.get("event"))
    if consumer == "design_runner":
        return event is not None and event.startswith("design.")
    if consumer == "release_shoulder_critic":
        return event == "release.critique"
    return event == "job.end"


def _pressure_adapter(
    *,
    project: dict[str, Any],
    manifests: list[dict[str, Any]],
    root_info: dict[str, Any],
    attributed: list[dict[str, Any]],
    events_coverage: dict[str, Any],
    config: dict[str, Any] | None,
    watchers: list[dict[str, Any]],
    started_at: datetime,
    event_evidence: list[dict[str, Any]],
    gate_cache: dict[tuple[str, str, str], int | None],
    gate_decode_cache: dict[
        str, tuple[str, str | None, str | None]
    ],
    strict_cache: dict[str, tuple[int | None, bool]],
) -> list[str]:
    usable_events = events_coverage["state"] in {"available", "partial"}
    manifest_by_role: dict[str, dict[str, Any]] = {}
    for manifest in manifests:
        manifest_by_role.setdefault(manifest["role"], manifest)
    pressure = project["pressure"]
    event_ids_by_ref = {
        item["source_ref"]: item["id"]
        for item in event_evidence
        if item["project_id"] == project["project_id"]
    }
    config_ids = list(project["safety"]["evidence_ids"])
    manifest_ids = {
        unit["role"]: unit["evidence_ids"][0]
        for unit in project["units"]
        if unit["evidence_ids"]
    }
    project_provenance_ids = sorted(
        set(config_ids + list(manifest_ids.values()))
    )
    pressure_fault_ids: list[str] = []
    day_start = started_at.replace(hour=0, minute=0, second=0, microsecond=0)
    shoulder_table = config.get("shoulder") if isinstance(config, dict) else None
    shoulder_auto = (
        shoulder_table.get("auto_wire", False)
        if isinstance(shoulder_table, dict)
        else False
    )
    if not isinstance(shoulder_auto, bool):
        shoulder_auto = False
    shoulder_env = Path(project["project_path"]) / ".agents" / "shoulder.env"
    shoulder_applicable = bool(watchers) or shoulder_env.is_file() or shoulder_auto
    if shoulder_applicable:
        shoulder_state = "applicable"
    elif config is None:
        shoulder_state = "unknown"
    else:
        shoulder_state = "not_applicable"

    for index, (consumer_name, role) in enumerate(CONSUMERS):
        consumer = pressure["daily_budget_consumers"][index]
        if consumer_name == "release_shoulder_critic":
            applicability = shoulder_state
        else:
            applicability = (
                "applicable"
                if role in manifest_by_role
                else "not_applicable"
            )
        consumer["applicability"] = applicability
        if applicability != "applicable":
            consumer["configured_daily_budget"] = None
            pressure["budget_deferrals_by_consumer"][consumer_name] = None
            continue
        if usable_events:
            current = pressure["budget_deferrals_by_consumer"][consumer_name]
            pressure["budget_deferrals_by_consumer"][consumer_name] = current or 0
        else:
            pressure["budget_deferrals_by_consumer"][consumer_name] = None

        svc = (
            manifest_by_role[role]["service_stem"]
            if role in manifest_by_role
            else ""
        )
        provenance_ids = list(config_ids)
        if role in manifest_ids:
            provenance_ids.append(manifest_ids[role])
        if consumer_name == "release_shoulder_critic":
            provenance_ids.extend(
                watcher["evidence_id"]
                for watcher in watchers
                if watcher.get("evidence_id")
            )
        provenance_ids = sorted(set(provenance_ids))
        if consumer_name == "release_shoulder_critic":
            consumer["gate_scope"] = "unscoped_event_root"
            if len(watchers) == 1:
                gate_state = watchers[0]["event_root_state"]
                gate_root = watchers[0]["event_root"]
            else:
                gate_state, gate_root = "unknown", None
        elif consumer_name == "design_runner":
            consumer["gate_scope"] = "unscoped_event_root"
            gate_state = root_info["state"]
            gate_root = root_info["root"]
        else:
            consumer["gate_scope"] = "exact_service"
            if root_info["state"] == "mixed":
                gate_state, gate_root = "mixed", None
            else:
                manifest_root = manifest_by_role[role]["event_root_env"]
                if manifest_root is None:
                    gate_state, gate_root = "unset_sentinel", "/nonexistent"
                else:
                    gate_state, gate_root = "runner_manifest", manifest_root
        consumer["event_root_state"] = gate_state
        consumer["event_root"] = gate_root

        attributed_total: int | float | None = 0 if usable_events else None
        relevant_ids: list[str] = []
        if attributed_total is not None:
            for item in attributed:
                timestamp = item["timestamp"]
                record = item["object"]
                if not (day_start <= timestamp < started_at):
                    continue
                if not _consumer_matches(consumer_name, record, svc):
                    continue
                tokens = _finite_nonnegative(record.get("tokens"))
                if tokens is not None:
                    attributed_total += tokens
                source_ref = f"file:{item['path']}:line:{item['line']}"
                if source_ref in event_ids_by_ref:
                    relevant_ids.append(event_ids_by_ref[source_ref])
        consumer["attributed_tokens_today"] = attributed_total
        if gate_root is None:
            gate_tokens = None
            gate_invalid = None
        else:
            gate_path = Path(gate_root) / f"{started_at.date().isoformat()}.jsonl"
            gate_tokens = _cached_gate_operand(
                gate_path,
                consumer_name,
                svc,
                gate_cache,
                gate_decode_cache,
            )
            gate_invalid, parser_difference = _cached_strict_gate_invalid_count(
                gate_path, strict_cache
            )
            if gate_tokens is None:
                project["limitations"].append(
                    "gate_operand_missing_dependency"
                )
            if parser_difference:
                project["limitations"].append("gate_parser_differs_from_v1")
        consumer["gate_tokens_today"] = gate_tokens
        consumer["gate_records_invalid_today"] = gate_invalid
        cap = consumer["configured_daily_budget"]
        if isinstance(cap, int) and cap > 0 and attributed_total is not None:
            consumer["attributed_fraction_today"] = attributed_total / cap
        if isinstance(cap, int) and cap > 0 and gate_tokens is not None:
            consumer["gate_fraction_today"] = gate_tokens / cap
        consumer["evidence_ids"] = sorted(set(relevant_ids))
        pressure["evidence_ids"].extend(relevant_ids)
        if (
            isinstance(cap, int)
            and cap >= 0
            and gate_tokens is not None
            and gate_tokens >= cap
        ):
            reason_ids = sorted(set(relevant_ids)) or provenance_ids
            consumer["evidence_ids"] = sorted(
                set(consumer["evidence_ids"] + reason_ids)
            )
            pressure["evidence_ids"].extend(reason_ids)
            pressure_fault_ids.extend(reason_ids)

    if usable_events and "design" in manifest_by_role:
        pressure["open_cap_deferrals"] = pressure["open_cap_deferrals"] or 0
    else:
        pressure["open_cap_deferrals"] = None
    deferral_observed = any(
        value is not None and value > 0
        for value in pressure["budget_deferrals_by_consumer"].values()
    )
    open_cap_observed = (
        pressure["open_cap_deferrals"] is not None
        and pressure["open_cap_deferrals"] > 0
    )
    current_open_cap_observed = (
        isinstance(pressure["undecided_open_proposals"], int)
        and isinstance(pressure["configured_max_open_proposals"], int)
        and pressure["configured_max_open_proposals"] >= 0
        and pressure["undecided_open_proposals"]
        >= pressure["configured_max_open_proposals"]
    )
    if deferral_observed or open_cap_observed or current_open_cap_observed:
        reason_ids = sorted(set(pressure["evidence_ids"])) or project_provenance_ids
        pressure["evidence_ids"].extend(reason_ids)
        pressure_fault_ids.extend(reason_ids)
    pressure["evidence_ids"] = sorted(set(pressure["evidence_ids"]))
    project["limitations"] = sorted(set(project["limitations"]))
    return sorted(set(pressure_fault_ids))


def _pressure_skeleton(roles: list[str]) -> dict[str, Any]:
    daily = []
    for consumer, role in CONSUMERS:
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


def _priority_id(
    rule_id: str,
    scope: str,
    project_ids: list[str],
    evidence_ids: list[str],
) -> str:
    payload = (
        rule_id
        + "\0"
        + scope
        + "\0"
        + ",".join(sorted(set(project_ids)))
        + "\0"
        + ",".join(sorted(set(evidence_ids)))
    ).encode("utf-8")
    return "pri_" + hashlib.sha256(payload).hexdigest()[:16]


def _priority_record(
    *,
    category: str,
    scope: str,
    claim_kind: str,
    rule_id: str,
    title: str,
    project_ids: list[str],
    evidence_ids: list[str],
    evidence_by_id: dict[str, dict[str, Any]],
    operands: dict[str, Any],
    confidence_basis: str,
    limitations: list[str],
) -> dict[str, Any] | None:
    projects = sorted(set(project_ids))
    evidence = sorted(
        evidence_id
        for evidence_id in set(evidence_ids)
        if evidence_id in evidence_by_id
    )
    if not evidence:
        return None
    timestamps = [
        evidence_by_id[evidence_id]["observed_at"]
        for evidence_id in evidence
        if evidence_by_id[evidence_id]["observed_at"] is not None
    ]
    return {
        "id": _priority_id(rule_id, scope, projects, evidence),
        "rank": 0,
        "category": category,
        "scope": scope,
        "claim_kind": claim_kind,
        "rule_id": rule_id,
        "title": title,
        "project_ids": projects,
        "evidence_count": len(evidence),
        "newest_ts": max(timestamps, default=None),
        "evidence_ids": evidence,
        "operands": operands,
        "confidence_basis": confidence_basis,
        "limitations": sorted(set(limitations)),
    }


def _project_provenance_ids(
    project: dict[str, Any],
    *,
    role: str | None = None,
    evidence: list[dict[str, Any]],
) -> list[str]:
    result = list(project["safety"]["evidence_ids"])
    for unit in project["units"]:
        if role is None or unit["role"] == role:
            result.extend(unit["evidence_ids"])
    if role == "release":
        result.extend(
            item["id"]
            for item in evidence
            if item["project_id"] == project["project_id"]
            and item["kind"] == "shoulder_watcher_identity"
        )
    return sorted(set(result))


def _is_recurrence_failure(item: dict[str, Any]) -> bool:
    if item["kind"] == "doctor_finding":
        return True
    if item["kind"] == "job_end":
        return item["fields"].get("status") in {"fail", "partial"}
    if item["kind"] == "critique_event":
        return item["fields"].get("event") in {
            "release.critique.spawn_failed",
            "release.critique.delivery_failed",
        }
    return False


def _derive_priorities(document: dict[str, Any]) -> list[dict[str, Any]]:
    evidence = list(document["evidence"])
    evidence_by_id = {item["id"]: item for item in evidence}
    projects = {item["project_id"]: item for item in document["fleet"]}
    core_ids = {
        item["project_id"]
        for item in document["fleet"]
        if item["project_path"] == document["meta"]["core_root"]
    }
    candidates: list[dict[str, Any]] = []

    direct_rules = {
        "core_doctor_drift_v1": [],
        "core_job_failure_v1": [],
        "core_restart_failure_v1": [],
        "core_critic_failure_v1": [],
    }
    for item in evidence:
        if item["project_id"] not in core_ids:
            continue
        fields = item["fields"]
        if item["kind"] == "doctor_finding":
            direct_rules["core_doctor_drift_v1"].append(item["id"])
        elif (
            item["kind"] == "job_end"
            and fields.get("status") in {"fail", "partial"}
        ):
            direct_rules["core_job_failure_v1"].append(item["id"])
        elif (
            item["kind"] == "incident_event"
            and fields.get("event") == "medic.action.restart"
            and fields.get("outcome") in {"fail", "failed"}
        ):
            direct_rules["core_restart_failure_v1"].append(item["id"])
        elif (
            item["kind"] == "critique_event"
            and fields.get("event")
            in {
                "release.critique.spawn_failed",
                "release.critique.delivery_failed",
            }
        ):
            direct_rules["core_critic_failure_v1"].append(item["id"])
    direct_titles = {
        "core_doctor_drift_v1": "Repair observed Shipyard core install drift",
        "core_job_failure_v1": "Repair observed Shipyard core job failure",
        "core_restart_failure_v1": "Repair failed Shipyard core restart",
        "core_critic_failure_v1": "Repair Shipyard core critic failure",
    }
    for rule_id, ids in direct_rules.items():
        record = _priority_record(
            category="confirmed_failure",
            scope="shipyard_core",
            claim_kind="fact",
            rule_id=rule_id,
            title=direct_titles[rule_id],
            project_ids=[
                evidence_by_id[evidence_id]["project_id"]
                for evidence_id in ids
            ],
            evidence_ids=ids,
            evidence_by_id=evidence_by_id,
            operands={"failure_records": len(set(ids))},
            confidence_basis="Direct evidence names the canonical Shipyard core project.",
            limitations=[],
        )
        if record is not None:
            candidates.append(record)

    for item in document["attention"]:
        if (
            item["project_id"] in core_ids
            and item["kind"] in {"open_proposal", "owner_decision"}
        ):
            record = _priority_record(
                category="human_gate",
                scope="shipyard_core",
                claim_kind=item["claim_kind"],
                rule_id="core_human_gate_v1",
                title=item["title"],
                project_ids=[item["project_id"]],
                evidence_ids=item["evidence_ids"],
                evidence_by_id=evidence_by_id,
                operands={
                    "attention_id": item["id"],
                    "attention_kind": item["kind"],
                },
                confidence_basis="Persisted core attention requires an operator decision.",
                limitations=item["limitations"],
            )
            if record is not None:
                candidates.append(record)

    recurrence_groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for item in evidence:
        if item["recurrence_key"] is not None and _is_recurrence_failure(item):
            recurrence_groups[item["recurrence_key"]].append(item)
    for recurrence_key, items in sorted(recurrence_groups.items()):
        project_ids = sorted(
            {
                item["project_id"]
                for item in items
                if item["project_id"] is not None
            }
        )
        if len(project_ids) < 2:
            continue
        record = _priority_record(
            category="recurring_failure",
            scope="core_candidate",
            claim_kind="assessment",
            rule_id="cross_project_recurrence_v1",
            title=f"Investigate recurring fleet failure: {recurrence_key}",
            project_ids=project_ids,
            evidence_ids=[item["id"] for item in items],
            evidence_by_id=evidence_by_id,
            operands={
                "recurrence_key": recurrence_key,
                "project_count": len(project_ids),
            },
            confidence_basis="Exact L19 recurrence appears in at least two projects.",
            limitations=["cross_project_recurrence_is_not_core_proof"],
        )
        if record is not None:
            candidates.append(record)

    for item in document["attention"]:
        if (
            item["project_id"] in core_ids
            and item["kind"] == "open_proposal"
            and "unresolved_signal_ids" not in item["limitations"]
            and len(set(item["evidence_ids"])) > 1
        ):
            record = _priority_record(
                category="evidenced_opportunity",
                scope="shipyard_core",
                claim_kind="assessment",
                rule_id="core_evidenced_opportunity_v1",
                title=item["title"],
                project_ids=[item["project_id"]],
                evidence_ids=item["evidence_ids"],
                evidence_by_id=evidence_by_id,
                operands={
                    "attention_id": item["id"],
                    "resolved_signal_count": len(set(item["evidence_ids"])) - 1,
                },
                confidence_basis="Every persisted signal ID resolves to exact core evidence.",
                limitations=item["limitations"],
            )
            if record is not None:
                candidates.append(record)

    historical_keys = {
        "bugs_caught_and_fixed",
        "usage_assessed_projects",
        "features_shipped_end_to_end",
        "consequential_decisions_surfaced",
        "critique_actionability",
    }
    for item in document["effectiveness"]:
        if item["key"] not in historical_keys:
            continue
        if item["state"] != "measured" and item["evidence_ids"]:
            record = _priority_record(
                category="instrumentation_gap",
                scope="shipyard_core",
                claim_kind="derived",
                rule_id="historical_benchmark_gap_v1",
                title=f"Close benchmark linkage: {item['key']}",
                project_ids=[
                    evidence_by_id[evidence_id]["project_id"]
                    for evidence_id in item["evidence_ids"]
                    if evidence_id in evidence_by_id
                    and evidence_by_id[evidence_id]["project_id"] is not None
                ],
                evidence_ids=item["evidence_ids"],
                evidence_by_id=evidence_by_id,
                operands={
                    "effectiveness_key": item["key"],
                    "state": item["state"],
                    "missing_link": item["reason"],
                },
                confidence_basis="Observed benchmark components cannot prove the historical outcome.",
                limitations=item["limitations"],
            )
            if record is not None:
                candidates.append(record)

    coverage_groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for item in evidence:
        if item["kind"] == "coverage_gap" and item["recurrence_key"] is not None:
            coverage_groups[item["recurrence_key"]].append(item)
    for recurrence_key, items in sorted(coverage_groups.items()):
        project_ids = sorted(
            {
                item["project_id"]
                for item in items
                if item["project_id"] is not None
            }
        )
        if len(project_ids) < 2:
            continue
        record = _priority_record(
            category="instrumentation_gap",
            scope="core_candidate",
            claim_kind="derived",
            rule_id="cross_project_coverage_gap_v1",
            title=f"Close repeated fleet coverage gap: {recurrence_key}",
            project_ids=project_ids,
            evidence_ids=[item["id"] for item in items],
            evidence_by_id=evidence_by_id,
            operands={
                "recurrence_key": recurrence_key,
                "project_count": len(project_ids),
            },
            confidence_basis="The same exact coverage reason blocks at least two projects.",
            limitations=["cross_project_gap_scope_not_core_proof"],
        )
        if record is not None:
            candidates.append(record)

    shared_groups: dict[tuple[str, str], list[tuple[dict[str, Any], dict[str, Any]]]] = (
        defaultdict(list)
    )
    for project in document["fleet"]:
        for consumer in project["pressure"]["daily_budget_consumers"]:
            if (
                consumer["consumer"]
                in {"design_runner", "release_shoulder_critic"}
                and consumer["applicability"] == "applicable"
                and consumer["gate_scope"] == "unscoped_event_root"
                and consumer["event_root"] is not None
                and consumer["event_root_state"]
                in {
                    "runner_manifest",
                    "core_fallback",
                    "configured",
                    "project_default",
                }
            ):
                shared_groups[
                    (consumer["consumer"], consumer["event_root"])
                ].append((project, consumer))
    shared = [
        (key, members)
        for key, members in sorted(shared_groups.items())
        if len({project["project_id"] for project, _ in members}) > 1
    ]
    if shared:
        shared_projects: list[str] = []
        shared_evidence: list[str] = []
        consumers: list[str] = []
        roots: list[str] = []
        shared_operands: list[dict[str, Any]] = []
        for (consumer_name, root), members in shared:
            consumers.append(consumer_name)
            roots.append(root)
            for project, consumer in members:
                shared_projects.append(project["project_id"])
                shared_operands.append(
                    {
                        "project_id": project["project_id"],
                        "consumer": consumer_name,
                        "event_root": root,
                        "attributed_tokens_today": consumer[
                            "attributed_tokens_today"
                        ],
                        "gate_tokens_today": consumer["gate_tokens_today"],
                    }
                )
                shared_evidence.extend(consumer["evidence_ids"])
                shared_evidence.extend(
                    _project_provenance_ids(
                        project,
                        role=consumer["role"],
                        evidence=evidence,
                    )
                )
        record = _priority_record(
            category="instrumentation_gap",
            scope="shipyard_core",
            claim_kind="derived",
            rule_id="budget_gate_scope_mismatch_v1",
            title="Scope shared budget gates to attributed projects",
            project_ids=shared_projects,
            evidence_ids=shared_evidence,
            evidence_by_id=evidence_by_id,
            operands={
                "consumers": sorted(set(consumers)),
                "event_roots": sorted(set(roots)),
                "members": sorted(
                    shared_operands,
                    key=lambda item: (
                        item["consumer"],
                        item["project_id"],
                    ),
                ),
            },
            confidence_basis="Applicable unscoped gates share a resolved root across projects.",
            limitations=["gate_operand_is_unscoped"],
        )
        if record is not None:
            candidates.append(record)

    mismatch_projects: list[str] = []
    mismatch_evidence: list[str] = []
    mismatch_consumers: list[str] = []
    mismatch_operands: list[dict[str, Any]] = []
    for project in document["fleet"]:
        project_manifests = [
            item
            for item in evidence
            if item["project_id"] == project["project_id"]
            and item["kind"] == "manifest_identity"
        ]
        manifest_by_role = {
            item["fields"]["role"]: item for item in project_manifests
        }
        emitted_core_fallback = bool(project_manifests) and all(
            item["fields"]["event_root_env"] is None
            for item in project_manifests
        )
        for consumer in project["pressure"]["daily_budget_consumers"]:
            if (
                consumer["consumer"]
                in {
                    "build_runner",
                    "release_runner",
                    "medic_runner",
                    "scribe_runner",
                }
                and consumer["applicability"] == "applicable"
                and consumer["event_root_state"] == "unset_sentinel"
                and emitted_core_fallback
                and consumer["role"] in manifest_by_role
            ):
                mismatch_projects.append(project["project_id"])
                mismatch_consumers.append(consumer["consumer"])
                mismatch_operands.append(
                    {
                        "project_id": project["project_id"],
                        "consumer": consumer["consumer"],
                        "emitted_event_root_state": "core_fallback",
                        "gate_event_root_state": "unset_sentinel",
                        "attributed_tokens_today": consumer[
                            "attributed_tokens_today"
                        ],
                        "gate_tokens_today": consumer["gate_tokens_today"],
                    }
                )
                mismatch_evidence.extend(consumer["evidence_ids"])
                mismatch_evidence.extend(
                    _project_provenance_ids(
                        project,
                        role=consumer["role"],
                        evidence=evidence,
                    )
                )
    if mismatch_projects:
        record = _priority_record(
            category="instrumentation_gap",
            scope="shipyard_core",
            claim_kind="derived",
            rule_id="budget_gate_root_mismatch_v1",
            title="Align unset runner budget roots with emitted events",
            project_ids=mismatch_projects,
            evidence_ids=mismatch_evidence,
            evidence_by_id=evidence_by_id,
            operands={
                "consumers": sorted(set(mismatch_consumers)),
                "members": sorted(
                    mismatch_operands,
                    key=lambda item: (
                        item["consumer"],
                        item["project_id"],
                    ),
                ),
            },
            confidence_basis="Runner gates use /nonexistent while emitted events use core fallback.",
            limitations=["unset_sentinel_differs_from_emitted_event_root"],
        )
        if record is not None:
            candidates.append(record)

    manifests: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for item in evidence:
        if item["kind"] == "manifest_identity":
            manifests[(item["project_id"], item["fields"]["role"])].append(item)
    for (project_id, role), items in sorted(manifests.items()):
        if len(items) < 2:
            continue
        record = _priority_record(
            category="hygiene",
            scope="shipyard_core",
            claim_kind="derived",
            rule_id="duplicate_matching_manifest_v1",
            title=f"Remove duplicate matching {role} manifests",
            project_ids=[project_id],
            evidence_ids=[item["id"] for item in items],
            evidence_by_id=evidence_by_id,
            operands={"role": role, "manifest_count": len(items)},
            confidence_basis="Multiple accepted manifests map to one project and canonical role.",
            limitations=[],
        )
        if record is not None:
            candidates.append(record)

    category_rank = {
        category: index for index, category in enumerate(PRIORITY_CATEGORIES)
    }
    candidates.sort(key=lambda item: item["id"])
    candidates.sort(key=lambda item: item["newest_ts"] or "", reverse=True)
    candidates.sort(key=lambda item: item["evidence_count"], reverse=True)
    candidates.sort(key=lambda item: category_rank[item["category"]])
    for rank, item in enumerate(candidates, 1):
        item["rank"] = rank
    return candidates


def build_document(
    *, core_root: str, unit_dir: str, started_at: datetime, days: int
) -> dict[str, Any] | None:
    window_start_at = started_at - timedelta(days=days)
    manifests = discover_manifests(core_root, unit_dir)
    if not manifests:
        return None
    delegation_executor, delegation_futures = _start_delegation_reporters(
        core_root=core_root,
        window_start=window_start_at,
    )

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
                    limitations=[LATER_PHASE_LIMITATION],
                )
            )
    for source in GLOBAL_SOURCES:
        coverage.append(
            _coverage(
                None,
                source,
                "unavailable",
                "unsupported",
                limitations=[LATER_PHASE_LIMITATION],
            )
        )
    coverage_by_key = {
        (item["project_id"], item["source"]): item for item in coverage
    }

    direct_fault_ids: dict[str, list[str]] = defaultdict(list)
    exact_pressure_ids: dict[str, list[str]] = defaultdict(list)
    config_by_path: dict[str, dict[str, Any] | None] = {}
    open_proposals_by_id: dict[str, list[dict[str, Any]]] = defaultdict(list)
    decision_conflicts_by_id: dict[str, dict[str, list[str]]] = defaultdict(dict)
    for project in fleet:
        config, config_coverage, config_evidence = _load_config_adapter(project)
        config_by_path[project["project_path"]] = config
        coverage_by_key[(project["project_id"], "config")] = config_coverage
        if config_evidence is not None:
            evidence.append(config_evidence)

        systemd_coverage, systemd_evidence, systemd_faults = _systemd_adapter(
            project, started_at
        )
        coverage_by_key[(project["project_id"], "systemd")] = systemd_coverage
        evidence.extend(systemd_evidence)
        direct_fault_ids[project["project_id"]].extend(systemd_faults)

        doctor, doctor_coverage, doctor_evidence = _doctor_adapter(
            project, core_root, config is not None, config_coverage["reason"]
        )
        project["doctor"] = doctor
        coverage_by_key[(project["project_id"], "doctor")] = doctor_coverage
        evidence.extend(doctor_evidence)
        if doctor["state"] == "drift":
            direct_fault_ids[project["project_id"]].extend(
                finding["evidence_id"] for finding in doctor["findings"]
            )

        if "design" in project["roles"]:
            (
                decision_coverage,
                decision_evidence,
                decided_ids,
                decision_conflicts,
            ) = _decision_adapter(project)
            coverage_by_key[
                (project["project_id"], "decisions")
            ] = decision_coverage
            evidence.extend(decision_evidence)
            decision_conflicts_by_id[project["project_id"]] = decision_conflicts

            (
                proposal_coverage,
                proposal_evidence,
                open_proposals,
            ) = _proposal_adapter(project, config, decided_ids)
            coverage_by_key[
                (project["project_id"], "proposals")
            ] = proposal_coverage
            evidence.extend(proposal_evidence)
            open_proposals_by_id[project["project_id"]] = open_proposals
            if proposal_coverage["state"] in {"available", "partial"}:
                undecided = len(open_proposals)
                project["pressure"]["undecided_open_proposals"] = undecided
                cap = project["pressure"]["configured_max_open_proposals"]
                project["pressure"]["open_cap_remaining"] = (
                    max(0, cap - undecided) if isinstance(cap, int) else None
                )
                proposal_ids = sorted(
                    proposal["evidence_id"] for proposal in open_proposals
                )
                project["pressure"]["evidence_ids"].extend(proposal_ids)
        else:
            for source in ("proposals", "decisions"):
                coverage_by_key[(project["project_id"], source)] = _coverage(
                    project["project_id"],
                    source,
                    "not_applicable",
                    "unsupported",
                    limitations=["design_role_not_installed"],
                )

        overseer_coverage, overseer_evidence = _overseer_adapter(project)
        coverage_by_key[(project["project_id"], "overseer")] = overseer_coverage
        evidence.extend(overseer_evidence)
        project["limitations"] = []

    (
        events_coverage,
        events_evidence,
        events_faults,
        events_pressure,
        event_roots,
        attributed_events,
    ) = _events_adapter(
        fleet=fleet,
        by_project=by_project,
        core_root=core_root,
        window_start=window_start_at,
        started_at=started_at,
    )
    coverage_by_key.update(events_coverage)
    evidence.extend(events_evidence)
    for project_id, ids in events_faults.items():
        direct_fault_ids[project_id].extend(ids)
    for project_id, ids in events_pressure.items():
        exact_pressure_ids[project_id].extend(ids)

    watchers_by_path, watcher_evidence = _discover_shoulders(
        core_root=core_root,
        unit_dir=unit_dir,
        fleet=fleet,
    )
    evidence.extend(watcher_evidence)

    gate_operand_cache: dict[tuple[str, str, str], int | None] = {}
    gate_decode_cache: dict[
        str, tuple[str, str | None, str | None]
    ] = {}
    strict_gate_cache: dict[str, tuple[int | None, bool]] = {}
    for project in fleet:
        project_path = project["project_path"]
        project_id = project["project_id"]
        config = config_by_path[project_path]
        auxiliary_coverage, auxiliary_evidence = _fyi_usage_adapters(
            project, window_start_at, started_at
        )
        for source, record in auxiliary_coverage.items():
            coverage_by_key[(project_id, source)] = record
        evidence.extend(auxiliary_evidence)

        incident_coverage, incident_evidence = _incident_state_adapter(
            project, config
        )
        coverage_by_key[(project_id, "incident_state")] = incident_coverage
        evidence.extend(incident_evidence)

        caddy_coverage, caddy_evidence = _caddy_adapter(
            project, config, window_start_at, started_at
        )
        coverage_by_key[(project_id, "caddy")] = caddy_coverage
        evidence.extend(caddy_evidence)

        pressure_ids = _pressure_adapter(
            project=project,
            manifests=by_project[project_path],
            root_info=event_roots[project_path],
            attributed=attributed_events[project_path],
            events_coverage=coverage_by_key[(project_id, "events")],
            config=config,
            watchers=watchers_by_path[project_path],
            started_at=started_at,
            event_evidence=events_evidence,
            gate_cache=gate_operand_cache,
            gate_decode_cache=gate_decode_cache,
            strict_cache=strict_gate_cache,
        )
        exact_pressure_ids[project_id].extend(pressure_ids)

    (
        delegation_coverage,
        delegation_evidence,
        delegation_records,
    ) = _delegation_effectiveness(
        executor=delegation_executor,
        futures=delegation_futures,
    )
    coverage_by_key.update(delegation_coverage)
    evidence.extend(delegation_evidence)

    coverage = list(coverage_by_key.values())
    source_rank = {source: index for index, source in enumerate(COVERAGE_ORDER)}
    coverage.sort(
        key=lambda item: (
            item["project_id"] is not None,
            item["project_id"] or "",
            source_rank[item["source"]],
        )
    )

    coverage_by_key = {
        (item["project_id"], item["source"]): item for item in coverage
    }
    for project in fleet:
        project_id = project["project_id"]
        reasons = sorted(set(direct_fault_ids[project_id]))
        if reasons:
            project["state"] = "fault_observed"
            project["state_reason_ids"] = reasons
            continue
        primary_gaps = [
            coverage_by_key[(project_id, source)]
            for source in ("manifest", "config", "systemd", "doctor", "events")
            if coverage_by_key[(project_id, source)]["state"] != "available"
        ]
        pressure_reasons = sorted(set(exact_pressure_ids[project_id]))
        if primary_gaps or pressure_reasons:
            gap_evidence = [_coverage_evidence(record) for record in primary_gaps]
            evidence.extend(gap_evidence)
            project["state"] = "degraded_observed"
            project["state_reason_ids"] = sorted(
                {item["id"] for item in gap_evidence} | set(pressure_reasons)
            )
        else:
            project["state"] = "no_fault_observed"
            project["state_reason_ids"] = []

    evidence_by_id = {item["id"]: item for item in evidence}
    attention: list[dict[str, Any]] = []
    signal_evidence: dict[tuple[str, str], list[str]] = defaultdict(list)
    for item in evidence_by_id.values():
        if item["project_id"] is None:
            continue
        fields = item["fields"]
        for key in ("id", "incident_id"):
            signal_id = _nonempty_string(fields.get(key))
            if signal_id is not None and item["kind"] != "open_proposal":
                signal_evidence[(item["project_id"], signal_id)].append(item["id"])

    for project in fleet:
        project_id = project["project_id"]
        for proposal in open_proposals_by_id[project_id]:
            linked_ids = [proposal["evidence_id"]]
            unresolved = False
            for signal_id in proposal["signal_ids"]:
                resolved = signal_evidence.get((project_id, signal_id), [])
                if resolved:
                    linked_ids.extend(resolved)
                else:
                    unresolved = True
            limitations: list[str] = []
            if unresolved:
                limitations.append("unresolved_signal_ids")
            if proposal["approval_action"] is None:
                limitations.append("approval_action_not_persisted")
            attention.append(
                _attention_record(
                    kind="open_proposal",
                    project_id=project_id,
                    claim_kind="assessment",
                    title=proposal["title"],
                    detected_at=proposal["detected_at"],
                    severity=proposal["severity"],
                    approval_action=proposal["approval_action"],
                    evidence_ids=linked_ids,
                    limitations=limitations,
                    started_at=started_at,
                )
            )

        for evidence_ids in decision_conflicts_by_id[project_id].values():
            timestamps = [
                evidence_by_id[evidence_id]["observed_at"]
                for evidence_id in evidence_ids
                if evidence_id in evidence_by_id
                and evidence_by_id[evidence_id]["observed_at"] is not None
            ]
            attention.append(
                _attention_record(
                    kind="owner_decision",
                    project_id=project_id,
                    claim_kind="derived",
                    title="Resolve conflicting persisted proposal decisions",
                    detected_at=max(timestamps, default=None),
                    severity=None,
                    approval_action=None,
                    evidence_ids=evidence_ids,
                    limitations=["conflicting_persisted_decisions"],
                    started_at=started_at,
                )
            )

        for evidence_id in sorted(set(direct_fault_ids[project_id])):
            item = evidence_by_id.get(evidence_id)
            if item is None or item["kind"] == "doctor_finding":
                continue
            attention.append(
                _attention_record(
                    kind="observed_fault",
                    project_id=project_id,
                    claim_kind="fact",
                    title="Observed current fleet fault",
                    detected_at=item["observed_at"],
                    severity="high",
                    approval_action=None,
                    evidence_ids=[evidence_id],
                    limitations=[],
                    started_at=started_at,
                )
            )

        if project["doctor"]["state"] == "drift":
            for finding in project["doctor"]["findings"]:
                evidence_id = finding["evidence_id"]
                item = evidence_by_id.get(evidence_id)
                if item is None:
                    continue
                attention.append(
                    _attention_record(
                        kind="install_drift",
                        project_id=project_id,
                        claim_kind="fact",
                        title="Shipyard installation drift",
                        detected_at=item["observed_at"],
                        severity="med",
                        approval_action=None,
                        evidence_ids=[evidence_id],
                        limitations=[],
                        started_at=started_at,
                    )
                )

    for record in coverage:
        if (
            record["project_id"] is None
            or record["state"] in {"available", "not_applicable"}
        ):
            continue
        item = _coverage_evidence(record)
        evidence_by_id[item["id"]] = item
        attention.append(
            _attention_record(
                kind="coverage_gap",
                project_id=record["project_id"],
                claim_kind="derived",
                title=f"Coverage gap: {record['source']}",
                detected_at=record["newest_ts"],
                severity=None,
                approval_action=None,
                evidence_ids=[item["id"]],
                limitations=list(record["limitations"]),
                started_at=started_at,
            )
        )

    evidence = sorted(evidence_by_id.values(), key=lambda item: item["id"])
    effectiveness = _benchmark_effectiveness(evidence) + delegation_records
    effectiveness_state_counts = {
        state: sum(1 for item in effectiveness if item["state"] == state)
        for state in ("measured", "partial", "unmeasured")
    }
    attention.sort(
        key=lambda item: (
            item["detected_at"] is None,
            item["detected_at"] or "",
            item["id"],
        )
    )

    started_text = _format_utc(started_at)
    window_start = _format_utc(window_start_at)
    role_count = sum(len(project["roles"]) for project in fleet)
    state_counts = {
        "fault_observed": 0,
        "degraded_observed": 0,
        "no_fault_observed": 0,
        "unknown": 0,
    }
    for project in fleet:
        state_counts[project["state"]] += 1
    fleet_state = next(
        state
        for state in (
            "fault_observed",
            "degraded_observed",
            "unknown",
            "no_fault_observed",
        )
        if state_counts[state]
    )
    document = {
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
        "attention": attention,
        "effectiveness": effectiveness,
        "priorities": [],
        "summary": {
            "fleet_state": fleet_state,
            "project_state_counts": state_counts,
            "attention_count": len(attention),
            "effectiveness_state_counts": effectiveness_state_counts,
            "priority_count": 0,
            "top_priority_ids": [],
        },
    }
    priorities = _derive_priorities(document)
    document["priorities"] = priorities
    document["summary"]["priority_count"] = len(priorities)
    document["summary"]["top_priority_ids"] = [
        item["id"] for item in priorities[:3]
    ]
    return document


def render_human(document: dict[str, Any]) -> str:
    def scalar(value: Any) -> str:
        if value is None:
            return "unavailable"
        if isinstance(value, bool):
            return "true" if value else "false"
        return str(value)

    def budget_pressure(project: dict[str, Any]) -> str:
        members = []
        deferrals = project["pressure"]["budget_deferrals_by_consumer"]
        for consumer in project["pressure"]["daily_budget_consumers"]:
            name = consumer["consumer"]
            if consumer["applicability"] != "applicable":
                members.append(f"{name}:{consumer['applicability']}")
                continue
            members.append(
                f"{name}:{scalar(consumer['gate_tokens_today'])}/"
                f"{scalar(consumer['configured_daily_budget'])}"
                f"(deferred={scalar(deferrals[name])})"
            )
        return "[" + ",".join(members) + "]"

    def open_pressure(project: dict[str, Any]) -> str:
        pressure = project["pressure"]
        return (
            f"{scalar(pressure['undecided_open_proposals'])}/"
            f"{scalar(pressure['configured_max_open_proposals'])}"
            f"(remaining={scalar(pressure['open_cap_remaining'])},"
            f"deferred={scalar(pressure['open_cap_deferrals'])})"
        )

    meta = document["meta"]
    lines = [
        "shipyard inspect — fleet observation",
        (
            f"window: {meta['window_start_at']} to {meta['window_end_at']} "
            f"({meta['window_days']}d, end exclusive)"
        ),
        f"fleet: {meta['project_count']} project(s), {meta['role_count']} role(s)",
        f"state: {document['summary']['fleet_state']}",
        "",
        "FLEET",
    ]
    for project in document["fleet"]:
        roles = ",".join(project["roles"])
        safety = project["safety"]
        lines.append(
            f"  - {project['project_id']} {project['project_name']}: "
            f"state={project['state']} roles={len(project['roles'])}({roles}) "
            f"doctor={project['doctor']['state']} "
            f"budget={budget_pressure(project)} "
            f"open-cap={open_pressure(project)} "
            f"gates=merge:{scalar(safety['can_merge'])},"
            f"no-ci:{scalar(safety['allow_no_ci'])},"
            f"verify:{scalar(safety['release_verify_gate'])},"
            f"branch:{scalar(safety['configured_branch'])}"
        )
    if not document["fleet"]:
        lines.append("  none")

    lines.extend(["", "ATTENTION"])
    if document["attention"]:
        for item in document["attention"]:
            limitations = ",".join(item["limitations"]) or "none"
            lines.append(
                f"  - [{item['id']}] {item['kind']} project={item['project_id']} "
                f"{item['title']} limitations={limitations}"
            )
    else:
        lines.append("  none")

    lines.extend(["", "EFFECTIVENESS"])
    if document["effectiveness"]:
        for item in document["effectiveness"]:
            limitations = ",".join(item["limitations"]) or "none"
            lines.append(
                f"  - {item['key']}: {item['state']} "
                f"value={scalar(item['value'])} evidence={len(item['evidence_ids'])} "
                f"reason={scalar(item['reason'])} limitations={limitations}"
            )
    else:
        lines.append("  none")

    lines.extend(["", "NEXT SHIPYARD PR"])
    if document["priorities"]:
        for item in document["priorities"]:
            limitations = ",".join(item["limitations"]) or "none"
            lines.append(
                f"  - [{item['id']}] {item['category']}/{item['scope']} "
                f"{item['title']} rule={item['rule_id']}"
            )
            lines.append(
                f"    why: evidence={item['evidence_count']}; "
                f"limitations={limitations}"
            )
    else:
        lines.append("  none")

    lines.extend(["", "COVERAGE"])
    gaps = [
        item for item in document["coverage"] if item["state"] != "available"
    ]
    if gaps:
        for item in gaps:
            owner = item["project_id"] or "global"
            limitations = ",".join(item["limitations"]) or "none"
            lines.append(
                f"  - {owner}/{item['source']}: {item['state']} "
                f"reason={item['reason']} valid={item['records_valid']}/"
                f"{item['records_total']} limitations={limitations}"
            )
    else:
        lines.append("  none")
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
