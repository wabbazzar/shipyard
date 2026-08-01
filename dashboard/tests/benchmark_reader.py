#!/usr/bin/env python3
"""Deterministic resource gate for the bounded JSONL reader."""

from __future__ import annotations

import argparse
import hashlib
import json
import resource
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[2]
if str(REPOSITORY) not in sys.path:
    sys.path.insert(0, str(REPOSITORY))

from dashboard.reader import EventReader  # noqa: E402


def checksum(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(root.glob("*.jsonl")):
        digest.update(path.name.encode())
        with path.open("rb") as stream:
            while block := stream.read(1024 * 1024):
                digest.update(block)
    return digest.hexdigest()


def generate(root: Path, rows: int) -> None:
    base = datetime(2026, 7, 1, tzinfo=timezone.utc)
    stream = None
    try:
        for index in range(rows):
            if index % 10_000 == 0:
                if stream is not None:
                    stream.close()
                file_index = index // 10_000
                stream = (root / f"2026-07-{file_index + 1:02d}.jsonl").open("wb")
            stamp = (base + timedelta(seconds=index)).isoformat(timespec="seconds").replace("+00:00", "Z")
            row = {
                "ts": stamp,
                "svc": f"project-{index % 20}-role-{index % 5}",
                "event": "job.end",
                "project": f"project-{index % 20}",
                "role": f"role-{index % 5}",
                "status": "fail" if index % 97 == 0 else "ok",
                "duration_s": index % 300,
            }
            stream.write(json.dumps(row, separators=(",", ":"), sort_keys=True).encode() + b"\n")
    finally:
        if stream is not None:
            stream.close()


def peak_rss_mib() -> float:
    value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    if sys.platform != "darwin":
        value *= 1024
    return value / (1024 * 1024)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rows", type=int, default=300_000)
    parser.add_argument("--max-seconds", type=float, default=10.0)
    parser.add_argument("--max-rss-mib", type=float, default=256.0)
    args = parser.parse_args()
    if args.rows < 1 or args.max_seconds <= 0 or args.max_rss_mib <= 0:
        parser.error("all limits must be positive")

    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        generate(root, args.rows)
        before = checksum(root)
        query_now = datetime(2026, 7, 1, tzinfo=timezone.utc) + timedelta(seconds=args.rows)
        started = time.perf_counter()
        reader = EventReader(root, clock=lambda: query_now).refresh()
        elapsed = time.perf_counter() - started
        result_count = len(reader.query_refs(window="30d", now=query_now, limit=2_000))
        after = checksum(root)
        rss = peak_rss_mib()

        print(f"rows={reader.row_count} result_count={result_count}")
        print(f"elapsed_seconds={elapsed:.3f} peak_rss_mib={rss:.1f}")
        print(f"checksum_before={before}")
        print(f"checksum_after={after}")

        failures = []
        if reader.row_count != args.rows:
            failures.append(f"indexed {reader.row_count} rows, expected {args.rows}")
        if reader.error_count or reader.incomplete_tails:
            failures.append(
                f"index reported {reader.error_count} errors and {len(reader.incomplete_tails)} tails"
            )
        if result_count != min(2_000, args.rows):
            failures.append(f"query returned {result_count} rows")
        if before != after:
            failures.append("fixture checksum changed")
        if elapsed >= args.max_seconds:
            failures.append(f"elapsed {elapsed:.3f}s is not below {args.max_seconds:.3f}s")
        if rss >= args.max_rss_mib:
            failures.append(f"peak RSS {rss:.1f} MiB is not below {args.max_rss_mib:.1f} MiB")
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
