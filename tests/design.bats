#!/usr/bin/env bats
# tests/design.bats — mentat, the design-loop agent (role id `design`).
#
# No real LLM anywhere: `claude` is a PATH-shim stub returning a canned
# `--output-format json` payload whose .result is a JSON array of
# proposals. Telemetry (events/fyi/usage) is planted in a fixture project.

setup() {
  load helpers
  quartet_setup
}

RUNNER="agents/design/runner.sh"
COLLECTORS="agents/design/collectors.sh"

# Canned claude reply: a JSON array of 2 proposals, 1000+200 = 1200 tokens.
CANNED_PROPOSALS='[{"type":"feature","title":"Add CSV export","rationale":"users keep asking","evidence":"fyi: please add CSV export","suggested_scope":"export module","severity":"med"},{"type":"bug","title":"Fix nightly release failure","rationale":"release keeps failing","evidence":"job_fail=1 today","severity":"high","suggested_scope":"CI"}]'

# canned_claude_json <proposals-json> — the full --output-format json object.
canned_claude_json() {
  jq -cn --arg r "$1" '{type:"result", result:$r, usage:{input_tokens:1000, output_tokens:200}}'
}

# run_design <project> [args...] — runner with the captured env.
run_design() {
  local project="$1"; shift
  QUARTET_DIR="$QUARTET_ROOT" \
  QUARTET_EVENTS_DIR="$EVENTS_DIR" \
  QUARTET_NOTIFY_CMD="$NOTIFY_CMD" \
  QUARTET_SOURCE="test" \
    bash "$QUARTET_ROOT/$RUNNER" --project "$project" "$@"
}

opened_events() { events_json | jq -c 'select(.event=="design.proposal.opened")'; }
skipped_events() { events_json | jq -c 'select(.event=="design.proposal.skipped")'; }

source_checksums() {
  python3 - "$@" <<'PY'
import hashlib
from pathlib import Path
import sys

for raw_path in sys.argv[1:]:
    path = Path(raw_path)
    print(f"{path.name}:{hashlib.sha256(path.read_bytes()).hexdigest()}")
PY
}

# plant_telemetry <project> — canned events + fyi + usage in the fixture.
plant_telemetry() {
  local p="$1" today
  today="$(date -u +%Y-%m-%d)"
  printf '%s\n' \
    "{\"ts\":\"${today}T01:00:00Z\",\"svc\":\"$(basename "$p")-release\",\"event\":\"job.end\",\"status\":\"fail\",\"role\":\"release\"}" \
    "{\"ts\":\"${today}T01:30:00Z\",\"svc\":\"$(basename "$p")-release\",\"event\":\"job.end\",\"status\":\"ok\",\"role\":\"release\"}" \
    "{\"ts\":\"${today}T02:00:00Z\",\"svc\":\"$(basename "$p")-medic\",\"event\":\"medic.incident.detected\",\"incident_id\":\"inc_aaa\",\"role\":\"medic\"}" \
    "{\"ts\":\"${today}T02:00:01Z\",\"svc\":\"$(basename "$p")-medic\",\"event\":\"medic.incident.classified\",\"incident_id\":\"inc_aaa\",\"role\":\"medic\"}" \
    "{\"ts\":\"${today}T02:00:02Z\",\"svc\":\"$(basename "$p")-medic\",\"event\":\"medic.incident\",\"incident_id\":\"inc_aaa\",\"role\":\"medic\"}" \
    "{\"ts\":\"${today}T02:00:03Z\",\"svc\":\"$(basename "$p")-medic\",\"event\":\"medic.incident.frozen\",\"incident_id\":\"inc_aaa\",\"role\":\"medic\"}" \
    "{\"ts\":\"${today}T03:00:00Z\",\"svc\":\"$(basename "$p")-release\",\"event\":\"release.critique\",\"block\":2,\"warn\":1,\"note\":0}" \
    >> "$(events_file)"
  mkdir -p "$p/data" "$p/data/usage"
  printf '%s\n' '{"ts":"2026-01-01T00:00:00Z","id":"fyi_1","text":"please add CSV export"}' \
    >> "$p/data/fyi-requests.jsonl"
  printf '%s\n' \
    '{"ts":"2026-01-01T00:00:00Z","action":"view","path":"/dash"}' \
    '{"ts":"2026-01-01T00:01:00Z","action":"view","path":"/dash"}' \
    '{"ts":"2026-01-01T00:02:00Z","action":"export","path":"/dash"}' \
    >> "$p/data/usage/beacons.jsonl"
}

# ---------------------------------------------------------------------------
# (a) --check-config: read-only, valid JSON, correct role/display
# ---------------------------------------------------------------------------

@test "--check-config emits valid JSON with role design + display mentat (spacetime)" {
  P="$(make_fixture_project mentcc names-spacetime.toml)"
  run run_design "$P" --check-config
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
  [ "$(echo "$output" | jq -r '.role')" = "design" ]
  [ "$(echo "$output" | jq -r '.display')" = "mentat" ]
  [ "$(echo "$output" | jq -r '.budget_tokens_daily')" = "1000000" ]
  [ "$(echo "$output" | jq -r '.max_open_proposals')" = "1" ]
}

@test "--check-config writes no events and no result file" {
  P="$(make_fixture_project mentcc2 names-spacetime.toml)"
  run run_design "$P" --check-config
  [ "$status" -eq 0 ]
  [ ! -f "$(events_file)" ]
  run bash -c "ls '$P/tmp'/*mentat-result.json 2>/dev/null"
  [ -z "$output" ]
}

@test "--check-config legacy config resolves display to design (no [names])" {
  P="$(make_fixture_project mentleg absent-keys.toml)"
  run run_design "$P" --check-config
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.display')" = "design" ]
}

# ---------------------------------------------------------------------------
# (b) collectors: planted telemetry produces correct counts
# ---------------------------------------------------------------------------

@test "collectors count events, fyi, and usage from planted files" {
  P="$(make_fixture_project mentcol names-spacetime.toml)"
  plant_telemetry "$P"
  EVENT_SOURCE="$(events_file)"
  EXPECTED_UTC_DAY="$(python3 - <<'PY'
from datetime import datetime, timezone
print(datetime.now(timezone.utc).date())
PY
)"
  [ "$(basename "$EVENT_SOURCE")" = "$EXPECTED_UTC_DAY.jsonl" ]
  CHECKSUM_BEFORE="$(source_checksums "$EVENT_SOURCE")"
  run bash -c "QUARTET_DIR='$QUARTET_ROOT' QUARTET_EVENTS_DIR='$EVENTS_DIR' \
    bash '$QUARTET_ROOT/$COLLECTORS' --project '$P' --json"
  [ "$status" -eq 0 ]
  CHECKSUM_AFTER="$(source_checksums "$EVENT_SOURCE")"
  [ "$CHECKSUM_AFTER" = "$CHECKSUM_BEFORE" ]
  echo "$output" | jq -e . >/dev/null
  [ "$(echo "$output" | jq -r '.sources.events.job_fail')" = "1" ]
  [ "$(echo "$output" | jq -r '.sources.events.job_ok')" = "1" ]
  [ "$(echo "$output" | jq -r '.sources.events.medic_incidents')" = "1" ]
  [ "$(echo "$output" | jq -r '.sources.events.release_findings.block')" = "2" ]
  [ "$(echo "$output" | jq -r '.sources.fyi.count')" = "1" ]
  [ "$(echo "$output" | jq -r '.sources.usage.count')" = "3" ]
  [ "$(echo "$output" | jq -r '.sources.usage.by_action.view')" = "2" ]
}

@test "collectors drop fyi-requests an existing proposal already addresses (no re-proposal)" {
  # Regression for the overseer finding (2026-07-25): mentat re-proposed
  # already-handled fyi_2/fyi_3. A request whose id is cited by an existing
  # proposal (signal_ids OR evidence) must NOT be re-surfaced; a fresh one still is.
  P="$(make_fixture_project mentddup names-spacetime.toml)"
  mkdir -p "$P/data" "$P/tmp"
  printf '%s\n' \
    '{"ts":"2026-01-01T00:00:00Z","id":"fyi_1","text":"add CSV export"}' \
    '{"ts":"2026-01-02T00:00:00Z","id":"fyi_2","text":"support multi-city"}' \
    > "$P/data/fyi-requests.jsonl"
  # fyi_1 addressed via signal_ids, evidence cites its text; fyi_2 untouched.
  cat > "$P/tmp/mentddup-mentat-result.json" <<'JSON'
{"ts":"2026-01-03T00:00:00Z","project":"mentddup","proposals":[
  {"id":"mentat:mentddup:aaaa1111","type":"feature","title":"Add CSV export",
   "evidence":"fyi-requests.jsonl: add CSV export","signal_ids":["fyi_1"],
   "severity":"low","status":"open"}]}
JSON
  run bash -c "QUARTET_DIR='$QUARTET_ROOT' QUARTET_EVENTS_DIR='$EVENTS_DIR' \
    bash '$QUARTET_ROOT/$COLLECTORS' --project '$P' --json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.sources.fyi.count')" = "1" ]                       # only fyi_2 survives
  [ "$(echo "$output" | jq -r '[.sources.fyi.examples[].id] | index("fyi_1")')" = "null" ]
  [ "$(echo "$output" | jq -r '[.sources.fyi.examples[].id] | index("fyi_2")')" != "null" ]
}

@test "collectors write nothing to the project" {
  P="$(make_fixture_project mentcolro names-spacetime.toml)"
  plant_telemetry "$P"
  BEFORE="$(git -C "$P" status --porcelain; ls -R "$P" | md5sum)"
  run bash -c "QUARTET_DIR='$QUARTET_ROOT' QUARTET_EVENTS_DIR='$EVENTS_DIR' \
    bash '$QUARTET_ROOT/$COLLECTORS' --project '$P' --json"
  [ "$status" -eq 0 ]
  AFTER="$(git -C "$P" status --porcelain; ls -R "$P" | md5sum)"
  [ "$BEFORE" = "$AFTER" ]
}

# ---------------------------------------------------------------------------
# (c) proposal drafting: stubbed claude (2 proposals) -> result + events
# ---------------------------------------------------------------------------

@test "drafting writes a valid result file and 2 design.proposal.opened events (role:design)" {
  P="$(make_fixture_project mentdraft names-spacetime.toml)"
  # pin the cap so this exercises multi-proposal drafting independent of the
  # fleet default (now 1) — the default itself is asserted by --check-config.
  printf '\n[design]\nmax_open_proposals = 3\n' >>"$P/.agents/config.toml"
  plant_telemetry "$P"
  make_stub claude 0 "$(canned_claude_json "$CANNED_PROPOSALS")"

  run run_design "$P" --mode design
  [ "$status" -eq 0 ]

  RF="$P/tmp/mentdraft-mentat-result.json"
  [ -s "$RF" ]
  jq -e . "$RF" >/dev/null
  [ "$(jq '.proposals | length' "$RF")" = "2" ]
  [ "$(jq -r '.project' "$RF")" = "mentdraft" ]
  jq -e '.proposals | all(.status=="open" and (.id | startswith("mentat:mentdraft:")))' "$RF" >/dev/null

  [ "$(opened_events | wc -l)" -eq 2 ]
  [ "$(opened_events | jq -c 'select(.role=="design")' | wc -l)" -eq 2 ]
  # last opened event carries the run token usage
  [ "$(opened_events | jq -s '[.[].tokens] | add')" = "1200" ]
}

@test "outcome lineage: proposal events retain explicit IDs and the invocation run ID" {
  P="$(make_fixture_project mentlineage names-spacetime.toml)"
  printf '\n[design]\nmax_open_proposals = 3\n[telemetry]\noutcome_lineage = true\n' \
    >>"$P/.agents/config.toml"
  plant_telemetry "$P"
  make_stub claude 0 "$(canned_claude_json "$CANNED_PROPOSALS")"

  run run_design "$P" --mode design
  [ "$status" -eq 0 ]
  RUN_ID="$(events_json | jq -r 'select(.event=="job.start" and .role=="design") | .run_id')"
  [[ "$RUN_ID" =~ ^[0-9a-f]{32}$ ]]
  [ "$(opened_events | jq -s --arg id "$RUN_ID" \
    'length == 2 and all(.run_id == $id and (.proposal_id | type == "string"))')" = "true" ]
  events_json | jq -s -e --arg id "$RUN_ID" \
    'any(.[]; .event=="job.end" and .run_id==$id)' >/dev/null
}

# ---------------------------------------------------------------------------
# (d) open-proposal cap (<=3): 3 undecided pre-seeded -> skip + logged
# ---------------------------------------------------------------------------

@test "3 undecided proposals pre-seeded: drafting skipped, claude never called" {
  P="$(make_fixture_project mentcap names-spacetime.toml)"
  plant_telemetry "$P"
  make_stub claude 0 "$(canned_claude_json "$CANNED_PROPOSALS")"
  mkdir -p "$P/tmp"
  cat >"$P/tmp/mentcap-mentat-result.json" <<'JSON'
{"ts":"2026-01-01T00:00:00Z","project":"mentcap","proposals":[
  {"id":"mentat:mentcap:aaaaaaaa","type":"feature","title":"A","status":"open","severity":"low"},
  {"id":"mentat:mentcap:bbbbbbbb","type":"bug","title":"B","status":"open","severity":"med"},
  {"id":"mentat:mentcap:cccccccc","type":"feature","title":"C","status":"open","severity":"low"}]}
JSON

  run run_design "$P" --mode design
  [ "$status" -eq 0 ]
  [ "$(stub_calls claude)" = "0" ]
  [ "$(skipped_events | jq -c 'select(.reason=="open_cap")' | wc -l)" -eq 1 ]
  [ "$(opened_events | wc -l)" -eq 0 ]
}

@test "one decided proposal frees a slot below the cap: drafting proceeds" {
  P="$(make_fixture_project mentcapd names-spacetime.toml)"
  # cap pinned to 3 so "one decided frees a slot" is meaningful (fleet default is 1).
  printf '\n[design]\nmax_open_proposals = 3\n' >>"$P/.agents/config.toml"
  plant_telemetry "$P"
  make_stub claude 0 "$(canned_claude_json "$CANNED_PROPOSALS")"
  mkdir -p "$P/tmp" "$P/data"
  cat >"$P/tmp/mentcapd-mentat-result.json" <<'JSON'
{"ts":"2026-01-01T00:00:00Z","project":"mentcapd","proposals":[
  {"id":"mentat:mentcapd:aaaaaaaa","type":"feature","title":"A","status":"open","severity":"low"},
  {"id":"mentat:mentcapd:bbbbbbbb","type":"bug","title":"B","status":"open","severity":"med"},
  {"id":"mentat:mentcapd:cccccccc","type":"feature","title":"C","status":"open","severity":"low"}]}
JSON
  # decide one -> undecided drops to 2, one slot free
  printf '%s\n' '{"proposal_id":"mentat:mentcapd:cccccccc","decision":"reject"}' \
    > "$P/data/decisions.jsonl"

  run run_design "$P" --mode design
  [ "$status" -eq 0 ]
  [ "$(stub_calls claude)" -ge 1 ]
  # only 1 free slot -> exactly 1 new proposal opened, total stays <= 3 undecided
  [ "$(opened_events | wc -l)" -eq 1 ]
}

# ---------------------------------------------------------------------------
# (e) token-budget gate: today's design.* tokens >= cap -> skip, no claude
# ---------------------------------------------------------------------------

@test "daily token budget reached: skip + design.proposal.skipped reason=budget, claude never called" {
  P="$(make_fixture_project mentbud names-spacetime.toml)"
  plant_telemetry "$P"
  make_stub claude 0 "$(canned_claude_json "$CANNED_PROPOSALS")"
  # spacetime fixture has no [design] budget -> default 1,000,000. Pre-seed
  # a design.* event that already blew it.
  printf '%s\n' \
    "{\"ts\":\"$(date -u +%Y-%m-%d)T00:00:00Z\",\"svc\":\"mentbud-mentat\",\"event\":\"design.proposal.opened\",\"role\":\"design\",\"tokens\":1000000}" \
    >> "$(events_file)"

  run run_design "$P" --mode design
  [ "$status" -eq 0 ]
  [ "$(stub_calls claude)" = "0" ]
  [ "$(skipped_events | jq -c 'select(.reason=="budget")' | wc -l)" -eq 1 ]
  # only the pre-seeded opened event exists — no NEW one was drafted
  [ "$(opened_events | wc -l)" -eq 1 ]
  # no result file written on a budget skip
  run bash -c "ls '$P/tmp'/*mentat-result.json 2>/dev/null"
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# (f) --self-test
# ---------------------------------------------------------------------------

@test "--self-test exits 0" {
  run bash -c "QUARTET_DIR='$QUARTET_ROOT' bash '$QUARTET_ROOT/$RUNNER' --self-test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale incident excluded"* ]]
}
