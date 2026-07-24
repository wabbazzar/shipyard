#!/usr/bin/env bats
#
# medic-transient-cooldown.bats — the medic scan's transient→stuck notify path
# must record a cooldown (ticket: medic-transient-storm-cooldown, defect 2).
#
# The 2026-07-24 storm: a persistently-failed unit was re-notified on EVERY
# 10-min scan tick because transient→stuck was the sole notify path that set no
# cooldown. Contract pinned here: two consecutive scans of the same unresolved
# transient incident emit ONE notify, and tick 1 records a `transient_stuck`
# cooldown for the stable per-UTC-day incident id.
#
# Scaffold mirrors incident-reroute.bats (the canonical medic-scan harness):
# every binary is a PATH stub — no network, no GitHub, no model.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  quartet_setup
}

install_agents() {
  local dir="$1" cfg="$2" name="$3"
  mkdir -p "$dir/.agents" "$dir/tmp"
  sed "s/__PROJECT_NAME__/$name/g" "$FIXTURES_DIR/$cfg" >"$dir/.agents/config.toml"
  local a
  for a in release build medic scribe design; do
    printf '# %s — %s\nFixture prompt.\n' "$name" "$a" >"$dir/.agents/$a.md"
  done
  grep -q '^tmp/$' "$dir/.gitignore" 2>/dev/null || printf 'tmp/\n' >>"$dir/.gitignore"
}

topo_commit_all() {
  local br; br="$(git -C "$1" rev-parse --abbrev-ref HEAD)"
  git -C "$1" add -A
  git -C "$1" commit -q -m "fixture: install .agents"
  git -C "$1" push -q origin "$br"
}

make_fake_quartet() {
  FAKE_QD="$BATS_TEST_TMPDIR/fake-quartet"
  mkdir -p "$FAKE_QD/agents/build" "$FAKE_QD/agents/release"
  ln -s "$QUARTET_ROOT/agents/lib" "$FAKE_QD/agents/lib"
  export FAKE_QD
  cat >"$FAKE_QD/agents/build/runner.sh" <<STUB
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$FAKE_QD/agents/build/runner.sh"
}

# Stage a persistently-failed unit + a classifier that always returns transient.
prep_transient() {
  local p="$1" name="$2"
  UNIT="$name-web"
  OPS_JSON="$BATS_TEST_TMPDIR/ops.json"
  jq -n --arg u "$UNIT" \
    '{cron:[], systemd:[{name:$u, state:"failed", description:"web", timerSchedule:""}]}' \
    >"$OPS_JSON"
  IID="$(printf '%s' "systemd-failed $UNIT $(date -u +%Y-%m-%d)" | sha256sum | awk '{print $1}')"
  jq -n --arg iid "$IID" \
    '{pass:true, errors:[], incidents_classified:[
       {incident_id:$iid, class:"transient", action:"retry",
        surface:"runners", source:"systemd",
        incident_summary:"web unit failed: API stalled mid-run"}]}' \
    >"$BATS_TEST_TMPDIR/medic-classification.json"
  make_stub_script claude \
    "cp '$BATS_TEST_TMPDIR/medic-classification.json' '$p/tmp/medic-result.json'; exit 0"
  # Unit stays failed forever -> retry recheck never clears -> transient->stuck.
  make_stub_script systemctl '
case "$*" in
  *list-units*) echo "'"$UNIT"' loaded failed"; exit 0 ;;
  *) exit 0 ;;
esac'
}

run_medic_scan() {
  run env QUARTET_DIR="$FAKE_QD" \
    QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    QUARTET_NOTIFY_CMD="$NOTIFY_CMD" \
    QUARTET_OPS_JSON="$OPS_JSON" \
    QUARTET_SOURCE="test" \
    bash "$QUARTET_ROOT/agents/medic/runner.sh" --project "$1" --mode scan
}

@test "transient→stuck records a cooldown; a second scan does NOT re-notify" {
  make_fake_quartet
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" branch-present.toml ts1
  topo_commit_all "$p"
  prep_transient "$p" ts1

  # Tick 1: unresolved transient -> one "transient→stuck" notify + a cooldown.
  run_medic_scan "$p"
  [ "$status" -eq 0 ]

  # The cooldown is recorded for the stable per-UTC-day id, reason transient_stuck.
  local reason
  reason="$(jq -r --arg iid "$IID" '.cooldowns[$iid].reason // "MISSING"' "$p/tmp/medic-state.json")"
  [ "$reason" = "transient_stuck" ]

  # A frozen event was emitted on the transient→stuck path (parity w/ siblings).
  ev="$(events_json | jq -c --arg iid "$IID" \
        'select(.event=="medic.incident.frozen" and .incident_id==$iid and .reason=="transient_stuck")')"
  [ -n "$ev" ]

  # Tick 2 (same UTC day): the incident is unchanged; the cooldown must suppress it.
  run_medic_scan "$p"
  [ "$status" -eq 0 ]

  # CONTRACT: exactly ONE transient→stuck notify across both ticks (buggy: 2).
  run notify_log
  local n; n="$(printf '%s\n' "$output" | grep -c 'transient→stuck')"
  [ "$n" = "1" ]
}
