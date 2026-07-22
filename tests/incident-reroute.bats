#!/usr/bin/env bats
#
# incident-reroute.bats — D-L15: medic incident-repair reroute + retired
# build incident side-door + default-off build→execute-ticket wiring.
#
# Each test fails on the real defect: the build runner is a recording stub,
# so a reroute that regressed to escalating would record a call and the
# assertion `stub_calls augur-runner == 0` would fail. The retirement and
# ticket-mode cases assert on real exit codes + event/side-effect absence.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  quartet_setup
}

# ---------------------------------------------------------------------------
# Local helpers (mirroring gap-fixes' medic-loop scaffold, reroute-era).
# ---------------------------------------------------------------------------

install_agents() {
  local dir="$1" cfg="$2" name="$3"
  mkdir -p "$dir/.agents" "$dir/tmp"
  sed "s/__PROJECT_NAME__/$name/g" "$FIXTURES_DIR/$cfg" >"$dir/.agents/config.toml"
  local a
  for a in guardian augur medic scribe; do
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
  # Recording build stub — a regression must NEVER reach it post-D-L15.
  cat >"$FAKE_QD/agents/build/runner.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SHIM_LOG/augur-runner.argv"
exit 1
STUB
  chmod +x "$FAKE_QD/agents/build/runner.sh"
}

# stage a failed systemd unit + a regression classifier stub.
prep_regression() {
  local p="$1" name="$2" cls="${3:-regression}"
  UNIT="$name-web"
  OPS_JSON="$BATS_TEST_TMPDIR/ops.json"
  MENTAT_RESULT="$p/tmp/$name-design-result.json"
  jq -n --arg u "$UNIT" \
    '{cron:[], systemd:[{name:$u, state:"failed", description:"web", timerSchedule:""}]}' \
    >"$OPS_JSON"
  IID="$(printf '%s' "systemd-failed $UNIT $(date -u +%Y-%m-%d)" | sha256sum | awk '{print $1}')"
  jq -n --arg iid "$IID" --arg cls "$cls" \
    '{pass:true, errors:[], incidents_classified:[
       {incident_id:$iid, class:$cls, action:"propose_repair",
        surface:"runners", source:"systemd",
        incident_summary:"web unit failed",
        hypothesis:"a recent commit broke web"}]}' \
    >"$BATS_TEST_TMPDIR/medic-classification.json"
  make_stub_script claude \
    "cp '$BATS_TEST_TMPDIR/medic-classification.json' '$p/tmp/medic-result.json'; exit 0"
  make_stub_script systemctl '
case "$*" in
  *list-units*) echo "'"$UNIT"' loaded failed"; exit 0 ;;
  *restart*)    exit 0 ;;
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

# ---------------------------------------------------------------------------
# A. Reroute: regression → incident-repair proposal, no build escalation
# ---------------------------------------------------------------------------

@test "reroute: regression-class incident -> proposal + design event + one page, build NOT invoked" {
  make_fake_quartet
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" branch-present.toml rr1
  topo_commit_all "$p"
  prep_regression "$p" rr1

  run_medic_scan "$p"
  [ "$status" -eq 0 ]

  # (1) proposal in the mentat result file, type incident-repair, status open
  [ -f "$MENTAT_RESULT" ]
  [ "$(jq -r '.proposals[0].type'   "$MENTAT_RESULT")" = "incident-repair" ]
  [ "$(jq -r '.proposals[0].status' "$MENTAT_RESULT")" = "open" ]

  # (2) design.proposal.opened with role:design + type:incident-repair
  ev="$(events_json | jq -c 'select(.event=="design.proposal.opened")')"
  [ -n "$ev" ]
  [ "$(jq -r '.role' <<<"$ev")" = "design" ]
  [ "$(jq -r '.type' <<<"$ev")" = "incident-repair" ]

  # (3) exactly one notify fired
  run notify_log
  [ "$(printf '%s\n' "$output" | grep -c .)" = "1" ]

  # (4) the build runner was NOT invoked in incident mode (zero calls)
  [ "$(stub_calls augur-runner)" = "0" ]
}

# ---------------------------------------------------------------------------
# B. Mitigation stays UNGATED: a restart-class incident still restarts
# ---------------------------------------------------------------------------

@test "mitigation ungated: restart-class incident still fires the restart action" {
  make_fake_quartet
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" branch-present.toml rr2
  topo_commit_all "$p"
  prep_regression "$p" rr2 restart   # classifier returns class=restart

  run_medic_scan "$p"
  [ "$status" -eq 0 ]

  # medic.action.restart emitted for the failed unit — unchanged, ungated.
  ev="$(events_json | jq -c 'select(.event=="medic.action.restart")')"
  [ -n "$ev" ]
  [ "$(jq -r '.unit' <<<"$ev")" = "$UNIT" ]
  # systemctl restart <unit> actually ran.
  run stub_argv systemctl
  [[ "$output" == *"restart $UNIT"* ]]
  # And no proposal was written (restart is mitigation, not a code fix).
  [ ! -f "$MENTAT_RESULT" ]
}

# ---------------------------------------------------------------------------
# C. Retired build incident side-door
# ---------------------------------------------------------------------------

@test "retired: build --mode incident exits non-zero with the retired message, no events" {
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" can-merge-true.toml rr3
  topo_commit_all "$p"
  printf '{"incident_id":"x","summary":"s"}\n' >"$BATS_TEST_TMPDIR/inc.json"
  make_stub claude 97
  make_stub gh 97

  run run_runner build "$p" --mode incident --incident-file "$BATS_TEST_TMPDIR/inc.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"retired"* ]]
  # No events emitted at all.
  [ ! -f "$(events_file)" ] || [ -z "$(events_json)" ]
  [ "$(stub_calls claude)" = "0" ]
  [ "$(stub_calls gh)" = "0" ]
}

@test "retired: no incident-role reference remains in the build runner" {
  run grep -rn "incident-role" "$QUARTET_ROOT/agents/build/runner.sh"
  [ "$status" -ne 0 ]   # grep finds nothing
  [ -z "$output" ]
  # The role file itself is gone.
  [ ! -f "$QUARTET_ROOT/agents/build/incident-role.md" ]
}

# ---------------------------------------------------------------------------
# D. Build --mode ticket, gated behind [build] ticket_mode (DEFAULT OFF)
# ---------------------------------------------------------------------------

@test "ticket: --mode ticket disabled by default -> errors 'disabled', skill NOT invoked" {
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" branch-present.toml rr4   # no [build] ticket_mode
  topo_commit_all "$p"
  make_stub claude 97   # must never be reached
  printf '# ticket\n' >"$BATS_TEST_TMPDIR/t.md"

  run run_runner build "$p" --mode ticket --ticket-file "$BATS_TEST_TMPDIR/t.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"disabled"* ]]
  [ "$(stub_calls claude)" = "0" ]
}

@test "ticket: [build] ticket_mode=true -> dispatches the execute-ticket skill path" {
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" branch-present.toml rr5
  # Enable the flag inside the existing [build] table (no duplicate header).
  sed -i '/^\[build\]/a ticket_mode = true' "$p/.agents/config.toml"
  topo_commit_all "$p"
  # Stub claude to record its argv (the dispatch).
  make_stub claude 0
  printf '# my ticket\n' >"$p/docs-ticket.md"

  run run_runner build "$p" --mode ticket --ticket-file "$p/docs-ticket.md"
  [ "$status" -eq 0 ]
  # The skill dispatch happened: claude was invoked with the ticket path.
  [ "$(stub_calls claude)" -ge 1 ]
  run stub_argv claude
  [[ "$output" == *"execute-ticket"* ]]
  [[ "$output" == *"$p/docs-ticket.md"* ]]
}
