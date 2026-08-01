from __future__ import annotations

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
        self.assertTrue(
            {row["durability"] for row in self.document["changes"]} <= {"unknown"}
        )

    def test_fixture_recursively_excludes_private_content_and_raw_history(self) -> None:
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
