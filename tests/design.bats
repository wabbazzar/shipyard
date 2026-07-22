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

# plant_telemetry <project> — canned events + fyi + usage in the fixture.
plant_telemetry() {
  local p="$1" today
  today="$(date -u +%Y-%m-%d)"
  printf '%s\n' \
    "{\"ts\":\"${today}T01:00:00Z\",\"svc\":\"$(basename "$p")-guardian\",\"event\":\"job.end\",\"status\":\"fail\",\"role\":\"release\"}" \
    "{\"ts\":\"${today}T01:30:00Z\",\"svc\":\"$(basename "$p")-guardian\",\"event\":\"job.end\",\"status\":\"ok\",\"role\":\"release\"}" \
    "{\"ts\":\"${today}T02:00:00Z\",\"svc\":\"$(basename "$p")-medic\",\"event\":\"medic.incident.opened\",\"role\":\"medic\"}" \
    "{\"ts\":\"${today}T03:00:00Z\",\"svc\":\"$(basename "$p")-guardian\",\"event\":\"release.critique\",\"block\":2,\"warn\":1,\"note\":0}" \
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
  [ "$(echo "$output" | jq -r '.max_open_proposals')" = "3" ]
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
  run bash -c "QUARTET_DIR='$QUARTET_ROOT' QUARTET_EVENTS_DIR='$EVENTS_DIR' \
    bash '$QUARTET_ROOT/$COLLECTORS' --project '$P' --json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
  [ "$(echo "$output" | jq -r '.sources.events.job_fail')" = "1" ]
  [ "$(echo "$output" | jq -r '.sources.events.job_ok')" = "1" ]
  [ "$(echo "$output" | jq -r '.sources.events.medic_incidents')" = "1" ]
  [ "$(echo "$output" | jq -r '.sources.events.release_findings.block')" = "2" ]
  [ "$(echo "$output" | jq -r '.sources.fyi.count')" = "1" ]
  [ "$(echo "$output" | jq -r '.sources.usage.count')" = "3" ]
  [ "$(echo "$output" | jq -r '.sources.usage.by_action.view')" = "2" ]
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
}
