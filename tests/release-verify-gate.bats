#!/usr/bin/env bats
#
# release-verify-gate.bats — [release] verify_gate: a false-green guard.
#
# In hook/daily mode the model SELF-REPORTS its verdict. A hallucinated/careless
# pass:true (overseer 2026-07-25: caladan proctor reported JS check numbers in a
# pure-Python repo) would otherwise reach medic/the dispatch as a green. When
# verify_gate is set, the runner re-runs the REAL typecheck + test_cmd and
# overrides a claimed pass to fail. Unset = today's model-trusted behavior.
#
# The harness (claude) is a PATH stub that writes the result.json the model
# "returns"; test_cmd/typecheck are shell strings the runner eval's, so a test
# drives them to pass/fail directly.

setup() {
  load helpers
  quartet_setup
  make_stub systemctl 0
  make_stub notify.sh 0
}

# write a pass:true result.json at the path named in the prompt (the model's job)
stub_pass() {
  make_stub_script claude '
for a in "$@"; do _last="$a"; done
rf="$(printf "%s" "$_last" | grep -oE "\"result_file\":[[:space:]]*\"[^\"]*\"" | head -1 | sed "s/.*\"result_file\":[[:space:]]*\"//; s/\"$//")"
case "$rf" in *release-result.json) printf "%s" "{\"pass\":true,\"mode\":\"daily\",\"timestamp\":\"t\"}" > "$rf" ;; esac
printf "%s" "{\"result\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
'
}

# set [release] test_cmd / typecheck to <cmd> and (optionally) enable verify_gate
setup_cfg() {
  local proj="$1" testcmd="$2" verify="${3:-}"
  fixture_replace_in_place "$proj/.agents/config.toml" \
    '^test_cmd .*$' "test_cmd     = \"$testcmd\""
  fixture_replace_in_place "$proj/.agents/config.toml" \
    '^typecheck .*$' 'typecheck    = "true"'
  [ "$verify" = "on" ] && fixture_replace_in_place \
    "$proj/.agents/config.toml" '^\[release\]$' $'[release]\nverify_gate = true'
  return 0
}

job_status() { events_json | jq -r 'select(.event=="job.end" and (.svc|endswith("-release"))) | .status' | tail -1; }
run_release() { run_runner release "$PROJ" --mode daily; }

@test "verify_gate on: model pass but real test_cmd fails → overridden to fail (false green caught)" {
  PROJ="$(make_fixture_project vgfail can-merge-true.toml)"
  setup_cfg "$PROJ" "false" on          # test_cmd exits 1
  stub_pass
  run_release
  [ "$(job_status)" = "fail" ]
  [ "$(jq -r '.pass' "$PROJ/tmp/vgfail-release-result.json")" = "false" ]
  [ "$(jq -r '.false_green_caught' "$PROJ/tmp/vgfail-release-result.json")" = "true" ]
}

@test "verify_gate on: model pass and real gate passes → verdict stands (ok)" {
  PROJ="$(make_fixture_project vgok can-merge-true.toml)"
  setup_cfg "$PROJ" "true" on           # test_cmd exits 0
  stub_pass
  run_release
  [ "$(job_status)" = "ok" ]
  [ "$(jq -r '.pass' "$PROJ/tmp/vgok-release-result.json")" = "true" ]
  [ "$(jq -r '.false_green_caught // false' "$PROJ/tmp/vgok-release-result.json")" = "false" ]
}

@test "verify_gate UNSET (default): a model pass is trusted even if test_cmd would fail" {
  PROJ="$(make_fixture_project vgoff can-merge-true.toml)"
  setup_cfg "$PROJ" "false" ""          # test_cmd would fail, but guard is off
  stub_pass
  run_release
  [ "$(job_status)" = "ok" ]            # today's behavior: trust the model
  [ "$(jq -r '.false_green_caught // "absent"' "$PROJ/tmp/vgoff-release-result.json")" = "absent" ]
}
