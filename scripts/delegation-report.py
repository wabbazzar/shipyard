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
  python3 scripts/delegation-report.py --since 2026-07-27T20:17:45Z --json

Transcript root resolves as ${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}.
Codex root resolves as ${CODEX_SESSIONS_DIR:-${CODEX_HOME:-$HOME/.codex}/sessions}.
"""

from __future__ import annotations

import argparse
import glob
import hashlib
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
CODEX_MARKER = "<!-- shipyard-skill:execute-ticket:v1 -->"
OPERATOR_RELATIONSHIP_SCHEMA_VERSION = 1
MAX_RELATIONSHIP_AGGREGATES = 500
MAX_SKILL_AGGREGATES = 500
SKILL_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._:-]{0,127}$")
CODEX_SKILL_MARKER_RE = re.compile(
    r"<!-- shipyard-skill:([a-z0-9][a-z0-9._:-]{0,127}):v[1-9][0-9]* -->"
)
CODEX_SPAWN_CALLS = frozenset(
    {"spawn_agent", "collaboration.spawn_agent", "functions.collaboration.spawn_agent"}
)
DELEGATION_CALLS = frozenset(
    {
        "spawn_agent",
        "followup_task",
        "send_message",
        "interrupt_agent",
        "list_agents",
        "wait_agent",
    }
)


def transcript_root() -> str:
    return os.environ.get(
        "CLAUDE_PROJECTS_DIR", os.path.join(os.path.expanduser("~"), ".claude", "projects")
    )


def codex_transcript_root() -> str:
    override = os.environ.get("CODEX_SESSIONS_DIR")
    if override:
        return override
    codex_home = os.environ.get("CODEX_HOME")
    if codex_home:
        return os.path.join(codex_home, "sessions")
    return os.path.join(os.path.expanduser("~"), ".codex", "sessions")


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


def _parse_timestamp(value: object) -> datetime | None:
    """Parse one transcript timestamp as an aware UTC datetime."""
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        return None
    return parsed.astimezone(timezone.utc)


def _parse_since(value: str) -> datetime:
    """argparse converter for an explicit timezone-aware inclusive cutoff."""
    parsed = _parse_timestamp(value)
    if parsed is None:
        try:
            naive = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except (TypeError, ValueError):
            raise argparse.ArgumentTypeError(
                "--since must be a valid timezone-aware ISO-8601 timestamp"
            ) from None
        if naive.tzinfo is None or naive.utcoffset() is None:
            raise argparse.ArgumentTypeError(
                "--since timestamp must include a timezone (for example, Z or +00:00)"
            )
        raise argparse.ArgumentTypeError(
            "--since must be a valid timezone-aware ISO-8601 timestamp"
        )
    return parsed


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
        "malformed_timestamps": 0,
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

                msg = rec.get("message") or {}
                content = msg.get("content")

                invocation = _is_invocation(rec, skill)
                parsed_ts = None
                if invocation and not active:
                    if cutoff is not None:
                        parsed_ts = _parse_timestamp(rec.get("timestamp"))
                        if parsed_ts is None:
                            agg["malformed_timestamps"] += 1
                            continue
                        if parsed_ts < cutoff:
                            continue
                    active = True
                    seen = True

                if not active:
                    continue

                # Every measured record must itself be in the requested window.
                # A bad timestamp is evidence about transcript quality, not a
                # reason to silently include or discard an unknown record.
                if cutoff is not None:
                    if parsed_ts is None:
                        parsed_ts = _parse_timestamp(rec.get("timestamp"))
                    if parsed_ts is None:
                        agg["malformed_timestamps"] += 1
                        continue
                    if parsed_ts < cutoff:
                        continue

                # Remember tool_use ids so a later tool_result can be attributed.
                if rec.get("type") == "assistant" and isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "tool_use":
                            tool_names[block.get("id")] = block.get("name") or "?"
                            tool_calls[block.get("name") or "?"] += 1
                            if block.get("name") in ("Agent", "Task"):
                                agents += 1

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


def _codex_assistant_message(payload: dict) -> bool:
    return payload.get("type") == "message" and payload.get("role") == "assistant"


def _codex_has_marker(payload: dict) -> bool:
    """Match only the versioned marker in canonical assistant message text."""
    if not _codex_assistant_message(payload):
        return False
    content = payload.get("content")
    if not isinstance(content, list):
        return False
    return any(
        isinstance(block, dict)
        and block.get("type") == "output_text"
        and isinstance(block.get("text"), str)
        and CODEX_MARKER in block["text"]
        for block in content
    )


def scan_codex(root: str, cutoff: datetime | None) -> dict:
    """Scan canonical Codex rollout records after the forward-only marker."""
    agg = {
        "sessions": 0,
        "zero_agent_sessions": 0,
        "turns": 0,
        "input_tokens": 0,
        "cache_read_tokens": 0,
        "output_tokens": 0,
        "reasoning_output_tokens": 0,
        "context_tokens": 0,
        "agent_calls": 0,
        "malformed_records": 0,
        "malformed_boundaries": 0,
        "malformed_timestamps": 0,
    }
    tool_calls: Counter = Counter()
    tool_bytes: Counter = Counter()

    paths = glob.glob(os.path.join(root, "*", "*", "*", "rollout-*.jsonl"))
    for path in sorted(paths):
        active = False
        agents = 0
        task: dict | None = None
        calls: dict[str, str] = {}
        results: dict[str, object] = {}
        session_calls: Counter = Counter()

        try:
            fh = open(path, errors="ignore")
        except OSError:
            continue

        with fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except (ValueError, TypeError):
                    if active:
                        agg["malformed_records"] += 1
                    continue
                if not isinstance(rec, dict):
                    if active:
                        agg["malformed_records"] += 1
                    continue

                rec_type = rec.get("type")
                payload = rec.get("payload")
                if not isinstance(payload, dict):
                    if active and rec_type in ("response_item", "event_msg"):
                        agg["malformed_records"] += 1
                    continue

                parsed_ts = None
                if rec_type == "response_item" and _codex_has_marker(payload) and not active:
                    if cutoff is not None:
                        parsed_ts = _parse_timestamp(rec.get("timestamp"))
                        if parsed_ts is None:
                            agg["malformed_timestamps"] += 1
                            continue
                        if parsed_ts < cutoff:
                            continue
                    active = True

                event_type = payload.get("type")
                if rec_type == "event_msg" and event_type == "task_started":
                    if active and task is not None:
                        agg["malformed_boundaries"] += 1
                    task = {"turn_id": payload.get("turn_id"), "usage": None}

                if not active:
                    continue

                if cutoff is not None:
                    if parsed_ts is None:
                        parsed_ts = _parse_timestamp(rec.get("timestamp"))
                    if parsed_ts is None:
                        agg["malformed_timestamps"] += 1
                        continue
                    if parsed_ts < cutoff:
                        continue

                if rec_type == "response_item":
                    if _codex_assistant_message(payload):
                        agg["turns"] += 1
                    if event_type in ("function_call", "custom_tool_call"):
                        name = payload.get("name")
                        call_id = payload.get("call_id")
                        if not isinstance(name, str) or not isinstance(call_id, str):
                            agg["malformed_records"] += 1
                            continue
                        calls[call_id] = name
                        session_calls[name] += 1
                        # Count canonical collaboration calls, whether the
                        # harness records a bare or namespace-qualified name.
                        # sub_agent_activity remains visible in tool counts but
                        # is a duplicate UI/activity signal, not another call.
                        if name.rsplit(".", 1)[-1] in DELEGATION_CALLS:
                            agents += 1
                    elif event_type in ("function_call_output", "custom_tool_call_output"):
                        call_id = payload.get("call_id")
                        if not isinstance(call_id, str) or "output" not in payload:
                            agg["malformed_records"] += 1
                            continue
                        results[call_id] = payload["output"]
                    continue

                if rec_type != "event_msg":
                    continue
                if event_type == "token_count" and task is not None:
                    info = payload.get("info")
                    usage = info.get("last_token_usage") if isinstance(info, dict) else None
                    if usage is not None:
                        if isinstance(usage, dict):
                            task["usage"] = usage
                        else:
                            agg["malformed_records"] += 1
                elif event_type == "task_complete":
                    if task is None or payload.get("turn_id") != task.get("turn_id"):
                        agg["malformed_boundaries"] += 1
                        task = None
                        continue
                    usage = task.get("usage")
                    if usage is None:
                        agg["malformed_boundaries"] += 1
                    else:
                        input_tokens = usage.get("input_tokens", 0)
                        cached_tokens = usage.get("cached_input_tokens", 0)
                        output_tokens = usage.get("output_tokens", 0)
                        reasoning_tokens = usage.get("reasoning_output_tokens", 0)
                        values = (input_tokens, cached_tokens, output_tokens, reasoning_tokens)
                        if not all(isinstance(value, int) and value >= 0 for value in values):
                            agg["malformed_records"] += 1
                        else:
                            agg["input_tokens"] += input_tokens
                            agg["cache_read_tokens"] += cached_tokens
                            agg["output_tokens"] += output_tokens
                            agg["reasoning_output_tokens"] += reasoning_tokens
                            agg["context_tokens"] += input_tokens
                    task = None

        if not active:
            continue
        if task is not None:
            agg["malformed_boundaries"] += 1
        agg["sessions"] += 1
        agg["agent_calls"] += agents
        if agents == 0:
            agg["zero_agent_sessions"] += 1
        tool_calls.update(session_calls)
        for call_id, output in results.items():
            name = calls.get(call_id)
            if name is None:
                continue
            size = len(
                json.dumps(output, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            )
            tool_bytes[name] += size

    agg["tool_calls"] = dict(tool_calls)
    agg["tool_result_bytes_proxy"] = dict(tool_bytes)
    agg["serialized_tool_result_bytes_proxy"] = sum(tool_bytes.values())
    return agg


def _iso_timestamp(value: object) -> tuple[str, str] | None:
    """Return one normalized UTC timestamp and its day bucket."""
    parsed = _parse_timestamp(value)
    if parsed is None:
        return None
    timestamp = parsed.isoformat().replace("+00:00", "Z")
    return timestamp, timestamp[:10]


def _opaque_actor(provider: str, seed: str) -> str:
    """Make a stable actor id without returning a transcript or machine path."""
    digest = hashlib.sha256(f"{provider}\0{seed}".encode("utf-8")).hexdigest()[:16]
    return f"{provider}-session-{digest}"


def _opaque_callee(provider: str, caller_id: str, call_id: str) -> str:
    """Identify one observed callee without returning its tool arguments."""
    digest = hashlib.sha256(
        f"{provider}\0{caller_id}\0{call_id}".encode("utf-8")
    ).hexdigest()[:16]
    return f"{provider}-callee-{digest}"


def _session_seed(provider: str, path: str, explicit: object) -> str:
    if isinstance(explicit, str) and explicit:
        return explicit
    # Only the digest produced by _opaque_actor crosses the output boundary.
    # The path seed prevents same-basename sessions from collapsing together.
    return f"{provider}:{os.path.abspath(path)}"


def _completion_from_result(block: dict) -> str:
    return "failed" if block.get("is_error") is True else "completed"


def _add_observation(
    rows: dict[tuple, dict],
    key: tuple,
    row: dict,
    limit: int,
) -> bool:
    """Aggregate one observation, returning False when a new key is bounded out."""
    current = rows.get(key)
    if current is not None:
        current["count"] += 1
        current["first_timestamp"] = min(
            current["first_timestamp"], row["first_timestamp"]
        )
        current["last_timestamp"] = max(
            current["last_timestamp"], row["last_timestamp"]
        )
        return True
    if len(rows) >= limit:
        return False
    rows[key] = row
    return True


def _relationship_row(
    provider: str,
    actor_id: str,
    call_id: str,
    timestamp: str,
    bucket: str,
    completion: str | None,
) -> tuple[tuple, dict]:
    callee_id = _opaque_callee(provider, actor_id, call_id)
    key = (bucket, actor_id, callee_id, completion or "")
    row = {
        "provider": provider,
        "bucket": bucket,
        "caller_id": actor_id,
        "callee_id": callee_id,
        "first_timestamp": timestamp,
        "last_timestamp": timestamp,
        "count": 1,
    }
    if completion is not None:
        row["completion"] = completion
    return key, row


def _skill_row(
    provider: str,
    actor_id: str,
    skill_id: str,
    timestamp: str,
    bucket: str,
    completion: str | None,
) -> tuple[tuple, dict]:
    key = (bucket, actor_id, skill_id, completion or "")
    row = {
        "provider": provider,
        "bucket": bucket,
        "actor_id": actor_id,
        "skill_id": skill_id,
        "first_timestamp": timestamp,
        "last_timestamp": timestamp,
        "count": 1,
    }
    if completion is not None:
        row["completion"] = completion
    return key, row


def _finalize_operator_source(
    provider: str,
    file_count: int,
    usable_records: int,
    malformed_records: int,
    truncated: int,
    relationships: dict[tuple, dict],
    skills: dict[tuple, dict],
) -> dict:
    limitations = []
    if malformed_records:
        limitations.append(
            {"code": "parse_gaps", "state": "partial", "count": malformed_records}
        )
    if truncated:
        limitations.append(
            {"code": "aggregate_truncated", "state": "partial", "count": truncated}
        )
    if file_count == 0:
        return {
            "provider": provider,
            "state": "unknown",
            "coverage": {"state": "unknown"},
            "caller_callee": None,
            "skill_invocations": None,
            "limitations": [{"code": "no_transcripts", "state": "unknown"}],
        }
    if usable_records == 0:
        return {
            "provider": provider,
            "state": "unknown",
            "coverage": {
                "state": "unknown",
                "files_scanned": file_count,
                "malformed_records": malformed_records,
            },
            "caller_callee": None,
            "skill_invocations": None,
            "limitations": limitations
            or [{"code": "parse_gaps", "state": "unknown"}],
        }
    state = "partial" if limitations else "available"
    coverage_state = "partial" if limitations else "complete"
    return {
        "provider": provider,
        "state": state,
        "coverage": {
            "state": coverage_state,
            "files_scanned": file_count,
            "malformed_records": malformed_records,
            "truncated": bool(truncated),
        },
        "caller_callee": sorted(
            relationships.values(),
            key=lambda row: (
                row["first_timestamp"],
                row["caller_id"],
                row["callee_id"],
                row.get("completion", ""),
            ),
        ),
        "skill_invocations": sorted(
            skills.values(),
            key=lambda row: (
                row["first_timestamp"],
                row["actor_id"],
                row["skill_id"],
                row.get("completion", ""),
            ),
        ),
        "limitations": limitations,
    }


def scan_operator_claude(root: str, cutoff: datetime | None) -> dict:
    relationships: dict[tuple, dict] = {}
    skills: dict[tuple, dict] = {}
    malformed_records = 0
    usable_records = 0
    truncated = 0
    paths = sorted(glob.glob(os.path.join(root, "*", "*.jsonl")))

    for path in paths:
        calls: list[dict] = []
        results: dict[str, str] = {}
        explicit_session = None
        try:
            fh = open(path, errors="ignore")
        except OSError:
            malformed_records += 1
            continue
        with fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except (TypeError, ValueError):
                    malformed_records += 1
                    continue
                if not isinstance(rec, dict):
                    malformed_records += 1
                    continue
                usable_records += 1
                if explicit_session is None and isinstance(rec.get("sessionId"), str):
                    explicit_session = rec["sessionId"]
                msg = rec.get("message")
                content = msg.get("content") if isinstance(msg, dict) else None
                if rec.get("type") == "assistant" and isinstance(content, list):
                    for block in content:
                        if not isinstance(block, dict) or block.get("type") != "tool_use":
                            continue
                        call_id = block.get("id")
                        if not isinstance(call_id, str):
                            malformed_records += 1
                            continue
                        timestamp = _iso_timestamp(rec.get("timestamp"))
                        if timestamp is None:
                            malformed_records += 1
                            continue
                        parsed = _parse_timestamp(rec.get("timestamp"))
                        if cutoff is not None and parsed is not None and parsed < cutoff:
                            continue
                        name = block.get("name")
                        if name in ("Agent", "Task"):
                            calls.append(
                                {"kind": "relationship", "id": call_id, "time": timestamp}
                            )
                        elif name == "Skill":
                            tool_input = block.get("input")
                            skill_id = (
                                tool_input.get("skill") if isinstance(tool_input, dict) else None
                            )
                            if isinstance(skill_id, str) and SKILL_ID_RE.fullmatch(skill_id):
                                calls.append(
                                    {
                                        "kind": "skill",
                                        "id": call_id,
                                        "skill_id": skill_id,
                                        "time": timestamp,
                                    }
                                )
                            else:
                                malformed_records += 1
                elif rec.get("type") == "user" and isinstance(content, list):
                    for block in content:
                        if not isinstance(block, dict) or block.get("type") != "tool_result":
                            continue
                        call_id = block.get("tool_use_id")
                        if isinstance(call_id, str):
                            results[call_id] = _completion_from_result(block)
                        else:
                            malformed_records += 1

        actor_id = _opaque_actor(
            "claude", _session_seed("claude", path, explicit_session)
        )
        for call in calls:
            timestamp, bucket = call["time"]
            completion = results.get(call["id"])
            if call["kind"] == "relationship":
                key, row = _relationship_row(
                    "claude", actor_id, call["id"], timestamp, bucket, completion
                )
                if not _add_observation(
                    relationships, key, row, MAX_RELATIONSHIP_AGGREGATES
                ):
                    truncated += 1
            else:
                key, row = _skill_row(
                    "claude",
                    actor_id,
                    call["skill_id"],
                    timestamp,
                    bucket,
                    completion,
                )
                if not _add_observation(skills, key, row, MAX_SKILL_AGGREGATES):
                    truncated += 1

    return _finalize_operator_source(
        "claude",
        len(paths),
        usable_records,
        malformed_records,
        truncated,
        relationships,
        skills,
    )


def scan_operator_codex(root: str, cutoff: datetime | None) -> dict:
    relationships: dict[tuple, dict] = {}
    skills: dict[tuple, dict] = {}
    malformed_records = 0
    usable_records = 0
    truncated = 0
    paths = sorted(glob.glob(os.path.join(root, "**", "rollout-*.jsonl"), recursive=True))

    for path in paths:
        calls: list[dict] = []
        results: set[str] = set()
        explicit_session = None
        try:
            fh = open(path, errors="ignore")
        except OSError:
            malformed_records += 1
            continue
        with fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except (TypeError, ValueError):
                    malformed_records += 1
                    continue
                if not isinstance(rec, dict):
                    malformed_records += 1
                    continue
                usable_records += 1
                payload = rec.get("payload")
                if not isinstance(payload, dict):
                    continue
                if rec.get("type") == "session_meta" and isinstance(payload.get("id"), str):
                    explicit_session = payload["id"]
                    continue
                if rec.get("type") != "response_item":
                    continue
                event_type = payload.get("type")
                timestamp = _iso_timestamp(rec.get("timestamp"))
                if timestamp is None:
                    malformed_records += 1
                    continue
                parsed = _parse_timestamp(rec.get("timestamp"))
                if cutoff is not None and parsed is not None and parsed < cutoff:
                    continue
                if event_type in ("function_call", "custom_tool_call"):
                    name = payload.get("name")
                    call_id = payload.get("call_id")
                    if not isinstance(name, str) or not isinstance(call_id, str):
                        malformed_records += 1
                        continue
                    if name in CODEX_SPAWN_CALLS:
                        calls.append(
                            {"kind": "relationship", "id": call_id, "time": timestamp}
                        )
                elif event_type in ("function_call_output", "custom_tool_call_output"):
                    call_id = payload.get("call_id")
                    if isinstance(call_id, str):
                        results.add(call_id)
                    else:
                        malformed_records += 1
                elif _codex_assistant_message(payload):
                    content = payload.get("content")
                    if not isinstance(content, list):
                        continue
                    for block in content:
                        if not isinstance(block, dict) or block.get("type") != "output_text":
                            continue
                        text = block.get("text")
                        if not isinstance(text, str):
                            continue
                        for marker in CODEX_SKILL_MARKER_RE.finditer(text):
                            calls.append(
                                {
                                    "kind": "skill",
                                    "skill_id": marker.group(1),
                                    "time": timestamp,
                                }
                            )

        actor_id = _opaque_actor("codex", _session_seed("codex", path, explicit_session))
        for call in calls:
            timestamp, bucket = call["time"]
            if call["kind"] == "relationship":
                completion = "completed" if call["id"] in results else None
                key, row = _relationship_row(
                    "codex", actor_id, call["id"], timestamp, bucket, completion
                )
                if not _add_observation(
                    relationships, key, row, MAX_RELATIONSHIP_AGGREGATES
                ):
                    truncated += 1
            else:
                key, row = _skill_row(
                    "codex", actor_id, call["skill_id"], timestamp, bucket, None
                )
                if not _add_observation(skills, key, row, MAX_SKILL_AGGREGATES):
                    truncated += 1

    source = _finalize_operator_source(
        "codex",
        len(paths),
        usable_records,
        malformed_records,
        truncated,
        relationships,
        skills,
    )
    if source["state"] != "unknown":
        source["state"] = "partial"
        source["coverage"]["state"] = "partial"
        source["limitations"].append(
            {"code": "skill_marker_coverage_partial", "state": "partial"}
        )
    return source


def _missing_operator_source(provider: str) -> dict:
    return {
        "provider": provider,
        "state": "unknown",
        "coverage": {"state": "unknown"},
        "caller_callee": None,
        "skill_invocations": None,
        "limitations": [{"code": "transcript_root_missing", "state": "unknown"}],
    }


def operator_relationship_document(cutoff: datetime | None, window: str) -> dict:
    sources = {}
    claude_root = transcript_root()
    codex_root = codex_transcript_root()
    sources["claude"] = (
        scan_operator_claude(claude_root, cutoff)
        if os.path.isdir(claude_root)
        else _missing_operator_source("claude")
    )
    sources["codex"] = (
        scan_operator_codex(codex_root, cutoff)
        if os.path.isdir(codex_root)
        else _missing_operator_source("codex")
    )
    sources["hermes"] = {
        "provider": "hermes",
        "state": "unknown",
        "coverage": {"state": "unknown"},
        "caller_callee": None,
        "skill_invocations": None,
        "limitations": [{"code": "unsupported_provider", "state": "unknown"}],
    }
    return {
        "schema_version": OPERATOR_RELATIONSHIP_SCHEMA_VERSION,
        "kind": "shipyard.operator.relationships",
        "window": window,
        "sources": sources,
    }


def scan_ledgers(ticket_dir: str) -> dict:
    """Count `builder:` lines by kind, inside each ticket's Ledger section only.

    Scoping to the Ledger matters: a ticket that *documents* the contract (this
    one does) carries `builder: subagent | inline` in its spec prose, which would
    otherwise be counted as a real phase entry. Absent section → zeros.
    """
    out = {"subagent": 0, "inline": 0, "total": 0}
    pattern = re.compile(r"^\s*builder:\s*(subagent|inline)\b", re.IGNORECASE | re.MULTILINE)
    for path in sorted(glob.glob(os.path.join(ticket_dir, "**", "*.md"), recursive=True)):
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
        "malformed_timestamps": agg["malformed_timestamps"],
        "read_byte_pct": agg["tool_bytes"].get("Read", 0) / total_bytes * 100,
        "tool_bytes": agg["tool_bytes"],
        "tool_calls": agg["tool_calls"],
        "total_tool_bytes": sum(agg["tool_bytes"].values()),
        "ledger_builder": ledgers,
    }


def summarize_codex(agg: dict, ledgers: dict) -> dict:
    sessions = max(agg["sessions"], 1)
    return {
        "sessions": agg["sessions"],
        "zero_agent_sessions": agg["zero_agent_sessions"],
        "zero_agent_pct": agg["zero_agent_sessions"] / sessions * 100,
        "turns": agg["turns"],
        "input_tokens": agg["input_tokens"],
        "cache_read_tokens": agg["cache_read_tokens"],
        "output_tokens": agg["output_tokens"],
        "reasoning_output_tokens": agg["reasoning_output_tokens"],
        "context_tokens": agg["context_tokens"],
        "agent_calls": agg["agent_calls"],
        "malformed_records": agg["malformed_records"],
        "malformed_boundaries": agg["malformed_boundaries"],
        "malformed_timestamps": agg["malformed_timestamps"],
        "tool_calls": agg["tool_calls"],
        "serialized_tool_result_bytes_proxy": agg["serialized_tool_result_bytes_proxy"],
        "tool_result_bytes_proxy": agg["tool_result_bytes_proxy"],
        "filesystem_network_bytes": None,
        "cross_provider_cost_equivalent": None,
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
        f"  malformed timestamps skipped {s['malformed_timestamps']}",
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


def render_codex(s: dict, skill: str, window: str) -> str:
    lines = [
        f"delegation-report — source=codex skill={skill} window={window}",
        "",
        f"  sessions                     {s['sessions']}",
        f"  sessions with ZERO subagents {s['zero_agent_sessions']} ({s['zero_agent_pct']:.0f}%)",
        f"  spawn_agent calls            {s['agent_calls']}",
        f"  assistant turns              {s['turns']}",
        f"  malformed records skipped    {s['malformed_records']}",
        f"  malformed task boundaries    {s['malformed_boundaries']}",
        f"  malformed timestamps skipped {s['malformed_timestamps']}",
        "",
        f"  input/context tokens         {s['context_tokens']}",
        f"  cached input tokens          {s['cache_read_tokens']}",
        f"  output tokens                {s['output_tokens']}",
        f"  reasoning output tokens      {s['reasoning_output_tokens']}",
        "",
        "  serialized tool-result bytes (context-ingress proxy only):",
    ]
    for name, size in sorted(
        s["tool_result_bytes_proxy"].items(), key=lambda item: -item[1]
    ):
        calls = s["tool_calls"].get(name, 0)
        lines.append(f"    {name:<18} {calls:>6} calls  {size:>8} bytes")
    led = s["ledger_builder"]
    lines += [
        f"    proxy total: {s['serialized_tool_result_bytes_proxy']} bytes",
        "  filesystem/network read/write bytes: unavailable",
        "  cross-provider cost equivalent: unavailable",
        "",
        f"  Ledger builder: lines        subagent={led['subagent']} inline={led['inline']}"
        f" total={led['total']}",
    ]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--skill", help="skill to attribute (default: execute-ticket)")
    ap.add_argument(
        "--source",
        choices=("claude", "codex", "all"),
        help="transcript source (default: claude)",
    )
    window = ap.add_mutually_exclusive_group()
    window.add_argument("--days", type=int, help="window in days (default: 30)")
    window.add_argument("--all", action="store_true", help="no time window")
    window.add_argument(
        "--since",
        type=_parse_since,
        metavar="ISO-8601",
        help="inclusive timezone-aware ISO-8601 cutoff",
    )
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument(
        "--operator-json",
        action="store_true",
        help="bounded content-free Claude/Codex relationship JSON",
    )
    ap.add_argument("--tickets-dir", default="docs/tickets", help="where to count Ledger builder: lines")
    args = ap.parse_args(argv)

    if args.operator_json:
        incompatible = []
        if args.source is not None:
            incompatible.append("--source")
        if args.skill is not None:
            incompatible.append("--skill")
        if args.json:
            incompatible.append("--json")
        if incompatible:
            ap.error(
                "--operator-json cannot be combined with " + ", ".join(incompatible)
            )

    source_mode = args.source or "claude"
    skill = args.skill or "execute-ticket"

    roots = {}
    if source_mode in ("claude", "all"):
        roots["claude"] = transcript_root()
    if source_mode in ("codex", "all"):
        roots["codex"] = codex_transcript_root()
    if not args.operator_json:
        for source, root in roots.items():
            if not os.path.isdir(root):
                source_label = "" if source == "claude" else f"{source} "
                print(
                    f"delegation-report: no {source_label}transcript root at {root}",
                    file=sys.stderr,
                )
                return 2

    days = 30 if args.days is None else args.days
    cutoff = None if args.all else args.since or datetime.now(timezone.utc) - timedelta(days=days)
    if args.all:
        window_label = "all"
    elif args.since is not None:
        window_label = f"since {args.since.isoformat().replace('+00:00', 'Z')} (inclusive)"
    else:
        window_label = f"{days}d"
    cutoff_label = cutoff.isoformat().replace("+00:00", "Z") if cutoff else None
    if args.operator_json:
        print(
            json.dumps(
                operator_relationship_document(cutoff, window_label),
                indent=2,
                sort_keys=True,
            )
        )
        return 0
    ledgers = scan_ledgers(args.tickets_dir)
    summaries = {}
    if "claude" in roots:
        summaries["claude"] = summarize(scan(roots["claude"], skill, cutoff), ledgers)
    if "codex" in roots:
        summaries["codex"] = summarize_codex(scan_codex(roots["codex"], cutoff), ledgers)
    for summary in summaries.values():
        summary["window"] = window_label
        summary["cutoff"] = cutoff_label

    if source_mode == "all":
        if args.json:
            print(json.dumps({"sources": summaries}, indent=2, sort_keys=True))
        else:
            print("source: claude")
            print(render(summaries["claude"], skill, window_label))
            print("\nsource: codex")
            print(render_codex(summaries["codex"], skill, window_label))
    elif source_mode == "codex":
        summary = summaries["codex"]
        if args.json:
            print(json.dumps(summary, indent=2, sort_keys=True))
        else:
            print(render_codex(summary, skill, window_label))
    else:
        summary = summaries["claude"]
        if args.json:
            print(json.dumps(summary, indent=2, sort_keys=True))
        else:
            print(render(summary, skill, window_label))
    return 0


if __name__ == "__main__":
    sys.exit(main())
