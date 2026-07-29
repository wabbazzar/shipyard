#!/usr/bin/env python3
"""Read-only Shipyard fleet inspection document builder (schema v1)."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import tomllib
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
LATER_PHASE_LIMITATION = "adapter_not_implemented_later_phase"
ASCII_POSITIVE_INTEGER = re.compile(r"^[1-9][0-9]*$")
ASCII_NONNEGATIVE_INTEGER = re.compile(r"^[0-9]+$")
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
    invalid: int = 0,
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
        "records_invalid": invalid,
        "records_out_of_window": 0,
        "records_unattributed": 0,
        "records_ambiguous": 0,
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
    for project in fleet:
        config, config_coverage, config_evidence = _load_config_adapter(project)
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
        project["limitations"] = [LATER_PHASE_LIMITATION]

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
        if primary_gaps:
            gap_evidence = [_coverage_evidence(record) for record in primary_gaps]
            evidence.extend(gap_evidence)
            project["state"] = "degraded_observed"
            project["state_reason_ids"] = sorted(
                item["id"] for item in gap_evidence
            )
        else:
            project["state"] = "no_fault_observed"
            project["state_reason_ids"] = []

    evidence.sort(key=lambda item: item["id"])

    started_text = _format_utc(started_at)
    window_start = _format_utc(started_at - timedelta(days=days))
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
            "fleet_state": fleet_state,
            "project_state_counts": state_counts,
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
