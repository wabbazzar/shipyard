#!/usr/bin/env bats
#
# gap-fixes.bats — Phase 1 gap fixes, test-first.
#
# Covers:
#   1a  medic passes --project to guardian post-merge
#   1b  shape-aware, honest revert (squash vs true merge; medic.action.revert)
#   1c  augur_can_merge defaults to FALSE
#   1d  zero CI checks fails the gate unless augur.allow_no_ci=true (waived loudly)
#   1e  shared detect_trunk() — config wins, origin/HEAD detected, no silent master
#   1f  --check-config on all four runners (read-only effective-gates JSON)
#   1g  medic --self-test (both commit shapes, honest failure)

bats_require_minimum_version 1.5.0   # `run --separate-stderr` (Phase 9 tests)

setup() {
  load helpers
  quartet_setup
}

# ---------------------------------------------------------------------------
# Local helpers
# ---------------------------------------------------------------------------

# install_agents <project-dir> <config-fixture> <name>
#
# Drops a .agents install (config from tests/fixtures + the four prompt
# files) into an existing repo (e.g. a make_git_topology clone). Does NOT
# commit — callers that need a clean tree run topo_commit_all after any
# config edits.
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

# topo_commit_all <project-dir> — commit + push everything on the current branch.
topo_commit_all() {
  local br
  br="$(git -C "$1" rev-parse --abbrev-ref HEAD)"
  git -C "$1" add -A
  git -C "$1" commit -q -m "fixture: install .agents"
  git -C "$1" push -q origin "$br"
}

# make_fake_quartet — a QUARTET_DIR whose child runners (augur, guardian)
# are recording stubs, with the REAL agents/lib symlinked in. Lets a test
# drive the real medic runner while intercepting its child invocations
# (they're called by absolute path, so PATH shims can't catch them).
make_fake_quartet() {
  FAKE_QD="$BATS_TEST_TMPDIR/fake-quartet"
  mkdir -p "$FAKE_QD/agents/build" "$FAKE_QD/agents/release"
  ln -s "$QUARTET_ROOT/agents/lib" "$FAKE_QD/agents/lib"
  export FAKE_QD
}

# write_guardian_stub <exit-code> — recording guardian runner in FAKE_QD.
write_guardian_stub() {
  cat >"$FAKE_QD/agents/release/runner.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SHIM_LOG/guardian-runner.argv"
exit $1
STUB
  chmod +x "$FAKE_QD/agents/release/runner.sh"
}

# write_augur_stub <result-dest> <result-src> — recording augur runner in
# FAKE_QD that "succeeds" by copying a prepared result file into place.
write_augur_stub() {
  cat >"$FAKE_QD/agents/build/runner.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SHIM_LOG/augur-runner.argv"
cp "$2" "$1"
exit 0
STUB
  chmod +x "$FAKE_QD/agents/build/runner.sh"
}

# medic_incident_iid <unit-name> — the incident_id medic's detect_scan_runners
# computes for a failed systemd unit today (stable_id "systemd-failed" name day).
medic_incident_iid() {
  printf '%s' "systemd-failed $1 $(date -u +%Y-%m-%d)" | sha256sum | awk '{print $1}'
}

# write_build_recording_stub — a build/runner.sh in FAKE_QD that RECORDS its
# argv and exits non-zero. Post-D-L15 medic must NEVER invoke it for a
# regression; a recorded call is a reroute regression the test catches.
write_build_recording_stub() {
  cat >"$FAKE_QD/agents/build/runner.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SHIM_LOG/augur-runner.argv"
exit 1
STUB
  chmod +x "$FAKE_QD/agents/build/runner.sh"
}

# prep_medic_loop <project-dir> <name> [merge-sha] — shared setup for the
# medic scan → classify → (D-L15 reroute) proposal loop, all stubs.
# Sets: UNIT, IID, OPS_JSON, MENTAT_RESULT. The classifier stub returns a
# regression-class incident; a recording build stub proves medic does NOT
# escalate to build anymore.
prep_medic_loop() {
  local p="$1" name="$2"
  UNIT="$name-web"
  IID="$(medic_incident_iid "$UNIT")"
  OPS_JSON="$BATS_TEST_TMPDIR/ops.json"
  # Legacy configs (no [names]) resolve design→"design".
  MENTAT_RESULT="$p/tmp/$name-design-result.json"
  jq -n --arg u "$UNIT" \
    '{cron:[], systemd:[{name:$u, state:"failed", description:"fixture web", timerSchedule:""}]}' \
    >"$OPS_JSON"

  # claude stub: writes medic's classification result (class=regression).
  jq -n --arg iid "$IID" \
    '{pass:true, errors:[], incidents_classified:[
       {incident_id:$iid, class:"regression", action:"propose_repair",
        surface:"runners", source:"systemd",
        incident_summary:"fixture web unit failed",
        hypothesis:"recent commit broke web"}]}' \
    >"$BATS_TEST_TMPDIR/medic-classification.json"
  make_stub_script claude \
    "cp '$BATS_TEST_TMPDIR/medic-classification.json' '$p/tmp/medic-result.json'; exit 0"

  # A recording build stub — proves the code-fix escalation is retired.
  write_build_recording_stub

  # systemctl stub (harmless; the reroute never retriggers a unit).
  make_stub_script systemctl '
case "$*" in
  *list-units*) echo "'"$UNIT"' loaded failed"; exit 0 ;;
  *) exit 0 ;;
esac'
}

# run_medic_scan <project-dir> — real medic runner, fake QUARTET_DIR children.
run_medic_scan() {
  run env QUARTET_DIR="$FAKE_QD" \
    QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    QUARTET_NOTIFY_CMD="$NOTIFY_CMD" \
    QUARTET_OPS_JSON="$OPS_JSON" \
    QUARTET_SOURCE="test" \
    bash "$QUARTET_ROOT/agents/medic/runner.sh" --project "$1" --mode scan
}

# ---------------------------------------------------------------------------
# 1a / 1b — D-L15 incident-repair reroute (was: escalate-to-augur + revert)
#
# A regression-class incident no longer escalates to build/augur. Medic
# writes an immediate incident-repair PROPOSAL into the design loop's result
# file, emits design.proposal.opened AS design, pages once, and never touches
# git. These tests pin that new contract.
# ---------------------------------------------------------------------------

@test "1a: regression writes an incident-repair proposal (correct schema), not a build escalation" {
  make_fake_quartet
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" branch-present.toml m1a
  topo_commit_all "$p"

  prep_medic_loop "$p" m1a

  run_medic_scan "$p"
  [ "$status" -eq 0 ]

  # A proposal landed in the mentat result file with the right schema.
  [ -f "$MENTAT_RESULT" ]
  [ "$(jq -r '.proposals | length' "$MENTAT_RESULT")" = "1" ]
  prop="$(jq -c '.proposals[0]' "$MENTAT_RESULT")"
  [ "$(jq -r '.type'     <<<"$prop")" = "incident-repair" ]
  [ "$(jq -r '.severity' <<<"$prop")" = "high" ]
  [ "$(jq -r '.status'   <<<"$prop")" = "open" ]
  [ "$(jq -r '.suggested_scope' <<<"$prop")" = "runners" ]
  [[ "$(jq -r '.id' <<<"$prop")" == mentat:m1a:* ]]

  # The build runner was NEVER invoked (the code-fix side-door is retired).
  [ "$(stub_calls augur-runner)" = "0" ]
  [ ! -f "$SHIM_LOG/guardian-runner.argv" ]
}

@test "1b: reroute does NOT invoke the build runner in incident mode (zero calls)" {
  make_fake_quartet
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" branch-present.toml m1bs
  topo_commit_all "$p"

  prep_medic_loop "$p" m1bs

  run_medic_scan "$p"
  [ "$status" -eq 0 ]

  # No incident-mode escalation happened, and no revert action was recorded
  # (medic never merged anything to revert).
  [ "$(stub_calls augur-runner)" = "0" ]
  [ -z "$(events_json | jq -c 'select(.event=="medic.action.revert")')" ]
  [ -z "$(events_json | jq -c 'select(.event=="build.incident.attempted")')" ]
  # The action ledger records propose_repair, not escalate_augur.
  act="$(jq -c '.actions_taken[] | select(.action=="propose_repair")' "$p/tmp/medic-result.json")"
  [ -n "$act" ]
  [ "$(jq -r '.outcome' <<<"$act")" = "proposed" ]
  [ -z "$(jq -c '.actions_taken[] | select(.action=="escalate_augur")' "$p/tmp/medic-result.json")" ]
}

@test "1b: reroute emits design.proposal.opened AS design (role + svc + type + severity)" {
  make_fake_quartet
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" branch-present.toml m1bt
  topo_commit_all "$p"

  prep_medic_loop "$p" m1bt

  run_medic_scan "$p"
  [ "$status" -eq 0 ]

  ev="$(events_json | jq -c 'select(.event=="design.proposal.opened")')"
  [ -n "$ev" ]
  [ "$(jq -r '.role'     <<<"$ev")" = "design" ]
  [ "$(jq -r '.svc'      <<<"$ev")" = "m1bt-design" ]
  [ "$(jq -r '.type'     <<<"$ev")" = "incident-repair" ]
  [ "$(jq -r '.severity' <<<"$ev")" = "high" ]
  [ "$(jq -r '.tokens'   <<<"$ev")" = "0" ]
  # The proposal_id on the event matches the one written to the result file.
  [ "$(jq -r '.proposal_id' <<<"$ev")" = "$(jq -r '.proposals[0].id' "$MENTAT_RESULT")" ]
}

@test "1b: reroute pages exactly once — 'incident-repair proposed … awaiting stamp'" {
  make_fake_quartet
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" branch-present.toml m1bf
  topo_commit_all "$p"

  prep_medic_loop "$p" m1bf

  run_medic_scan "$p"
  [ "$status" -eq 0 ]

  run notify_log
  [ "$(printf '%s\n' "$output" | grep -c .)" = "1" ]
  [[ "$output" == *"incident-repair proposed"* ]]
  [[ "$output" == *"awaiting stamp in the dispatch"* ]]
}

# ---------------------------------------------------------------------------
# 1c — augur_can_merge defaults to FALSE
# ---------------------------------------------------------------------------

@test "1c: check-config reports can_merge=false when augur_can_merge absent" {
  # absent-keys has no branch either — give the repo a resolvable origin/HEAD.
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" absent-keys.toml c1c
  run run_runner build "$p" --check-config
  [ "$status" -eq 0 ]
  jq -e . <<<"$output" >/dev/null
  [ "$(jq -r '.can_merge' <<<"$output")" = "false" ]
}

@test "1c: check-config reports can_merge=true when configured true" {
  proj="$(make_fixture_project c1ct can-merge-true.toml)"
  run run_runner medic "$proj" --check-config
  [ "$status" -eq 0 ]
  jq -e . <<<"$output" >/dev/null
  [ "$(jq -r '.can_merge' <<<"$output")" = "true" ]
}

# ---------------------------------------------------------------------------
# 1d — zero CI checks must not pass silently
# ---------------------------------------------------------------------------

# prep_augur_incident <project-dir> <name> — a valid incident file plus
# claude/gh stubs that EXPLODE if invoked. Post-D-L15 the retired incident
# path must exit before touching either. Sets INC_FILE.
prep_augur_incident() {
  local p="$1" name="$2"
  local iid="cafe0123456789abcdef0123456789abcdef012345"
  INC_FILE="$BATS_TEST_TMPDIR/incident.json"
  jq -n --arg iid "$iid" \
    '{incident_id:$iid, detected_at:"2026-07-21T00:00:00Z", source:"systemd",
      surface:"runners", summary:"fixture web down", hypothesis:"x", evidence:{}}' \
    >"$INC_FILE"
  # If the retired path ever reached claude/gh, these blow the run up.
  make_stub claude 97
  make_stub gh 97
}

@test "1d: build --mode incident is RETIRED — exits 3, prints the message, emits no events" {
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" can-merge-true.toml a1d
  sed -i '/^wall_clock_sec/a in_scope_paths = ["*"]' "$p/.agents/config.toml"
  topo_commit_all "$p"
  prep_augur_incident "$p" a1d

  run run_runner build "$p" --mode incident --incident-file "$INC_FILE"
  [ "$status" -eq 3 ]
  [[ "$output" == *"retired"* ]]
  [[ "$output" == *"design loop"* ]]

  # No events, no result file, no claude/gh calls — a clean, loud no-op.
  [ ! -f "$(events_file)" ] || [ -z "$(events_json)" ]
  [ ! -f "$p/tmp/a1d-augur-result.json" ]
  [ "$(stub_calls claude)" = "0" ]
  [ "$(stub_calls gh)" = "0" ]
}

@test "1d: incident retirement holds regardless of allow_no_ci/can_merge config" {
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" allow-no-ci-true.toml a1dw
  sed -i '/^wall_clock_sec/a in_scope_paths = ["*"]' "$p/.agents/config.toml"
  topo_commit_all "$p"
  prep_augur_incident "$p" a1dw

  run run_runner build "$p" --mode incident --incident-file "$INC_FILE"
  [ "$status" -eq 3 ]
  [[ "$output" == *"retired"* ]]
  # No build.incident.* events of any kind.
  [ ! -f "$(events_file)" ] || [ -z "$(events_json | jq -c 'select(.event|startswith("build.incident"))')" ]
  [ "$(stub_calls gh)" = "0" ]
}

# ---------------------------------------------------------------------------
# 1e — shared detect_trunk()
# ---------------------------------------------------------------------------

@test "1e: detect_trunk — config branch wins" {
  proj="$(make_fixture_project dt1 branch-present.toml)"   # no origin at all
  # shellcheck disable=SC1091
  source "$QUARTET_ROOT/agents/lib/detect-trunk.sh"
  cfg="$(load_fixture_config branch-present.toml)"
  run detect_trunk "$cfg" "$proj"
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "1e: detect_trunk — origin/HEAD detected when config branch absent" {
  # Trunk deliberately named neither main nor master: only real detection
  # can produce it.
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo" trunk1)"
  # shellcheck disable=SC1091
  source "$QUARTET_ROOT/agents/lib/detect-trunk.sh"
  cfg="$(load_fixture_config absent-keys.toml)"
  run detect_trunk "$cfg" "$p"
  [ "$status" -eq 0 ]
  [ "$output" = "trunk1" ]
}

@test "1e: detect_trunk — unresolvable fails loudly, never defaults to master" {
  proj="$(make_fixture_project dt3 absent-keys.toml)"      # no branch, no origin
  # shellcheck disable=SC1091
  source "$QUARTET_ROOT/agents/lib/detect-trunk.sh"
  cfg="$(load_fixture_config absent-keys.toml)"
  run detect_trunk "$cfg" "$proj"
  [ "$status" -eq 2 ]
  [[ "$output" == *trunk* ]]
  [[ "$output" != *"master"* ]]
}

@test "1e: runner on a trunk-less project exits 2 mentioning trunk" {
  proj="$(make_fixture_project dt4 absent-keys.toml)"
  run run_runner build "$proj" --check-config
  [ "$status" -eq 2 ]
  [[ "$output" == *trunk* ]]
  [[ "$output" != *"master"* ]]
}

# ---------------------------------------------------------------------------
# 1f — --check-config on all four runners
# ---------------------------------------------------------------------------

@test "1f: all four runners --check-config emit correct effective gates, read-only" {
  proj="$(make_fixture_project cc1 allow-no-ci-true.toml)"
  # Any claude/gh call would be a side effect — make them explode.
  make_stub claude 97
  make_stub gh 97

  for agent in build release medic scribe; do
    run run_runner "$agent" "$proj" --check-config
    [ "$status" -eq 0 ]
    jq -e . <<<"$output" >/dev/null
    [ "$(jq -r '.agent' <<<"$output")" = "$agent" ]
    [ "$(jq -r '.role' <<<"$output")" = "$agent" ]
    [ "$(jq -r '.project' <<<"$output")" = "cc1" ]
    [ "$(jq -r '.trunk' <<<"$output")" = "main" ]
    [ "$(jq -r '.can_merge' <<<"$output")" = "true" ]
    [ "$(jq -r '.allow_no_ci' <<<"$output")" = "true" ]
    [ "$(jq -r '.budgets | type' <<<"$output")" = "object" ]
  done

  # STRICTLY read-only: no events, no result files, no claude/gh calls.
  [ ! -f "$(events_file)" ] || [ -z "$(events_json)" ]
  [ -z "$(ls -A "$proj/tmp")" ]
  [ "$(stub_calls claude)" = "0" ]
  [ "$(stub_calls gh)" = "0" ]
}

@test "1f: check-config defaults — absent keys report false gates" {
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" absent-keys.toml cc2
  run run_runner release "$p" --check-config
  [ "$status" -eq 0 ]
  [ "$(jq -r '.can_merge' <<<"$output")" = "false" ]
  [ "$(jq -r '.allow_no_ci' <<<"$output")" = "false" ]
  [ "$(jq -r '.trunk' <<<"$output")" = "main" ]   # detected from origin/HEAD
  [ -z "$(ls -A "$p/tmp")" ]
}

@test "1f: augur and scribe check-config include their scope globs" {
  proj="$(make_fixture_project cc3 allow-no-ci-true.toml)"
  run run_runner build "$proj" --check-config
  [ "$status" -eq 0 ]
  [ "$(jq -r '.in_scope_paths | type' <<<"$output")" = "array" ]
  [ "$(jq -r '.forbidden_paths | type' <<<"$output")" = "array" ]
  run run_runner scribe "$proj" --check-config
  [ "$status" -eq 0 ]
  [ "$(jq -r '.content_paths | type' <<<"$output")" = "array" ]
}

# ---------------------------------------------------------------------------
# 1g — medic --self-test
# ---------------------------------------------------------------------------

@test "1g: medic --self-test exercises both commit shapes and exits 0" {
  run bash "$QUARTET_ROOT/agents/medic/runner.sh" --self-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"squash"* ]]
  [[ "$output" == *"true-merge"* ]]
}

@test "1g: medic --self-test detects a sabotaged revert" {
  cat >"$BATS_TEST_TMPDIR/sabotage.sh" <<'EOF'
# Sabotaged revert: claims success, reverts nothing.
medic_revert_merge() { return 0; }
EOF
  run env MEDIC_REVERT_LIB="$BATS_TEST_TMPDIR/sabotage.sh" \
    bash "$QUARTET_ROOT/agents/medic/runner.sh" --self-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
}

@test "1b: a re-detected incident dedups by title — no second proposal, no second page" {
  make_fake_quartet
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" branch-present.toml m1bp
  topo_commit_all "$p"

  prep_medic_loop "$p" m1bp

  # First tick: proposal opened, one page.
  run_medic_scan "$p"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.proposals | length' "$MENTAT_RESULT")" = "1" ]

  # Second tick (same day, same incident → same title): must dedup.
  run_medic_scan "$p"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.proposals | length' "$MENTAT_RESULT")" = "1" ]   # still ONE

  # Exactly one design.proposal.opened across both ticks, and one page.
  [ "$(events_json | jq -c 'select(.event=="design.proposal.opened")' | grep -c .)" = "1" ]
  run notify_log
  [ "$(printf '%s\n' "$output" | grep -c 'incident-repair proposed')" = "1" ]
}

@test "phase11: build --mode ticket with ticket_mode absent -> disabled (exit 2, no-op)" {
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" absent-keys.toml p3neg
  topo_commit_all "$p"
  make_stub claude 97   # dispatch must NOT happen when disabled
  printf '# ticket\n' >"$BATS_TEST_TMPDIR/ticket.md"

  run run_runner build "$p" --mode ticket --ticket-file "$BATS_TEST_TMPDIR/ticket.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ticket_mode disabled"* ]]
  [ "$(stub_calls claude)" = "0" ]
}

# ---------------------------------------------------------------------------
# Phase 9 — canonical role IDs + install-time theme layer
#
# THE SAFETY PROPERTY: a config with no [names] block must keep the exact
# unit/svc display names it has today (build→augur, release→guardian), while
# the event `role:` field and event-name prefixes move to canonical ids.
# ---------------------------------------------------------------------------

@test "phase9: no [names] config — release svc is the role id, role=release, no deprecation" {
  proj="$(make_fixture_project glegacy can-merge-true.toml)"
  head_sha="$(git -C "$proj" rev-parse HEAD)"

  run --separate-stderr run_runner release "$proj" --mode post-merge --merge-sha "$head_sha"
  [ "$status" -eq 0 ]
  # the legacy normalization is retired — nothing to deprecation-warn about
  [[ "$stderr" != *"deprecated"* ]]

  line="$(events_json | jq -c 'select(.event=="job.end")')"
  [ -n "$line" ]
  [ "$(jq -r '.svc'  <<<"$line")" = "glegacy-release" ]    # role id IS the display
  [ "$(jq -r '.role' <<<"$line")" = "release" ]
  [ "$(jq -r '.status' <<<"$line")" = "ok" ]
}

@test "phase9: no [names] config — build check-config role=build display=build, canonical keys" {
  proj="$(make_fixture_project blegacy can-merge-true.toml)"

  run --separate-stderr run_runner build "$proj" --check-config
  [ "$status" -eq 0 ]
  jq -e . <<<"$output" >/dev/null                          # clean JSON on stdout
  [ "$(jq -r '.role'    <<<"$output")" = "build" ]
  [ "$(jq -r '.display' <<<"$output")" = "build" ]         # role id IS the display
  [ "$(jq -r '.can_merge'   <<<"$output")" = "true" ]      # [medic] can_merge, canonical
  [[ "$stderr" != *"deprecated"* ]]
}

@test "phase9: spacetime [names] — check-config shows role:release display:proctor, build:helldiver" {
  proj="$(make_fixture_project stc names-spacetime.toml)"

  run run_runner release "$proj" --check-config
  [ "$status" -eq 0 ]
  jq -e . <<<"$output" >/dev/null
  [ "$(jq -r '.role'    <<<"$output")" = "release" ]
  [ "$(jq -r '.display' <<<"$output")" = "proctor" ]

  run run_runner build "$proj" --check-config
  [ "$status" -eq 0 ]
  [ "$(jq -r '.role'    <<<"$output")" = "build" ]
  [ "$(jq -r '.display' <<<"$output")" = "helldiver" ]
}

@test "phase9: spacetime — release runner post-merge emits svc <proj>-proctor role release" {
  proj="$(make_fixture_project stp names-spacetime.toml)"
  head_sha="$(git -C "$proj" rev-parse HEAD)"

  run run_runner release "$proj" --mode post-merge --merge-sha "$head_sha"
  [ "$status" -eq 0 ]
  line="$(events_json | jq -c 'select(.event=="job.end")')"
  [ "$(jq -r '.svc'  <<<"$line")" = "stp-proctor" ]        # themed display
  [ "$(jq -r '.role' <<<"$line")" = "release" ]            # role is still canonical
}

@test "phase9: legacy [augur]/[guardian] sections are NOT normalized (retired 2026-07-22)" {
  cfg="$(load_fixture_config legacy-augur-can-merge-true.toml)"
  # the loader passes raw TOML through; legacy sections no longer back-fill
  [ "$(jq -r '.medic.can_merge'   <<<"$cfg")" = "null" ]
  [ "$(jq -r '.build.allow_no_ci' <<<"$cfg")" = "null" ]
  [ "$(jq -r '.release.test_cmd'  <<<"$cfg")" = "null" ]
  # the raw legacy keys are still present in the JSON — just unused
  [ "$(jq -r '.augur.allow_no_ci'     <<<"$cfg")" = "true" ]
  [ "$(jq -r '.medic.augur_can_merge' <<<"$cfg")" = "true" ]
}

@test "phase9/D-L15: medic reroute on legacy config — proposal event AS design, no build.incident.* escalation" {
  make_fake_quartet
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" legacy-augur-can-merge-true.toml m9
  topo_commit_all "$p"

  prep_medic_loop "$p" m9

  run_medic_scan "$p"
  [ "$status" -eq 0 ]

  # The proposal event carries the DESIGN svc/role (legacy display=design)...
  pev="$(events_json | jq -c 'select(.event=="design.proposal.opened")')"
  [ -n "$pev" ]
  [ "$(jq -r '.svc'  <<<"$pev")" = "m9-design" ]
  [ "$(jq -r '.role' <<<"$pev")" = "design" ]
  # ...while medic's OWN lifecycle events keep the legacy medic svc + role.
  jline="$(events_json | jq -c 'select(.event=="job.end" and .svc=="m9-medic")')"
  [ -n "$jline" ]
  [ "$(jq -r '.role' <<<"$jline")" = "medic" ]

  # The retired escalation path emits NONE of its old events.
  [ -z "$(events_json | jq -c 'select(.event=="build.incident.attempted")')" ]
  [ -z "$(events_json | jq -c 'select(.event=="build.incident.merged")')" ]
  [ -z "$(events_json | jq -c 'select(.event=="release.post_merge.run")')" ]
  [ "$(stub_calls augur-runner)" = "0" ]
}

# ---------------------------------------------------------------------------
# Theme re-bake dedupe: a rename/theme change must never leave two unit sets
# ---------------------------------------------------------------------------

@test "re-install with a new theme sweeps the old-name unit set for the same role" {
  make_stub systemctl 0
  make_stub crontab 0 ""
  make_stub gh 0
  make_stub claude 0
  P="$(make_fixture_project themedup can-merge-true.toml)"
  UNITS="$HOME/.config/systemd/user"

  # First install: default display names are the role ids — themedup-release.
  QUARTET_DIR="$QUARTET_ROOT" bash "$QUARTET_ROOT/install.sh" \
    --project "$P" --agents release >/dev/null
  [ -f "$UNITS/themedup-release.service" ]
  [ -f "$UNITS/themedup-release.timer" ]
  # Plus a hand-planted LEGACY-name unit for the same role (old guardian dir
  # alias) — the sweep must catch it too.
  sed 's#agents/release/runner.sh#agents/guardian/runner.sh#; ' \
    "$UNITS/themedup-release.service" >"$UNITS/themedup-guardian.service"
  cp "$UNITS/themedup-release.timer" "$UNITS/themedup-guardian.timer"

  # Re-install with a theme: new name written, old-name set for the SAME
  # role removed — this is the duplicate-initiation bug.
  run env QUARTET_DIR="$QUARTET_ROOT" bash "$QUARTET_ROOT/install.sh" \
    --project "$P" --agents release --theme spacetime
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed stale duplicate: themedup-release"* ]]
  [[ "$output" == *"removed stale duplicate: themedup-guardian"* ]]
  [ -f "$UNITS/themedup-proctor.service" ]
  [ -f "$UNITS/themedup-proctor.timer" ]
  [ ! -e "$UNITS/themedup-release.service" ]
  [ ! -e "$UNITS/themedup-release.timer" ]
  [ ! -e "$UNITS/themedup-guardian.service" ]
  [ ! -e "$UNITS/themedup-guardian.timer" ]
}

@test "dry-run announces the stale-duplicate sweep without touching files" {
  make_stub systemctl 0
  make_stub crontab 0 ""
  make_stub gh 0
  make_stub claude 0
  P="$(make_fixture_project themedry can-merge-true.toml)"
  UNITS="$HOME/.config/systemd/user"

  QUARTET_DIR="$QUARTET_ROOT" bash "$QUARTET_ROOT/install.sh" \
    --project "$P" --agents release >/dev/null
  [ -f "$UNITS/themedry-release.service" ]

  run env QUARTET_DIR="$QUARTET_ROOT" bash "$QUARTET_ROOT/install.sh" \
    --project "$P" --agents release --theme spacetime --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would remove stale duplicate: themedry-release"* ]]
  [ -f "$UNITS/themedry-release.service" ]   # untouched on dry-run
}

@test "delivery retry reuses the cached critique instead of re-running claude" {
  make_stub claude 0 '{"type":"result","result":"warn|src/a.ts|no test","usage":{"input_tokens":10,"output_tokens":5}}'
  make_stub claude-note 3
  P="$(make_fixture_project critcache can-merge-true.toml)"
  mkdir -p "$P/tmp"
  printf 'src/a.ts %s\n' "$(date +%s)" >"$P/tmp/critic-queue-s9"
  touch -d "2 minutes ago" "$P/tmp/critic-queue-s9"
  export CRITIC_IDLE_SEC=1 CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"

  QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    bash "$QUARTET_ROOT/agents/release/critic-watch.sh" --project "$P" --session s9 --once
  [ -s "$P/tmp/critic-queue-s9" ]          # exit 3 kept the queue
  C1="$(stub_calls claude)"                         # prompt is multi-line; compare counts
  [ "$C1" -ge 1 ]

  run env QUARTET_EVENTS_DIR="$EVENTS_DIR" CRITIC_IDLE_SEC=1 \
    CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note" \
    bash "$QUARTET_ROOT/agents/release/critic-watch.sh" --project "$P" --session s9 --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"reusing cached critique"* ]]
  [ "$(stub_calls claude)" = "$C1" ]                # NOT re-run
}
