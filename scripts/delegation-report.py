#!/usr/bin/env python3
"""delegation-report — measure orchestrator context bloat for a pipeline skill.

Reads Claude Code session transcripts and reports, for the sessions in which a
given skill (default: execute-ticket) was actually invoked, how much of the cost
is the orchestrator re-carrying its own context versus producing work — plus the
delegation signals that predict it (Agent calls, sessions with zero subagents,
which tool returns the most bytes).

Ships with docs/tickets/delegation-plan-pipeline.md, whose Phase 7 compares a
post-change run against the baseline this script recorded on 2026-07-27.

Read-only. Stdlib only. No network.

  python3 scripts/delegation-report.py --all
  python3 scripts/delegation-report.py --days 30 --json

Transcript root resolves as ${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone

# Cost-equivalent weights (Opus token-price ratios, NOT billing). Used only to
# express "how much of the spend is context re-carry" on one scale.
W_INPUT = 1.0
W_CACHE_WRITE = 1.25
W_CACHE_READ = 0.1
W_OUTPUT = 5.0

# A turn above this much carried context is counted as "bloated".
BLOAT_CTX = 300_000
# A single tool result above this is called out individually.
BIG_RESULT = 60_000


def transcript_root() -> str:
    return os.environ.get(
        "CLAUDE_PROJECTS_DIR", os.path.join(os.path.expanduser("~"), ".claude", "projects")
    )


def _is_invocation(rec: dict, skill: str) -> bool:
    """True if this record is a REAL invocation of `skill`.

    Deliberately narrow. Matching the bare skill name is wrong: every session's
    system-reminder lists every available skill, which would attribute ~every
    session to the skill (measured 2026-07-27: 82% vs the true 28%).
    """
    msg = rec.get("message") or {}
    content = msg.get("content")

    if rec.get("type") == "user" and isinstance(content, str):
        if f"<command-name>{skill}" in content:
            return True

    if rec.get("type") == "assistant" and isinstance(content, list):
        for block in content:
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue
            if block.get("name") != "Skill":
                continue
            if (block.get("input") or {}).get("skill") == skill:
                return True

    return False


def _in_window(ts: str | None, cutoff: datetime | None) -> bool:
    if cutoff is None:
        return True
    if not ts:
        return False
    try:
        return datetime.fromisoformat(str(ts).replace("Z", "+00:00")) >= cutoff
    except ValueError:
        return False


def scan(root: str, skill: str, cutoff: datetime | None) -> dict:
    agg = {
        "sessions": 0,
        "zero_agent_sessions": 0,
        "turns": 0,
        "output_tokens": 0,
        "cache_read_tokens": 0,
        "cache_write_tokens": 0,
        "input_tokens": 0,
        "bloated_turns": 0,
        "bloated_cache_read": 0,
        "ctx_sum": 0,
        "peak_ctx": 0,
        "agent_calls": 0,
        "big_results": 0,
        "largest_result": 0,
    }
    tool_calls: Counter = Counter()
    tool_bytes: Counter = Counter()
    peaks: list[int] = []

    for path in sorted(glob.glob(os.path.join(root, "*", "*.jsonl"))):
        active = False
        seen = False
        in_window = False
        agents = 0
        session_peak = 0
        tool_names: dict[str, str] = {}

        try:
            fh = open(path, errors="ignore")
        except OSError:
            continue

        with fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except (ValueError, TypeError):
                    continue

                if _is_invocation(rec, skill):
                    active = True
                    seen = True

                msg = rec.get("message") or {}
                content = msg.get("content")

                # Remember tool_use ids so a later tool_result can be attributed.
                if rec.get("type") == "assistant" and isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "tool_use":
                            tool_names[block.get("id")] = block.get("name") or "?"
                            if active:
                                tool_calls[block.get("name") or "?"] += 1
                                if block.get("name") in ("Agent", "Task"):
                                    agents += 1

                if not active:
                    continue

                if rec.get("type") == "user" and isinstance(content, list):
                    for block in content:
                        if not isinstance(block, dict) or block.get("type") != "tool_result":
                            continue
                        name = tool_names.get(block.get("tool_use_id"), "?")
                        size = len(json.dumps(block.get("content", "")))
                        tool_bytes[name] += size
                        if size > BIG_RESULT:
                            agg["big_results"] += 1
                        agg["largest_result"] = max(agg["largest_result"], size)

                if rec.get("type") != "assistant":
                    continue

                if not _in_window(rec.get("timestamp"), cutoff):
                    continue
                in_window = True

                usage = msg.get("usage") or {}
                cache_read = usage.get("cache_read_input_tokens", 0)
                cache_write = usage.get("cache_creation_input_tokens", 0)
                ctx = cache_read + cache_write

                agg["turns"] += 1
                agg["input_tokens"] += usage.get("input_tokens", 0)
                agg["output_tokens"] += usage.get("output_tokens", 0)
                agg["cache_read_tokens"] += cache_read
                agg["cache_write_tokens"] += cache_write
                agg["ctx_sum"] += ctx
                session_peak = max(session_peak, ctx)
                if cache_read > BLOAT_CTX:
                    agg["bloated_turns"] += 1
                    agg["bloated_cache_read"] += cache_read

        if seen and in_window:
            agg["sessions"] += 1
            agg["agent_calls"] += agents
            if agents == 0:
                agg["zero_agent_sessions"] += 1
            peaks.append(session_peak)
            agg["peak_ctx"] = max(agg["peak_ctx"], session_peak)

    agg["top_peaks"] = sorted(peaks, reverse=True)[:5]
    agg["tool_calls"] = dict(tool_calls)
    agg["tool_bytes"] = dict(tool_bytes)
    return agg


def scan_ledgers(ticket_dir: str) -> dict:
    """Count `builder:` lines by kind, inside each ticket's Ledger section only.

    Scoping to the Ledger matters: a ticket that *documents* the contract (this
    one does) carries `builder: subagent | inline` in its spec prose, which would
    otherwise be counted as a real phase entry. Absent section → zeros.
    """
    out = {"subagent": 0, "inline": 0, "total": 0}
    pattern = re.compile(r"^\s*builder:\s*(subagent|inline)\b", re.IGNORECASE | re.MULTILINE)
    for path in sorted(glob.glob(os.path.join(ticket_dir, "*.md"))):
        try:
            text = open(path, errors="ignore").read()
        except OSError:
            continue
        ledger = re.split(r"^#{1,3}\s+Ledger\s*$", text, maxsplit=1, flags=re.MULTILINE)
        if len(ledger) < 2:
            continue
        for match in pattern.finditer(ledger[1]):
            out[match.group(1).lower()] += 1
            out["total"] += 1
    return out


def summarize(agg: dict, ledgers: dict) -> dict:
    turns = max(agg["turns"], 1)
    cost_ctx = agg["cache_read_tokens"] * W_CACHE_READ
    cost_out = agg["output_tokens"] * W_OUTPUT
    cost_all = (
        agg["input_tokens"] * W_INPUT
        + agg["cache_write_tokens"] * W_CACHE_WRITE
        + cost_ctx
        + cost_out
    )
    total_bytes = max(sum(agg["tool_bytes"].values()), 1)
    sessions = max(agg["sessions"], 1)
    return {
        "sessions": agg["sessions"],
        "zero_agent_sessions": agg["zero_agent_sessions"],
        "zero_agent_pct": agg["zero_agent_sessions"] / sessions * 100,
        "turns": agg["turns"],
        "output_tokens": agg["output_tokens"],
        "cache_read_tokens": agg["cache_read_tokens"],
        "cost_equiv_total": cost_all,
        # Two denominators, both reported so neither can be quoted ambiguously:
        #   *_of_total   — share of ALL cost-equivalent tokens (incl. cache-write)
        #   *_vs_output  — context carry measured against produced work alone;
        #                  this is the headline ratio the ticket's Phase 7 gates on.
        "cache_read_cost_pct_of_total": cost_ctx / max(cost_all, 1) * 100,
        "output_cost_pct_of_total": cost_out / max(cost_all, 1) * 100,
        "cache_read_pct_vs_output": cost_ctx / max(cost_ctx + cost_out, 1) * 100,
        "avg_ctx_per_turn": agg["ctx_sum"] / turns,
        "peak_ctx": agg["peak_ctx"],
        "top_peaks": agg["top_peaks"],
        "bloated_turns": agg["bloated_turns"],
        "bloated_turn_pct": agg["bloated_turns"] / turns * 100,
        "bloated_cache_read_pct": agg["bloated_cache_read"] / max(agg["cache_read_tokens"], 1) * 100,
        "agent_calls": agg["agent_calls"],
        "big_results": agg["big_results"],
        "largest_result": agg["largest_result"],
        "read_byte_pct": agg["tool_bytes"].get("Read", 0) / total_bytes * 100,
        "tool_bytes": agg["tool_bytes"],
        "tool_calls": agg["tool_calls"],
        "total_tool_bytes": sum(agg["tool_bytes"].values()),
        "ledger_builder": ledgers,
    }


def render(s: dict, skill: str, window: str) -> str:
    lines = [
        f"delegation-report — skill={skill} window={window}",
        "",
        f"  sessions                     {s['sessions']}",
        f"  sessions with ZERO subagents {s['zero_agent_sessions']} ({s['zero_agent_pct']:.0f}%)",
        f"  Agent calls (all sessions)   {s['agent_calls']}",
        f"  assistant turns              {s['turns']}",
        "",
        f"  output tokens                {s['output_tokens'] / 1e6:.2f} M",
        f"  cache-read (context carry)   {s['cache_read_tokens'] / 1e9:.2f} B",
        f"  cost-equivalent, of total    cache-read {s['cache_read_cost_pct_of_total']:.0f}%"
        f"  vs output {s['output_cost_pct_of_total']:.0f}%",
        f"  context carry vs work alone  {s['cache_read_pct_vs_output']:.0f}%"
        f"  (the Phase 7 headline ratio)",
        "",
        f"  avg context per turn         {s['avg_ctx_per_turn'] / 1e3:.0f} k",
        f"  peak context                 {s['peak_ctx'] / 1e3:.0f} k"
        f"   (top: {', '.join(f'{p / 1e3:.0f}k' for p in s['top_peaks'])})",
        f"  turns above {BLOAT_CTX // 1000}k context      "
        f"{s['bloated_turns']} ({s['bloated_turn_pct']:.0f}%),"
        f" carrying {s['bloated_cache_read_pct']:.0f}% of all context reads",
        "",
        "  bytes returned into the orchestrator:",
    ]
    for name, size in sorted(s["tool_bytes"].items(), key=lambda kv: -kv[1])[:8]:
        calls = s["tool_calls"].get(name, 0)
        share = size / max(s["total_tool_bytes"], 1) * 100
        avg = size / calls / 1e3 if calls else 0.0
        lines.append(
            f"    {name:<18} {calls:>6} calls  {size / 1e6:>7.2f} MB  {share:>5.1f}%"
            f"  avg {avg:>6.1f} KB"
        )
    led = s["ledger_builder"]
    lines += [
        f"    results >{BIG_RESULT // 1000}KB: {s['big_results']}"
        f"   largest: {s['largest_result'] / 1e3:.0f} KB",
        "",
        f"  Ledger builder: lines        subagent={led['subagent']} inline={led['inline']}"
        f" total={led['total']}",
    ]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--skill", default="execute-ticket", help="skill to attribute (default: execute-ticket)")
    ap.add_argument("--days", type=int, default=30, help="window in days (default: 30)")
    ap.add_argument("--all", action="store_true", help="no time window")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--tickets-dir", default="docs/tickets", help="where to count Ledger builder: lines")
    args = ap.parse_args(argv)

    root = transcript_root()
    if not os.path.isdir(root):
        print(f"delegation-report: no transcript root at {root}", file=sys.stderr)
        return 2

    cutoff = None if args.all else datetime.now(timezone.utc) - timedelta(days=args.days)
    summary = summarize(scan(root, args.skill, cutoff), scan_ledgers(args.tickets_dir))

    if args.json:
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        print(render(summary, args.skill, "all" if args.all else f"{args.days}d"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
