"""Shipyard-owned operator semantics for dashboard adapters.

The browser and downstream dashboards render this document; they do not infer
promise state, priority, topology, or narrative from raw events.
"""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Optional


OPERATOR_VIEW_SCHEMA_VERSION = 1
OPERATOR_BUILD_VERSION = "0.1.0"
OPERATOR_RULE_VERSION = "operator-outcomes-v1"
INSPECTION_TTL_SECONDS = 300
MAX_ATTENTION = 200
MAX_EVIDENCE = 500
MAX_STORY_BEATS = 8
MAX_BRIEF_SIGNALS = 4
MAX_ATTENTION_GROUPS = 8
MAX_RELATIONSHIP_EDGES = 500
MAX_OUTCOME_CHAINS = 500
MAX_CHANGE_RANGES = 50
MAX_SCOPE_PROJECTS = 50
MAX_RUNTIME_EVENTS_PER_NODE = 20
MAX_ARCHITECTURE_GRAPH_NODES = 32
MAX_ARCHITECTURE_GRAPH_EDGES = 64
MAX_PROJECT_RUNTIME_GRAPH_NODES = 8
MAX_PROJECT_RUNTIME_GRAPH_EDGES = 8
MAX_DELIVERY_GRAPHS = 50
MAX_DELIVERY_GRAPH_NODES = 12
MAX_DELIVERY_GRAPH_EDGES = 16
MAX_GRAPH_EVIDENCE_IDS = 20
DELIVERY_EVENT_FAMILIES = (
    "design.proposal",
    "build.ticket.outcome",
    "build.work.outcome",
    "medic.incident",
)
DELIVERY_IDENTIFIER_FIELDS = (
    "proposal_id",
    "incident_id",
    "work_id",
    "upstream_work_id",
)
WINDOW_DAYS = {"24h": 1, "7d": 7, "30d": 30}
PROMISE_DEFINITIONS = (
    ("bugs_caught_and_fixed", "Bugs caught and fixed"),
    ("usage_assessed_projects", "Projects assessed"),
    ("features_shipped_end_to_end", "Features shipped end to end"),
    ("consequential_decisions_surfaced", "Decisions surfaced"),
    ("critique_actionability", "Critiques acted on"),
    ("execute_ticket_delegation_claude", "Claude delegation"),
    ("execute_ticket_delegation_codex", "Codex delegation"),
    ("execute_ticket_delegation_hermes", "Hermes delegation"),
)

_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@-]{0,159}$")
_CODE_RE = re.compile(r"^[a-z0-9][a-z0-9_.:-]{0,127}$")
_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
_STATE_RANK = {"violated": 0, "unverified": 1, "verified": 2, "not_applicable": 3}
_ROLE_STATE_RANK = {"failed": 0, "stale": 1, "running": 2, "healthy": 3, "unknown": 4}
_RUNTIME_TERMINAL_STATUSES = {"ok", "fail", "abort", "partial", "skipped"}
_RUNTIME_TERMINAL_REASONS = {
    "dirty",
    "not_trunk",
    "open_cap",
    "budget",
    "budget_deferred",
}
_TOKEN_FIELDS = (
    "input_tokens",
    "cache_read_tokens",
    "cache_write_tokens",
    "output_tokens",
    "reasoning_tokens",
)

# Titles copied into the public brief must be controlled by the inspector rule,
# never by an event, prompt, model result, or other free-form source field.
_PRIORITY_LABELS = {
    "core_doctor_drift_v1": "Repair observed Shipyard core install drift",
    "core_job_failure_v1": "Repair observed Shipyard core job failure",
    "core_restart_failure_v1": "Repair failed Shipyard core restart",
    "core_critic_failure_v1": "Repair Shipyard core critic failure",
    "core_human_gate_v1": "Resolve the Shipyard operator gate",
    "cross_project_recurrence_v1": "Investigate a recurring fleet failure",
    "core_evidenced_opportunity_v1": "Review the evidenced Shipyard opportunity",
    "historical_benchmark_gap_v1": "Close outcome linkage",
    "cross_project_coverage_gap_v1": "Close repeated coverage gaps",
    "budget_gate_scope_mismatch_v1": "Scope shared budget gates to attributed projects",
    "budget_gate_root_mismatch_v1": "Align unset runner budget roots with emitted events",
    "duplicate_matching_manifest_v1": "Remove duplicate matching manifests",
}
_PRIORITY_NUMERIC_OPERANDS = {
    "core_doctor_drift_v1": ("failure_records",),
    "core_job_failure_v1": ("failure_records",),
    "core_restart_failure_v1": ("failure_records",),
    "core_critic_failure_v1": ("failure_records",),
    "cross_project_recurrence_v1": ("project_count",),
    "core_evidenced_opportunity_v1": ("resolved_signal_count",),
    "cross_project_coverage_gap_v1": ("project_count",),
    "duplicate_matching_manifest_v1": ("manifest_count",),
}


class OperatorDataError(ValueError):
    """Raised when a core data source does not satisfy its public contract."""


class GraphValidationError(OperatorDataError):
    """Controlled graph rejection whose code is safe for public limitations."""

    _CODES = {
        "bound",
        "cycle",
        "dangling_endpoint",
        "duplicate_id",
        "invalid",
        "project_isolation",
    }

    def __init__(self, code: str):
        if code not in self._CODES:
            code = "invalid"
        self.code = code
        super().__init__(f"graph validation failed: {code}")


@dataclass(frozen=True)
class CacheResult:
    data: Optional[dict[str, Any]]
    state: str
    age_seconds: Optional[int]
    limitation: Optional[str]


@dataclass
class _CacheEntry:
    data: dict[str, Any]
    loaded_at: float


class InspectionCache:
    """Bounded-TTL, per-window, single-flight background snapshot cache."""

    def __init__(
        self,
        loader: Callable[[str], dict[str, Any]],
        *,
        ttl_seconds: int = INSPECTION_TTL_SECONDS,
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        if ttl_seconds <= 0:
            raise ValueError("inspection TTL must be positive")
        self.loader = loader
        self.ttl_seconds = ttl_seconds
        self.monotonic = monotonic
        self._lock = threading.Lock()
        self._entries: dict[str, _CacheEntry] = {}
        self._in_flight: Optional[str] = None
        self._errors: set[str] = set()
        self._last_attempt: dict[str, float] = {}

    def get(self, window: str) -> CacheResult:
        if window not in WINDOW_DAYS:
            raise ValueError("unsupported operator window")
        now = self.monotonic()
        with self._lock:
            entry = self._entries.get(window)
            age = max(0, int(now - entry.loaded_at)) if entry is not None else None
            fresh = entry is not None and age is not None and age < self.ttl_seconds
            if fresh:
                return CacheResult(entry.data, "fresh", age, None)
            failed = window in self._errors
            retry_due = not failed or now - self._last_attempt.get(window, now) >= self.ttl_seconds
            if self._in_flight is None and retry_due:
                self._in_flight = window
                self._last_attempt[window] = now
                worker = threading.Thread(
                    target=self._refresh,
                    args=(window,),
                    name=f"shipyard-operator-{window}",
                    daemon=True,
                )
                worker.start()
            if entry is not None:
                return CacheResult(
                    entry.data,
                    "stale",
                    age,
                    "inspection_refresh_failed" if failed else "inspection_refreshing",
                )
            return CacheResult(
                None,
                "unavailable",
                None,
                "inspection_refresh_failed" if failed else "inspection_refreshing",
            )

    def _refresh(self, window: str) -> None:
        try:
            loaded = self.loader(window)
            if not isinstance(loaded, dict):
                raise OperatorDataError("inspection loader returned a non-object")
        except Exception:  # The public cache result intentionally redacts source errors.
            with self._lock:
                self._errors.add(window)
                if self._in_flight == window:
                    self._in_flight = None
            return
        loaded_at = self.monotonic()
        with self._lock:
            self._entries[window] = _CacheEntry(loaded, loaded_at)
            self._errors.discard(window)
            if self._in_flight == window:
                self._in_flight = None


def _object(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _array(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def _safe_id(value: Any) -> Optional[str]:
    return value if isinstance(value, str) and _ID_RE.fullmatch(value) else None


def _safe_code(value: Any) -> Optional[str]:
    return value if isinstance(value, str) and _CODE_RE.fullmatch(value) else None


def _safe_timestamp(value: Any) -> Optional[str]:
    if not isinstance(value, str) or len(value) > 40:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        return None
    return parsed.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _safe_number(value: Any) -> Optional[int | float]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if value != value or value in {float("inf"), float("-inf")}:
        return None
    return value


def _safe_limitations(values: Any) -> list[str]:
    limitations: list[str] = []
    redacted = False
    for value in _array(values):
        candidate = value.get("code") if isinstance(value, dict) else value
        code = _safe_code(candidate)
        if code is not None:
            limitations.append(code)
        elif candidate is not None:
            redacted = True
    if redacted:
        limitations.append("redacted_source_detail")
    return sorted(set(limitations))[:50]


def _safe_ids(values: Any, *, limit: int = 50) -> list[str]:
    result = []
    for value in _array(values):
        safe = _safe_id(value)
        if safe is not None and safe not in result:
            result.append(safe)
        if len(result) >= limit:
            break
    return result


def _is_delivery_lineage_event(event: dict[str, Any]) -> bool:
    event_name = _safe_code(event.get("event"))
    if event_name is None or not any(
        event_name == family or event_name.startswith(family + ".")
        for family in DELIVERY_EVENT_FAMILIES
    ):
        return False
    return any(
        _safe_id(event.get(field)) is not None
        for field in DELIVERY_IDENTIFIER_FIELDS
    )


def _controlled_explanation(
    state: str,
    limitations: list[str],
    *,
    terminal_status: Optional[str] = None,
    terminal_reason: Optional[str] = None,
) -> dict[str, str]:
    """Return bounded public copy without forwarding source prose or codes."""
    if state == "verified":
        return {
            "reason_code": "target_met",
            "reason": "The observed evidence meets the configured target.",
            "impact": "No promise gap is evidenced in this window.",
            "action": "Keep monitoring the next evidence window.",
        }
    if state == "violated":
        return {
            "reason_code": "target_missed",
            "reason": "The observed evidence does not meet the configured target.",
            "impact": "The promised outcome is below its target in this window.",
            "action": "Review the linked evidence and restore the target.",
        }
    if state == "not_applicable":
        return {
            "reason_code": "not_applicable",
            "reason": "This measurement does not apply to the current population.",
            "impact": "It is excluded from the verified total rather than counted as success or failure.",
            "action": "No action is required unless the population changes.",
        }
    if terminal_status == "fail" or state == "failed":
        return {
            "reason_code": "runtime_failed",
            "reason": "The latest recorded run ended in failure.",
            "impact": "This role did not complete its scheduled work.",
            "action": "Review the linked runtime evidence and repair the failing run.",
        }
    if terminal_status == "abort":
        return {
            "reason_code": "recorded_early_stop",
            "reason": "The scheduled run stopped before producing a result.",
            "impact": "This recorded early stop is not an outage; no completed result was produced.",
            "action": "Review the run preconditions before the next scheduled attempt.",
        }
    if state == "healthy":
        return {
            "reason_code": "runtime_healthy",
            "reason": "The latest recorded run completed successfully.",
            "impact": "No runtime failure is evidenced for this role in the selected window.",
            "action": "Keep monitoring the next scheduled run.",
        }
    if state == "running":
        return {
            "reason_code": "runtime_in_progress",
            "reason": "A run started and has not recorded a terminal result yet.",
            "impact": "The outcome is pending rather than successful or failed.",
            "action": "Wait for the terminal event or investigate if the run becomes stale.",
        }
    if state == "stale":
        return {
            "reason_code": "runtime_stale",
            "reason": "A run started but no timely terminal result was recorded.",
            "impact": "The role may be stuck or its terminal telemetry may be missing.",
            "action": "Inspect the latest run and its event coverage.",
        }
    if any(code == "unsupported_in_v1" or code.startswith("unsupported_") for code in limitations):
        return {
            "reason_code": "unsupported_in_v1",
            "reason": "This measurement is not supported by the current evidence contract.",
            "impact": "No success or failure conclusion can be drawn from this source.",
            "action": "Add supported evidence before evaluating this promise.",
        }
    if "event_window_truncated" in limitations:
        return {
            "reason_code": "event_window_truncated",
            "reason": "The selected event window exceeded the bounded outcome page.",
            "impact": "The visible evidence may not contain the complete denominator.",
            "action": "Use project runtime evidence or a narrower window before drawing a conclusion.",
        }
    if "inspection_unavailable" in limitations:
        return {
            "reason_code": "inspection_unavailable",
            "reason": "The fleet inspection snapshot is unavailable.",
            "impact": "This state cannot be verified from the current inspection.",
            "action": "Restore inspection coverage and reassess the promise.",
        }
    if any("missing" in code or "partial" in code or "gap" in code for code in limitations):
        return {
            "reason_code": "evidence_incomplete",
            "reason": "Required evidence is missing or incomplete for this measurement.",
            "impact": "The state remains unknown rather than being counted as success.",
            "action": "Close the named evidence coverage gap and reassess.",
        }
    return {
        "reason_code": "evidence_unknown",
        "reason": "Available evidence does not establish a verified state.",
        "impact": "No success or failure conclusion is justified.",
        "action": "Review evidence coverage before acting on this state.",
    }


def _event_evidence_id(event: dict[str, Any]) -> str:
    safe = {
        key: event.get(key)
        for key in (
            "ts",
            "event",
            "role",
            "status",
            "outcome",
            "disposition",
            "run_id",
            "work_id",
            "upstream_work_id",
            "proposal_id",
            "incident_id",
            "critique_id",
            "project_id",
            "project",
            "svc",
        )
        if isinstance(event.get(key), (str, int, float))
    }
    digest = hashlib.sha256(
        json.dumps(safe, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()[:20]
    return f"event:{digest}"


def _safe_event_evidence(event: dict[str, Any]) -> dict[str, Any]:
    fields: dict[str, Any] = {}
    for key in (
        "event",
        "role",
        "status",
        "outcome",
        "disposition",
        "run_id",
        "work_id",
        "upstream_work_id",
        "proposal_id",
        "incident_id",
        "critique_id",
    ):
        value = event.get(key)
        safe = _safe_id(value)
        if safe is not None:
            fields[key] = safe
    for key in _TOKEN_FIELDS + ("duration_s",):
        value = _safe_number(event.get(key))
        if value is not None and value >= 0:
            fields[key] = value
    return {
        "id": _event_evidence_id(event),
        "source": "events",
        "kind": "event",
        "observed_at": _safe_timestamp(event.get("ts")),
        "fields": fields,
        "limitations": [],
    }


def load_presentation_topology(path: Path) -> dict[str, Any]:
    """Load only the generated presentation's declared graph contract."""
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise OperatorDataError("presentation topology is unavailable") from exc
    graph = _object(_object(document).get("graph"))
    roles = _array(graph.get("roles"))
    skills = _array(graph.get("skills"))
    edges = _array(graph.get("edges"))
    if not roles or not skills:
        raise OperatorDataError("presentation topology is incomplete")

    safe_roles = []
    role_ids: set[str] = set()
    for raw in roles:
        row = _object(raw)
        role_id = _safe_code(row.get("id"))
        name = row.get("name")
        loop = _safe_code(row.get("loop"))
        if role_id is None or not isinstance(name, str) or not name or len(name) > 80 or loop is None:
            raise OperatorDataError("presentation role is malformed")
        if role_id in role_ids:
            raise OperatorDataError("presentation role IDs are not unique")
        role_ids.add(role_id)
        safe_roles.append({"id": role_id, "name": name, "loop": loop})

    safe_skills = []
    skill_ids: set[str] = set()
    for raw in skills:
        row = _object(raw)
        skill_id = _safe_code(row.get("id"))
        label = row.get("label")
        kind = _safe_code(row.get("kind"))
        memberships = row.get("roles")
        if (
            skill_id is None
            or not isinstance(label, str)
            or not label
            or len(label) > 80
            or kind is None
            or not isinstance(memberships, list)
            or any(role not in role_ids for role in memberships)
        ):
            raise OperatorDataError("presentation skill is malformed")
        if skill_id in skill_ids:
            raise OperatorDataError("presentation skill IDs are not unique")
        skill_ids.add(skill_id)
        safe_skills.append(
            {"id": skill_id, "label": label, "kind": kind, "roles": list(memberships)}
        )

    safe_edges = []
    for raw in edges:
        row = _object(raw)
        source = _safe_code(row.get("from"))
        target = _safe_code(row.get("to"))
        if source not in skill_ids or target not in skill_ids:
            raise OperatorDataError("presentation pipeline edge is malformed")
        safe_edges.append({"from": source, "to": target})
    return {"roles": safe_roles, "skills": safe_skills, "edges": safe_edges}


def _promise_rows(inspection: Optional[dict[str, Any]]) -> list[dict[str, Any]]:
    measured = {
        key: item
        for raw in _array(_object(inspection).get("effectiveness"))
        if (item := _object(raw))
        and (key := _safe_code(item.get("key"))) is not None
    }
    rows = []
    for key, label in PROMISE_DEFINITIONS:
        item = measured.get(key)
        if item is None:
            limitations = ["inspection_unavailable" if inspection is None else "promise_evidence_missing"]
            rows.append(
                {
                    "id": f"promise:{key}",
                    "label": label,
                    "state": "unverified",
                    "target": {"operator": None, "value": None, "unit": None},
                    "observed_value": None,
                    "evidence_ids": [],
                    "limitations": limitations,
                    **_controlled_explanation("unverified", limitations),
                }
            )
            continue
        source_state = _safe_code(item.get("state")) or "unmeasured"
        observed = _safe_number(item.get("value"))
        target_value = _safe_number(item.get("target_value"))
        operator = item.get("target_operator") if item.get("target_operator") in {"gte", "lte", "eq"} else None
        if source_state == "not_applicable":
            state = "not_applicable"
        elif source_state != "measured" or observed is None or target_value is None or operator is None:
            state = "unverified"
        else:
            met = {
                "gte": observed >= target_value,
                "lte": observed <= target_value,
                "eq": observed == target_value,
            }[operator]
            state = "verified" if met else "violated"
        unit = _safe_code(item.get("unit"))
        limitations = _safe_limitations(item.get("limitations"))
        rows.append(
            {
                "id": f"promise:{key}",
                "label": label,
                "state": state,
                "target": {"operator": operator, "value": target_value, "unit": unit},
                "observed_value": observed,
                "evidence_ids": _safe_ids(item.get("evidence_ids")),
                "limitations": limitations,
                **_controlled_explanation(state, limitations),
            }
        )
    return sorted(rows, key=lambda row: (_STATE_RANK[row["state"]], row["id"]))


def _priority_operands(rule_id: Optional[str], value: Any) -> dict[str, int | float]:
    allowed = _PRIORITY_NUMERIC_OPERANDS.get(rule_id or "", ())
    source = _object(value)
    result: dict[str, int | float] = {}
    for key in allowed:
        number = _safe_number(source.get(key))
        if number is not None and number >= 0:
            result[key] = number
    return result


def _priority_action(
    rule_id: Optional[str],
    label: str,
    operands: dict[str, int | float],
    *,
    evidence_count: int,
) -> str:
    if rule_id == "core_job_failure_v1" and isinstance(operands.get("failure_records"), int):
        count = operands["failure_records"]
        noun = "failure" if count == 1 else "failures"
        return f"Repair {count} observed Shipyard job {noun}"
    if rule_id == "core_doctor_drift_v1" and isinstance(operands.get("failure_records"), int):
        return f"Repair {operands['failure_records']} observed Shipyard install drift records"
    if rule_id == "core_restart_failure_v1" and isinstance(operands.get("failure_records"), int):
        return f"Repair {operands['failure_records']} failed Shipyard restart records"
    if rule_id == "core_critic_failure_v1" and isinstance(operands.get("failure_records"), int):
        return f"Repair {operands['failure_records']} Shipyard critic failure records"
    if evidence_count:
        noun = "record" if evidence_count == 1 else "records"
        return f"Review {evidence_count} {noun} for {label.lower()}"
    return label


def _attention_rows(inspection: Optional[dict[str, Any]]) -> tuple[list[dict[str, Any]], bool]:
    if inspection is None:
        return [], False
    rows: list[dict[str, Any]] = []
    for raw in _array(inspection.get("priorities")):
        item = _object(raw)
        item_id = _safe_id(item.get("id"))
        rank = _safe_number(item.get("rank"))
        category = _safe_code(item.get("category"))
        if item_id is None or not isinstance(rank, int) or category is None:
            continue
        rule_id = _safe_code(item.get("rule_id"))
        safe_title = _PRIORITY_LABELS.get(rule_id or "", category.replace("_", " ").title())
        evidence_ids = _safe_ids(item.get("evidence_ids"))
        evidence_count = _safe_number(item.get("evidence_count"))
        if not isinstance(evidence_count, int) or evidence_count < len(evidence_ids):
            evidence_count = len(evidence_ids)
        operands = _priority_operands(rule_id, item.get("operands"))
        project_ids = _safe_ids(item.get("project_ids"), limit=50)
        state = "alarm" if category in {"confirmed_failure", "recurring_failure"} else "waiting"
        rows.append(
            {
                "id": item_id,
                "kind": "next_pr",
                "label": safe_title,
                "action": _priority_action(
                    rule_id, safe_title, operands, evidence_count=evidence_count
                ),
                "rule_id": rule_id,
                "scope": _safe_code(item.get("scope")) or "fleet",
                "project_ids": project_ids,
                "operands": operands,
                "priority": rank,
                "state": state,
                "detected_at": _safe_timestamp(item.get("newest_ts")),
                "evidence_count": evidence_count,
                "evidence_ids": evidence_ids,
                "limitations": _safe_limitations(item.get("limitations")),
            }
        )
    priority_offset = len(rows) + 1
    for index, raw in enumerate(_array(inspection.get("attention"))):
        item = _object(raw)
        item_id = _safe_id(item.get("id"))
        kind = _safe_code(item.get("kind"))
        if item_id is None or kind is None:
            continue
        severity = item.get("severity_advisory")
        state = "alarm" if severity in {"high", "critical"} else "waiting"
        label = kind.replace("_", " ").title()
        evidence_ids = _safe_ids(item.get("evidence_ids"))
        project_id = _safe_id(item.get("project_id"))
        rows.append(
            {
                "id": item_id,
                "kind": kind,
                "label": label,
                "action": _priority_action(
                    None, label, {}, evidence_count=len(evidence_ids)
                ),
                "rule_id": f"attention_{kind}",
                "scope": "project" if project_id is not None else "fleet",
                "project_ids": [project_id] if project_id is not None else [],
                "operands": {},
                "priority": priority_offset + index,
                "state": state,
                "detected_at": _safe_timestamp(item.get("detected_at")),
                "evidence_count": len(evidence_ids),
                "evidence_ids": evidence_ids,
                "limitations": _safe_limitations(item.get("limitations")),
            }
        )
    rows.sort(key=lambda row: (row["priority"], row["id"]))
    return rows[:MAX_ATTENTION], len(rows) > MAX_ATTENTION


def _inspection_evidence(inspection: Optional[dict[str, Any]]) -> list[dict[str, Any]]:
    if inspection is None:
        return []
    rows = []
    for raw in _array(inspection.get("evidence")):
        item = _object(raw)
        item_id = _safe_id(item.get("id"))
        source = _safe_code(item.get("source"))
        kind = _safe_code(item.get("kind"))
        if item_id is None or source is None or kind is None:
            continue
        row = {
            "id": item_id,
            "source": source,
            "kind": kind,
            "observed_at": _safe_timestamp(item.get("observed_at")),
            "limitations": _safe_limitations(item.get("limitations")),
        }
        project_id = _safe_id(item.get("project_id"))
        if project_id is not None:
            row["project_id"] = project_id
        rows.append(row)
    return rows


def _evidence_references(value: Any) -> list[str]:
    references: list[str] = []

    def visit(item: Any) -> None:
        if isinstance(item, dict):
            for key, child in item.items():
                if key == "evidence_ids" and isinstance(child, list):
                    for candidate in child:
                        if isinstance(candidate, str) and candidate not in references:
                            references.append(candidate)
                else:
                    visit(child)
        elif isinstance(item, list):
            for child in item:
                visit(child)

    visit(value)
    return references


def _bound_evidence(
    evidence: list[dict[str, Any]], consumers: list[Any]
) -> tuple[list[dict[str, Any]], set[str], set[str], bool]:
    by_id = {row["id"]: row for row in evidence}
    ordered_ids = []
    for consumer in consumers:
        for evidence_id in _evidence_references(consumer):
            if evidence_id in by_id and evidence_id not in ordered_ids:
                ordered_ids.append(evidence_id)
    for row in evidence:
        if row["id"] not in ordered_ids:
            ordered_ids.append(row["id"])
    selected_ids = set(ordered_ids[:MAX_EVIDENCE])
    missing_ids = {
        evidence_id
        for consumer in consumers
        for evidence_id in _evidence_references(consumer)
        if evidence_id not in by_id
    }
    rows = [by_id[evidence_id] for evidence_id in ordered_ids[:MAX_EVIDENCE]]
    return rows, selected_ids, missing_ids, len(ordered_ids) > MAX_EVIDENCE


def _constrain_evidence_links(
    value: Any,
    selected_ids: set[str],
    missing_ids: set[str],
) -> None:
    if isinstance(value, dict):
        for key, child in list(value.items()):
            if key != "evidence_ids":
                _constrain_evidence_links(child, selected_ids, missing_ids)
                continue
            if not isinstance(child, list):
                value[key] = []
                value.setdefault("limitations", []).append("evidence_unavailable")
                continue
            retained = [item for item in child if item in selected_ids]
            absent = any(item in missing_ids for item in child)
            truncated = any(item not in selected_ids and item not in missing_ids for item in child)
            value[key] = retained
            limitations = value.setdefault("limitations", [])
            if absent and "evidence_unavailable" not in limitations:
                limitations.append("evidence_unavailable")
            if truncated and "evidence_truncated" not in limitations:
                limitations.append("evidence_truncated")
        return
    if isinstance(value, list):
        for child in value:
            _constrain_evidence_links(child, selected_ids, missing_ids)


def _relationship_sources(relationships: Optional[dict[str, Any]]) -> list[dict[str, Any]]:
    if relationships is None:
        return []
    sources = _object(relationships.get("sources"))
    rows = []
    for provider in ("claude", "codex", "hermes"):
        source = _object(sources.get(provider))
        state = source.get("state") if source.get("state") in {"available", "partial", "unknown"} else "unknown"
        coverage = _object(source.get("coverage"))
        row: dict[str, Any] = {
            "provider": provider,
            "state": state,
            "coverage_state": coverage.get("state") if coverage.get("state") in {"complete", "partial", "unknown"} else "unknown",
            "limitations": _safe_limitations(source.get("limitations")),
        }
        for key in ("files_scanned", "malformed_records"):
            number = _safe_number(coverage.get(key))
            if isinstance(number, int) and number >= 0:
                row[key] = number
        rows.append(row)
    return rows


def _fleet_projects(inspection: Optional[dict[str, Any]]) -> list[dict[str, Any]]:
    projects: list[dict[str, Any]] = []
    for raw in _array(_object(inspection).get("fleet")):
        item = _object(raw)
        project_id = _safe_id(item.get("project_id"))
        project_label = _safe_id(item.get("project_name"))
        if project_id is None or project_label is None:
            continue
        roles = []
        for value in _array(item.get("roles")):
            role = _safe_code(value)
            if role is not None and role not in roles:
                roles.append(role)
        projects.append(
            {
                "project_id": project_id,
                "project_label": project_label,
                "project_state": _safe_code(item.get("state")) or "unknown",
                "roles": roles,
            }
        )
        if len(projects) >= MAX_SCOPE_PROJECTS:
            break
    return projects


def _safe_coverage_counts(item: dict[str, Any]) -> dict[str, Optional[int]]:
    result: dict[str, Optional[int]] = {}
    for key in (
        "records_total",
        "records_valid",
        "records_invalid",
        "records_out_of_window",
        "records_unattributed",
        "records_ambiguous",
    ):
        value = _safe_number(item.get(key))
        result[key] = value if isinstance(value, int) and value >= 0 else None
    return result


def _scope_document(inspection: Optional[dict[str, Any]]) -> dict[str, Any]:
    projects = _fleet_projects(inspection)
    coverage = [_object(row) for row in _array(_object(inspection).get("coverage"))]
    rows = []
    for project in projects:
        project_id = project["project_id"]
        source_rows = [row for row in coverage if _safe_id(row.get("project_id")) == project_id]
        event_row = next(
            (row for row in source_rows if _safe_code(row.get("source")) == "events"),
            {},
        )
        inspection_rows = [row for row in source_rows if _safe_code(row.get("source")) != "events"]
        available_sources = sum(
            1 for row in inspection_rows if _safe_code(row.get("state")) in {"available", "not_applicable"}
        )
        rows.append(
            {
                "project_id": project_id,
                "project_label": project["project_label"],
                "inspection": {
                    "state": "available" if inspection is not None else "unknown",
                    "project_state": project["project_state"],
                    "sources_available": available_sources,
                    "sources_total": len(inspection_rows),
                },
                "events": {
                    "state": _safe_code(event_row.get("state")) or "unknown",
                    "reason": _safe_code(event_row.get("reason")) or "unknown",
                    **_safe_coverage_counts(event_row),
                },
            }
        )
    unattributed_row = next(
        (
            row
            for row in coverage
            if row.get("project_id") is None
            and _safe_code(row.get("source")) == "events_attribution"
        ),
        {},
    )
    unattributed_counts = _safe_coverage_counts(unattributed_row)
    return {
        "kind": "current_user_fleet",
        "label": "Current-user Shipyard fleet",
        "projects": rows,
        "unattributed": {
            "state": _safe_code(unattributed_row.get("state")) or "unknown",
            "records_unattributed": unattributed_counts["records_unattributed"],
            "records_ambiguous": unattributed_counts["records_ambiguous"],
        },
        "limitations": ["scope_projects_truncated"] if len(_array(_object(inspection).get("fleet"))) > len(projects) else [],
    }


def _project_runtime_nodes(
    declared: dict[str, Any],
    summary: dict[str, Any],
    runtime_events: list[dict[str, Any]],
    inspection: Optional[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    projects = _fleet_projects(inspection)
    project_by_id = {item["project_id"]: item for item in projects}
    projects_by_label: dict[str, list[dict[str, Any]]] = {}
    for project in projects:
        projects_by_label.setdefault(project["project_label"], []).append(project)

    def resolve_project(item: dict[str, Any]) -> Optional[dict[str, Any]]:
        explicit = project_by_id.get(_safe_id(item.get("project_id")) or "")
        if explicit is not None:
            return explicit
        matches = projects_by_label.get(_safe_id(item.get("project")) or "", [])
        return matches[0] if len(matches) == 1 else None

    role_labels = {item["id"]: item["name"] for item in declared["roles"] if item["id"] != "human"}
    services: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for raw in _array(summary.get("services")):
        item = _object(raw)
        project = resolve_project(item)
        role = _safe_code(item.get("role"))
        if project is not None and role in role_labels:
            services.setdefault((project["project_id"], role), []).append(item)

    events: dict[tuple[str, str, str], list[dict[str, Any]]] = {}
    for raw in runtime_events:
        item = _object(raw)
        if _safe_code(item.get("event")) not in {"job.start", "job.end"}:
            continue
        project = resolve_project(item)
        role = _safe_code(item.get("role"))
        service = _safe_id(item.get("svc"))
        if project is None or role not in role_labels or service is None:
            continue
        bucket = events.setdefault((project["project_id"], role, service), [])
        if len(bucket) < MAX_RUNTIME_EVENTS_PER_NODE:
            bucket.append(item)

    nodes: list[dict[str, Any]] = []
    evidence: list[dict[str, Any]] = []
    for project in projects:
        observed_roles = {
            role
            for key in (*services.keys(), *events.keys())
            if key[0] == project["project_id"]
            for role in [key[1]]
        }
        roles = [role for role in role_labels if role in set(project["roles"]) | observed_roles]
        for role in roles:
            key = (project["project_id"], role)
            role_services = services.get(key, [])
            service_events = {
                service: rows
                for (project_id, event_role, service), rows in events.items()
                if project_id == project["project_id"] and event_role == role
            }
            known_services = [
                item for item in role_services if item.get("state") in _ROLE_STATE_RANK
            ]
            controlling_service: dict[str, Any] = {}
            if known_services:
                worst_rank = min(_ROLE_STATE_RANK[item["state"]] for item in known_services)
                controlling_service = max(
                    (
                        item
                        for item in known_services
                        if _ROLE_STATE_RANK[item["state"]] == worst_rank
                    ),
                    key=lambda item: (
                        _safe_timestamp(item.get("last_activity")) or "",
                        _safe_id(item.get("svc")) or "",
                    ),
                )
            state = controlling_service.get("state", "unknown")
            controlling_svc = _safe_id(controlling_service.get("svc"))
            if controlling_svc is None and len(service_events) == 1:
                controlling_svc = next(iter(service_events))
            role_events = service_events.get(controlling_svc, []) if controlling_svc else []
            terminal_events = [
                item
                for item in role_events
                if _safe_code(item.get("event")) == "job.end"
            ]
            terminal = max(
                terminal_events,
                key=lambda item: _safe_timestamp(item.get("ts")) or "",
                default={},
            )
            terminal_status = _safe_code(controlling_service.get("terminal_status"))
            if terminal_status not in _RUNTIME_TERMINAL_STATUSES:
                terminal_status = _safe_code(terminal.get("status"))
            terminal_reason = _safe_code(controlling_service.get("terminal_reason"))
            if terminal_reason not in _RUNTIME_TERMINAL_REASONS:
                terminal_reason = _safe_code(terminal.get("reason"))
            if state == "failed":
                terminal_status = "fail"
                if _safe_code(controlling_service.get("terminal_status")) != "fail":
                    terminal_reason = None
            elif state == "healthy":
                if terminal_status in {"fail", "abort", "partial", "skipped"}:
                    state = "failed" if terminal_status == "fail" else "unknown"
                else:
                    terminal_status = "ok"
                    terminal_reason = None
            elif state in {"running", "stale"}:
                terminal_status = None
                terminal_reason = None
            elif terminal_status not in _RUNTIME_TERMINAL_STATUSES:
                terminal_status = None
            if terminal_reason not in _RUNTIME_TERMINAL_REASONS:
                terminal_reason = None
            if not known_services and terminal_status == "ok":
                state = "healthy"
            elif not known_services and terminal_status == "fail":
                state = "failed"
            event_ids = [_event_evidence_id(item) for item in role_events]
            timestamps = [
                value
                for item in role_events
                if (value := _safe_timestamp(item.get("ts"))) is not None
            ]
            controlling_activity = _safe_timestamp(
                controlling_service.get("last_activity")
            )
            if not timestamps and controlling_activity is not None:
                timestamps.append(controlling_activity)
            limitations = [] if role_events else ["runtime_lifecycle_unobserved"]
            if len(service_events) > 1 or len(
                {
                    service
                    for item in known_services
                    if (service := _safe_id(item.get("svc"))) is not None
                }
            ) > 1:
                limitations.append("runtime_sibling_services_omitted")
            if any(item.get("runtime_identity_truncated") is True for item in role_events):
                limitations.append("runtime_identity_truncated")
            explanation = _controlled_explanation(
                state,
                limitations,
                terminal_status=terminal_status,
                terminal_reason=terminal_reason,
            )
            nodes.append(
                {
                    "id": f"runtime:{project['project_id']}:{role}",
                    "kind": "role_runtime",
                    "project_id": project["project_id"],
                    "project_label": project["project_label"],
                    "role_id": role,
                    "label": role_labels[role],
                    "scope": {
                        "kind": "project",
                        "project_id": project["project_id"],
                        "project_label": project["project_label"],
                    },
                    "state": state,
                    "observed_count": len(role_events),
                    "last_activity": max(timestamps, default=None),
                    "terminal_status": terminal_status,
                    "terminal_reason": terminal_reason,
                    "evidence_count": len(event_ids),
                    "evidence_ids": event_ids,
                    "limitations": limitations,
                    **explanation,
                }
            )
            for item in role_events:
                evidence_row = _safe_event_evidence(item)
                evidence_row["project_id"] = project["project_id"]
                evidence.append(evidence_row)
    return nodes, evidence


def _topology_document(
    declared: dict[str, Any],
    summary: dict[str, Any],
    events: list[dict[str, Any]],
    runtime_events: list[dict[str, Any]],
    inspection: Optional[dict[str, Any]],
    relationships: Optional[dict[str, Any]],
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    evidence: list[dict[str, Any]] = []
    runtime_nodes, runtime_evidence = _project_runtime_nodes(
        declared, summary, runtime_events, inspection
    )
    evidence.extend(runtime_evidence)
    runtime_by_role: dict[str, list[dict[str, Any]]] = {}
    for node in runtime_nodes:
        runtime_by_role.setdefault(node["role_id"], []).append(node)

    nodes: list[dict[str, Any]] = []
    for role in declared["roles"]:
        role_id = role["id"]
        if role_id == "human":
            nodes.append(
                {
                    "id": "role:human",
                    "kind": "human",
                    "label": role["name"],
                    "loop": role["loop"],
                    "state": "declared",
                    "observed_count": None,
                    "last_activity": None,
                    "evidence_ids": [],
                    "limitations": ["human_activity_not_inferred"],
                }
            )
            continue
        constituents = runtime_by_role.get(role_id, [])
        states = [item.get("state") for item in constituents if item.get("state") in _ROLE_STATE_RANK]
        state = min(states, key=lambda value: _ROLE_STATE_RANK[value]) if states else "unknown"
        ids = [evidence_id for item in constituents for evidence_id in item["evidence_ids"]][:10]
        activity = [
            item["last_activity"]
            for item in constituents
            if item.get("last_activity") is not None
        ]
        observed_count = sum(item["observed_count"] for item in constituents)
        limitations = [] if observed_count else ["role_runtime_unobserved"]
        explanation = _controlled_explanation(state, limitations)
        nodes.append(
            {
                "id": f"role:{role_id}",
                "kind": "role",
                "label": role["name"],
                "loop": role["loop"],
                "scope": {"kind": "current_user_fleet", "project_id": None, "project_label": None},
                "state": state,
                "observed_count": observed_count,
                "last_activity": max(activity, default=None),
                "reduction_rule": "worst_known_state_unknown_if_none",
                "constituent_projects": [item["project_id"] for item in constituents],
                "evidence_ids": ids,
                "limitations": limitations,
                **explanation,
            }
        )

    skill_counts: dict[str, int] = {}
    skill_last: dict[str, str] = {}
    skill_evidence: dict[str, list[str]] = {}
    observed_edges: list[dict[str, Any]] = []
    actor_nodes: dict[str, dict[str, Any]] = {}
    sources = _object(_object(relationships).get("sources")) if relationships else {}
    declared_skill_ids = {skill["id"] for skill in declared["skills"]}
    observed_only_skills: set[str] = set()
    for provider in ("claude", "codex", "hermes"):
        source = _object(sources.get(provider))
        for raw in _array(source.get("caller_callee")):
            item = _object(raw)
            caller = _safe_id(item.get("caller_id"))
            callee = _safe_id(item.get("callee_id"))
            count = _safe_number(item.get("count"))
            if caller is None or callee is None or not isinstance(count, int) or count < 1:
                continue
            caller_node = f"agent:{provider}:{caller}"
            callee_node = f"agent:{provider}:{callee}"
            actor_nodes.setdefault(caller_node, {"id": caller_node, "kind": "agent", "label": f"{provider.title()} caller", "provider": provider, "state": "observed", "evidence_ids": []})
            actor_nodes.setdefault(callee_node, {"id": callee_node, "kind": "agent", "label": f"{provider.title()} callee", "provider": provider, "state": "observed", "evidence_ids": []})
            evidence_id = "relationship:" + hashlib.sha256(
                f"{provider}\0{caller}\0{callee}\0{item.get('bucket')}\0{item.get('completion')}\0{item.get('first_timestamp')}\0{item.get('last_timestamp')}".encode()
            ).hexdigest()[:20]
            relationship_evidence = {
                "id": evidence_id,
                "source": "relationships",
                "kind": "caller_callee",
                "observed_at": _safe_timestamp(item.get("last_timestamp")),
                "fields": {"provider": provider, "count": count},
                "limitations": [],
            }
            evidence.append(relationship_evidence)
            actor_nodes[caller_node]["evidence_ids"].append(evidence_id)
            actor_nodes[callee_node]["evidence_ids"].append(evidence_id)
            edge = {
                "id": f"observed:{evidence_id}",
                "kind": "call",
                "from": caller_node,
                "to": callee_node,
                "state": "observed",
                "count": count,
                "last_activity": _safe_timestamp(item.get("last_timestamp")),
                "evidence_ids": [evidence_id],
            }
            completion = _safe_code(item.get("completion"))
            if completion is not None:
                edge["completion"] = completion
            observed_edges.append(edge)
        for raw in _array(source.get("skill_invocations")):
            item = _object(raw)
            actor = _safe_id(item.get("actor_id"))
            skill = _safe_code(item.get("skill_id"))
            count = _safe_number(item.get("count"))
            if actor is None or skill is None or not isinstance(count, int) or count < 1:
                continue
            actor_node = f"agent:{provider}:{actor}"
            actor_nodes.setdefault(actor_node, {"id": actor_node, "kind": "agent", "label": f"{provider.title()} caller", "provider": provider, "state": "observed", "evidence_ids": []})
            evidence_id = "skill-call:" + hashlib.sha256(
                f"{provider}\0{actor}\0{skill}\0{item.get('bucket')}\0{item.get('completion')}\0{item.get('first_timestamp')}\0{item.get('last_timestamp')}".encode()
            ).hexdigest()[:20]
            evidence.append(
                {
                    "id": evidence_id,
                    "source": "relationships",
                    "kind": "skill_invocation",
                    "observed_at": _safe_timestamp(item.get("last_timestamp")),
                    "fields": {"provider": provider, "skill_id": skill, "count": count},
                    "limitations": [],
                }
            )
            actor_nodes[actor_node]["evidence_ids"].append(evidence_id)
            skill_counts[skill] = skill_counts.get(skill, 0) + count
            if skill not in declared_skill_ids:
                observed_only_skills.add(skill)
            timestamp = _safe_timestamp(item.get("last_timestamp"))
            if timestamp and timestamp > skill_last.get(skill, ""):
                skill_last[skill] = timestamp
            skill_evidence.setdefault(skill, []).append(evidence_id)
            observed_edges.append(
                {
                    "id": f"observed:{evidence_id}",
                    "kind": "skill_call",
                    "from": actor_node,
                    "to": f"skill:{skill}",
                    "state": "observed",
                    "count": count,
                    "last_activity": timestamp,
                    "evidence_ids": [evidence_id],
                }
            )

    for skill in declared["skills"]:
        skill_id = skill["id"]
        observed_count = skill_counts.get(skill_id, 0)
        nodes.append(
            {
                "id": f"skill:{skill_id}",
                "kind": "skill",
                "label": skill["label"],
                "skill_kind": skill["kind"],
                "state": "observed" if observed_count else "unknown",
                "observed_count": observed_count if observed_count else None,
                "last_activity": skill_last.get(skill_id),
                "evidence_ids": skill_evidence.get(skill_id, [])[:20],
                "limitations": [] if observed_count else ["skill_invocation_unobserved"],
            }
        )
    for skill_id in sorted(observed_only_skills):
        nodes.append(
            {
                "id": f"skill:{skill_id}",
                "kind": "skill",
                "label": skill_id,
                "skill_kind": "observed",
                "state": "observed",
                "observed_count": skill_counts[skill_id],
                "last_activity": skill_last.get(skill_id),
                "evidence_ids": skill_evidence.get(skill_id, [])[:20],
                "limitations": ["skill_not_in_declared_topology"],
            }
        )
    nodes.extend(actor_nodes[key] for key in sorted(actor_nodes))

    declared_edges = []
    for skill in declared["skills"]:
        for role in skill["roles"]:
            declared_edges.append(
                {
                    "id": f"membership:{role}:{skill['id']}",
                    "kind": "membership",
                    "from": f"role:{role}",
                    "to": f"skill:{skill['id']}",
                    "state": "declared",
                    "evidence_ids": [],
                }
            )
    for edge in declared["edges"]:
        declared_edges.append(
            {
                "id": f"pipeline:{edge['from']}:{edge['to']}",
                "kind": "pipeline",
                "from": f"skill:{edge['from']}",
                "to": f"skill:{edge['to']}",
                "state": "declared",
                "evidence_ids": [],
            }
        )
    return (
        {
            "nodes": nodes,
            "runtime_nodes": runtime_nodes,
            "declared_edges": declared_edges,
            "observed_edges": observed_edges[:MAX_RELATIONSHIP_EDGES],
            "limitations": ["relationship_edges_truncated"] if len(observed_edges) > MAX_RELATIONSHIP_EDGES else [],
        },
        evidence,
    )


def _validate_and_rank_graph(
    graph: dict[str, Any],
    *,
    max_nodes: int,
    max_edges: int,
) -> dict[str, Any]:
    """Validate a bounded public DAG and assign deterministic Kahn ranks."""
    if _safe_id(graph.get("id")) is None:
        raise GraphValidationError("invalid")
    if _safe_code(graph.get("kind")) not in {"architecture", "project_runtime", "delivery"}:
        raise GraphValidationError("invalid")
    label = graph.get("label")
    if not isinstance(label, str) or not label or len(label) > 80:
        raise GraphValidationError("invalid")
    if _safe_code(graph.get("state")) is None:
        raise GraphValidationError("invalid")
    scope = _object(graph.get("scope"))
    scope_kind = _safe_code(scope.get("kind"))
    if scope_kind not in {"current_user_fleet", "project", "unattributed"}:
        raise GraphValidationError("invalid")
    project_id = _safe_id(scope.get("project_id"))
    project_label = scope.get("project_label")
    if scope_kind == "current_user_fleet":
        if scope.get("project_id") is not None or scope.get("project_label") is not None:
            raise GraphValidationError("project_isolation")
    elif project_id is None or not isinstance(project_label, str) or not project_label:
        raise GraphValidationError("invalid")

    nodes = _array(graph.get("nodes"))
    edges = _array(graph.get("edges"))
    if not nodes or len(nodes) > max_nodes or len(edges) > max_edges:
        raise GraphValidationError("bound")
    node_by_id: dict[str, dict[str, Any]] = {}
    node_order: dict[str, int] = {}
    for ordinal, raw in enumerate(nodes):
        node = _object(raw)
        node_id = _safe_id(node.get("id"))
        node_label = node.get("label")
        if node_id is None:
            raise GraphValidationError("invalid")
        if node_id in node_by_id:
            raise GraphValidationError("duplicate_id")
        if _safe_code(node.get("kind")) is None or _safe_code(node.get("state")) is None:
            raise GraphValidationError("invalid")
        if not isinstance(node_label, str) or not node_label or len(node_label) > 80:
            raise GraphValidationError("invalid")
        if scope_kind != "current_user_fleet" and node.get("project_id") != project_id:
            raise GraphValidationError("project_isolation")
        evidence_count = node.get("evidence_count")
        evidence_ids = _array(node.get("evidence_ids"))
        if not isinstance(evidence_count, int) or evidence_count < 0:
            raise GraphValidationError("invalid")
        if "observed_count" in node:
            observed_count = node.get("observed_count")
            if observed_count is not None and (
                isinstance(observed_count, bool)
                or not isinstance(observed_count, int)
                or observed_count < 0
                or observed_count > MAX_RUNTIME_EVENTS_PER_NODE
            ):
                raise GraphValidationError("invalid")
        if "terminal_status" in node and node.get("terminal_status") not in {
            None,
            *_RUNTIME_TERMINAL_STATUSES,
        }:
            raise GraphValidationError("invalid")
        if "terminal_reason" in node and node.get("terminal_reason") not in {
            None,
            *_RUNTIME_TERMINAL_REASONS,
        }:
            raise GraphValidationError("invalid")
        if len(evidence_ids) > MAX_GRAPH_EVIDENCE_IDS or any(_safe_id(value) is None for value in evidence_ids):
            raise GraphValidationError("invalid")
        if len(_safe_limitations(node.get("limitations"))) != len(_array(node.get("limitations"))):
            raise GraphValidationError("invalid")
        node_by_id[node_id] = dict(node)
        node_order[node_id] = ordinal

    edge_ids: set[str] = set()
    outgoing: dict[str, list[str]] = {node_id: [] for node_id in node_by_id}
    indegree = {node_id: 0 for node_id in node_by_id}
    for raw in edges:
        edge = _object(raw)
        edge_id = _safe_id(edge.get("id"))
        source = _safe_id(edge.get("from"))
        target = _safe_id(edge.get("to"))
        if edge_id is None:
            raise GraphValidationError("invalid")
        if edge_id in edge_ids:
            raise GraphValidationError("duplicate_id")
        if source not in node_by_id or target not in node_by_id:
            raise GraphValidationError("dangling_endpoint")
        if source == target:
            raise GraphValidationError("cycle")
        if _safe_code(edge.get("kind")) is None or _safe_code(edge.get("state")) is None:
            raise GraphValidationError("invalid")
        evidence_count = edge.get("evidence_count")
        evidence_ids = _array(edge.get("evidence_ids"))
        if not isinstance(evidence_count, int) or evidence_count < 0:
            raise GraphValidationError("invalid")
        if len(evidence_ids) > MAX_GRAPH_EVIDENCE_IDS or any(_safe_id(value) is None for value in evidence_ids):
            raise GraphValidationError("invalid")
        if len(_safe_limitations(edge.get("limitations"))) != len(_array(edge.get("limitations"))):
            raise GraphValidationError("invalid")
        edge_ids.add(edge_id)
        outgoing[source].append(target)
        indegree[target] += 1

    ready = sorted((node_id for node_id, degree in indegree.items() if degree == 0), key=node_order.get)
    rank_by_node = {node_id: 0 for node_id in node_by_id}
    visited: list[str] = []
    while ready:
        source = ready.pop(0)
        visited.append(source)
        for target in outgoing[source]:
            rank_by_node[target] = max(rank_by_node[target], rank_by_node[source] + 1)
            indegree[target] -= 1
            if indegree[target] == 0:
                ready.append(target)
                ready.sort(key=node_order.get)
    if len(visited) != len(node_by_id):
        raise GraphValidationError("cycle")
    ranks = [
        [node_id for node_id in node_by_id if rank_by_node[node_id] == rank]
        for rank in range(max(rank_by_node.values(), default=0) + 1)
    ]
    ordered_ids = [node_id for rank in ranks for node_id in rank]
    return {
        **graph,
        "nodes": [node_by_id[node_id] for node_id in ordered_ids],
        "edges": [dict(_object(edge)) for edge in edges],
        "ranks": ranks,
        "limitations": _safe_limitations(graph.get("limitations")),
    }


def _graph_node(
    node_id: str,
    kind: str,
    label: str,
    state: str,
    *,
    project_id: Optional[str] = None,
    evidence_ids: Optional[list[str]] = None,
    limitations: Optional[list[str]] = None,
    reason: str,
    **fields: Any,
) -> dict[str, Any]:
    safe_evidence = [value for value in (evidence_ids or []) if _safe_id(value) is not None]
    return {
        "id": node_id,
        "kind": kind,
        "label": label,
        "state": state,
        **({"project_id": project_id} if project_id is not None else {}),
        "reason": reason,
        "evidence_count": len(safe_evidence),
        "evidence_ids": safe_evidence[:MAX_GRAPH_EVIDENCE_IDS],
        "limitations": _safe_limitations(limitations),
        **fields,
    }


def _graph_edge(
    edge_id: str,
    kind: str,
    source: str,
    target: str,
    state: str,
    *,
    evidence_ids: Optional[list[str]] = None,
    reason: str,
) -> dict[str, Any]:
    safe_evidence = [value for value in (evidence_ids or []) if _safe_id(value) is not None]
    return {
        "id": edge_id,
        "kind": kind,
        "from": source,
        "to": target,
        "state": state,
        "reason": reason,
        "evidence_count": len(safe_evidence),
        "evidence_ids": safe_evidence[:MAX_GRAPH_EVIDENCE_IDS],
        "limitations": [],
    }


def _architecture_graph(topology: dict[str, Any]) -> dict[str, Any]:
    nodes = [
        _graph_node(
            item["id"],
            item["kind"],
            item["label"],
            "declared",
            reason="Declared in the Shipyard architecture contract.",
        )
        for item in _array(topology.get("nodes"))
        if _safe_code(_object(item).get("kind")) in {"human", "role", "skill"}
        and not (
            _safe_code(_object(item).get("kind")) == "skill"
            and _safe_code(_object(item).get("skill_kind")) == "observed"
        )
    ]
    nodes.append(
        _graph_node(
            "outcome:delivered-change",
            "outcome",
            "Delivered change",
            "expected",
            reason="The build workflow is expected to produce a delivered change.",
        )
    )
    edges = [
        _graph_edge(
            item["id"],
            item["kind"],
            item["from"],
            item["to"],
            "declared",
            reason="This connection is explicitly declared by Shipyard.",
        )
        for item in _array(topology.get("declared_edges"))
    ]
    if any(node["id"] == "skill:execute-ticket" for node in nodes):
        edges.append(
            _graph_edge(
                "outcome:execute-ticket:delivered-change",
                "outcome",
                "skill:execute-ticket",
                "outcome:delivered-change",
                "declared",
                reason="Execute Ticket owns the declared delivery outcome.",
            )
        )
    return _validate_and_rank_graph(
        {
            "id": "graph:fleet-architecture",
            "kind": "architecture",
            "label": "Fleet architecture",
            "scope": {"kind": "current_user_fleet", "project_id": None, "project_label": None},
            "state": "declared",
            "nodes": nodes,
            "edges": edges,
            "limitations": [],
        },
        max_nodes=MAX_ARCHITECTURE_GRAPH_NODES,
        max_edges=MAX_ARCHITECTURE_GRAPH_EDGES,
    )


def _runtime_graphs(
    topology: dict[str, Any],
    inspection: Optional[dict[str, Any]],
    unattributed_delivery_events: Optional[list[dict[str, Any]]] = None,
) -> list[dict[str, Any]]:
    runtime_nodes = [_object(item) for item in _array(topology.get("runtime_nodes"))]
    graph_state_rank = {"failed": 0, "unknown": 1, "stale": 2, "running": 3, "healthy": 4}
    graphs: list[dict[str, Any]] = []
    for project in _fleet_projects(inspection):
        project_id = project["project_id"]
        project_label = project["project_label"]
        roles = [item for item in runtime_nodes if item.get("project_id") == project_id]
        root_id = f"runtime-project:{project_id}"
        nodes = [
            _graph_node(
                root_id,
                "project",
                project_label,
                project["project_state"],
                project_id=project_id,
                reason="This project is in the current-user Shipyard fleet.",
            )
        ]
        edges = []
        for item in roles[: MAX_PROJECT_RUNTIME_GRAPH_NODES - 1]:
            nodes.append(
                _graph_node(
                    item["id"],
                    "role",
                    item["label"],
                    item["state"],
                    project_id=project_id,
                    evidence_ids=_array(item.get("evidence_ids")),
                    limitations=_safe_limitations(item.get("limitations")),
                    reason=item.get("reason") if isinstance(item.get("reason"), str) else "Runtime evidence is unavailable.",
                    impact=item.get("impact"),
                    action=item.get("action"),
                    role=item.get("role_id"),
                    role_id=item.get("role_id"),
                    observed_count=item.get("observed_count"),
                    last_activity=item.get("last_activity"),
                    terminal_status=item.get("terminal_status"),
                    terminal_reason=item.get("terminal_reason"),
                )
            )
            edges.append(
                _graph_edge(
                    f"runtime-scope:{project_id}:{item['role_id']}",
                    "project_role",
                    root_id,
                    item["id"],
                    "scoped",
                    reason="This runtime role belongs to the named project.",
                )
            )
        graph_limitations = []
        if len(roles) > MAX_PROJECT_RUNTIME_GRAPH_NODES - 1:
            graph_limitations.append("runtime_roles_truncated")
        graphs.append(
            _validate_and_rank_graph(
                {
                    "id": f"graph:runtime:{project_id}",
                    "kind": "project_runtime",
                    "label": f"{project_label} runtime",
                    "scope": {"kind": "project", "project_id": project_id, "project_label": project_label},
                    "state": min((item["state"] for item in roles), key=lambda value: graph_state_rank.get(value, 1), default="unknown"),
                    "nodes": nodes,
                    "edges": edges,
                    "limitations": graph_limitations,
                },
                max_nodes=MAX_PROJECT_RUNTIME_GRAPH_NODES,
                max_edges=MAX_PROJECT_RUNTIME_GRAPH_EDGES,
            )
        )
    scope = _scope_document(inspection)
    unattributed = _object(scope.get("unattributed"))
    unattributed_count = sum(
        value for key in ("records_unattributed", "records_ambiguous")
        if isinstance((value := unattributed.get(key)), int) and value >= 0
    )
    unattributed_event_ids = [
        _event_evidence_id(event)
        for event in (unattributed_delivery_events or [])
    ]
    unattributed_count = max(unattributed_count, len(unattributed_event_ids))
    unattributed_id = "unattributed"
    graphs.append(
        _validate_and_rank_graph(
            {
                "id": "graph:runtime:unattributed",
                "kind": "project_runtime",
                "label": "Unattributed runtime evidence",
                "scope": {"kind": "unattributed", "project_id": unattributed_id, "project_label": "Unattributed evidence"},
                "state": "unknown",
                "nodes": [
                    _graph_node(
                        "runtime-project:unattributed",
                        "unattributed",
                        "Unattributed evidence",
                        "unknown",
                        project_id=unattributed_id,
                        reason="These records could not be assigned to exactly one fleet project.",
                    ),
                    _graph_node(
                        "runtime:unattributed:records",
                        "evidence_bucket",
                        "Unattributed records",
                        "unknown",
                        project_id=unattributed_id,
                        evidence_ids=unattributed_event_ids,
                        reason="Project ownership is unavailable for these operator records.",
                        evidence_count=unattributed_count,
                    ),
                ],
                "edges": [
                    _graph_edge(
                        "runtime-scope:unattributed:records",
                        "unattributed_evidence",
                        "runtime-project:unattributed",
                        "runtime:unattributed:records",
                        "unknown",
                        reason="The records are explicitly separated from named projects.",
                    )
                ],
                "limitations": ["project_attribution_unavailable"],
            },
            max_nodes=MAX_PROJECT_RUNTIME_GRAPH_NODES,
            max_edges=MAX_PROJECT_RUNTIME_GRAPH_EDGES,
        )
    )
    return graphs


def _delivery_graphs(
    events: list[dict[str, Any]], inspection: Optional[dict[str, Any]]
) -> tuple[list[dict[str, Any]], list[str], list[dict[str, Any]]]:
    projects = _fleet_projects(inspection)
    by_id = {item["project_id"]: item for item in projects}
    by_label: dict[str, list[dict[str, Any]]] = {}
    for project in projects:
        by_label.setdefault(project["project_label"], []).append(project)

    def direct_project_for(event: dict[str, Any]) -> Optional[tuple[str, str]]:
        explicit_id = _safe_id(event.get("project_id"))
        explicit_label = _safe_id(event.get("project"))
        if explicit_id is not None:
            installed = by_id.get(explicit_id)
            return (
                (installed["project_id"], installed["project_label"])
                if installed is not None else None
            )
        matches = by_label.get(explicit_label or "", [])
        if len(matches) == 1:
            return matches[0]["project_id"], matches[0]["project_label"]
        return None

    run_projects: dict[str, set[tuple[str, str]]] = {}
    for event in events:
        run_id = _safe_id(event.get("run_id"))
        project = direct_project_for(event)
        if run_id is not None and project is not None:
            run_projects.setdefault(run_id, set()).add(project)

    def project_for(event: dict[str, Any]) -> Optional[tuple[str, str]]:
        direct = direct_project_for(event)
        if direct is not None:
            return direct
        if event.get("project_id") not in (None, "") or event.get("project") not in (None, ""):
            return None
        run_id = _safe_id(event.get("run_id"))
        matches = run_projects.get(run_id or "", set())
        return next(iter(matches)) if len(matches) == 1 else None

    grouped: dict[tuple[str, str], list[dict[str, Any]]] = {}
    unattributed_events: list[dict[str, Any]] = []
    for event in events:
        if not _is_delivery_lineage_event(event):
            continue
        project = project_for(event)
        if project is not None:
            grouped.setdefault(project, []).append(event)
        elif any(
            _safe_id(event.get(key)) is not None
            for key in ("proposal_id", "incident_id", "work_id", "upstream_work_id")
        ):
            unattributed_events.append(event)

    graphs: list[dict[str, Any]] = []
    limitations: list[str] = []
    for (project_id, project_label), rows in grouped.items():
        raw_nodes: dict[str, dict[str, Any]] = {}
        raw_edges: list[dict[str, Any]] = []
        edge_by_key: dict[tuple[str, str], dict[str, Any]] = {}
        proposal_ids = {
            value for event in rows
            if (value := _safe_id(event.get("proposal_id"))) is not None
        }
        incident_ids = {
            value for event in rows
            if (value := _safe_id(event.get("incident_id"))) is not None
        }

        def add_node(node_id: str, kind: str, label: str, evidence_id: str) -> None:
            existing = raw_nodes.get(node_id)
            if existing is None:
                raw_nodes[node_id] = _graph_node(
                    node_id,
                    kind,
                    label,
                    "observed",
                    project_id=project_id,
                    evidence_ids=[evidence_id],
                    reason="This stage is linked by an explicit event identifier.",
                )
            else:
                if kind in {"proposal", "incident", "ticket"}:
                    existing["kind"] = kind
                    existing["label"] = label
                if evidence_id not in existing["evidence_ids"]:
                    existing["evidence_ids"].append(evidence_id)
                    existing["evidence_ids"] = existing["evidence_ids"][:MAX_GRAPH_EVIDENCE_IDS]
                    existing["evidence_count"] += 1

        def add_edge(source: str, target: str, kind: str, evidence_id: str) -> None:
            if source == target:
                return
            key = (source, target)
            existing = edge_by_key.get(key)
            if existing is not None:
                existing["evidence_count"] += 1
                if evidence_id not in existing["evidence_ids"] and len(existing["evidence_ids"]) < MAX_GRAPH_EVIDENCE_IDS:
                    existing["evidence_ids"].append(evidence_id)
                return
            digest = hashlib.sha256(f"{source}\0{target}".encode()).hexdigest()[:16]
            edge = _graph_edge(
                f"delivery-edge:{digest}",
                kind,
                source,
                target,
                "observed",
                evidence_ids=[evidence_id],
                reason="The source event explicitly links these stages.",
            )
            edge_by_key[key] = edge
            raw_edges.append(edge)

        for event in rows:
            evidence_id = _event_evidence_id(event)
            proposal_id = _safe_id(event.get("proposal_id"))
            incident_id = _safe_id(event.get("incident_id"))
            work_id = _safe_id(event.get("work_id"))
            upstream_id = _safe_id(event.get("upstream_work_id"))
            run_id = _safe_id(event.get("run_id"))
            event_kind = _safe_code(event.get("event"))
            if proposal_id is not None:
                add_node(f"delivery:proposal:{proposal_id}", "proposal", "Proposal", evidence_id)
            if incident_id is not None:
                add_node(f"delivery:incident:{incident_id}", "incident", "Incident", evidence_id)
            if work_id is not None:
                work_kind = "ticket" if event_kind == "build.ticket.outcome" else "work"
                work_label = "Ticket" if work_kind == "ticket" else "Work item"
                add_node(f"delivery:work:{work_id}", work_kind, work_label, evidence_id)
            if upstream_id is not None:
                upstream_node = f"delivery:work:{upstream_id}"
                if upstream_id in proposal_ids:
                    upstream_node = f"delivery:proposal:{upstream_id}"
                    add_node(upstream_node, "proposal", "Proposal", evidence_id)
                elif upstream_id in incident_ids:
                    upstream_node = f"delivery:incident:{upstream_id}"
                    add_node(upstream_node, "incident", "Incident", evidence_id)
                else:
                    add_node(upstream_node, "work", "Work item", evidence_id)
                if work_id is not None:
                    add_edge(upstream_node, f"delivery:work:{work_id}", "explicit_lineage", evidence_id)
            if work_id is not None and proposal_id is not None:
                add_edge(f"delivery:proposal:{proposal_id}", f"delivery:work:{work_id}", "explicit_lineage", evidence_id)
            if work_id is not None and incident_id is not None:
                add_edge(f"delivery:incident:{incident_id}", f"delivery:work:{work_id}", "explicit_lineage", evidence_id)
            if run_id is not None and work_id is not None:
                run_node = f"delivery:run:{run_id}"
                add_node(run_node, "build_run", "Build run", evidence_id)
                add_edge(f"delivery:work:{work_id}", run_node, "explicit_run", evidence_id)
            if work_id is not None and _safe_code(event.get("outcome")) == "pr_opened":
                pr_digest = hashlib.sha256(work_id.encode()).hexdigest()[:20]
                pr_node = f"delivery:pr:{pr_digest}"
                add_node(pr_node, "pull_request", "Pull request", evidence_id)
                source = f"delivery:run:{run_id}" if run_id is not None else f"delivery:work:{work_id}"
                add_edge(source, pr_node, "explicit_outcome", evidence_id)

        if not raw_nodes:
            continue
        parent = {node_id: node_id for node_id in raw_nodes}

        def find(node_id: str) -> str:
            while parent[node_id] != node_id:
                parent[node_id] = parent[parent[node_id]]
                node_id = parent[node_id]
            return node_id

        def union(left: str, right: str) -> None:
            left_root, right_root = find(left), find(right)
            if left_root != right_root:
                parent[right_root] = left_root

        for edge in raw_edges:
            union(edge["from"], edge["to"])
        components: dict[str, list[str]] = {}
        for node_id in raw_nodes:
            components.setdefault(find(node_id), []).append(node_id)
        for component_ids in components.values():
            if len(graphs) >= MAX_DELIVERY_GRAPHS:
                limitations.append("delivery_graphs_truncated")
                break
            component_set = set(component_ids)
            component_edges = [edge for edge in raw_edges if edge["from"] in component_set and edge["to"] in component_set]
            digest = hashlib.sha256("\0".join(sorted(component_ids)).encode()).hexdigest()[:16]
            nodes = [raw_nodes[node_id] for node_id in component_ids]
            indegree = {node_id: 0 for node_id in component_ids}
            outdegree = {node_id: 0 for node_id in component_ids}
            for edge in component_edges:
                indegree[edge["to"]] += 1
                outdegree[edge["from"]] += 1
            roots = [node_id for node_id in component_ids if indegree[node_id] == 0]
            sinks = [node_id for node_id in component_ids if outdegree[node_id] == 0]

            def gap(stage: str, label: str) -> str:
                node_id = f"delivery:gap:{digest}:{stage}"
                nodes.append(
                    _graph_node(
                        node_id,
                        "missing_stage",
                        label,
                        "unverified",
                        project_id=project_id,
                        limitations=[f"{stage}_evidence_missing"],
                        reason="No explicit correlated evidence is available for this stage.",
                    )
                )
                return node_id

            ask_roots = [
                node_id for node_id in roots
                if raw_nodes[node_id]["kind"] in {"proposal", "incident"}
            ]
            ask_gap = None if ask_roots else gap("ask", "Ask not linked")
            has_ticket = any(raw_nodes[node_id]["kind"] == "ticket" for node_id in component_ids)
            ticket_gap = None if has_ticket else gap("ticket", "Ticket not linked")
            if ask_gap is not None and ticket_gap is not None:
                component_edges.append(
                    _graph_edge(
                        f"delivery-edge:{digest}:ask-ticket",
                        "missing_stage",
                        ask_gap,
                        ticket_gap,
                        "expected",
                        reason="Neither an originating ask nor a ticket is explicitly linked.",
                    )
                )
                for root in roots:
                    component_edges.append(
                        _graph_edge(
                            f"delivery-edge:{digest}:ticket-root:{len(component_edges)}",
                            "missing_stage",
                            ticket_gap,
                            root,
                            "expected",
                            reason="The observed lineage begins after the missing ticket stage.",
                        )
                    )
            elif ask_gap is not None:
                for root in roots:
                    component_edges.append(
                        _graph_edge(
                            f"delivery-edge:{digest}:ask:{len(component_edges)}",
                            "missing_stage",
                            ask_gap,
                            root,
                            "expected",
                            reason="The observed lineage has no explicit originating ask.",
                        )
                    )
            elif ticket_gap is not None:
                ask_targets = [
                    edge["to"] for edge in component_edges
                    if edge["from"] in set(ask_roots)
                ]
                for ask_root in ask_roots:
                    component_edges.append(
                        _graph_edge(
                            f"delivery-edge:{digest}:ask-ticket:{len(component_edges)}",
                            "missing_stage",
                            ask_root,
                            ticket_gap,
                            "expected",
                            reason="The explicit ask has no explicitly linked ticket.",
                        )
                    )
                for target in dict.fromkeys(ask_targets):
                    component_edges.append(
                        _graph_edge(
                            f"delivery-edge:{digest}:ticket-target:{len(component_edges)}",
                            "missing_stage",
                            ticket_gap,
                            target,
                            "expected",
                            reason="Observed work continues after the missing ticket stage.",
                        )
                    )
            terminal_sources = [node_id for node_id in sinks if raw_nodes[node_id]["kind"] == "pull_request"]
            if not terminal_sources:
                pr_gap = gap("pull-request", "Pull request not linked")
                for sink in sinks:
                    component_edges.append(
                        _graph_edge(
                            f"delivery-edge:{digest}:pr:{len(component_edges)}",
                            "missing_stage",
                            sink,
                            pr_gap,
                            "expected",
                            reason="The observed lineage has no explicit pull-request outcome.",
                        )
                    )
                terminal_sources = [pr_gap]
            deploy_gap = gap("deploy", "Deploy not linked")
            usage_gap = gap("usage", "Usage outcome not linked")
            for source in terminal_sources:
                component_edges.append(
                    _graph_edge(
                        f"delivery-edge:{digest}:deploy:{len(component_edges)}",
                        "missing_stage",
                        source,
                        deploy_gap,
                        "expected",
                        reason="No explicit correlated deploy evidence is available.",
                    )
                )
            component_edges.append(
                _graph_edge(
                    f"delivery-edge:{digest}:usage",
                    "missing_stage",
                    deploy_gap,
                    usage_gap,
                    "expected",
                    reason="No explicit correlated usage outcome is available.",
                )
            )
            try:
                graphs.append(
                    _validate_and_rank_graph(
                        {
                            "id": f"graph:delivery:{project_id}:{digest}",
                            "kind": "delivery",
                            "label": "Project delivery",
                            "scope": {"kind": "project", "project_id": project_id, "project_label": project_label},
                            "state": "incomplete",
                            "nodes": nodes,
                            "edges": component_edges,
                            "limitations": ["deploy_evidence_missing", "usage_outcome_evidence_missing"],
                        },
                        max_nodes=MAX_DELIVERY_GRAPH_NODES,
                        max_edges=MAX_DELIVERY_GRAPH_EDGES,
                    )
                )
            except GraphValidationError as error:
                limitations.append(f"delivery_graph_{error.code}")
    return graphs, sorted(set(limitations)), unattributed_events


def _graphs_document(
    topology: dict[str, Any],
    inspection: Optional[dict[str, Any]],
    events: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[str]]:
    delivery, limitations, unattributed_events = _delivery_graphs(events, inspection)
    return [
        _architecture_graph(topology),
        *_runtime_graphs(topology, inspection, unattributed_events),
        *delivery,
    ], limitations


def _outcome_document(
    events: list[dict[str, Any]],
    attention_count: Optional[int],
    *,
    event_stream_truncated: bool,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    event_evidence = [_safe_event_evidence(event) for event in events]
    evidence_id_by_object = {id(event): row["id"] for event, row in zip(events, event_evidence)}
    by_run: dict[str, list[dict[str, Any]]] = {}
    for event in events:
        run_id = _safe_id(event.get("run_id"))
        if run_id is not None:
            by_run.setdefault(run_id, []).append(event)
    chains = []
    for run_id in sorted(by_run):
        rows = sorted(by_run[run_id], key=lambda row: (_safe_timestamp(row.get("ts")) or "", str(row.get("event", ""))))
        starts = [row for row in rows if row.get("event") == "job.start"]
        ends = [row for row in rows if row.get("event") == "job.end"]
        domain = [row for row in rows if row.get("event") not in {"job.start", "job.end"}]
        state = "complete" if starts and ends else "incomplete"
        role = next((_safe_code(row.get("role")) for row in rows if _safe_code(row.get("role"))), None)
        chain = {
            "run_id": run_id,
            "role": role,
            "state": state,
            "status": _safe_code(ends[-1].get("status")) if ends else None,
            "started_at": _safe_timestamp(starts[0].get("ts")) if starts else None,
            "ended_at": _safe_timestamp(ends[-1].get("ts")) if ends else None,
            "work_ids": sorted({safe for row in domain if (safe := _safe_id(row.get("work_id"))) is not None}),
            "proposal_ids": sorted({safe for row in rows if (safe := _safe_id(row.get("proposal_id"))) is not None}),
            "incident_ids": sorted({safe for row in rows if (safe := _safe_id(row.get("incident_id"))) is not None}),
            "evidence_ids": [evidence_id_by_object[id(row)] for row in rows[:50]],
            "limitations": [] if state == "complete" else ["run_terminal_evidence_missing"],
        }
        chains.append(chain)
    chains = chains[:MAX_OUTCOME_CHAINS]

    parents: dict[str, str] = {}

    def find(item: str) -> str:
        parents.setdefault(item, item)
        while parents[item] != item:
            parents[item] = parents[parents[item]]
            item = parents[item]
        return item

    def union(left: str, right: str) -> None:
        left_root = find(left)
        right_root = find(right)
        if left_root != right_root:
            parents[max(left_root, right_root)] = min(left_root, right_root)

    event_ids: list[tuple[dict[str, Any], list[str]]] = []
    for event in events:
        identifiers = []
        for key in ("proposal_id", "incident_id", "work_id", "upstream_work_id"):
            value = _safe_id(event.get(key))
            if value is not None and value not in identifiers:
                identifiers.append(value)
        if not identifiers:
            continue
        for value in identifiers:
            find(value)
        for value in identifiers[1:]:
            union(identifiers[0], value)
        event_ids.append((event, identifiers))
    grouped: dict[str, list[dict[str, Any]]] = {}
    group_identifiers: dict[str, set[str]] = {}
    for event, identifiers in event_ids:
        root = find(identifiers[0])
        grouped.setdefault(root, []).append(event)
        group_identifiers.setdefault(root, set()).update(identifiers)
    lineages = []
    successful_work_outcomes = {"pr_opened", "ok"}
    for root in sorted(grouped):
        rows = sorted(grouped[root], key=lambda row: (_safe_timestamp(row.get("ts")) or "", str(row.get("event", ""))))
        has_incident = any(_safe_id(row.get("incident_id")) is not None for row in rows)
        explicit_types = {
            row.get("type") for row in rows if row.get("type") in {"feature", "bug"}
        }
        kind = "bugfix" if has_incident or "bug" in explicit_types else ("feature" if "feature" in explicit_types else "work")
        work_rows = [row for row in rows if row.get("event") in {"build.work.outcome", "build.ticket.outcome"}]
        succeeded = any(row.get("outcome") in successful_work_outcomes for row in work_rows)
        upstream = any(_safe_id(row.get("upstream_work_id")) is not None for row in rows)
        state = "complete" if succeeded and (upstream or has_incident or explicit_types) else "unverified"
        lineages.append(
            {
                "id": "lineage:" + hashlib.sha256("\0".join(sorted(group_identifiers[root])).encode()).hexdigest()[:20],
                "kind": kind,
                "state": state,
                "identifiers": sorted(group_identifiers[root])[:20],
                "outcome": next((_safe_code(row.get("outcome")) for row in reversed(rows) if _safe_code(row.get("outcome"))), None),
                "started_at": _safe_timestamp(rows[0].get("ts")),
                "ended_at": _safe_timestamp(rows[-1].get("ts")),
                "evidence_ids": [evidence_id_by_object[id(row)] for row in rows[:50]],
                "limitations": [] if state == "complete" else ["end_to_end_lineage_incomplete"],
            }
        )
    lineages = lineages[:MAX_OUTCOME_CHAINS]

    terminal = [event for event in events if event.get("event") == "job.end"]
    successful = sum(1 for event in terminal if event.get("status") == "ok")
    reliability = {
        "state": "partial" if terminal and event_stream_truncated else ("measured" if terminal else "unknown"),
        "completed": len(terminal) if terminal else None,
        "successful": successful if terminal else None,
        "rate": successful / len(terminal) if terminal else None,
        "limitations": ["event_window_truncated"] if terminal and event_stream_truncated else ([] if terminal else ["job_terminal_denominator_missing"]),
    }
    roles = sorted({_safe_code(event.get("role")) for event in events if _safe_code(event.get("role"))})
    role_contracts = []
    for role in roles:
        started = sum(1 for event in events if event.get("role") == role and event.get("event") == "job.start")
        completed = sum(1 for event in events if event.get("role") == role and event.get("event") == "job.end")
        ok = sum(1 for event in events if event.get("role") == role and event.get("event") == "job.end" and event.get("status") == "ok")
        role_contracts.append(
            {
                "role": role,
                "state": "partial" if started and event_stream_truncated else ("measured" if started else "unknown"),
                "started": started if started else None,
                "completed": completed if started else None,
                "successful": ok if started else None,
                "completion_rate": completed / started if started else None,
                "limitations": ["event_window_truncated"] if started and event_stream_truncated else ([] if started else ["role_start_denominator_missing"]),
            }
        )
    token_totals = {key: 0 for key in _TOKEN_FIELDS}
    token_coverage = {key: 0 for key in _TOKEN_FIELDS}
    legacy_total = 0
    legacy_coverage = 0
    for event in terminal:
        total = _safe_number(event.get("tokens"))
        if isinstance(total, int) and total >= 0:
            legacy_total += total
            legacy_coverage += 1
        for key in _TOKEN_FIELDS:
            value = _safe_number(event.get(key))
            if isinstance(value, int) and value >= 0:
                token_totals[key] += value
                token_coverage[key] += 1
    any_token_observed = legacy_coverage > 0 or any(token_coverage.values())
    complete_total_coverage = bool(terminal) and legacy_coverage == len(terminal)
    efficiency: dict[str, Any] = {
        "state": "measured" if complete_total_coverage and not event_stream_truncated else ("partial" if any_token_observed else "unknown"),
        "completed_runs": len(terminal) if terminal else None,
        "total_tokens": legacy_total if legacy_coverage else None,
        "total_token_coverage_runs": legacy_coverage if terminal else None,
        "limitations": ["event_window_truncated"] if any_token_observed and event_stream_truncated else ([] if complete_total_coverage else (["token_coverage_partial"] if any_token_observed else ["token_class_denominator_missing"])),
    }
    for key, value in token_totals.items():
        efficiency[key] = value if token_coverage[key] else None
        efficiency[f"{key}_coverage_runs"] = token_coverage[key] if terminal else None
    efficiency["tokens_per_completed_run"] = (
        legacy_total / len(terminal) if complete_total_coverage else None
    )

    critiques = {
        _safe_id(event.get("critique_id"))
        for event in events
        if _safe_id(event.get("critique_id")) is not None
    }
    dispositions = {name: 0 for name in ("deposited", "deferred", "failed", "expired")}
    for event in events:
        disposition = event.get("disposition")
        if disposition in dispositions and _safe_id(event.get("critique_id")) is not None:
            dispositions[disposition] += 1
    shoulder = {
        "state": "partial" if critiques and event_stream_truncated else ("measured" if critiques else "unknown"),
        "critiques": len(critiques) if critiques else None,
        **{key: value if critiques else None for key, value in dispositions.items()},
        "limitations": ["event_window_truncated"] if critiques and event_stream_truncated else ([] if critiques else ["critique_lineage_missing"]),
    }
    operator_load = {
        "state": "measured" if attention_count is not None else "unknown",
        "attention_items": attention_count,
        "limitations": [] if attention_count is not None else ["operator_attention_unavailable"],
    }
    return {
        "chains": chains,
        "lineages": lineages,
        "role_contracts": role_contracts,
        "reliability": reliability,
        "operator_load": operator_load,
        "efficiency": efficiency,
        "shoulder": shoulder,
    }, event_evidence


def _git(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=5,
        check=False,
    )


def _change_bucket(path: str) -> str:
    lowered = path.lower()
    components = lowered.split("/")
    name = components[-1]
    if components[0] in {"docs", "doc"} or name.endswith((".md", ".rst")):
        return "docs"
    if any(component in {"test", "tests", "__tests__", "spec", "specs"} for component in components[:-1]) or name.startswith(("test_", "spec_")) or ".test." in name or ".spec." in name:
        return "test"
    return "product"


def _git_range_metrics(repo: Path, base: str, head: str) -> Optional[dict[str, Any]]:
    try:
        if not repo.is_dir() or not _SHA_RE.fullmatch(base) or not _SHA_RE.fullmatch(head):
            return None
        resolved = []
        for value in (base, head):
            result = _git(repo, "rev-parse", "--verify", f"{value}^{{commit}}")
            if result.returncode != 0 or not _SHA_RE.fullmatch(result.stdout.strip()):
                return None
            resolved.append(result.stdout.strip())
        base, head = resolved
        if _git(repo, "merge-base", "--is-ancestor", base, head).returncode != 0:
            return None
        current = _git(repo, "rev-parse", "--verify", "HEAD^{commit}")
        contains = _git(repo, "for-each-ref", "--format=%(refname)", f"--contains={head}")
        if current.returncode != 0 or (current.stdout.strip() != head and not contains.stdout.strip()):
            return None
        commit_result = _git(repo, "rev-list", "--count", f"{base}..{head}")
        diff_result = _git(repo, "diff", "--numstat", "--no-renames", base, head)
    except (OSError, subprocess.SubprocessError):
        return None
    if commit_result.returncode != 0 or diff_result.returncode != 0:
        return None
    try:
        commits = int(commit_result.stdout.strip())
    except ValueError:
        return None
    additions = 0
    deletions = 0
    files = 0
    buckets = {"product": 0, "test": 0, "docs": 0}
    for line in diff_result.stdout.splitlines():
        parts = line.split("\t", 2)
        if len(parts) != 3:
            return None
        added, removed, path = parts
        if added != "-":
            try:
                additions += int(added)
                deletions += int(removed)
            except ValueError:
                return None
        files += 1
        buckets[_change_bucket(path)] += 1
    return {
        "base_sha": base,
        "head_sha": head,
        "additions": additions,
        "deletions": deletions,
        "files_touched": files,
        "commits": commits,
        "buckets": buckets,
        "durability": "unknown",
        "limitations": ["durability_not_proven"],
    }


def collect_change_metrics(
    events: list[dict[str, Any]], inspection: Optional[dict[str, Any]]
) -> tuple[list[dict[str, Any]], list[str]]:
    project_paths: dict[str, Path] = {}
    project_names: dict[str, list[str]] = {}
    if inspection is not None:
        for raw in _array(inspection.get("fleet")):
            item = _object(raw)
            project_id = _safe_id(item.get("project_id"))
            project_name = _safe_id(item.get("project_name"))
            project_path = item.get("project_path")
            if project_id is not None and isinstance(project_path, str):
                project_paths[project_id] = Path(project_path)
                if project_name is not None:
                    project_names.setdefault(project_name, []).append(project_id)
    requested = False
    invalid = False
    truncated = False
    results = []
    seen: set[tuple[str, str, str]] = set()
    for event in events:
        project_id = _safe_id(event.get("project_id"))
        if project_id is None:
            project = _safe_id(event.get("project"))
            matches = project_names.get(project or "", [])
            project_id = matches[0] if len(matches) == 1 else None
        base = event.get("base_sha")
        head = event.get("head_sha")
        if base is None and head is None:
            continue
        requested = True
        if project_id is None or project_id not in project_paths or not isinstance(base, str) or not isinstance(head, str):
            invalid = True
            continue
        key = (project_id, base, head)
        if key in seen:
            continue
        if len(seen) >= MAX_CHANGE_RANGES:
            truncated = True
            break
        seen.add(key)
        metrics = _git_range_metrics(project_paths[project_id], base, head)
        if metrics is None:
            invalid = True
            continue
        metrics["project_id"] = project_id
        metrics["evidence_ids"] = [_event_evidence_id(event)]
        results.append(metrics)
    results.sort(key=lambda row: (row["project_id"], row["base_sha"], row["head_sha"]))
    limitations = []
    if not requested:
        limitations.append("explicit_git_range_unavailable")
    if invalid:
        limitations.append("invalid_git_range")
    if truncated:
        limitations.append("git_ranges_truncated")
    return results, limitations


def _safe_change_rows(changes: Optional[list[dict[str, Any]]]) -> list[dict[str, Any]]:
    rows = []
    for raw in changes or []:
        item = _object(raw)
        project_id = _safe_id(item.get("project_id"))
        base = item.get("base_sha")
        head = item.get("head_sha")
        if project_id is None or not isinstance(base, str) or not _SHA_RE.fullmatch(base) or not isinstance(head, str) or not _SHA_RE.fullmatch(head):
            continue
        numbers = {}
        valid = True
        for key in ("additions", "deletions", "files_touched", "commits"):
            value = item.get(key)
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                valid = False
                break
            numbers[key] = value
        buckets = _object(item.get("buckets"))
        if not valid or any(not isinstance(buckets.get(key), int) or isinstance(buckets.get(key), bool) or buckets[key] < 0 for key in ("product", "test", "docs")):
            continue
        rows.append(
            {
                "project_id": project_id,
                "base_sha": base,
                "head_sha": head,
                **numbers,
                "buckets": {key: buckets[key] for key in ("product", "test", "docs")},
                "durability": "unknown",
                "evidence_ids": _safe_ids(item.get("evidence_ids")),
                "limitations": sorted(set(_safe_limitations(item.get("limitations")) + ["durability_not_proven"])),
            }
        )
    return sorted(rows, key=lambda row: (row["project_id"], row["base_sha"], row["head_sha"]))


def _coverage_rows(
    inspection: Optional[dict[str, Any]],
    relationships: Optional[dict[str, Any]],
    topology_available: bool,
    *,
    attention_truncated: bool,
    evidence_truncated: bool,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    if inspection is not None:
        for raw in _array(inspection.get("coverage")):
            item = _object(raw)
            source = _safe_code(item.get("source"))
            state = item.get("state") if item.get("state") in {"available", "partial", "unavailable", "unknown"} else "unknown"
            if source is None:
                continue
            row: dict[str, Any] = {
                "source": source,
                "state": state,
                "reason": _safe_code(item.get("reason")),
                "limitations": _safe_limitations(item.get("limitations")),
            }
            project_id = _safe_id(item.get("project_id"))
            if project_id is not None:
                row["project_id"] = project_id
            for key in ("records_total", "records_valid", "records_invalid", "records_out_of_window", "records_unattributed", "records_ambiguous"):
                number = _safe_number(item.get(key))
                if isinstance(number, int) and number >= 0:
                    row[key] = number
            rows.append(row)
    rows.extend(
        {
            "source": f"relationships_{row['provider']}",
            "state": row["state"],
            "reason": row["coverage_state"],
            "limitations": row["limitations"],
            **({"records_total": row["files_scanned"]} if "files_scanned" in row else {}),
            **({"records_invalid": row["malformed_records"]} if "malformed_records" in row else {}),
        }
        for row in _relationship_sources(relationships)
    )
    rows.append(
        {
            "source": "presentation_topology",
            "state": "available" if topology_available else "unavailable",
            "reason": "ok" if topology_available else "topology_invalid",
            "limitations": [],
        }
    )
    rows.append(
        {
            "source": "operator_bounds",
            "state": "partial" if attention_truncated or evidence_truncated else "available",
            "reason": "truncated" if attention_truncated or evidence_truncated else "ok",
            "limitations": [
                code
                for code, present in (
                    ("attention_truncated", attention_truncated),
                    ("evidence_truncated", evidence_truncated),
                )
                if present
            ],
        }
    )
    return rows


def _brief_document(
    promises: list[dict[str, Any]],
    attention: list[dict[str, Any]],
    outcomes: dict[str, Any],
    *,
    inspection_state: str,
    attention_truncated: bool,
) -> dict[str, Any]:
    grouped: list[dict[str, Any]] = []
    group_index: dict[tuple[str, str], int] = {}
    for item in attention:
        rule_id = item.get("rule_id") if isinstance(item.get("rule_id"), str) else item["kind"]
        scope = item.get("scope") if isinstance(item.get("scope"), str) else "fleet"
        key = (rule_id, scope)
        if key not in group_index:
            digest = hashlib.sha256(f"{rule_id}\0{scope}".encode("utf-8")).hexdigest()[:16]
            group_index[key] = len(grouped)
            grouped.append(
                {
                    "id": f"attention-group:{digest}",
                    "label": item["label"],
                    "action": item.get("action") or item["label"],
                    "state": item["state"],
                    "item_count": 0,
                    "evidence_count": 0,
                    "project_count": None,
                    "latest_at": item.get("detected_at"),
                    "evidence_ids": [],
                    "limitations": [],
                    "_project_ids": [],
                    "_failure_records": 0,
                    "_counts_complete": True,
                }
            )
        group = grouped[group_index[key]]
        group["item_count"] += 1
        source_evidence_count = item.get("evidence_count")
        if not (
            isinstance(source_evidence_count, int)
            and not isinstance(source_evidence_count, bool)
            and source_evidence_count == len(item["evidence_ids"])
        ):
            group["_counts_complete"] = False
        for evidence_id in item["evidence_ids"]:
            if evidence_id not in group["evidence_ids"]:
                group["evidence_ids"].append(evidence_id)
        for project_id in item.get("project_ids", []):
            if project_id not in group["_project_ids"]:
                group["_project_ids"].append(project_id)
        latest = item.get("detected_at")
        if isinstance(latest, str) and (group["latest_at"] is None or latest > group["latest_at"]):
            group["latest_at"] = latest
        group["limitations"].extend(item.get("limitations", []))
        failure_records = _object(item.get("operands")).get("failure_records")
        if isinstance(failure_records, int) and not isinstance(failure_records, bool) and failure_records >= 0:
            group["_failure_records"] += failure_records

    for group in grouped:
        group["project_count"] = len(group.pop("_project_ids")) or None
        counts_complete = group.pop("_counts_complete")
        group["evidence_count"] = len(group["evidence_ids"]) if counts_complete else None
        failure_records = group.pop("_failure_records")
        if group["label"] == _PRIORITY_LABELS["core_job_failure_v1"] and failure_records:
            noun = "failure" if failure_records == 1 else "failures"
            group["action"] = f"Repair {failure_records} observed Shipyard job {noun}"
        group["limitations"] = sorted(set(group["limitations"]))
        if len(group["evidence_ids"]) > 50:
            group["evidence_ids"] = group["evidence_ids"][:50]
            group["limitations"].append("evidence_truncated")

    brief_limitations: list[str] = []
    if inspection_state == "unavailable":
        brief_limitations.append("inspection_unavailable")
    elif inspection_state == "stale":
        brief_limitations.append("inspection_stale")
    if attention_truncated:
        brief_limitations.append("attention_truncated")
    if len(grouped) > MAX_ATTENTION_GROUPS:
        brief_limitations.append("attention_groups_truncated")
    bounded_groups = grouped[:MAX_ATTENTION_GROUPS]

    promise_counts = {
        state: sum(1 for item in promises if item["state"] == state)
        for state in _STATE_RANK
    }
    assessed_promises = promise_counts["verified"] + promise_counts["violated"]
    promise_state = (
        "alarm"
        if promise_counts["violated"]
        else ("waiting" if promise_counts["unverified"] else "clear")
    )
    reliability = _object(outcomes.get("reliability"))
    completed = _safe_number(reliability.get("completed"))
    successful = _safe_number(reliability.get("successful"))
    reliability_state = reliability.get("state")
    if not isinstance(reliability_state, str):
        reliability_state = "unknown"
    signals = [
        {
            "id": "promises_verified",
            "label": "Promises verified",
            "value": promise_counts["verified"],
            "unit": "promise" if promise_counts["verified"] == 1 else "promises",
            "state": promise_state,
            "observed": assessed_promises,
            "total": len(promises),
            "limitations": ["promise_evidence_incomplete"] if promise_counts["unverified"] else [],
        },
        {
            "id": "successful_runs",
            "label": "Successful runs",
            "value": successful if successful is not None and successful >= 0 else None,
            "unit": "completed run" if successful == 1 else "completed runs",
            "state": reliability_state,
            "observed": successful if successful is not None and successful >= 0 else None,
            "total": completed if completed is not None and completed >= 0 else None,
            "limitations": _safe_limitations(reliability.get("limitations")),
        },
        {
            "id": "attention",
            "label": "Attention",
            "value": len(grouped),
            "unit": "group" if len(grouped) == 1 else "groups",
            "state": bounded_groups[0]["state"] if bounded_groups else "unknown",
            "observed": len(bounded_groups),
            "total": len(grouped),
            "limitations": ["attention_truncated"] if attention_truncated else [],
        },
    ][:MAX_BRIEF_SIGNALS]
    if bounded_groups:
        lead = bounded_groups[0]
        state = lead["state"]
        takeaway = lead["label"]
        action = lead["action"]
    else:
        state = "unknown" if inspection_state != "stale" else "waiting"
        takeaway = "No operator action is currently evidenced"
        action = "Review current evidence coverage"
    return {
        "state": state,
        "takeaway": takeaway,
        "action": action,
        "signals": signals,
        "attention_groups": bounded_groups,
        "limitations": sorted(set(brief_limitations)),
    }


def _narrative_document(
    brief: dict[str, Any],
    promises: list[dict[str, Any]],
    attention: list[dict[str, Any]],
    outcomes: dict[str, Any],
    topology: dict[str, Any],
    changes: list[dict[str, Any]],
) -> dict[str, Any]:
    counts = {state: sum(1 for item in promises if item["state"] == state) for state in _STATE_RANK}
    focus = brief["takeaway"]
    beats = [
        {
            "id": "story:promises",
            "heading": "Outcomes",
            "body": f"{counts['verified']} verified · {counts['violated']} violated · {counts['unverified']} unverified",
            "state": "alarm" if counts["violated"] else ("waiting" if counts["unverified"] else "clear"),
            "evidence_ids": [evidence_id for item in promises for evidence_id in item["evidence_ids"]][:20],
        },
        {
            "id": "story:attention",
            "heading": "Needs you",
            "body": brief["action"],
            "state": brief["state"],
            "evidence_ids": brief["attention_groups"][0]["evidence_ids"] if brief["attention_groups"] else [],
        },
    ]
    reliability = outcomes["reliability"]
    if reliability["state"] == "measured":
        beats.append(
            {
                "id": "story:reliability",
                "heading": "Runs",
                "body": f"{reliability['successful']} of {reliability['completed']} completed successfully",
                "state": "clear" if reliability["successful"] == reliability["completed"] else "alarm",
                "evidence_ids": [evidence_id for chain in outcomes["chains"] for evidence_id in chain["evidence_ids"]][:20],
            }
        )
    observed_calls = sum(edge["count"] for edge in topology["observed_edges"] if edge["kind"] == "call")
    observed_skills = sum(edge["count"] for edge in topology["observed_edges"] if edge["kind"] == "skill_call")
    beats.append(
        {
            "id": "story:crew",
            "heading": "Crew",
            "body": f"{observed_calls} observed calls · {observed_skills} skill invocations",
            "state": "signal" if observed_calls or observed_skills else "unknown",
            "evidence_ids": [evidence_id for edge in topology["observed_edges"] for evidence_id in edge["evidence_ids"]][:20],
        }
    )
    efficiency = outcomes["efficiency"]
    if efficiency["state"] == "measured":
        beats.append(
            {
                "id": "story:tokens",
                "heading": "Tokens",
                "body": f"{int(efficiency['tokens_per_completed_run'])} classified tokens per completed run",
                "state": "signal",
                "evidence_ids": [],
            }
        )
    if changes:
        beats.append(
            {
                "id": "story:changes",
                "heading": "Changes",
                "body": f"{sum(item['additions'] for item in changes)} added · {sum(item['deletions'] for item in changes)} removed",
                "state": "signal",
                "evidence_ids": [evidence_id for item in changes for evidence_id in item["evidence_ids"]][:20],
            }
        )
    return {
        "heading": brief["takeaway"],
        "subline": brief["action"],
        "focus": focus,
        "operator_action": brief["action"],
        "beats": beats[:MAX_STORY_BEATS],
    }


def compose_operator_document(
    *,
    window: str,
    generated_at: datetime,
    summary: dict[str, Any],
    events: list[dict[str, Any]],
    inspection: Optional[dict[str, Any]],
    relationships: Optional[dict[str, Any]],
    topology: dict[str, Any],
    inspection_state: str,
    refresh_age_seconds: Optional[int],
    refresh_limitation: Optional[str] = None,
    event_stream_truncated: bool = False,
    runtime_events: Optional[list[dict[str, Any]]] = None,
    runtime_limitations: Optional[list[str]] = None,
    delivery_events: Optional[list[dict[str, Any]]] = None,
    delivery_limitations: Optional[list[str]] = None,
    source_provenance: Optional[dict[str, str]] = None,
    changes: Optional[list[dict[str, Any]]] = None,
    change_limitations: Optional[list[str]] = None,
) -> dict[str, Any]:
    """Compose one deterministic, content-minimizing operator document."""
    if window not in WINDOW_DAYS:
        raise OperatorDataError("unsupported operator window")
    if generated_at.tzinfo is None or generated_at.utcoffset() is None:
        raise OperatorDataError("generated_at must be timezone-aware")
    if inspection_state not in {"fresh", "stale", "unavailable"}:
        raise OperatorDataError("invalid inspection state")
    safe_events = [event for event in events if isinstance(event, dict)]
    safe_runtime_events = [
        event
        for event in (runtime_events if runtime_events is not None else safe_events)
        if isinstance(event, dict)
    ]
    safe_runtime_limitations = _safe_limitations(runtime_limitations)
    recovered_delivery_events = [
        event for event in (delivery_events or [])
        if isinstance(event, dict) and _is_delivery_lineage_event(event)
    ]
    displayed_event_ids = {_event_evidence_id(event) for event in safe_events}
    recovered_by_evidence_id: dict[str, dict[str, Any]] = {}
    for event in recovered_delivery_events:
        evidence_id = _event_evidence_id(event)
        if evidence_id not in displayed_event_ids:
            recovered_by_evidence_id.setdefault(evidence_id, event)
    graph_delivery_events = [*safe_events, *recovered_by_evidence_id.values()]
    safe_delivery_events = [
        event for event in graph_delivery_events
        if _is_delivery_lineage_event(event)
    ]
    safe_delivery_limitations = _safe_limitations(delivery_limitations)
    promises = _promise_rows(inspection)
    attention, attention_truncated = _attention_rows(inspection)
    inspection_attention_count = _safe_number(
        _object(_object(inspection).get("summary")).get("attention_count")
    ) if inspection is not None else None
    if not isinstance(inspection_attention_count, int) or inspection_attention_count < 0:
        inspection_attention_count = len(attention) if inspection is not None else None
    outcomes, event_evidence = _outcome_document(
        safe_events,
        inspection_attention_count,
        event_stream_truncated=event_stream_truncated,
    )
    topology_document, relationship_evidence = _topology_document(
        topology, summary, safe_events, safe_runtime_events, inspection, relationships
    )
    graphs, graph_limitations = _graphs_document(
        topology_document, inspection, graph_delivery_events
    )
    brief = _brief_document(
        promises,
        attention,
        outcomes,
        inspection_state=inspection_state,
        attention_truncated=attention_truncated,
    )
    changes = _safe_change_rows(changes)
    safe_change_limitations = _safe_limitations(
        change_limitations if change_limitations is not None else ["explicit_git_range_unavailable"]
    )
    # Project-keyed runtime evidence wins over the same globally bounded event
    # so its controlled project linkage cannot be erased by de-duplication.
    displayed_evidence_ids = {row["id"] for row in event_evidence}
    recovered_delivery_evidence = [
        _safe_event_evidence(event)
        for event in safe_delivery_events
        if _event_evidence_id(event) not in displayed_evidence_ids
    ]
    evidence = (
        _inspection_evidence(inspection)
        + relationship_evidence
        + event_evidence
        + recovered_delivery_evidence
    )
    unique_evidence: list[dict[str, Any]] = []
    seen_evidence: set[str] = set()
    for row in evidence:
        if row["id"] not in seen_evidence:
            unique_evidence.append(row)
            seen_evidence.add(row["id"])
    consumers = [brief, promises, attention, outcomes, topology_document, graphs, changes]
    unique_evidence, selected_evidence_ids, missing_evidence_ids, evidence_truncated = _bound_evidence(
        unique_evidence, consumers
    )
    for consumer in consumers:
        _constrain_evidence_links(consumer, selected_evidence_ids, missing_evidence_ids)
    limitations = list(safe_change_limitations)
    if inspection_state == "unavailable":
        limitations.append("inspection_unavailable")
    elif inspection_state == "stale":
        limitations.append("inspection_stale")
    if inspection is None:
        limitations.append("inspection_snapshot_missing")
    if relationships is None:
        limitations.append("relationship_snapshot_missing")
    if event_stream_truncated:
        limitations.append("event_window_truncated")
    limitations.extend(safe_runtime_limitations)
    limitations.extend(safe_delivery_limitations)
    limitations.extend(graph_limitations)
    if refresh_limitation is not None:
        safe_refresh_limitation = _safe_code(refresh_limitation)
        if safe_refresh_limitation is not None:
            limitations.append(safe_refresh_limitation)
    limitations.extend(_safe_limitations(topology_document.get("limitations")))
    provenance = _object(source_provenance)
    source_revision = provenance.get("source_revision")
    if not isinstance(source_revision, str) or not _SHA_RE.fullmatch(source_revision):
        source_revision = "unknown"
    source_state = provenance.get("source_state")
    if source_state not in {"clean", "modified", "unknown"}:
        source_state = "unknown"
    source_digest = provenance.get("source_digest")
    if not isinstance(source_digest, str) or not re.fullmatch(r"[0-9a-f]{64}", source_digest):
        source_digest = "unknown"
    metadata = {
        "schema_version": OPERATOR_VIEW_SCHEMA_VERSION,
        "build_version": OPERATOR_BUILD_VERSION,
        "rule_version": OPERATOR_RULE_VERSION,
        "inspection_rule_version": _safe_code(_object(_object(inspection).get("meta")).get("rule_version")) if inspection else None,
        "window": window,
        "generated_at": generated_at.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
        "inspection_state": inspection_state,
        "refresh_age_seconds": refresh_age_seconds,
        "source_revision": source_revision,
        "source_state": source_state,
        "source_digest": source_digest,
        "scope": _scope_document(inspection),
        "limits": {"attention": MAX_ATTENTION, "evidence": MAX_EVIDENCE, "story_beats": MAX_STORY_BEATS},
        "limitations": sorted(set(limitations)),
    }
    topology_available = bool(topology.get("roles")) and bool(topology.get("skills"))
    if not topology_available:
        metadata["limitations"].append("presentation_topology_unavailable")
        metadata["limitations"] = sorted(set(metadata["limitations"]))
    coverage = _coverage_rows(
        inspection,
        relationships,
        topology_available,
        attention_truncated=attention_truncated,
        evidence_truncated=evidence_truncated,
    )
    coverage.append(
        {
            "source": "operator_events",
            "state": "partial" if event_stream_truncated else "available",
            "reason": "bounded_at_maximum" if event_stream_truncated else "ok",
            "records_total": len(safe_events),
            "limitations": ["event_window_truncated"] if event_stream_truncated else [],
        }
    )
    coverage.append(
        {
            "source": "runtime_lifecycle",
            "state": "partial" if safe_runtime_limitations else "available",
            "reason": "bounded_at_maximum" if safe_runtime_limitations else "ok",
            "records_total": len(safe_runtime_events),
            "limitations": safe_runtime_limitations,
        }
    )
    coverage.append(
        {
            "source": "delivery_lifecycle",
            "state": "partial" if safe_delivery_limitations else "available",
            "reason": "bounded_at_maximum" if safe_delivery_limitations else "ok",
            "records_total": len(safe_delivery_events),
            "limitations": safe_delivery_limitations,
        }
    )
    narrative = _narrative_document(
        brief, promises, attention, outcomes, topology_document, changes
    )
    return {
        "schema_version": OPERATOR_VIEW_SCHEMA_VERSION,
        "kind": "shipyard.operator",
        "metadata": metadata,
        "brief": brief,
        "narrative": narrative,
        "promises": promises,
        "outcomes": outcomes,
        "graphs": graphs,
        "topology": topology_document,
        "changes": changes,
        "attention": attention,
        "coverage": coverage,
        "evidence": unique_evidence,
    }


def make_expensive_loader(repo_root: Path) -> Callable[[str], dict[str, Any]]:
    repo_root = repo_root.resolve(strict=True)

    def load(window: str) -> dict[str, Any]:
        days = WINDOW_DAYS[window]
        inspect_result = subprocess.run(
            [
                "bash",
                str(repo_root / "skills" / "shipyard" / "shipyard.sh"),
                "inspect",
                "--python-executable",
                sys.executable,
                "--json",
                "--days",
                str(days),
            ],
            cwd=repo_root,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=120,
            check=False,
        )
        if inspect_result.returncode == 3:
            inspection = None
        elif inspect_result.returncode == 0:
            inspection = json.loads(inspect_result.stdout)
            if not isinstance(inspection, dict):
                raise OperatorDataError("inspection output is not an object")
        else:
            raise OperatorDataError("inspection command failed")
        relationship_result = subprocess.run(
            [sys.executable, str(repo_root / "scripts" / "delegation-report.py"), "--operator-json", "--days", str(days)],
            cwd=repo_root,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=120,
            check=False,
        )
        if relationship_result.returncode != 0:
            raise OperatorDataError("relationship command failed")
        relationships = json.loads(relationship_result.stdout)
        if not isinstance(relationships, dict):
            raise OperatorDataError("relationship output is not an object")
        return {"inspection": inspection, "relationships": relationships}

    return load
