#!/usr/bin/env bats
#
# token-caps.bats — ticket bopthere#042: retire the legacy generation.
#
# Conformance gates (would have caught the drift):
#   1. no dollar caps anywhere in the runners (D-O1: caps are token-based)
#   2. no retired display names in the live tree (post-rename vocabulary only)
# Regression cases:
#   3. medic daily token gate, svc-scoped (foreign projects must not count)
#   4. medic post-result abort surfaced as job.end status=partial
#   5. every runner records real token usage on job.end
#   6. every `claude -p` call is wrapped in `timeout` (runaway guard)
#   7. --check-config advertises the renamed, token-based budget keys
#
# NOTE: the retired names never appear literally in this file — the grep in
# test 2 scans tests/ too, so patterns are built from split strings.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  quartet_setup
}

# ---------------------------------------------------------------------------
# Local helpers
# ---------------------------------------------------------------------------

# Retired-name regex, assembled so this file never contains the words.
banned_regex() {
  printf '\\b%s%s\\b|\\b%s%s\\b' "au" "gur" "guar" "dian"
}

# fix_trunk <project-dir> — absent-keys.toml deliberately omits `branch`
# and fixtures have no origin; pin trunk so detect-trunk resolves.
fix_trunk() {
  sed -i '1i branch = "main"' "$1/.agents/config.toml"
}

# stage_ops_incident <project-dir> <name> — a failed systemd unit in ops.json
# so a medic scan detects exactly one candidate. Sets globals OPS_JSON and
# IID (the incident id the classifier stub must answer with). Must run in
# the test body, NOT a command substitution — it sets variables.
stage_ops_incident() {
  local p="$1" name="$2"
  UNIT="$name-web"
  OPS_JSON="$BATS_TEST_TMPDIR/ops.json"
  jq -n --arg u "$UNIT" \
    '{cron:[], systemd:[{name:$u, state:"failed", description:"web", timerSchedule:""}]}' \
    >"$OPS_JSON"
  export OPS_JSON
  make_stub_script systemctl 'exit 0'
  IID="$(printf '%s' "systemd-failed $UNIT $(date -u +%Y-%m-%d)" | sha256sum | awk '{print $1}')"
}

# classify_stub <project-dir> <incident-id> [extra-body]
# A claude stub that writes a benign (notify-class) classification result,
# then runs [extra-body] (e.g. `exit 1` or printing a usage envelope).
classify_stub() {
  local p="$1" iid="$2" extra="${3:-exit 0}"
  jq -n --arg iid "$iid" \
    '{pass:true, errors:[], incidents_classified:[
       {incident_id:$iid, class:"infra", action:"notify",
        surface:"runners", source:"systemd",
        incident_summary:"web unit failed", hypothesis:"transient"}]}' \
    >"$BATS_TEST_TMPDIR/classification.json"
  make_stub_script claude \
    "cp '$BATS_TEST_TMPDIR/classification.json' '$p/tmp/medic-result.json'
$extra"
}

run_medic_scan() {
  run env QUARTET_DIR="$QUARTET_ROOT" \
    QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    QUARTET_NOTIFY_CMD="$NOTIFY_CMD" \
    QUARTET_OPS_JSON="$OPS_JSON" \
    QUARTET_SOURCE="test" \
    bash "$QUARTET_ROOT/agents/medic/runner.sh" --project "$1" --mode scan
}

# seed_tokens <svc> <n> — a prior job.end with token usage in today's stream.
seed_tokens() {
  jq -nc --arg svc "$1" --argjson n "$2" \
    '{ts:"2026-01-01T00:00:00Z", svc:$svc, event:"job.end", role:"medic",
      mode:"scan", status:"ok", tokens:$n}' >>"$(events_file)"
}

# The canonical claude --output-format json envelope with 1000+200 tokens.
usage_envelope() {
  printf '%s' '{"type":"result","result":"done","usage":{"input_tokens":1000,"output_tokens":200}}'
}

last_job_end() {
  events_json | jq -c 'select(.event=="job.end")' | tail -1
}

# ---------------------------------------------------------------------------
# 1+2. Conformance gates
# ---------------------------------------------------------------------------

@test "conformance: no dollar caps left in any runner" {
  run grep -rn 'max-budget-usd\|MEDIC_BUDGET' "$QUARTET_ROOT/agents"
  echo "$output"
  [ "$status" -ne 0 ]
}

@test "conformance: no retired display names in the live tree" {
  run grep -rniE "$(banned_regex)" \
    "$QUARTET_ROOT/agents" "$QUARTET_ROOT/install.sh" \
    "$QUARTET_ROOT/skills" "$QUARTET_ROOT/tests"
  echo "$output"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 3. Medic daily token gate — svc-scoped
# ---------------------------------------------------------------------------

@test "medic gate: over-cap own-svc tokens -> skip event, claude NOT invoked" {
  p="$(make_fixture_project tokgate absent-keys.toml)"
  fix_trunk "$p"
  printf 'budget_tokens_daily = 1000000\n' >>"$p/.agents/config.toml"
  stage_ops_incident "$p" tokgate
  classify_stub "$p" "$IID"
  seed_tokens "tokgate-medic" 2000000
  seed_tokens "other-medic" 5

  run_medic_scan "$p"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(stub_calls claude)" -eq 0 ]
  events_json | jq -e 'select(.event=="medic.skipped" and .reason=="budget")' >/dev/null
  last_job_end | jq -e '.status=="skipped" and .reason=="budget"' >/dev/null
}

@test "medic gate: foreign-svc tokens do NOT count -> claude still invoked" {
  p="$(make_fixture_project tokforeign absent-keys.toml)"
  fix_trunk "$p"
  printf 'budget_tokens_daily = 1000000\n' >>"$p/.agents/config.toml"
  stage_ops_incident "$p" tokforeign
  classify_stub "$p" "$IID"
  seed_tokens "other-medic" 2000000

  run_medic_scan "$p"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(stub_calls claude)" -ge 1 ]
}

# ---------------------------------------------------------------------------
# 4. Abort surfaced
# ---------------------------------------------------------------------------

@test "medic abort: nonzero claude exit with usable result -> job.end status=partial" {
  p="$(make_fixture_project tokabort absent-keys.toml)"
  fix_trunk "$p"
  stage_ops_incident "$p" tokabort
  classify_stub "$p" "$IID" "exit 1"

  run_medic_scan "$p"
  echo "$output"
  last_job_end | jq -e '.status=="partial" and .claude_exit==1' >/dev/null
}

# ---------------------------------------------------------------------------
# 5. Token accounting on job.end — all four runners
# ---------------------------------------------------------------------------

@test "tokens: medic job.end carries real usage from the json envelope" {
  p="$(make_fixture_project tokmedic absent-keys.toml)"
  fix_trunk "$p"
  stage_ops_incident "$p" tokmedic
  classify_stub "$p" "$IID" "printf '%s' '$(usage_envelope)'"

  run_medic_scan "$p"
  echo "$output"
  last_job_end | jq -e '.tokens==1200' >/dev/null
}

@test "tokens: build job.end carries real usage" {
  p="$(make_fixture_project tokbuild absent-keys.toml)"
  fix_trunk "$p"
  git -C "$p" add -A && git -C "$p" commit -qm "fixture: pin trunk"
  make_stub_script claude \
    "printf '{\"pass\":true,\"items\":[]}' >'$p/tmp/tokbuild-build-result.json'
printf '%s' '$(usage_envelope)'"
  make_stub gh 0
  run run_runner build "$p" --mode live
  echo "$output"
  last_job_end | jq -e '.tokens==1200' >/dev/null
}

@test "tokens: release job.end carries real usage" {
  p="$(make_fixture_project tokrel absent-keys.toml)"
  fix_trunk "$p"
  make_stub_script claude \
    "printf '{\"pass\":true}' >'$p/tmp/tokrel-release-result.json'
printf '%s' '$(usage_envelope)'"
  run run_runner release "$p" --mode daily
  echo "$output"
  last_job_end | jq -e '.tokens==1200' >/dev/null
}

@test "tokens: scribe job.end carries real usage" {
  p="$(make_fixture_project tokscribe absent-keys.toml)"
  fix_trunk "$p"
  make_stub_script claude \
    "printf '{\"pass\":true}' >'$p/tmp/tokscribe-scribe-result.json'
printf '%s' '$(usage_envelope)'"
  run run_runner scribe "$p" --mode daily
  echo "$output"
  last_job_end | jq -e '.tokens==1200' >/dev/null
}

# ---------------------------------------------------------------------------
# 6. Runaway guard
# ---------------------------------------------------------------------------

@test "timeout: no bare 'claude -p' invocation remains in any runner" {
  for r in medic build release scribe; do
    run grep -nE '^[[:space:]]*claude -p' "$QUARTET_ROOT/agents/$r/runner.sh"
    echo "$r: $output"
    [ "$status" -ne 0 ]
    run grep -cE 'timeout[[:space:]]+("?\$?[A-Z_{}0-9"]+)?[[:space:]]*claude -p' \
      "$QUARTET_ROOT/agents/$r/runner.sh"
    [ "${output:-0}" -ge 1 ]
  done
}

# ---------------------------------------------------------------------------
# 7. Renamed, token-based keys in --check-config
# ---------------------------------------------------------------------------

@test "check-config: token budget keys, no dollar or retired-name keys" {
  p="$(make_fixture_project tokcfg absent-keys.toml)"
  fix_trunk "$p"
  run run_runner medic "$p" --check-config
  echo "$output"
  [ "$status" -eq 0 ]
  jq -e '.budgets.budget_tokens_daily' <<<"$output" >/dev/null
  jq -e '.budgets.build_wall_clock_sec' <<<"$output" >/dev/null
  run jq -e '.budgets.claude_usd' <<<"$output"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 8. Probe resolve passthrough (hairpin-NAT workaround, 2026-07-23)
# ---------------------------------------------------------------------------

@test "probes: optional resolve key is passed to curl as --resolve" {
  p="$(make_fixture_project tokprobe absent-keys.toml)"
  fix_trunk "$p"
  cat >>"$p/.agents/config.toml" <<'TOML'

[[medic.probes]]
name          = "local-site"
url           = "https://example.test/"
expect_status = 200
resolve       = "example.test:443:127.0.0.1"
TOML
  make_stub_script curl 'printf "200"'
  make_stub_script claude 'exit 0'
  make_stub_script systemctl 'exit 0'
  OPS_JSON="$BATS_TEST_TMPDIR/ops.json"
  jq -n '{cron:[], systemd:[]}' >"$OPS_JSON"
  export OPS_JSON

  run_medic_scan "$p"
  echo "$output"
  [ "$status" -eq 0 ]
  stub_argv curl | grep -q -- '--resolve example.test:443:127.0.0.1'
}

# ---------------------------------------------------------------------------
# 9. [[medic.checks]] subprocesses see an EXPORTED QUARTET_DIR (2026-07-23).
#    Checks run in a fresh `bash -c`, so an unexported QUARTET_DIR reaches them
#    empty — breaking `cmd = bash "$QUARTET_DIR/install.sh" --doctor ...`.
#    This case fails on the real defect (drop the export → qd-seen.txt empty).
# ---------------------------------------------------------------------------

@test "checks: a [[medic.checks]] cmd sees the exported QUARTET_DIR" {
  p="$(make_fixture_project tokcheck absent-keys.toml)"
  fix_trunk "$p"
  cat >>"$p/.agents/config.toml" <<'TOML'

[[medic.checks]]
name        = "qd-visible"
cmd         = "printf '%s' \"$QUARTET_DIR\" > qd-seen.txt"
timeout_sec = 10
TOML
  make_stub_script claude 'exit 0'
  make_stub_script systemctl 'exit 0'
  OPS_JSON="$BATS_TEST_TMPDIR/ops.json"
  jq -n '{cron:[], systemd:[]}' >"$OPS_JSON"

  # Invoke WITHOUT QUARTET_DIR in the environment — exactly like the live unit,
  # whose baked env carries only NOTIFY/OPS/EVENTS. The runner self-resolves
  # QUARTET_DIR as a plain var; only the explicit `export` makes it reach the
  # `bash -c` check subprocess. (Passing it via env, as run_medic_scan does,
  # would mask the defect — an env var is inherited whether or not re-exported.)
  run env -u QUARTET_DIR \
    QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    QUARTET_NOTIFY_CMD="$NOTIFY_CMD" \
    QUARTET_OPS_JSON="$OPS_JSON" \
    QUARTET_SOURCE="test" \
    bash "$QUARTET_ROOT/agents/medic/runner.sh" --project "$p" --mode scan
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$p/qd-seen.txt" ]
  [ "$(cat "$p/qd-seen.txt")" = "$QUARTET_ROOT" ]   # non-empty AND correct
}
