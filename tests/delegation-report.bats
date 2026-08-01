#!/usr/bin/env bats
#
# delegation-report.bats — scripts/delegation-report.py, the measurement harness
# behind docs/tickets/delegation-plan-pipeline.md.
#
# Asserts:
#   * only REAL skill invocations are attributed (a Skill tool_use, or a
#     <command-name> block) — the bare skill name appearing in a session's
#     skills listing must NOT attribute that session. This is the trap that
#     inflated the first hand-run measurement from 28% to 82%;
#   * token/context aggregation is exact against known fixture usage numbers;
#   * sessions with zero Agent calls are counted as such;
#   * `builder:` Ledger lines are counted from the Ledger section ONLY, so a
#     ticket that documents the contract in prose isn't counted as a phase;
#   * --json emits parseable JSON; a missing transcript root exits 2.
#
# Hermetic: transcripts are synthesized into $BATS_TEST_TMPDIR and the script is
# pointed at them with CLAUDE_PROJECTS_DIR. The real transcript store is never
# read. No network, no model.

setup() {
  load helpers
  quartet_setup

  PROJECTS="$BATS_TEST_TMPDIR/projects"
  TICKETS="$BATS_TEST_TMPDIR/tickets"
  mkdir -p "$PROJECTS" "$TICKETS"
  export CLAUDE_PROJECTS_DIR="$PROJECTS"

  REPORT="$QUARTET_ROOT/scripts/delegation-report.py"
  FIXTURES="$QUARTET_ROOT/tests/fixtures/delegation-report"
}

# usage_line <output> <cache_read> <cache_write> -> a JSONL assistant record
usage_line() {
  printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":0,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s}}}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3"
}

# skill_invocation -> a JSONL assistant record that really invokes execute-ticket
skill_invocation() {
  printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","id":"t1","name":"Skill","input":{"skill":"execute-ticket"}}],"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

run_report() {
  run python3 "$REPORT" --all --json --tickets-dir "$TICKETS"
  [ "$status" -eq 0 ]
}

run_since_report() {
  run python3 "$REPORT" --since "$1" --json --tickets-dir "$TICKETS"
  [ "$status" -eq 0 ]
}

# jq-free field read: the script emits indented "key": value JSON
field() {
  printf '%s\n' "$output" | sed -n "s/.*\"$1\": \([0-9.]*\).*/\1/p" | head -1
}

run_codex_fixture() {
  CODEX_SESSIONS_DIR="$FIXTURES/codex/sessions" \
    run python3 "$REPORT" --source codex --all --json --tickets-dir "$TICKETS"
  [ "$status" -eq 0 ]
}

write_codex_session() {
  local root="$1" name="$2"
  mkdir -p "$root/2026/07/01"
  cat >"$root/2026/07/01/rollout-$name.jsonl" <<'JSONL'
{"timestamp":"2026-07-01T12:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
{"timestamp":"2026-07-01T12:00:01Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"<!-- shipyard-skill:execute-ticket:v1 -->"}]}}
{"timestamp":"2026-07-01T12:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":1,"total_tokens":14}}}}
{"timestamp":"2026-07-01T12:00:03Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}
JSONL
}

@test "a session that never invokes the skill is not attributed" {
  mkdir -p "$PROJECTS/proj-a"
  { usage_line 100 5000 100; } > "$PROJECTS/proj-a/s1.jsonl"

  run_report
  [ "$(field sessions)" = "0" ]
  [ "$(field turns)" = "0" ]
}

@test "the bare skill name in a skills listing does NOT attribute the session" {
  # The exact trap: every session's system-reminder lists every available
  # skill, so matching the bare string attributes ~every session.
  mkdir -p "$PROJECTS/proj-b"
  {
    printf '{"type":"user","timestamp":"%s","message":{"content":"<system-reminder>available skills: execute-ticket, write-ticket</system-reminder>"}}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    usage_line 999 999999 999
  } > "$PROJECTS/proj-b/s1.jsonl"

  run_report
  [ "$(field sessions)" = "0" ]
  [ "$(field turns)" = "0" ]
}

@test "a real Skill tool_use attributes the session with exact token totals" {
  mkdir -p "$PROJECTS/proj-c"
  {
    skill_invocation
    usage_line 200 100000 1000
    usage_line 300 400000 2000
  } > "$PROJECTS/proj-c/s1.jsonl"

  run_report
  [ "$(field sessions)" = "1" ]
  # 3 assistant records: the invocation (all zeros) + the two usage lines.
  [ "$(field turns)" = "3" ]
  [ "$(field output_tokens)" = "500" ]
  [ "$(field cache_read_tokens)" = "500000" ]
  # only the 400k turn is above the 300k bloat line
  [ "$(field bloated_turns)" = "1" ]
  # peak context = cache_read + cache_write of the largest turn
  [ "$(field peak_ctx)" = "402000" ]
}

@test "a <command-name> block also attributes the session" {
  mkdir -p "$PROJECTS/proj-d"
  {
    printf '{"type":"user","timestamp":"%s","message":{"content":"<command-name>execute-ticket</command-name>"}}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    usage_line 700 1000 10
  } > "$PROJECTS/proj-d/s1.jsonl"

  run_report
  [ "$(field sessions)" = "1" ]
  [ "$(field output_tokens)" = "700" ]
}

@test "records BEFORE the invocation are not attributed" {
  mkdir -p "$PROJECTS/proj-e"
  {
    usage_line 1000 50000 500      # pre-invocation: must be ignored
    skill_invocation
    usage_line 42 1000 10
  } > "$PROJECTS/proj-e/s1.jsonl"

  run_report
  [ "$(field output_tokens)" = "42" ]
}

@test "zero-subagent sessions are counted; Agent calls are tallied" {
  mkdir -p "$PROJECTS/proj-f" "$PROJECTS/proj-g"
  { skill_invocation; usage_line 10 100 10; } > "$PROJECTS/proj-f/s1.jsonl"
  {
    skill_invocation
    printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","id":"a1","name":"Agent","input":{}}],"usage":{"input_tokens":0,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$PROJECTS/proj-g/s1.jsonl"

  run_report
  [ "$(field sessions)" = "2" ]
  [ "$(field zero_agent_sessions)" = "1" ]
  [ "$(field agent_calls)" = "1" ]
}

@test "tool_result bytes are attributed to the calling tool" {
  mkdir -p "$PROJECTS/proj-h"
  {
    skill_invocation
    printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","id":"r1","name":"Read","input":{}}],"usage":{"input_tokens":0,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"type":"user","timestamp":"%s","message":{"content":[{"type":"tool_result","tool_use_id":"r1","content":"%s"}]}}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(printf 'x%.0s' $(seq 1 500))"
  } > "$PROJECTS/proj-h/s1.jsonl"

  run_report
  # Read is the only tool returning bytes, so it owns 100% of them
  [ "$(field read_byte_pct)" = "100.0" ]
}

@test "builder: lines are counted from the Ledger section ONLY" {
  # A ticket that DOCUMENTS the contract in prose must not be counted as a
  # phase entry — only what appears under the Ledger heading counts.
  cat > "$TICKETS/t1.md" <<'TICKET'
# A ticket

The contract this ticket documents, in a fenced block exactly as a real
spec would write it (line-start, which is what makes it a false positive):

```
builder: subagent (<N> agents) | inline (<reason>)
```

## Phases

Delegation: subagent — do the thing

## Ledger

- Phase 1 — commit abc123
  builder: subagent (2 agents)
- Phase 2 — commit def456
  builder: inline (single-file edit)
TICKET

  run_report
  [ "$(field subagent)" = "1" ]
  [ "$(field inline)" = "1" ]
}

@test "a ticket with no Ledger section yields zeros, not a crash" {
  printf '# no ledger here\n\nbuilder: subagent\n' > "$TICKETS/t2.md"
  run_report
  [ "$(field total)" = "0" ]
}

@test "human output renders and names the Phase 7 headline ratio" {
  mkdir -p "$PROJECTS/proj-i"
  { skill_invocation; usage_line 100 200000 1000; } > "$PROJECTS/proj-i/s1.jsonl"

  run python3 "$REPORT" --all --tickets-dir "$TICKETS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sessions with ZERO subagents"* ]]
  [[ "$output" == *"Phase 7 headline ratio"* ]]
}

@test "a missing transcript root exits 2" {
  CLAUDE_PROJECTS_DIR="$BATS_TEST_TMPDIR/nope" run python3 "$REPORT" --all
  [ "$status" -eq 2 ]
}

@test "--since is timezone-aware and inclusive; malformed timestamps are counted" {
  mkdir -p "$PROJECTS/proj-since"
  cat > "$PROJECTS/proj-since/s1.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-07-27T20:17:45Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Skill","input":{"skill":"execute-ticket"}}],"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"assistant","timestamp":"not-an-iso-timestamp","message":{"usage":{"input_tokens":0,"output_tokens":999,"cache_read_input_tokens":999,"cache_creation_input_tokens":0}}}
{"type":"assistant","timestamp":"2026-07-27T20:17:45+00:00","message":{"usage":{"input_tokens":0,"output_tokens":123,"cache_read_input_tokens":456,"cache_creation_input_tokens":0}}}
JSONL

  run_since_report "2026-07-27T20:17:45Z"
  [ "$(field sessions)" = "1" ]
  [ "$(field turns)" = "2" ]
  [ "$(field output_tokens)" = "123" ]
  [ "$(field malformed_timestamps)" = "1" ]
}

@test "--since excludes a skill invocation before the boundary" {
  mkdir -p "$PROJECTS/proj-before"
  cat > "$PROJECTS/proj-before/s1.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-07-27T20:17:44.999999Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Skill","input":{"skill":"execute-ticket"}}],"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"assistant","timestamp":"2026-07-27T20:17:46Z","message":{"usage":{"input_tokens":0,"output_tokens":999,"cache_read_input_tokens":999,"cache_creation_input_tokens":0}}}
JSONL

  run_since_report "2026-07-27T20:17:45Z"
  [ "$(field sessions)" = "0" ]
  [ "$(field output_tokens)" = "0" ]
}

@test "--since rejects invalid and timezone-naive ISO timestamps with rc 2" {
  run python3 "$REPORT" --since not-a-date --tickets-dir "$TICKETS"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--since"* ]]

  run python3 "$REPORT" --since 2026-07-27T20:17:45 --tickets-dir "$TICKETS"
  [ "$status" -eq 2 ]
  [[ "$output" == *"timezone"* ]]
}

@test "--since conflicts with explicitly supplied --days or --all" {
  run python3 "$REPORT" --since 2026-07-27T20:17:45Z --days 30 --tickets-dir "$TICKETS"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not allowed with argument"* || "$output" == *"cannot be combined"* ]]

  run python3 "$REPORT" --since 2026-07-27T20:17:45Z --all --tickets-dir "$TICKETS"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not allowed with argument"* || "$output" == *"cannot be combined"* ]]
}

@test "Ledger discovery recursively scans lifecycle ticket directories" {
  mkdir -p "$TICKETS/pending" "$TICKETS/complete"
  cat > "$TICKETS/complete/nested.md" <<'TICKET'
# Nested ticket

## Ledger

builder: subagent (1 agent)
TICKET

  run_report
  [ "$(field subagent)" = "1" ]
  [ "$(field total)" = "1" ]
}

@test "legacy golden human output is unchanged when source is omitted" {
  local fixture="$FIXTURES/claude"
  CLAUDE_PROJECTS_DIR="$fixture/projects" \
    run python3 "$REPORT" --all --tickets-dir "$fixture/tickets"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/human.actual"
  cmp -s "$fixture/human.golden" "$BATS_TEST_TMPDIR/human.actual"
}

@test "legacy golden JSON output is unchanged when source is omitted" {
  local fixture="$FIXTURES/claude"
  CLAUDE_PROJECTS_DIR="$fixture/projects" \
    run python3 "$REPORT" --all --json --tickets-dir "$fixture/tickets"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/json.actual"
  cmp -s "$fixture/json.golden" "$BATS_TEST_TMPDIR/json.actual"
}

@test "explicit Claude source matches both immutable legacy goldens" {
  local fixture="$FIXTURES/claude"
  CLAUDE_PROJECTS_DIR="$fixture/projects" \
    run python3 "$REPORT" --source claude --all --tickets-dir "$fixture/tickets"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/human.explicit"
  cmp -s "$fixture/human.golden" "$BATS_TEST_TMPDIR/human.explicit"

  CLAUDE_PROJECTS_DIR="$fixture/projects" \
    run python3 "$REPORT" --source claude --all --json --tickets-dir "$fixture/tickets"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/json.explicit"
  cmp -s "$fixture/json.golden" "$BATS_TEST_TMPDIR/json.explicit"
}

@test "Codex scans canonical turns and exact completed-boundary token totals" {
  run_codex_fixture
  [ "$(field sessions)" = "3" ]
  [ "$(field turns)" = "4" ]
  [ "$(field input_tokens)" = "330" ]
  [ "$(field cache_read_tokens)" = "172" ]
  [ "$(field output_tokens)" = "68" ]
  [ "$(field reasoning_output_tokens)" = "16" ]
  [ "$(field context_tokens)" = "330" ]
  [ "$(field malformed_boundaries)" = "1" ]
  [ "$(field malformed_records)" = "2" ]
  [[ "$output" != *"999999"* ]]
  [[ "$output" != *"888888"* ]]
}

@test "Codex pairs out-of-order results and counts spawn delegation once" {
  run_codex_fixture
  [ "$(field zero_agent_sessions)" = "2" ]
  [ "$(field agent_calls)" = "1" ]
  [ "$(field spawn_agent)" = "1" ]
  [ "$(field sub_agent_activity)" = "1" ]
  [ "$(field Read)" = "1" ]
  [ "$(field apply_patch)" = "1" ]
  [ "$(field serialized_tool_result_bytes_proxy)" = "87" ]
  [[ "$output" == *'"Read": 23'* ]]
  [[ "$output" == *'"apply_patch": 24'* ]]
  [[ "$output" == *'"spawn_agent": 20'* ]]
  [[ "$output" == *'"sub_agent_activity": 20'* ]]
}

@test "Codex counts explicit collaboration lifecycle calls without UI double-counting" {
  local root="$BATS_TEST_TMPDIR/collaboration"
  mkdir -p "$root/2026/07/01"
  cat >"$root/2026/07/01/rollout-collaboration.jsonl" <<'JSONL'
{"timestamp":"2026-07-01T12:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
{"timestamp":"2026-07-01T12:00:01Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"<!-- shipyard-skill:execute-ticket:v1 -->"}]}}
{"timestamp":"2026-07-01T12:00:02Z","type":"response_item","payload":{"type":"function_call","name":"spawn_agent","arguments":"{}","call_id":"spawn-1"}}
{"timestamp":"2026-07-01T12:00:03Z","type":"response_item","payload":{"type":"function_call","name":"collaboration.followup_task","arguments":"{}","call_id":"followup-1"}}
{"timestamp":"2026-07-01T12:00:04Z","type":"response_item","payload":{"type":"function_call","name":"send_message","arguments":"{}","call_id":"send-1"}}
{"timestamp":"2026-07-01T12:00:05Z","type":"response_item","payload":{"type":"function_call","name":"collaboration.interrupt_agent","arguments":"{}","call_id":"interrupt-1"}}
{"timestamp":"2026-07-01T12:00:06Z","type":"response_item","payload":{"type":"function_call","name":"list_agents","arguments":"{}","call_id":"list-1"}}
{"timestamp":"2026-07-01T12:00:07Z","type":"response_item","payload":{"type":"function_call","name":"collaboration.wait_agent","arguments":"{}","call_id":"wait-1"}}
{"timestamp":"2026-07-01T12:00:08Z","type":"response_item","payload":{"type":"function_call","name":"sub_agent_activity","arguments":"{}","call_id":"activity-1"}}
{"timestamp":"2026-07-01T12:00:09Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":1,"total_tokens":14}}}}
{"timestamp":"2026-07-01T12:00:10Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}
JSONL

  CODEX_SESSIONS_DIR="$root" \
    run python3 "$REPORT" --source codex --all --json --tickets-dir "$TICKETS"
  [ "$status" -eq 0 ]
  [ "$(field sessions)" = "1" ]
  [ "$(field zero_agent_sessions)" = "0" ]
  [ "$(field agent_calls)" = "6" ]
  [ "$(field spawn_agent)" = "1" ]
  [ "$(field collaboration.followup_task)" = "1" ]
  [ "$(field send_message)" = "1" ]
  [ "$(field collaboration.interrupt_agent)" = "1" ]
  [ "$(field list_agents)" = "1" ]
  [ "$(field collaboration.wait_agent)" = "1" ]
  [ "$(field sub_agent_activity)" = "1" ]
}

@test "Codex exposes byte proxy and unavailable cross-provider measurements honestly" {
  run_codex_fixture
  [[ "$output" == *'"filesystem_network_bytes": null'* ]]
  [[ "$output" == *'"cross_provider_cost_equivalent": null'* ]]
  [[ "$output" == *'"serialized_tool_result_bytes_proxy"'* ]]
  [[ "$output" == *'"tool_result_bytes_proxy"'* ]]
}

@test "Codex attribution requires the exact marker in an assistant response item" {
  run_codex_fixture
  # Two valid completed marker sessions plus one deliberately incomplete marker
  # session; skill-list text, user text, paths, and non-assistant markers exclude.
  [ "$(field sessions)" = "3" ]
}

@test "Codex root precedence is override then CODEX_HOME then HOME" {
  local override="$BATS_TEST_TMPDIR/override"
  local codex_home="$BATS_TEST_TMPDIR/codex-home"
  local fake_home="$BATS_TEST_TMPDIR/home"
  write_codex_session "$override" override
  write_codex_session "$codex_home/sessions" codex-home
  write_codex_session "$fake_home/.codex/sessions" home
  write_codex_session "$fake_home/.codex/sessions" home-two

  CODEX_SESSIONS_DIR="$override" CODEX_HOME="$codex_home" HOME="$fake_home" \
    run python3 "$REPORT" --source codex --all --json --tickets-dir "$TICKETS"
  [ "$status" -eq 0 ]
  [ "$(field sessions)" = "1" ]

  CODEX_SESSIONS_DIR= CODEX_HOME="$codex_home" HOME="$fake_home" \
    run python3 "$REPORT" --source codex --all --json --tickets-dir "$TICKETS"
  [ "$status" -eq 0 ]
  [ "$(field sessions)" = "1" ]

  CODEX_SESSIONS_DIR= CODEX_HOME= HOME="$fake_home" \
    run python3 "$REPORT" --source codex --all --json --tickets-dir "$TICKETS"
  [ "$status" -eq 0 ]
  [ "$(field sessions)" = "2" ]
}

@test "missing Codex root and invalid source exit 2" {
  CODEX_SESSIONS_DIR="$BATS_TEST_TMPDIR/missing" \
    run python3 "$REPORT" --source codex --all
  [ "$status" -eq 2 ]
  [ "$output" = "delegation-report: no codex transcript root at $BATS_TEST_TMPDIR/missing" ]

  run python3 "$REPORT" --source other --all
  [ "$status" -eq 2 ]
}

@test "missing Claude root preserves the legacy diagnostic" {
  CLAUDE_PROJECTS_DIR="$BATS_TEST_TMPDIR/missing-claude" \
    run python3 "$REPORT" --all
  [ "$status" -eq 2 ]
  [ "$output" = "delegation-report: no transcript root at $BATS_TEST_TMPDIR/missing-claude" ]
}

@test "all JSON keeps source cohorts separate with no pooled totals" {
  local fixture="$FIXTURES/claude"
  CLAUDE_PROJECTS_DIR="$fixture/projects" CODEX_SESSIONS_DIR="$FIXTURES/codex/sessions" \
    run python3 "$REPORT" --source all --all --json --tickets-dir "$fixture/tickets"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"sources": {'* ]]
  [[ "$output" == *'"claude": {'* ]]
  [[ "$output" == *'"codex": {'* ]]
  [[ "$output" != *'"combined"'* ]]
  [[ "$output" != *'"pooled"'* ]]
  [[ "$output" != *'"total_cost"'* ]]
}

@test "all human output has two headings and no blended total" {
  local fixture="$FIXTURES/claude"
  CLAUDE_PROJECTS_DIR="$fixture/projects" CODEX_SESSIONS_DIR="$FIXTURES/codex/sessions" \
    run python3 "$REPORT" --source all --all --tickets-dir "$fixture/tickets"
  [ "$status" -eq 0 ]
  [[ "$output" == *"source: claude"* ]]
  [[ "$output" == *"source: codex"* ]]
  [[ "$output" != *"combined total"* ]]
  [[ "$output" != *"blended total"* ]]
}

@test "operator mode emits exact content-free Claude and Codex relationships" {
  local fixture="$FIXTURES/operator"
  CLAUDE_PROJECTS_DIR="$fixture/claude/projects" \
    CODEX_SESSIONS_DIR="$fixture/codex/sessions" \
    run python3 "$REPORT" --operator-json --all
  [ "$status" -eq 0 ]

  printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/operator.json"
  python3 - "$BATS_TEST_TMPDIR/operator.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
assert doc["schema_version"] == 1
assert doc["kind"] == "shipyard.operator.relationships"
claude = doc["sources"]["claude"]
codex = doc["sources"]["codex"]
hermes = doc["sources"]["hermes"]
assert claude["state"] == "available"
assert codex["state"] == codex["coverage"]["state"] == "partial"
assert codex["limitations"] == [{
    "code": "skill_marker_coverage_partial", "state": "partial"
}]
assert hermes["state"] == hermes["coverage"]["state"] == "unknown"
assert hermes["caller_callee"] is hermes["skill_invocations"] is None
assert hermes["limitations"] == [{"code": "unsupported_provider", "state": "unknown"}]

assert [row["count"] for row in claude["caller_callee"]] == [1, 1, 1]
assert claude["caller_callee"][0]["completion"] == "completed"
assert claude["caller_callee"][1]["completion"] == "completed"
assert "completion" not in claude["caller_callee"][2]
assert claude["caller_callee"][0]["caller_id"].startswith("claude-session-")
assert len({row["caller_id"] for row in claude["caller_callee"]}) == 1
assert len({row["callee_id"] for row in claude["caller_callee"]}) == 3
assert all(row["callee_id"].startswith("claude-callee-")
           for row in claude["caller_callee"])
assert claude["caller_callee"][0]["first_timestamp"] == "2026-08-01T10:05:00Z"
assert claude["caller_callee"][1]["first_timestamp"] == "2026-08-01T10:06:00Z"
assert claude["skill_invocations"] == [{
    "actor_id": claude["skill_invocations"][0]["actor_id"],
    "bucket": "2026-08-01", "completion": "completed", "count": 1,
    "first_timestamp": "2026-08-01T10:00:00Z",
    "last_timestamp": "2026-08-01T10:00:00Z",
    "provider": "claude", "skill_id": "execute-ticket",
}]
assert [row["count"] for row in codex["caller_callee"]] == [1, 1]
assert codex["caller_callee"][0]["completion"] == "completed"
assert codex["caller_callee"][0]["caller_id"].startswith("codex-session-")
assert len({row["callee_id"] for row in codex["caller_callee"]}) == 2
assert all(row["callee_id"].startswith("codex-callee-")
           for row in codex["caller_callee"])
assert [row["skill_id"] for row in codex["skill_invocations"]] == [
    "execute-ticket", "coverage-audit"
]
assert all("completion" not in row for row in codex["skill_invocations"])
assert all(row["provider"] == "claude" for row in claude["caller_callee"])
assert all(row["provider"] == "codex" for row in codex["skill_invocations"])
PY
}

@test "operator mode never returns transcript content, paths, arguments, or results" {
  local fixture="$FIXTURES/operator"
  CLAUDE_PROJECTS_DIR="$fixture/claude/projects" \
    CODEX_SESSIONS_DIR="$fixture/codex/sessions" \
    run python3 "$REPORT" --operator-json --all
  [ "$status" -eq 0 ]
  [[ "$output" != *"FORBIDDEN_"* ]]
  [[ "$output" != *"prose-only-skill"* ]]
  [[ "$output" != *"$fixture"* ]]

  printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/operator-safe.json"
  python3 - "$BATS_TEST_TMPDIR/operator-safe.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
forbidden = {"prompt", "description", "message", "arguments", "result", "results",
             "path", "root", "transcript", "transcript_path"}
def walk(value):
    if isinstance(value, dict):
        assert not (forbidden & set(value)), forbidden & set(value)
        for child in value.values(): walk(child)
    elif isinstance(value, list):
        for child in value: walk(child)
walk(doc)
PY
}

@test "operator mode reports missing roots and unsupported Hermes as unknown" {
  CLAUDE_PROJECTS_DIR="$BATS_TEST_TMPDIR/missing-claude" \
    CODEX_SESSIONS_DIR="$BATS_TEST_TMPDIR/missing-codex" \
    run python3 "$REPORT" --operator-json --all
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/operator-missing.json"
  python3 - "$BATS_TEST_TMPDIR/operator-missing.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
for provider in ("claude", "codex"):
    source = doc["sources"][provider]
    assert source["state"] == source["coverage"]["state"] == "unknown"
    assert source["caller_callee"] is source["skill_invocations"] is None
    assert source["limitations"] == [{"code": "transcript_root_missing", "state": "unknown"}]
assert doc["sources"]["hermes"]["state"] == "unknown"
PY
}

@test "operator aggregate output is deterministically bounded" {
  local claude="$BATS_TEST_TMPDIR/bounded-claude"
  local codex="$BATS_TEST_TMPDIR/bounded-codex"
  mkdir -p "$claude/project" "$codex"
  python3 - "$claude/project/session.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as out:
    for index in range(600):
        out.write(json.dumps({
            "type": "assistant", "sessionId": "bounded-session",
            "timestamp": f"2026-08-{1 + index // 24:02d}T{index % 24:02d}:00:00Z",
            "message": {"content": [{"type": "tool_use", "id": f"skill-{index}",
                                      "name": "Skill", "input": {"skill": f"skill-{index}"}}]},
        }) + "\n")
PY
  CLAUDE_PROJECTS_DIR="$claude" CODEX_SESSIONS_DIR="$codex" \
    run python3 "$REPORT" --operator-json --all
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/bounded-one.json"
  CLAUDE_PROJECTS_DIR="$claude" CODEX_SESSIONS_DIR="$codex" \
    run python3 "$REPORT" --operator-json --all
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/bounded-two.json"
  cmp -s "$BATS_TEST_TMPDIR/bounded-one.json" "$BATS_TEST_TMPDIR/bounded-two.json"
  python3 - "$BATS_TEST_TMPDIR/bounded-one.json" <<'PY'
import json, sys
source = json.load(open(sys.argv[1], encoding="utf-8"))["sources"]["claude"]
assert len(source["skill_invocations"]) == 500
assert source["coverage"]["state"] == "partial"
assert {item["code"] for item in source["limitations"]} == {"aggregate_truncated"}
PY
}

@test "operator mode rejects legacy output selectors instead of ignoring them" {
  run python3 "$REPORT" --operator-json --all --source claude
  [ "$status" -eq 2 ]
  [[ "$output" == *"--operator-json cannot be combined with --source"* ]]

  run python3 "$REPORT" --operator-json --all --skill execute-ticket
  [ "$status" -eq 2 ]
  [[ "$output" == *"--operator-json cannot be combined with --skill"* ]]

  run python3 "$REPORT" --operator-json --all --json
  [ "$status" -eq 2 ]
  [[ "$output" == *"--operator-json cannot be combined with --json"* ]]
}
