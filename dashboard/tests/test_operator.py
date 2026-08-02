from __future__ import annotations

import hashlib
import json
import re
import subprocess
import tempfile
import threading
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

from dashboard.operator import (
    MAX_ATTENTION,
    MAX_EVIDENCE,
    MAX_RUNTIME_EVENTS_PER_NODE,
    MAX_STORY_BEATS,
    OPERATOR_VIEW_SCHEMA_VERSION,
    InspectionCache,
    collect_change_metrics,
    compose_operator_document,
    load_presentation_topology,
)


NOW = datetime(2026, 8, 1, 12, 0, 0, tzinfo=timezone.utc)


def inspection_fixture(project_path: str | None = None) -> dict[str, object]:
    fleet = []
    if project_path is not None:
        fleet.append(
            {
                "project_id": "project-safe",
                "project_name": "demo",
                "project_path": project_path,
                "roles": ["build"],
                "state": "no_fault_observed",
            }
        )
    return {
        "schema_version": 1,
        "meta": {
            "rule_version": "shipyard-inspect-v1",
            "core_root": "/private/SECRET_CORE",
            "unit_dir": "/private/SECRET_UNITS",
        },
        "summary": {"fleet_state": "degraded_observed", "attention_count": 1},
        "fleet": fleet,
        "effectiveness": [
            {
                "key": "bugs_caught_and_fixed",
                "benchmark_label": "Trial benchmark",
                "target_operator": "gte",
                "target_value": 1,
                "unit": "bugs",
                "state": "partial",
                "value": None,
                "evidence_ids": ["e-safe"],
                "limitations": ["missing_bug_fix_lineage"],
            },
            {
                "key": "features_shipped_end_to_end",
                "benchmark_label": "Trial benchmark",
                "target_operator": "gte",
                "target_value": 1,
                "unit": "projects",
                "state": "measured",
                "value": 2,
                "evidence_ids": ["e-safe"],
                "limitations": [],
            },
        ],
        "priorities": [
            {
                "id": "priority-safe",
                "rank": 1,
                "category": "instrumentation_gap",
                "scope": "shipyard_core",
                "claim_kind": "derived",
                "title": "Close outcome lineage",
                "evidence_ids": ["e-safe"],
                "limitations": [],
            }
        ],
        "attention": [
            {
                "id": "attention-safe",
                "project_id": "project-safe",
                "kind": "open_proposal",
                "title": "SECRET MODEL RESULT BODY",
                "detected_at": "2026-08-01T10:00:00Z",
                "severity_advisory": "high",
                "evidence_ids": ["e-safe"],
                "limitations": ["approval_action_not_persisted"],
            }
        ],
        "coverage": [
            {
                "project_id": "project-safe",
                "source": "events",
                "state": "partial",
                "reason": "parse_gap",
                "records_total": 4,
                "records_valid": 3,
                "limitations": ["SECRET /private/coverage.jsonl"],
            }
        ],
        "evidence": [
            {
                "id": "e-safe",
                "project_id": "project-safe",
                "source": "events",
                "claim_kind": "fact",
                "kind": "job_result",
                "observed_at": "2026-08-01T10:00:00Z",
                "source_ref": "file:/private/SECRET_FILE.jsonl:pointer:/0",
                "fields": {"filename": "SECRET_FILE.jsonl", "message": "SECRET MESSAGE"},
                "limitations": [],
            }
        ],
    }


def relationships_fixture() -> dict[str, object]:
    return {
        "schema_version": 1,
        "kind": "shipyard.operator.relationships",
        "window": "24h",
        "sources": {
            "claude": {
                "provider": "claude",
                "state": "available",
                "coverage": {"state": "complete", "files_scanned": 1},
                "caller_callee": [
                    {
                        "provider": "claude",
                        "bucket": "2026-08-01T10:00:00Z",
                        "caller_id": "actor-safe",
                        "callee_id": "callee-safe",
                        "first_timestamp": "2026-08-01T10:00:00Z",
                        "last_timestamp": "2026-08-01T10:01:00Z",
                        "count": 2,
                        "completion": "completed",
                    }
                ],
                "skill_invocations": [
                    {
                        "provider": "claude",
                        "bucket": "2026-08-01T10:00:00Z",
                        "actor_id": "actor-safe",
                        "skill_id": "execute-ticket",
                        "first_timestamp": "2026-08-01T10:00:00Z",
                        "last_timestamp": "2026-08-01T10:00:00Z",
                        "count": 1,
                    }
                ],
                "limitations": [],
            },
            "codex": {
                "provider": "codex",
                "state": "partial",
                "coverage": {"state": "partial"},
                "caller_callee": [],
                "skill_invocations": [],
                "limitations": [{"code": "skill_marker_coverage_partial", "state": "partial"}],
            },
            "hermes": {
                "provider": "hermes",
                "state": "unknown",
                "coverage": {"state": "unknown"},
                "caller_callee": None,
                "skill_invocations": None,
                "limitations": [{"code": "unsupported_provider", "state": "unknown"}],
            },
        },
    }


def events_fixture(*, base_sha: str | None = None, head_sha: str | None = None) -> list[dict[str, object]]:
    common = {
        "project_id": "project-safe",
        "project": "demo",
        "role": "build",
        "run_id": "a" * 32,
    }
    rows: list[dict[str, object]] = [
        {**common, "ts": "2026-08-01T10:00:00Z", "event": "job.start"},
        {
            **common,
            "ts": "2026-08-01T10:01:00Z",
            "event": "build.work.outcome",
            "work_id": "work-safe",
            "classification": "ATTEMPT",
            "outcome": "pr_opened",
            "commit_sha": head_sha,
            "base_sha": base_sha,
            "head_sha": head_sha,
            "result_path": "/private/SECRET_RESULT.json",
        },
        {
            **common,
            "ts": "2026-08-01T10:02:00Z",
            "event": "job.end",
            "status": "ok",
            "input_tokens": 100,
            "cache_read_tokens": 20,
            "output_tokens": 10,
        },
        {
            "ts": "2026-08-01T10:03:00Z",
            "event": "release.critique",
            "role": "release",
            "critique_id": "b" * 64,
        },
        {
            "ts": "2026-08-01T10:04:00Z",
            "event": "release.critique.delivery",
            "role": "release",
            "critique_id": "b" * 64,
            "disposition": "deposited",
        },
    ]
    return rows


class OperatorComposerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.repo_root = Path(__file__).resolve().parents[2]
        self.topology = load_presentation_topology(self.repo_root / "docs" / "shipyard-data.json")

    def compose(self, **overrides: object) -> dict[str, object]:
        values: dict[str, object] = {
            "window": "24h",
            "generated_at": NOW,
            "summary": {
                "counts": {"healthy": 1, "running": 0, "stale": 0, "failed": 0, "actionable": 0},
                "latest_timestamp": "2026-08-01T10:04:00Z",
                "services": [{"project": "demo", "role": "build", "state": "healthy", "last_activity": "2026-08-01T10:02:00Z"}],
                "actionables": [],
            },
            "events": events_fixture(),
            "inspection": inspection_fixture(),
            "relationships": relationships_fixture(),
            "topology": self.topology,
            "inspection_state": "fresh",
            "refresh_age_seconds": 12,
        }
        values.update(overrides)
        return compose_operator_document(**values)  # type: ignore[arg-type]

    def test_document_is_versioned_bounded_and_unknown_is_not_green(self) -> None:
        document = self.compose()
        self.assertEqual(document["schema_version"], OPERATOR_VIEW_SCHEMA_VERSION)
        self.assertEqual(document["kind"], "shipyard.operator")
        self.assertEqual(document["metadata"]["inspection_state"], "fresh")
        states = {item["id"]: item["state"] for item in document["promises"]}
        self.assertEqual(states["promise:bugs_caught_and_fixed"], "unverified")
        self.assertEqual(states["promise:features_shipped_end_to_end"], "verified")
        self.assertEqual(len(states), 8)
        self.assertLessEqual(len(document["attention"]), MAX_ATTENTION)
        self.assertLessEqual(len(document["evidence"]), MAX_EVIDENCE)
        self.assertLessEqual(len(document["narrative"]["beats"]), MAX_STORY_BEATS)

    def test_nonverified_states_explain_reason_impact_and_action(self) -> None:
        inspection = inspection_fixture()
        inspection["fleet"] = [
            {
                "project_id": "project-safe",
                "project_name": "demo",
                "roles": ["build"],
                "state": "no_fault_observed",
            }
        ]
        runtime_events = [
            {
                "project": "demo",
                "role": "build",
                "svc": "demo-helldiver",
                "ts": "2026-08-01T10:00:00Z",
                "event": "job.start",
            },
            {
                "project": "demo",
                "role": "build",
                "svc": "demo-helldiver",
                "ts": "2026-08-01T10:01:00Z",
                "event": "job.end",
                "status": "abort",
                "reason": "dirty",
            },
        ]

        document = self.compose(
            summary={
                "counts": {"healthy": 0, "running": 0, "stale": 0, "failed": 0, "actionable": 0},
                "latest_timestamp": "2026-08-01T10:01:00Z",
                "services": [
                    {
                        "project": "demo",
                        "role": "build",
                        "svc": "demo-helldiver",
                        "state": "unknown",
                        "last_activity": "2026-08-01T10:01:00Z",
                        "terminal_status": "abort",
                        "terminal_reason": "dirty",
                    }
                ],
                "actionables": [],
            },
            inspection=inspection,
            runtime_events=runtime_events,
        )

        for promise in document["promises"]:
            if promise["state"] != "verified":
                self.assertRegex(promise["reason_code"], r"^[a-z0-9_]+$")
                self.assertTrue(promise["reason"])
                self.assertTrue(promise["impact"])
                self.assertTrue(promise["action"])
        runtime = next(node for node in document["topology"]["runtime_nodes"] if node["project_id"] == "project-safe")
        self.assertEqual((runtime["terminal_status"], runtime["terminal_reason"]), ("abort", "dirty"))
        self.assertEqual(runtime["reason_code"], "recorded_early_stop")
        self.assertIn("not an outage", runtime["impact"].lower())
        self.assertNotIn("dirty", runtime["reason"].lower())

    def test_project_role_runtime_survives_global_event_cap(self) -> None:
        inspection = inspection_fixture()
        inspection["fleet"] = [
            {
                "project_id": "project-safe",
                "project_name": "demo",
                "roles": ["build"],
                "state": "no_fault_observed",
            },
            {
                "project_id": "project-other",
                "project_name": "other",
                "roles": ["medic"],
                "state": "no_fault_observed",
            },
        ]
        unrelated = [
            {
                "project": "other",
                "role": "medic",
                "svc": "other-suk",
                "ts": f"2026-08-01T11:{index // 60:02d}:{index % 60:02d}Z",
                "event": "medic.scan",
            }
            for index in range(2_000)
        ]
        runtime_events = [
            {
                "project": "demo",
                "role": "build",
                "svc": "demo-helldiver",
                "ts": "2026-08-01T10:00:00Z",
                "event": "job.start",
            },
            {
                "project": "demo",
                "role": "build",
                "svc": "demo-helldiver",
                "ts": "2026-08-01T10:01:00Z",
                "event": "job.end",
                "status": "abort",
                "reason": "dirty",
            },
        ]
        document = self.compose(
            events=unrelated,
            inspection=inspection,
            runtime_events=runtime_events,
            event_stream_truncated=True,
        )

        runtime = next(node for node in document["topology"]["runtime_nodes"] if node["project_id"] == "project-safe")
        self.assertEqual(runtime["observed_count"], 2)
        self.assertEqual(runtime["last_activity"], "2026-08-01T10:01:00Z")
        self.assertEqual((runtime["terminal_status"], runtime["terminal_reason"]), ("abort", "dirty"))
        self.assertEqual(runtime["evidence_count"], 2)
        evidence = {row["id"]: row for row in document["evidence"]}
        self.assertTrue(
            all(evidence[evidence_id]["project_id"] == "project-safe" for evidence_id in runtime["evidence_ids"])
        )
        other = next(node for node in document["topology"]["runtime_nodes"] if node["project_id"] == "project-other")
        self.assertFalse(set(other["evidence_ids"]) & set(runtime["evidence_ids"]))

    def test_scope_separates_fleet_projects_event_coverage_and_unattributed(self) -> None:
        inspection = inspection_fixture()
        inspection["fleet"] = [
            {
                "project_id": "project-safe",
                "project_name": "demo",
                "roles": ["build"],
                "state": "no_fault_observed",
            },
            {
                "project_id": "project-other",
                "project_name": "other",
                "roles": ["medic"],
                "state": "degraded_observed",
            },
        ]
        inspection["coverage"] = [
            {
                "project_id": "project-safe",
                "source": "events",
                "state": "available",
                "reason": "ok",
                "records_total": 4,
                "records_valid": 4,
                "records_invalid": 0,
                "records_out_of_window": 0,
                "limitations": [],
            },
            {
                "project_id": "project-other",
                "source": "events",
                "state": "partial",
                "reason": "malformed",
                "records_total": 7,
                "records_valid": 5,
                "records_invalid": 2,
                "records_out_of_window": 0,
                "limitations": [],
            },
            {
                "project_id": None,
                "source": "events_attribution",
                "state": "available",
                "reason": "ok",
                "records_total": 20,
                "records_valid": 11,
                "records_unattributed": 8,
                "records_ambiguous": 1,
                "records_out_of_window": 0,
                "limitations": [],
            },
        ]

        scope = self.compose(inspection=inspection)["metadata"]["scope"]
        self.assertEqual((scope["kind"], scope["label"]), ("current_user_fleet", "Current-user Shipyard fleet"))
        self.assertEqual(
            [(row["project_id"], row["project_label"]) for row in scope["projects"]],
            [("project-safe", "demo"), ("project-other", "other")],
        )
        by_project = {row["project_id"]: row for row in scope["projects"]}
        self.assertEqual(by_project["project-safe"]["events"]["records_valid"], 4)
        self.assertEqual(by_project["project-other"]["events"]["records_invalid"], 2)
        self.assertEqual(scope["unattributed"]["records_unattributed"], 8)
        self.assertEqual(scope["unattributed"]["records_ambiguous"], 1)
        self.assertNotIn("event_root", json.dumps(scope))

    def test_fleet_role_reduction_uses_only_installed_project_constituents(self) -> None:
        inspection = inspection_fixture()
        inspection["fleet"] = [
            {
                "project_id": "project-alpha",
                "project_name": "alpha",
                "roles": ["build"],
                "state": "no_fault_observed",
            },
            {
                "project_id": "project-beta",
                "project_name": "beta",
                "roles": ["build"],
                "state": "degraded_observed",
            },
        ]
        summary = {
            "counts": {"healthy": 1, "running": 0, "stale": 1, "failed": 2, "actionable": 0},
            "latest_timestamp": "2026-08-01T11:01:00Z",
            "services": [
                {"project": "alpha", "role": "build", "svc": "alpha-build", "state": "healthy", "last_activity": "2026-08-01T10:01:00Z"},
                {"project": "beta", "role": "build", "svc": "beta-build", "state": "stale", "last_activity": "2026-08-01T10:02:00Z"},
                {"project": "outside", "role": "build", "svc": "outside-build", "state": "failed", "last_activity": "2026-08-01T11:00:00Z"},
                {"project": None, "role": "build", "svc": "unattributed-build", "state": "failed", "last_activity": "2026-08-01T11:01:00Z"},
            ],
            "actionables": [],
        }
        runtime_events = [
            {"project_id": "project-alpha", "project": "alpha", "role": "build", "svc": "alpha-build", "ts": "2026-08-01T10:01:00Z", "event": "job.end", "status": "ok"},
            {"project_id": "project-beta", "project": "beta", "role": "build", "svc": "beta-build", "ts": "2026-08-01T10:02:00Z", "event": "job.start"},
            {"project": "outside", "role": "build", "svc": "outside-build", "ts": "2026-08-01T11:00:00Z", "event": "job.end", "status": "fail"},
            {"role": "build", "svc": "unattributed-build", "ts": "2026-08-01T11:01:00Z", "event": "job.end", "status": "fail"},
        ]

        document = self.compose(inspection=inspection, summary=summary, runtime_events=runtime_events)
        role = next(node for node in document["topology"]["nodes"] if node["id"] == "role:build")
        constituents = [
            node for node in document["topology"]["runtime_nodes"] if node["role_id"] == "build"
        ]
        constituent_ids = [node["project_id"] for node in constituents]
        expected_state = min(
            (node["state"] for node in constituents),
            key={"failed": 0, "stale": 1, "running": 2, "healthy": 3, "unknown": 4}.__getitem__,
        )

        self.assertEqual(constituent_ids, ["project-alpha", "project-beta"])
        self.assertEqual(role["constituent_projects"], constituent_ids)
        self.assertEqual(role["reduction_rule"], "worst_known_state_unknown_if_none")
        self.assertEqual(role["state"], expected_state)
        self.assertEqual(role["observed_count"], sum(node["observed_count"] for node in constituents))
        self.assertEqual(role["last_activity"], "2026-08-01T10:02:00Z")
        self.assertEqual(
            set(role["evidence_ids"]),
            {evidence_id for node in constituents for evidence_id in node["evidence_ids"]},
        )

    def test_failed_runtime_is_not_reclassified_by_newer_abort(self) -> None:
        inspection = inspection_fixture()
        inspection["fleet"] = [
            {
                "project_id": "project-safe",
                "project_name": "demo",
                "roles": ["build"],
                "state": "degraded_observed",
            }
        ]
        summary = {
            "counts": {"healthy": 0, "running": 0, "stale": 0, "failed": 1, "actionable": 1},
            "latest_timestamp": "2026-08-01T10:03:00Z",
            "services": [
                {
                    "project": "demo",
                    "role": "build",
                    "svc": "demo-failed",
                    "state": "failed",
                    "last_activity": "2026-08-01T10:01:00Z",
                    "terminal_status": "fail",
                    "terminal_reason": None,
                },
                {
                    "project": "demo",
                    "role": "build",
                    "svc": "demo-aborted",
                    "state": "unknown",
                    "last_activity": "2026-08-01T10:03:00Z",
                    "terminal_status": "abort",
                    "terminal_reason": "dirty",
                },
            ],
            "actionables": [],
        }
        runtime_events = [
            {"project_id": "project-safe", "project": "demo", "role": "build", "svc": "demo-failed", "ts": "2026-08-01T10:01:00Z", "event": "job.end", "status": "fail"},
            {"project_id": "project-safe", "project": "demo", "role": "build", "svc": "demo-aborted", "ts": "2026-08-01T10:03:00Z", "event": "job.end", "status": "abort", "reason": "dirty"},
        ]

        document = self.compose(inspection=inspection, summary=summary, runtime_events=runtime_events)
        runtime = next(node for node in document["topology"]["runtime_nodes"] if node["project_id"] == "project-safe")

        self.assertEqual(runtime["state"], "failed")
        self.assertEqual(runtime["reason_code"], "runtime_failed")
        self.assertNotEqual(runtime["reason_code"], "recorded_early_stop")
        self.assertNotIn("not an outage", runtime["impact"].lower())
        self.assertEqual(runtime["terminal_status"], "fail")
        self.assertIsNone(runtime["terminal_reason"])

    def test_project_runtime_evidence_is_coherent_with_controlling_service(self) -> None:
        inspection = inspection_fixture()
        inspection["fleet"] = [
            {
                "project_id": "project-safe",
                "project_name": "demo",
                "roles": ["build"],
                "state": "degraded_observed",
            }
        ]
        sibling_events = [
            {
                "project_id": "project-safe",
                "project": "demo",
                "role": "build",
                "svc": "demo-aaa-sibling",
                "ts": f"2026-08-01T10:00:{index:02d}Z",
                "event": "job.start",
            }
            for index in range(MAX_RUNTIME_EVENTS_PER_NODE + 1)
        ]
        controlling_event = {
            "project_id": "project-safe",
            "project": "demo",
            "role": "build",
            "svc": "demo-zzz-controlling",
            "ts": "2026-08-01T10:59:00Z",
            "event": "job.end",
            "status": "fail",
        }
        summary = {
            "counts": {"healthy": 1, "running": 0, "stale": 0, "failed": 1, "actionable": 1},
            "latest_timestamp": controlling_event["ts"],
            "services": [
                {
                    "project": "demo",
                    "role": "build",
                    "svc": "demo-aaa-sibling",
                    "state": "healthy",
                    "last_activity": sibling_events[-1]["ts"],
                    "terminal_status": None,
                    "terminal_reason": None,
                },
                {
                    "project": "demo",
                    "role": "build",
                    "svc": "demo-zzz-controlling",
                    "state": "failed",
                    "last_activity": controlling_event["ts"],
                    "terminal_status": "fail",
                    "terminal_reason": None,
                },
            ],
            "actionables": [],
        }

        document = self.compose(
            inspection=inspection,
            summary=summary,
            runtime_events=[*sibling_events, controlling_event],
        )
        runtime = next(
            node
            for node in document["topology"]["runtime_nodes"]
            if node["project_id"] == "project-safe" and node["role_id"] == "build"
        )
        expected_id = "event:" + hashlib.sha256(
            json.dumps(
                controlling_event,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        ).hexdigest()[:20]

        self.assertEqual(runtime["state"], "failed")
        self.assertEqual((runtime["terminal_status"], runtime["terminal_reason"]), ("fail", None))
        self.assertEqual(runtime["last_activity"], controlling_event["ts"])
        self.assertEqual(runtime["observed_count"], 1)
        self.assertEqual(runtime["evidence_count"], 1)
        self.assertEqual(runtime["evidence_ids"], [expected_id])
        self.assertEqual(runtime["reason_code"], "runtime_failed")
        linked = {row["id"]: row for row in document["evidence"]}
        self.assertEqual(linked[expected_id]["observed_at"], controlling_event["ts"])
        self.assertEqual(linked[expected_id]["fields"]["status"], "fail")

    def test_duplicate_project_labels_require_explicit_project_id(self) -> None:
        inspection = inspection_fixture()
        inspection["fleet"] = [
            {"project_id": "project-first", "project_name": "duplicate", "roles": ["build"], "state": "no_fault_observed"},
            {"project_id": "project-second", "project_name": "duplicate", "roles": ["build"], "state": "no_fault_observed"},
        ]
        runtime_events = [
            {"project_id": "project-first", "project": "duplicate", "role": "build", "svc": "explicit-build", "ts": "2026-08-01T10:00:00Z", "event": "job.end", "status": "ok"},
            {"project": "duplicate", "role": "build", "svc": "ambiguous-build", "ts": "2026-08-01T10:01:00Z", "event": "job.end", "status": "fail"},
        ]

        document = self.compose(
            inspection=inspection,
            summary={
                "counts": {"healthy": 0, "running": 0, "stale": 0, "failed": 0, "actionable": 0},
                "latest_timestamp": "2026-08-01T10:01:00Z",
                "services": [],
                "actionables": [],
            },
            runtime_events=runtime_events,
        )
        by_project = {
            node["project_id"]: node
            for node in document["topology"]["runtime_nodes"]
            if node["role_id"] == "build"
        }

        self.assertEqual(by_project["project-first"]["observed_count"], 1)
        self.assertEqual(by_project["project-first"]["state"], "healthy")
        self.assertEqual(by_project["project-second"]["observed_count"], 0)
        self.assertEqual(by_project["project-second"]["state"], "unknown")
        self.assertFalse(by_project["project-second"]["evidence_ids"])

    def test_brief_preserves_controlled_action_and_qualified_counts(self) -> None:
        inspection = inspection_fixture()
        evidence_ids = [f"failure-{index}" for index in range(18)]
        inspection["summary"] = {"fleet_state": "degraded_observed", "attention_count": 18}
        inspection["priorities"] = [
            {
                "id": "priority-core-job-failure",
                "rank": 1,
                "category": "confirmed_failure",
                "scope": "shipyard_core",
                "claim_kind": "fact",
                "rule_id": "core_job_failure_v1",
                "title": "Repair observed Shipyard core job failure",
                "project_ids": ["project-safe"],
                "evidence_count": 18,
                "newest_ts": "2026-08-01T10:00:00Z",
                "evidence_ids": evidence_ids,
                "operands": {"failure_records": 18},
                "limitations": [],
            }
        ]
        inspection["attention"] = []
        inspection["evidence"] = [
            {
                "id": evidence_id,
                "project_id": "project-safe",
                "source": "events",
                "kind": "job_result",
                "observed_at": "2026-08-01T10:00:00Z",
                "limitations": [],
            }
            for evidence_id in evidence_ids
        ]

        document = self.compose(inspection=inspection)
        brief = document["brief"]
        self.assertEqual(brief["takeaway"], "Repair observed Shipyard core job failure")
        self.assertEqual(brief["action"], "Repair 18 observed Shipyard job failures")
        attention_signal = next(row for row in brief["signals"] if row["id"] == "attention")
        self.assertEqual(
            (attention_signal["value"], attention_signal["unit"], attention_signal["observed"], attention_signal["total"]),
            (1, "group", 1, 1),
        )
        group = brief["attention_groups"][0]
        self.assertEqual(group["label"], "Repair observed Shipyard core job failure")
        self.assertEqual(group["action"], "Repair 18 observed Shipyard job failures")
        self.assertEqual((group["item_count"], group["evidence_count"], group["project_count"]), (1, 18, 1))

    def test_brief_groups_attention_without_losing_evidence(self) -> None:
        inspection = inspection_fixture()
        evidence_ids = [f"failure-{index}" for index in range(20)]
        inspection["summary"] = {"fleet_state": "degraded_observed", "attention_count": 10}
        inspection["priorities"] = [
            {
                "id": f"priority-core-job-failure-{index}",
                "rank": index + 1,
                "category": "confirmed_failure",
                "scope": "shipyard_core",
                "claim_kind": "fact",
                "rule_id": "core_job_failure_v1",
                "title": "Repair observed Shipyard core job failure",
                "project_ids": ["project-safe"],
                "evidence_count": 2,
                "newest_ts": f"2026-08-01T10:{index:02d}:00Z",
                "evidence_ids": evidence_ids[index * 2 : index * 2 + 2],
                "operands": {"failure_records": 2},
                "limitations": [],
            }
            for index in range(10)
        ]
        inspection["attention"] = []
        inspection["evidence"] = [
            {
                "id": evidence_id,
                "project_id": "project-safe",
                "source": "events",
                "kind": "job_result",
                "observed_at": "2026-08-01T10:00:00Z",
                "limitations": [],
            }
            for evidence_id in evidence_ids
        ]

        document = self.compose(inspection=inspection)
        self.assertEqual(len(document["attention"]), 10)
        self.assertEqual(len(document["brief"]["attention_groups"]), 1)
        group = document["brief"]["attention_groups"][0]
        self.assertEqual((group["item_count"], group["evidence_count"]), (10, 20))
        self.assertEqual(group["evidence_ids"], evidence_ids)
        self.assertTrue(set(group["evidence_ids"]).issubset({row["id"] for row in document["evidence"]}))

    def test_response_redacts_paths_filenames_messages_and_result_prose(self) -> None:
        encoded = json.dumps(self.compose(), sort_keys=True)
        for forbidden in (
            "/private/",
            "SECRET_CORE",
            "SECRET_FILE",
            ".jsonl",
            "SECRET MESSAGE",
            "SECRET MODEL RESULT BODY",
            "SECRET_RESULT",
            "source_ref",
            "project_path",
        ):
            self.assertNotIn(forbidden, encoded)

    def test_topology_preserves_declared_order_and_adds_observed_evidence(self) -> None:
        document = self.compose()
        expected_roles = [item["id"] for item in self.topology["roles"] if item["id"] != "human"]
        actual_roles = [item["id"].removeprefix("role:") for item in document["topology"]["nodes"] if item["kind"] == "role"]
        self.assertEqual(actual_roles, expected_roles)
        human = next(item for item in document["topology"]["nodes"] if item["id"] == "role:human")
        self.assertEqual((human["kind"], human["state"]), ("human", "declared"))
        skill = next(item for item in document["topology"]["nodes"] if item["id"] == "skill:execute-ticket")
        self.assertEqual(skill["observed_count"], 1)
        self.assertTrue(skill["evidence_ids"])
        observed = document["topology"]["observed_edges"]
        self.assertEqual(observed[0]["count"], 2)
        self.assertEqual(observed[0]["completion"], "completed")

    def test_run_outcomes_tokens_and_shoulder_delivery_use_explicit_ids(self) -> None:
        outcomes = self.compose()["outcomes"]
        self.assertEqual(outcomes["reliability"]["completed"], 1)
        self.assertEqual(outcomes["reliability"]["successful"], 1)
        self.assertEqual(outcomes["efficiency"]["input_tokens"], 100)
        self.assertEqual(outcomes["efficiency"]["output_tokens"], 10)
        self.assertEqual(outcomes["shoulder"]["deposited"], 1)
        self.assertEqual(outcomes["chains"][0]["run_id"], "a" * 32)
        self.assertEqual(outcomes["chains"][0]["state"], "complete")

    def test_feature_lineage_crosses_runs_only_through_explicit_upstream_id(self) -> None:
        events = events_fixture()
        events.extend(
            [
                {
                    "ts": "2026-08-01T09:00:00Z",
                    "event": "design.proposal",
                    "role": "design",
                    "proposal_id": "proposal-safe",
                    "type": "feature",
                },
                {
                    "ts": "2026-08-01T11:00:00Z",
                    "event": "build.ticket.outcome",
                    "role": "build",
                    "work_id": "ticket-safe",
                    "upstream_work_id": "proposal-safe",
                    "outcome": "ok",
                },
            ]
        )
        lineages = self.compose(events=events)["outcomes"]["lineages"]
        feature = next(item for item in lineages if "proposal-safe" in item["identifiers"])
        self.assertEqual((feature["kind"], feature["state"]), ("feature", "complete"))
        self.assertEqual(feature["identifiers"], ["proposal-safe", "ticket-safe"])

    def test_composer_is_pure_and_does_not_execute_git(self) -> None:
        with mock.patch("dashboard.operator.subprocess.run", side_effect=AssertionError("I/O in composer")):
            first = self.compose()
            second = self.compose()
        self.assertEqual(first, second)

    def test_explicit_valid_git_range_returns_aggregates_without_names(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@example.invalid"], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.name", "Test"], check=True)
            (repo / "app.txt").write_text("one\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(repo), "add", "app.txt"], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-qm", "base"], check=True)
            base = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
            (repo / "app.txt").write_text("one\ntwo\n", encoding="utf-8")
            (repo / "tests").mkdir()
            (repo / "tests" / "test_app.txt").write_text("ok\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(repo), "add", "app.txt", "tests/test_app.txt"], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-qm", "head"], check=True)
            head = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
            inspection = inspection_fixture(str(repo))
            events = events_fixture(base_sha=base, head_sha=head)
            changes, limitations = collect_change_metrics(events, inspection)
            document = self.compose(
                inspection=inspection,
                events=events,
                changes=changes,
                change_limitations=limitations,
            )
            self.assertEqual(document["changes"][0]["additions"], 2)
            self.assertEqual(document["changes"][0]["deletions"], 0)
            self.assertEqual(document["changes"][0]["files_touched"], 2)
            self.assertEqual(document["changes"][0]["commits"], 1)
            self.assertEqual(document["changes"][0]["buckets"], {"product": 1, "test": 1, "docs": 0})
            encoded = json.dumps(document["changes"])
            self.assertNotIn("app.txt", encoded)
            self.assertNotIn(str(repo), encoded)

    def test_missing_or_reversed_git_range_is_limited_not_guessed(self) -> None:
        missing = self.compose()
        self.assertEqual(missing["changes"], [])
        self.assertIn("explicit_git_range_unavailable", missing["metadata"]["limitations"])

    def test_git_timeout_is_an_invalid_range_limitation(self) -> None:
        inspection = inspection_fixture(str(self.repo_root))
        events = events_fixture(base_sha="1" * 40, head_sha="2" * 40)
        with mock.patch(
            "dashboard.operator._git",
            side_effect=subprocess.TimeoutExpired(["git"], 5),
        ):
            changes, limitations = collect_change_metrics(events, inspection)
        self.assertEqual(changes, [])
        self.assertEqual(limitations, ["invalid_git_range"])

    def test_unavailable_inspection_retains_declared_topology_and_unknowns(self) -> None:
        document = self.compose(
            inspection=None,
            relationships=None,
            inspection_state="unavailable",
            refresh_age_seconds=None,
        )
        self.assertEqual(len(document["promises"]), 8)
        self.assertTrue(all(item["state"] == "unverified" for item in document["promises"]))
        self.assertTrue(document["topology"]["nodes"])
        self.assertTrue(all(item["state"] in {"unknown", "healthy"} for item in document["topology"]["nodes"] if item["kind"] == "role"))
        self.assertIn("inspection_unavailable", document["metadata"]["limitations"])

    def test_truncated_event_window_marks_every_denominator_partial(self) -> None:
        document = self.compose(event_stream_truncated=True)
        self.assertEqual(document["outcomes"]["reliability"]["state"], "partial")
        self.assertEqual(document["outcomes"]["role_contracts"][0]["state"], "partial")
        self.assertEqual(document["outcomes"]["efficiency"]["state"], "partial")
        self.assertEqual(document["outcomes"]["shoulder"]["state"], "partial")
        self.assertIn("event_window_truncated", document["metadata"]["limitations"])
        event_coverage = next(item for item in document["coverage"] if item["source"] == "operator_events")
        self.assertEqual(event_coverage["state"], "partial")

    def test_attention_evidence_and_story_bounds_have_no_dangling_links(self) -> None:
        inspection = inspection_fixture()
        inspection["priorities"] = [
            {
                "id": f"priority-{index}",
                "rank": index + 1,
                "category": "instrumentation_gap",
                "scope": "shipyard_core",
                "claim_kind": "derived",
                "rule_id": "cross_project_coverage_gap_v1",
                "evidence_ids": [f"evidence-{index}"],
                "limitations": [],
            }
            for index in range(MAX_ATTENTION + 10)
        ]
        inspection["evidence"] = [
            {
                "id": f"evidence-{index}",
                "source": "events",
                "kind": "counter",
                "observed_at": "2026-08-01T10:00:00Z",
                "limitations": [],
            }
            for index in range(MAX_EVIDENCE + 100)
        ]
        document = self.compose(inspection=inspection)
        self.assertEqual(len(document["attention"]), MAX_ATTENTION)
        self.assertEqual(len(document["evidence"]), MAX_EVIDENCE)
        self.assertLessEqual(len(document["narrative"]["beats"]), MAX_STORY_BEATS)
        evidence_ids = {item["id"] for item in document["evidence"]}

        def assert_links(value: object) -> None:
            if isinstance(value, dict):
                if "evidence_ids" in value:
                    self.assertTrue(set(value["evidence_ids"]).issubset(evidence_ids))
                for child in value.values():
                    assert_links(child)
            elif isinstance(value, list):
                for child in value:
                    assert_links(child)

        assert_links(document)
        bounds = next(item for item in document["coverage"] if item["source"] == "operator_bounds")
        self.assertEqual(bounds["state"], "partial")


class OperatorFixtureContractTest(unittest.TestCase):
    EXPECTED_PROMISE_IDS = [
        "promise:bugs_caught_and_fixed",
        "promise:usage_assessed_projects",
        "promise:features_shipped_end_to_end",
        "promise:consequential_decisions_surfaced",
        "promise:critique_actionability",
        "promise:execute_ticket_delegation_claude",
        "promise:execute_ticket_delegation_codex",
        "promise:execute_ticket_delegation_hermes",
    ]

    def setUp(self) -> None:
        fixture = Path(__file__).with_name("fixtures") / "operator-v1.json"
        self.document = json.loads(fixture.read_text(encoding="utf-8"))

    def test_fixture_exposes_the_additive_schema_v1_adapter_surface(self) -> None:
        required = {
            "schema_version",
            "kind",
            "metadata",
            "brief",
            "narrative",
            "promises",
            "outcomes",
            "topology",
            "changes",
            "attention",
            "coverage",
            "evidence",
        }
        self.assertTrue(required.issubset(self.document))
        self.assertEqual(self.document["schema_version"], 1)
        self.assertEqual(self.document["kind"], "shipyard.operator")
        self.assertEqual(self.document["metadata"]["schema_version"], 1)
        self.assertRegex(self.document["metadata"]["source_revision"], r"^[0-9a-f]{40}$")
        self.assertIn(self.document["metadata"]["source_state"], {"clean", "modified", "unknown"})
        self.assertRegex(self.document["metadata"]["source_digest"], r"^[0-9a-f]{64}$")
        scope = self.document["metadata"]["scope"]
        self.assertEqual(scope["kind"], "current_user_fleet")
        self.assertTrue(scope["projects"])
        self.assertIn("unattributed", scope)
        self.assertIn(self.document["metadata"]["window"], {"24h", "7d", "30d"})
        self.assertEqual(
            self.document["metadata"]["limits"],
            {"attention": MAX_ATTENTION, "evidence": MAX_EVIDENCE, "story_beats": MAX_STORY_BEATS},
        )
        self.assertLessEqual(len(self.document["attention"]), MAX_ATTENTION)
        self.assertLessEqual(len(self.document["evidence"]), MAX_EVIDENCE)
        self.assertLessEqual(len(self.document["narrative"]["beats"]), MAX_STORY_BEATS)

    def test_fixture_has_stable_promises_and_only_public_state_enums(self) -> None:
        self.assertEqual(
            [row["id"] for row in self.document["promises"]],
            self.EXPECTED_PROMISE_IDS,
        )
        self.assertTrue(
            {row["state"] for row in self.document["promises"]}
            <= {"verified", "violated", "unverified", "not_applicable"}
        )
        for row in self.document["promises"]:
            self.assertTrue(all(row[key] for key in ("reason_code", "reason", "impact", "action")))
        self.assertIn(
            self.document["metadata"]["inspection_state"],
            {"fresh", "stale", "unavailable"},
        )
        self.assertTrue(
            {row["state"] for row in self.document["narrative"]["beats"]}
            <= {"clear", "waiting", "alarm", "signal", "unknown"}
        )
        self.assertTrue(
            {row["state"] for row in self.document["attention"]}
            <= {"clear", "waiting", "alarm", "signal", "unknown"}
        )
        self.assertTrue(
            {row["state"] for row in self.document["coverage"]}
            <= {"available", "partial", "unavailable", "unknown"}
        )
        outcomes = self.document["outcomes"]
        self.assertTrue(
            {
                outcomes["reliability"]["state"],
                outcomes["operator_load"]["state"],
                outcomes["efficiency"]["state"],
                outcomes["shoulder"]["state"],
                *(row["state"] for row in outcomes["role_contracts"]),
            }
            <= {"measured", "partial", "unknown"}
        )
        self.assertTrue(
            {row["state"] for row in outcomes["chains"]}
            <= {"complete", "incomplete"}
        )
        self.assertTrue(
            {row["state"] for row in outcomes["lineages"]}
            <= {"complete", "unverified"}
        )

    def test_fixture_evidence_links_and_topology_endpoints_are_closed(self) -> None:
        evidence_ids = [row["id"] for row in self.document["evidence"]]
        self.assertEqual(len(evidence_ids), len(set(evidence_ids)))
        known_evidence = set(evidence_ids)

        def assert_evidence_links(value: object) -> None:
            if isinstance(value, dict):
                if "evidence_ids" in value:
                    self.assertTrue(set(value["evidence_ids"]).issubset(known_evidence))
                for child in value.values():
                    assert_evidence_links(child)
            elif isinstance(value, list):
                for child in value:
                    assert_evidence_links(child)

        assert_evidence_links(self.document)
        nodes = self.document["topology"]["nodes"]
        node_ids = {node["id"] for node in nodes}
        self.assertEqual(len(node_ids), len(nodes))
        for edge in (
            self.document["topology"]["declared_edges"]
            + self.document["topology"]["observed_edges"]
        ):
            self.assertIn(edge["from"], node_ids)
            self.assertIn(edge["to"], node_ids)
        edge_ids = [
            edge["id"]
            for edge in (
                self.document["topology"]["declared_edges"]
                + self.document["topology"]["observed_edges"]
            )
        ]
        self.assertEqual(len(edge_ids), len(set(edge_ids)))
        self.assertTrue(
            {edge["state"] for edge in self.document["topology"]["declared_edges"]}
            <= {"declared"}
        )
        self.assertTrue(
            {edge["state"] for edge in self.document["topology"]["observed_edges"]}
            <= {"observed"}
        )
        self.assertTrue(
            {node["state"] for node in nodes}
            <= {"declared", "healthy", "running", "stale", "failed", "unknown", "observed"}
        )
        runtime_nodes = self.document["topology"]["runtime_nodes"]
        self.assertTrue(runtime_nodes)
        self.assertTrue(all(node["scope"]["kind"] == "project" for node in runtime_nodes))
        self.assertTrue(
            all(all(node[key] for key in ("reason_code", "reason", "impact", "action")) for node in runtime_nodes)
        )
        self.assertTrue(
            {row["durability"] for row in self.document["changes"]} <= {"unknown"}
        )

    def test_fixture_recursively_excludes_private_content_and_raw_history(self) -> None:
        brief = self.document["brief"]
        self.assertLessEqual(len(brief["signals"]), 4)
        self.assertLessEqual(len(brief["attention_groups"]), 8)
        self.assertEqual(
            set(brief),
            {"state", "takeaway", "action", "signals", "attention_groups", "limitations"},
        )
        forbidden_keys = {
            "path",
            "paths",
            "file_path",
            "project_path",
            "source_ref",
            "filename",
            "filenames",
            "prompt",
            "prompts",
            "message",
            "messages",
            "diff",
            "diffs",
            "result",
            "results",
            "result_body",
            "critique_body",
            "critique_text",
            "critique_prose",
            "transcript_path",
            "raw_jsonl",
        }
        forbidden_fragments = (
            "/home/",
            "/users/",
            "/private/",
            ".jsonl",
            "diff --git",
            "result body",
            "critique prose",
            "begin private key",
        )

        def assert_safe(value: object) -> None:
            if isinstance(value, dict):
                self.assertFalse(forbidden_keys & set(value))
                for child in value.values():
                    assert_safe(child)
            elif isinstance(value, list):
                for child in value:
                    assert_safe(child)
            elif isinstance(value, str):
                lowered = value.lower()
                self.assertFalse(any(fragment in lowered for fragment in forbidden_fragments))
                self.assertFalse(value.startswith(("/", "~", "\\")))
                self.assertIsNone(re.match(r"^[A-Za-z]:[\\/]", value))
                self.assertFalse(
                    lowered.endswith((".py", ".js", ".md", ".json", ".jsonl", ".toml", ".sh"))
                )

        assert_safe(self.document)


class InspectionCacheTest(unittest.TestCase):
    def test_cold_refresh_is_background_single_flight_then_fresh(self) -> None:
        entered = threading.Event()
        release = threading.Event()
        calls: list[str] = []

        def loader(window: str) -> dict[str, object]:
            calls.append(window)
            entered.set()
            self.assertTrue(release.wait(2))
            return {"inspection": {"ok": True}, "relationships": {"ok": True}}

        cache = InspectionCache(loader, ttl_seconds=300)
        first = cache.get("24h")
        self.assertEqual(first.state, "unavailable")
        self.assertTrue(entered.wait(1))
        second = cache.get("24h")
        self.assertEqual(second.state, "unavailable")
        self.assertEqual(calls, ["24h"])
        release.set()
        for _ in range(100):
            result = cache.get("24h")
            if result.state == "fresh":
                break
            time.sleep(0.01)
        self.assertEqual(result.state, "fresh")
        self.assertEqual(calls, ["24h"])

    def test_expired_last_good_is_stale_while_failed_refresh_preserves_it(self) -> None:
        now = [0.0]
        release = threading.Event()
        calls = 0

        def loader(_window: str) -> dict[str, object]:
            nonlocal calls
            calls += 1
            if calls == 1:
                return {"inspection": {"version": 1}, "relationships": None}
            self.assertTrue(release.wait(2))
            raise RuntimeError("SECRET loader path /private/failure")

        cache = InspectionCache(loader, ttl_seconds=5, monotonic=lambda: now[0])
        cache.get("7d")
        for _ in range(100):
            fresh = cache.get("7d")
            if fresh.state == "fresh":
                break
            time.sleep(0.01)
        self.assertEqual(fresh.data["inspection"]["version"], 1)
        now[0] = 6.0
        stale = cache.get("7d")
        self.assertEqual(stale.state, "stale")
        release.set()
        for _ in range(100):
            stale = cache.get("7d")
            if stale.limitation == "inspection_refresh_failed":
                break
            time.sleep(0.01)
        self.assertEqual(stale.state, "stale")
        self.assertEqual(stale.data["inspection"]["version"], 1)
        self.assertNotIn("SECRET", stale.limitation)

    def test_different_windows_share_one_global_expensive_flight(self) -> None:
        entered = threading.Event()
        release = threading.Event()
        calls: list[str] = []

        def loader(window: str) -> dict[str, object]:
            calls.append(window)
            entered.set()
            self.assertTrue(release.wait(2))
            return {"inspection": None, "relationships": None}

        cache = InspectionCache(loader)
        self.assertEqual(cache.get("24h").state, "unavailable")
        self.assertTrue(entered.wait(1))
        self.assertEqual(cache.get("7d").state, "unavailable")
        self.assertEqual(calls, ["24h"])
        release.set()
        for _ in range(100):
            if cache.get("24h").state == "fresh":
                break
            time.sleep(0.01)
        second = cache.get("7d")
        self.assertEqual(second.state, "unavailable")
        for _ in range(100):
            if calls == ["24h", "7d"]:
                break
            time.sleep(0.01)
        self.assertEqual(calls, ["24h", "7d"])


if __name__ == "__main__":
    unittest.main()
