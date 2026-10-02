#!/usr/bin/env bats
#
# job-fail-streak.bats — agents/lib/job-fail-streak.sh: read-only trailing
# job.end status=fail streak detector (design-claude-failed-diagnosis, phase 3).

setup() {
  load helpers
  quartet_setup
  SCRIPT="$QUARTET_ROOT/agents/lib/job-fail-streak.sh"
  EV="$BATS_TEST_TMPDIR/ev"
  mkdir -p "$EV"
  N=0
}

# ev_line <svc> <status> — append one job.end line with an increasing ts.
ev_line() {
  N=$((N+1))
  printf '{"ts":"2026-09-%02dT00:00:00Z","event":"job.end","svc":"%s","status":"%s"}\n' \
    "$N" "$1" "$2" >>"$EV/2026-09.jsonl"
}

streak() { run bash "$SCRIPT" --svc svc-a --events-dir "$EV" "$@"; }

@test "fail,fail -> exit 1 with one-line reason" {
  ev_line svc-a fail; ev_line svc-a fail
  streak
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  [[ "$output" == *svc-a* && "$output" == *2* ]]
}

@test "fail,skipped,fail -> skipped is neutral, streak 2 -> exit 1" {
  ev_line svc-a fail; ev_line svc-a skipped; ev_line svc-a fail
  streak
  [ "$status" -eq 1 ]
  [[ "$output" == *"2 consecutive"* ]]
}

@test "fail,ok -> exit 0" {
  ev_line svc-a fail; ev_line svc-a ok
  streak
  [ "$status" -eq 0 ]
}

@test "ok,fail,fail with --threshold 3 -> exit 0" {
  ev_line svc-a ok; ev_line svc-a fail; ev_line svc-a fail
  streak --threshold 3
  [ "$status" -eq 0 ]
}

@test "threshold override: 3 fails trips --threshold 3, one fail does not trip default" {
  ev_line svc-a fail; ev_line svc-a fail; ev_line svc-a fail
  streak --threshold 3
  [ "$status" -eq 1 ]
  rm -f "$EV"/*.jsonl; N=0
  ev_line svc-a fail
  streak
  [ "$status" -eq 0 ]
}

@test "other services' events are ignored" {
  ev_line svc-a fail; ev_line svc-b ok; ev_line svc-a fail
  streak
  [ "$status" -eq 1 ]
}

@test "empty and missing events dir -> exit 0" {
  streak
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" --svc svc-a --events-dir "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 0 ]
}

@test "malformed JSONL line is tolerated" {
  ev_line svc-a fail
  echo '{not json' >>"$EV/2026-09.jsonl"
  ev_line svc-a fail
  streak
  [ "$status" -eq 1 ]
}

@test "unknown arg -> exit 2" {
  run bash "$SCRIPT" --svc svc-a --bogus
  [ "$status" -eq 2 ]
}

@test "ts order across files: 4 fails then ok -> exit 0" {
  printf '{"ts":"2026-09-19T00:00:00Z","event":"job.end","svc":"svc-a","status":"fail"}\n{"ts":"2026-09-20T00:00:00Z","event":"job.end","svc":"svc-a","status":"fail"}\n' >"$EV/2026-09-19.jsonl"
  printf '{"ts":"2026-09-21T00:00:00Z","event":"job.end","svc":"svc-a","status":"fail"}\n{"ts":"2026-09-22T00:00:00Z","event":"job.end","svc":"svc-a","status":"fail"}\n' >"$EV/2026-09-21.jsonl"
  printf '{"ts":"2026-09-23T00:00:00Z","event":"job.end","svc":"svc-a","status":"ok"}\n' >"$EV/2026-09-23.jsonl"
  streak
  [ "$status" -eq 0 ]
  rm "$EV/2026-09-23.jsonl"
  streak
  [ "$status" -eq 1 ]
}

# --- Wired as a [[medic.checks]] entry: two scans notify at most once --------

@test "medic check design-fail-streak: two consecutive scans notify once (cooldown)" {
  FAKE_QD="$BATS_TEST_TMPDIR/fake-quartet"
  mkdir -p "$FAKE_QD/agents/build" "$FAKE_QD/agents/release"
  ln -s "$QUARTET_ROOT/agents/lib" "$FAKE_QD/agents/lib"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$FAKE_QD/agents/build/runner.sh"
  chmod +x "$FAKE_QD/agents/build/runner.sh"

  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  mkdir -p "$p/.agents" "$p/tmp"
  sed "s/__PROJECT_NAME__/ts1/g" "$FIXTURES_DIR/branch-present.toml" >"$p/.agents/config.toml"
  cat >>"$p/.agents/config.toml" <<TOML

[[medic.checks]]
name = "design-fail-streak"
cmd = 'bash "\$QUARTET_DIR/agents/lib/job-fail-streak.sh" --svc svc-a --threshold 2'
timeout_sec = 10
TOML
  for a in release build medic scribe design; do printf '# %s\nFixture.\n' "$a" >"$p/.agents/$a.md"; done
  printf 'tmp/\n' >>"$p/.gitignore"
  br="$(git -C "$p" rev-parse --abbrev-ref HEAD)"
  git -C "$p" add -A; git -C "$p" commit -q -m "fixture"; git -C "$p" push -q origin "$br"

  # Failing streak in the events dir the check reads (QUARTET_EVENTS_DIR).
  EVENTS_DIR="${EVENTS_DIR:?}"
  mkdir -p "$EVENTS_DIR"
  printf '%s\n' \
    '{"ts":"2026-09-01T00:00:00Z","event":"job.end","svc":"svc-a","status":"fail"}' \
    '{"ts":"2026-09-02T00:00:00Z","event":"job.end","svc":"svc-a","status":"fail"}' \
    >"$EVENTS_DIR/2026-09-02.jsonl"

  IID="$(printf '%s' "check design-fail-streak $(date -u +%Y-%m-%d)" | sha256sum | awk '{print $1}')"
  jq -n --arg iid "$IID" \
    '{pass:true, errors:[], incidents_classified:[
       {incident_id:$iid, class:"infra", action:"notify",
        surface:"runners", source:"check",
        incident_summary:"design-fail-streak check failed"}]}' \
    >"$BATS_TEST_TMPDIR/medic-classification.json"
  make_stub_script claude \
    "cp '$BATS_TEST_TMPDIR/medic-classification.json' '$p/tmp/medic-result.json'; exit 0"
  OPS_JSON="$BATS_TEST_TMPDIR/ops.json"
  echo '{"cron":[],"systemd":[]}' >"$OPS_JSON"

  scan() { run env QUARTET_DIR="$FAKE_QD" QUARTET_EVENTS_DIR="$EVENTS_DIR" \
      QUARTET_NOTIFY_CMD="$NOTIFY_CMD" QUARTET_OPS_JSON="$OPS_JSON" QUARTET_SOURCE=test \
      bash "$QUARTET_ROOT/agents/medic/runner.sh" --project "$p" --mode scan; }

  scan; [ "$status" -eq 0 ]
  [ "$(jq -r --arg i "$IID" '.cooldowns[$i].reason // "MISSING"' "$p/tmp/medic-state.json")" = "infra" ]
  scan; [ "$status" -eq 0 ]

  run notify_log
  n="$(printf '%s\n' "$output" | grep -c 'design-fail-streak')"
  [ "$n" = "1" ]
}
