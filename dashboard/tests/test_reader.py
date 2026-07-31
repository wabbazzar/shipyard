from __future__ import annotations

import hashlib
import json
import tempfile
import threading
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from dashboard.reader import EventReader, MAX_LIMIT, StaleReferenceError


NOW = datetime(2026, 7, 31, 12, 0, 0, tzinfo=timezone.utc)


def event(ts: datetime, name: str, **fields: object) -> dict[str, object]:
    timespec = "microseconds" if ts.microsecond else "seconds"
    value: dict[str, object] = {
        "ts": ts.isoformat(timespec=timespec).replace("+00:00", "Z"),
        "svc": fields.pop("svc", "alpha-build"),
        "event": name,
        "project": fields.pop("project", "alpha"),
        "role": fields.pop("role", "build"),
    }
    value.update(fields)
    return value


def append_rows(path: Path, rows: list[dict[str, object]], *, final_newline: bool = True) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("ab") as stream:
        for index, row in enumerate(rows):
            stream.write(json.dumps(row, separators=(",", ":"), sort_keys=True).encode())
            if final_newline or index < len(rows) - 1:
                stream.write(b"\n")


def checksums(root: Path) -> dict[str, str]:
    return {
        path.name: hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(root.glob("*.jsonl"))
    }


class ReaderTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def reader(self, **kwargs: object) -> EventReader:
        return EventReader(self.root, **kwargs).refresh()

    def test_empty_directory(self) -> None:
        reader = self.reader()
        self.assertEqual(reader.row_count, 0)
        self.assertEqual(reader.error_count, 0)
        self.assertIsNone(reader.latest_timestamp)
        self.assertEqual(reader.query_events(now=NOW), [])

    def test_multiday_unknown_fields_and_lazy_raw_lookup(self) -> None:
        append_rows(self.root / "2026-07-29.jsonl", [event(NOW - timedelta(days=2), "job.start", future={"x": 1})])
        append_rows(self.root / "2026-07-31.jsonl", [event(NOW - timedelta(seconds=1), "job.end", status="ok", alien=True)])
        before = checksums(self.root)
        reader = self.reader()
        refs = reader.query_refs(now=NOW)
        self.assertEqual([reader.filename(ref) for ref in refs], ["2026-07-31.jsonl", "2026-07-29.jsonl"])
        self.assertTrue(reader.read_event(refs[0])["alien"])
        self.assertEqual(reader.read_event(refs[1])["future"], {"x": 1})
        self.assertEqual(checksums(self.root), before)

    def test_newline_invalid_row_is_error_but_earlier_rows_survive(self) -> None:
        path = self.root / "2026-07-31.jsonl"
        append_rows(path, [event(NOW - timedelta(seconds=3), "job.start")])
        with path.open("ab") as stream:
            stream.write(b'{"broken":]\n')
            stream.write(b'{"ts":"2026-07-31T11:59:58Z","event":"bad.constant","value":NaN}\n')
        append_rows(path, [event(NOW - timedelta(seconds=1), "job.end", status="ok")])
        before = checksums(self.root)
        reader = self.reader()
        self.assertEqual(reader.row_count, 2)
        self.assertEqual(reader.error_count, 2)
        self.assertEqual(reader.problems[0].file, path.name)
        self.assertIn("non-standard JSON constant", reader.problems[1].message)
        self.assertEqual(checksums(self.root), before)

    def test_unterminated_tail_is_retried_without_parse_error(self) -> None:
        path = self.root / "2026-07-31.jsonl"
        append_rows(path, [event(NOW - timedelta(seconds=2), "job.start")])
        tail = event(NOW - timedelta(seconds=1), "job.end", status="ok")
        append_rows(path, [tail], final_newline=False)
        reader = self.reader()
        self.assertEqual(reader.row_count, 1)
        self.assertEqual(reader.error_count, 0)
        self.assertEqual(reader.incomplete_tails, [(path.name, reader.references[0].byte_length)])
        with path.open("ab") as stream:
            stream.write(b"\n")
        reader.refresh()
        self.assertEqual(reader.row_count, 2)
        self.assertEqual(reader.query_events(now=NOW)[0]["status"], "ok")

    def test_rotation_rebuilds_and_old_reference_becomes_stale(self) -> None:
        path = self.root / "2026-07-31.jsonl"
        append_rows(path, [event(NOW - timedelta(seconds=2), "job.start")])
        reader = self.reader()
        old_ref = reader.references[0]
        path.rename(self.root / "2026-07-31.jsonl.rotated")
        append_rows(path, [event(NOW - timedelta(seconds=1), "job.end", status="ok")])
        with self.assertRaises(StaleReferenceError):
            reader.read_event(old_ref)
        reader.refresh()
        with self.assertRaises(StaleReferenceError):
            reader.read_event(old_ref)
        self.assertEqual(reader.row_count, 1)
        self.assertEqual(reader.references[0].event, "job.end")

    def test_truncation_rebuilds_and_old_reference_becomes_stale(self) -> None:
        path = self.root / "2026-07-31.jsonl"
        append_rows(path, [event(NOW - timedelta(seconds=2), "job.start"), event(NOW - timedelta(seconds=1), "job.end", status="ok")])
        reader = self.reader()
        old_ref = reader.references[0]
        path.write_bytes(b"")
        with self.assertRaises(StaleReferenceError):
            reader.read_event(old_ref)
        reader.refresh()
        self.assertEqual(reader.row_count, 0)

    def test_append_after_snapshot_is_deferred_until_next_refresh(self) -> None:
        path = self.root / "2026-07-31.jsonl"
        append_rows(path, [event(NOW - timedelta(seconds=2), "job.start")])
        opened = threading.Event()
        appended = threading.Event()

        class CoordinatedReader(EventReader):
            def _open_snapshot(inner_self, candidate: Path):  # type: ignore[no-untyped-def]
                descriptor, info = super()._open_snapshot(candidate)
                opened.set()
                self.assertTrue(appended.wait(2))
                return descriptor, info

        def writer() -> None:
            self.assertTrue(opened.wait(2))
            append_rows(path, [event(NOW - timedelta(seconds=1), "job.end", status="ok")])
            appended.set()

        worker = threading.Thread(target=writer)
        worker.start()
        reader = CoordinatedReader(self.root).refresh()
        worker.join(2)
        self.assertFalse(worker.is_alive())
        self.assertEqual(reader.row_count, 1)
        reader = EventReader(self.root).refresh()
        self.assertEqual(reader.row_count, 2)

    def test_windows_are_start_inclusive_and_end_exclusive(self) -> None:
        rows = []
        for label, width in (("24h", timedelta(hours=24)), ("7d", timedelta(days=7)), ("30d", timedelta(days=30))):
            rows.extend(
                [
                    event(NOW - width - timedelta(microseconds=1), "mark", svc=label + "-before"),
                    event(NOW - width, "mark", svc=label + "-start"),
                ]
            )
        rows.extend([event(NOW - timedelta(microseconds=1), "mark", svc="inside"), event(NOW, "mark", svc="end")])
        append_rows(self.root / "events.jsonl", rows)
        reader = self.reader()
        for label in ("24h", "7d", "30d"):
            services = {ref.svc for ref in reader.query_refs(window=label, now=NOW, limit=100)}
            self.assertIn(label + "-start", services)
            self.assertNotIn(label + "-before", services)
            self.assertIn("inside", services)
            self.assertNotIn("end", services)

    def test_default_and_maximum_limits_are_exact(self) -> None:
        path = self.root / "events.jsonl"
        rows = [event(NOW - timedelta(seconds=index + 1), "tick", svc=f"svc-{index}") for index in range(MAX_LIMIT + 1)]
        append_rows(path, rows)
        reader = self.reader()
        self.assertEqual(len(reader.query_refs(window="30d", now=NOW)), 500)
        self.assertEqual(len(reader.query_refs(window="30d", now=NOW, limit=MAX_LIMIT)), MAX_LIMIT)
        with self.assertRaises(ValueError):
            reader.query_refs(now=NOW, limit=MAX_LIMIT + 1)
        with self.assertRaises(ValueError):
            reader.query_refs(now=NOW, limit=0)

    def test_deterministic_order_uses_timestamp_file_and_offset(self) -> None:
        stamp = NOW - timedelta(seconds=1)
        append_rows(self.root / "a.jsonl", [event(stamp, "first"), event(stamp, "second")])
        append_rows(self.root / "b.jsonl", [event(stamp, "third")])
        reader = self.reader()
        refs = reader.query_refs(now=NOW)
        self.assertEqual([(reader.filename(ref), ref.event) for ref in refs], [("b.jsonl", "third"), ("a.jsonl", "second"), ("a.jsonl", "first")])

    def test_filters_use_canonical_fields_and_event_family(self) -> None:
        append_rows(
            self.root / "events.jsonl",
            [
                event(NOW - timedelta(seconds=2), "medic.incident.detected", project="alpha", role="medic", svc="pretty-name", status="fail"),
                event(NOW - timedelta(seconds=1), "job.end", project="beta", role="build", svc="medic", status="ok"),
            ],
        )
        reader = self.reader()
        refs = reader.query_refs(now=NOW, project="alpha", role="medic", status="fail", event_family="medic.incident")
        self.assertEqual(len(refs), 1)
        self.assertEqual((refs[0].project, refs[0].role, refs[0].svc), ("alpha", "medic", "pretty-name"))
        self.assertEqual(reader.query_refs(now=NOW, role="pretty-name"), [])
        with self.assertRaises(ValueError):
            reader.query_refs(window="1h", now=NOW)

    def test_state_derivation_and_stale_boundary(self) -> None:
        rows = [
            event(NOW - timedelta(seconds=30), "job.end", svc="healthy", status="ok", duration_s=3),
            event(NOW - timedelta(seconds=20), "job.end", svc="failed", status="fail"),
            event(NOW - timedelta(seconds=10), "job.start", svc="running"),
            event(NOW - timedelta(seconds=7200), "job.start", svc="boundary"),
            event(NOW - timedelta(seconds=7201), "job.start", svc="stale"),
            event(NOW - timedelta(seconds=40), "job.end", svc="recovered", status="fail"),
            event(NOW - timedelta(seconds=5), "job.end", svc="recovered", status="ok"),
            event(NOW - timedelta(seconds=50), "job.end", svc="rerun", status="fail"),
            event(NOW - timedelta(seconds=4), "job.start", svc="rerun"),
        ]
        append_rows(self.root / "events.jsonl", rows)
        summary = self.reader().summarize(window="24h", now=NOW)
        by_svc = {state.svc: state for state in summary["services"]}
        self.assertEqual(by_svc["healthy"].state, "healthy")
        self.assertEqual(by_svc["healthy"].duration_s, 3.0)
        self.assertEqual(by_svc["failed"].state, "failed")
        self.assertEqual(by_svc["running"].state, "running")
        self.assertEqual(by_svc["boundary"].state, "running")
        self.assertEqual(by_svc["stale"].state, "stale")
        self.assertEqual(by_svc["recovered"].state, "healthy")
        self.assertEqual(by_svc["rerun"].state, "running")
        self.assertEqual(summary["counts"], {"healthy": 2, "running": 3, "stale": 1, "failed": 1, "actionable": 2})

    def test_matching_resolution_and_dedup_suppress_only_their_keys(self) -> None:
        rows = [
            event(NOW - timedelta(seconds=12), "medic.incident.detected", incident_id="closed"),
            event(NOW - timedelta(seconds=11), "medic.incident.detected", incident_id="open"),
            event(NOW - timedelta(seconds=10), "medic.incident.resolved", incident_id="closed"),
            event(NOW - timedelta(seconds=9), "notification.decision", **{"class": "actionable"}, episode="done", outcome="delivered"),
            event(NOW - timedelta(seconds=8), "notification.decision", **{"class": "actionable"}, episode="live", outcome="delivered"),
            event(NOW - timedelta(seconds=7), "notification.decision", **{"class": "actionable"}, episode="done", outcome="deduped"),
            event(NOW - timedelta(seconds=6), "notification.decision", **{"class": "actionable"}, episode="live", outcome="suppressed"),
            event(NOW - timedelta(seconds=5), "notification.decision", **{"class": "routine"}, episode="routine", outcome="delivered"),
        ]
        append_rows(self.root / "events.jsonl", rows)
        items = self.reader().summarize(window="24h", now=NOW)["actionables"]
        self.assertEqual({(item.kind, item.key) for item in items}, {("incident", "open"), ("notification", "live")})

    def test_any_later_nonfailure_terminal_clears_failed_actionable(self) -> None:
        append_rows(
            self.root / "events.jsonl",
            [
                event(NOW - timedelta(seconds=2), "job.end", svc="partial", status="fail"),
                event(NOW - timedelta(seconds=1), "job.end", svc="partial", status="partial"),
            ],
        )
        summary = self.reader().summarize(window="24h", now=NOW)
        self.assertEqual(summary["counts"]["actionable"], 0)
        self.assertEqual(summary["services"][0].state, "unknown")

    def test_resolution_keys_are_project_scoped_and_empty_episode_is_unique(self) -> None:
        append_rows(
            self.root / "events.jsonl",
            [
                event(NOW - timedelta(seconds=6), "medic.incident.detected", project="alpha", incident_id="same"),
                event(NOW - timedelta(seconds=5), "medic.incident.detected", project="beta", incident_id="same"),
                event(NOW - timedelta(seconds=4), "medic.incident.resolved", project="alpha", incident_id="same"),
                event(NOW - timedelta(seconds=3), "notification.decision", project="alpha", **{"class": "urgent"}, episode="", outcome="delivered"),
                event(NOW - timedelta(seconds=2), "notification.decision", project="alpha", **{"class": "urgent"}, episode="", outcome="delivered"),
                event(NOW - timedelta(seconds=1), "notification.decision", project="beta", **{"class": "urgent"}, episode="", outcome="deduped"),
            ],
        )
        items = self.reader().summarize(window="24h", now=NOW)["actionables"]
        self.assertEqual(sum(item.kind == "incident" for item in items), 1)
        self.assertEqual(sum(item.kind == "notification" for item in items), 2)
        self.assertEqual({item.key for item in items if item.kind == "incident"}, {"same"})
        self.assertEqual(len({item.key for item in items if item.kind == "notification"}), 2)

    def test_missing_project_or_role_does_not_replace_canonical_identity_with_svc(self) -> None:
        row = event(NOW - timedelta(seconds=1), "job.end", svc="display-name", status="ok")
        row.pop("project")
        row.pop("role")
        append_rows(self.root / "events.jsonl", [row])
        state = self.reader().summarize(window="24h", now=NOW)["services"][0]
        self.assertEqual((state.project, state.role, state.svc), ("", "", "display-name"))

    def test_source_checksums_unchanged_by_refresh_queries_and_summary(self) -> None:
        append_rows(self.root / "one.jsonl", [event(NOW - timedelta(seconds=2), "job.start")])
        append_rows(self.root / "two.jsonl", [event(NOW - timedelta(seconds=1), "job.end", status="ok")])
        before = checksums(self.root)
        reader = self.reader()
        reader.query_events(now=NOW)
        reader.summarize(now=NOW)
        reader.refresh()
        self.assertEqual(checksums(self.root), before)


if __name__ == "__main__":
    unittest.main()
