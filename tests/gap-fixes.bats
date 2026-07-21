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
  for a in guardian augur medic scribe; do
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
  mkdir -p "$FAKE_QD/agents/augur" "$FAKE_QD/agents/guardian"
  ln -s "$QUARTET_ROOT/agents/lib" "$FAKE_QD/agents/lib"
  export FAKE_QD
}

# write_guardian_stub <exit-code> — recording guardian runner in FAKE_QD.
write_guardian_stub() {
  cat >"$FAKE_QD/agents/guardian/runner.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SHIM_LOG/guardian-runner.argv"
exit $1
STUB
  chmod +x "$FAKE_QD/agents/guardian/runner.sh"
}

# write_augur_stub <result-dest> <result-src> — recording augur runner in
# FAKE_QD that "succeeds" by copying a prepared result file into place.
write_augur_stub() {
  cat >"$FAKE_QD/agents/augur/runner.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SHIM_LOG/augur-runner.argv"
cp "$2" "$1"
exit 0
STUB
  chmod +x "$FAKE_QD/agents/augur/runner.sh"
}

# medic_incident_iid <unit-name> — the incident_id medic's detect_scan_runners
# computes for a failed systemd unit today (stable_id "systemd-failed" name day).
medic_incident_iid() {
  printf '%s' "systemd-failed $1 $(date -u +%Y-%m-%d)" | sha256sum | awk '{print $1}'
}

# prep_medic_loop <project-dir> <name> <merge-sha> — shared setup for the
# full medic scan → classify → augur → guardian post-merge loop, all stubs.
# Sets: UNIT, IID, OPS_JSON.
prep_medic_loop() {
  local p="$1" name="$2" sha="$3"
  UNIT="$name-web"
  IID="$(medic_incident_iid "$UNIT")"
  OPS_JSON="$BATS_TEST_TMPDIR/ops.json"
  jq -n --arg u "$UNIT" \
    '{cron:[], systemd:[{name:$u, state:"failed", description:"fixture web", timerSchedule:""}]}' \
    >"$OPS_JSON"

  # claude stub: writes medic's classification result (class=regression).
  jq -n --arg iid "$IID" \
    '{pass:true, errors:[], incidents_classified:[
       {incident_id:$iid, class:"regression", action:"escalate_augur",
        surface:"runners", source:"systemd",
        incident_summary:"fixture web unit failed",
        hypothesis:"recent commit broke web"}]}' \
    >"$BATS_TEST_TMPDIR/medic-classification.json"
  make_stub_script claude \
    "cp '$BATS_TEST_TMPDIR/medic-classification.json' '$p/tmp/medic-result.json'; exit 0"

  # augur stub result: pass=true with the landed merge sha.
  jq -n --arg iid "$IID" --arg sha "$sha" \
    '{pass:true, incident_id:$iid, branch:("medic-incident-" + $iid[0:12]),
      pr_url:"https://github.com/example/proj/pull/9", merge_sha:$sha,
      files_changed:["web.txt"], errors:[]}' \
    >"$BATS_TEST_TMPDIR/augur-stub-result.json"
  write_augur_stub "$p/tmp/$name-augur-result.json" "$BATS_TEST_TMPDIR/augur-stub-result.json"

  # systemctl stub for the retrigger path.
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
# 1a — medic passes --project to guardian post-merge
# ---------------------------------------------------------------------------

@test "1a: medic invokes guardian post-merge WITH --project" {
  make_fake_quartet
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" branch-present.toml m1a
  topo_commit_all "$p"
  sha="$(topo_true_merge "$p" feat-fix web.txt "fixed web")"
  git -C "$p" push -q origin main

  prep_medic_loop "$p" m1a "$sha"
  write_guardian_stub 0   # post-merge validation passes

  run_medic_scan "$p"
  [ "$status" -eq 0 ]

  [ -f "$SHIM_LOG/guardian-runner.argv" ]
  argv="$(cat "$SHIM_LOG/guardian-runner.argv")"
  [[ "$argv" == *"--mode post-merge"* ]]
  [[ "$argv" == *"--merge-sha $sha"* ]]
  [[ "$argv" == *"--project $p"* ]]
}

# ---------------------------------------------------------------------------
# 1b — shape-aware honest revert
# ---------------------------------------------------------------------------

@test "1b: squash merge reverted — trunk clean, event outcome=reverted" {
  make_fake_quartet
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" branch-present.toml m1bs
  topo_commit_all "$p"
  sha="$(topo_squash_merge "$p" feat-bad bad.txt "regression")"
  git -C "$p" push -q origin main
  [ "$(commit_parent_count "$p" "$sha")" = "1" ]

  prep_medic_loop "$p" m1bs "$sha"
  write_guardian_stub 1   # post-merge validation FAILS → medic must revert

  run_medic_scan "$p"
  [ "$status" -eq 0 ]

  # The merged change is actually gone from trunk (local and origin).
  [ ! -f "$p/bad.txt" ]
  run git -C "$p" show "origin/main:bad.txt"
  [ "$status" -ne 0 ]

  ev="$(events_json | jq -c 'select(.event=="medic.action.revert")')"
  [ -n "$ev" ]
  [ "$(jq -r '.outcome' <<<"$ev")" = "reverted" ]
  [ "$(jq -r '.merge_sha' <<<"$ev")" = "$sha" ]

  run notify_log
  [[ "$output" == *"reverted"* ]]
  [[ "$output" != *"revert_failed"* ]]
}

@test "1b: true merge reverted — trunk clean, event outcome=reverted" {
  make_fake_quartet
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" branch-present.toml m1bt
  topo_commit_all "$p"
  sha="$(topo_true_merge "$p" feat-bad bad.txt "regression")"
  git -C "$p" push -q origin main
  [ "$(commit_parent_count "$p" "$sha")" = "2" ]

  prep_medic_loop "$p" m1bt "$sha"
  write_guardian_stub 1

  run_medic_scan "$p"
  [ "$status" -eq 0 ]

  [ ! -f "$p/bad.txt" ]
  ev="$(events_json | jq -c 'select(.event=="medic.action.revert")')"
  [ -n "$ev" ]
  [ "$(jq -r '.outcome' <<<"$ev")" = "reverted" ]
}

@test "1b: failed revert is reported honestly — outcome=revert_failed, no false claim" {
  make_fake_quartet
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" branch-present.toml m1bf
  topo_commit_all "$p"
  sha="$(topo_squash_merge "$p" feat-bad bad.txt "regression")"
  git -C "$p" push -q origin main

  # Force the revert to fail: dirty the file the revert must touch.
  printf 'uncommitted local edit\n' >>"$p/bad.txt"

  prep_medic_loop "$p" m1bf "$sha"
  write_guardian_stub 1

  run_medic_scan "$p"
  [ "$status" -eq 0 ]

  # Nothing was reverted...
  [ -f "$p/bad.txt" ]
  # ...and medic says so.
  ev="$(events_json | jq -c 'select(.event=="medic.action.revert")')"
  [ -n "$ev" ]
  [ "$(jq -r '.outcome' <<<"$ev")" = "revert_failed" ]

  run notify_log
  [[ "$output" == *"revert_failed"* ]]
  # No false "…; reverted." success claim.
  [[ "$output" != *"; reverted"* ]]
}

# ---------------------------------------------------------------------------
# 1c — augur_can_merge defaults to FALSE
# ---------------------------------------------------------------------------

@test "1c: check-config reports can_merge=false when augur_can_merge absent" {
  # absent-keys has no branch either — give the repo a resolvable origin/HEAD.
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" absent-keys.toml c1c
  run run_runner augur "$p" --check-config
  [ "$status" -eq 0 ]
  jq -e . <<<"$output" >/dev/null
  [ "$(jq -r '.can_merge' <<<"$output")" = "false" ]
}

@test "1c: check-config reports can_merge=true when configured true" {
  proj="$(make_fixture_project c1ct augur-can-merge-true.toml)"
  run run_runner medic "$proj" --check-config
  [ "$status" -eq 0 ]
  jq -e . <<<"$output" >/dev/null
  [ "$(jq -r '.can_merge' <<<"$output")" = "true" ]
}

# ---------------------------------------------------------------------------
# 1d — zero CI checks must not pass silently
# ---------------------------------------------------------------------------

# prep_augur_incident <project-dir> <name> — stubs + incident file for a
# full augur incident run in which claude "fixes" the issue and opens a PR,
# and gh reports zero CI checks. Sets INC_FILE.
prep_augur_incident() {
  local p="$1" name="$2"
  local iid="cafe0123456789abcdef0123456789abcdef012345"
  INC_FILE="$BATS_TEST_TMPDIR/incident.json"
  jq -n --arg iid "$iid" \
    '{incident_id:$iid, detected_at:"2026-07-21T00:00:00Z", source:"systemd",
      surface:"runners", summary:"fixture web down", hypothesis:"x", evidence:{}}' \
    >"$INC_FILE"

  # claude stub runs with cwd = the incident worktree: commit a fix, push
  # the branch, drop a passing result with a PR URL.
  jq -n --arg iid "$iid" \
    '{pass:true, incident_id:$iid, branch:("medic-incident-" + $iid[0:12]),
      pr_url:"https://github.com/example/proj/pull/7", merge_sha:"",
      files_changed:["augur-fix.txt"], errors:[]}' \
    >"$BATS_TEST_TMPDIR/augur-claude-result.json"
  make_stub_script claude "
printf 'fix\n' > augur-fix.txt
git add augur-fix.txt
git commit -q -m 'augur: fix web'
git push -q origin HEAD
cp '$BATS_TEST_TMPDIR/augur-claude-result.json' '$p/tmp/$name-augur-result.json'
exit 0"

  # gh: zero CI checks; merge/view succeed if reached.
  make_stub_script gh '
case "$1 $2" in
  "pr checks") echo "[]"; exit 0 ;;
  "pr merge")  exit 0 ;;
  "pr view")   echo "MERGED"; exit 0 ;;
  *) exit 0 ;;
esac'
}

@test "1d: no CI checks + allow_no_ci absent -> gate_fail ci_no_checks, no merge" {
  # can_merge=true so the run reaches the CI gate; allow_no_ci absent.
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" augur-can-merge-true.toml a1d
  sed -i '/^wall_clock_sec/a in_scope_paths = ["*"]' "$p/.agents/config.toml"
  topo_commit_all "$p"
  prep_augur_incident "$p" a1d

  run run_runner augur "$p" --mode incident --incident-file "$INC_FILE"
  [ "$status" -eq 0 ]   # gate_fail exits 0 — PR stays open for review

  # The gate refused: merge_blocked event with reason ci_no_checks...
  ev="$(events_json | jq -c 'select(.event=="augur.incident.merge_blocked")')"
  [ -n "$ev" ]
  [ "$(jq -r '.reason' <<<"$ev")" = "ci_no_checks" ]
  # ...result records the refusal...
  [ "$(jq -r '.errors | index("ci_no_checks") != null' "$p/tmp/a1d-augur-result.json")" = "true" ]
  [ "$(jq -r '.merge_sha' "$p/tmp/a1d-augur-result.json")" = "" ]
  # ...and gh pr merge was never run.
  run stub_argv gh
  [[ "$output" != *"pr merge"* ]]
}

@test "1d: no CI checks + allow_no_ci=true -> passes AND emits ci_waived" {
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" allow-no-ci-true.toml a1dw
  sed -i '/^wall_clock_sec/a in_scope_paths = ["*"]' "$p/.agents/config.toml"
  topo_commit_all "$p"
  prep_augur_incident "$p" a1dw

  run run_runner augur "$p" --mode incident --incident-file "$INC_FILE"
  [ "$status" -eq 0 ]

  # The waiver is loud:
  ev="$(events_json | jq -c 'select(.event=="augur.incident.ci_waived")')"
  [ -n "$ev" ]
  [ "$(jq -r '.project' <<<"$ev")" = "a1dw" ]
  # And the merge went ahead (gh pr merge invoked, job ended ok).
  run stub_argv gh
  [[ "$output" == *"pr merge"* ]]
  end_ev="$(events_json | jq -c 'select(.event=="job.end")')"
  [ "$(jq -r '.status' <<<"$end_ev")" = "ok" ]
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
  run run_runner augur "$proj" --check-config
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

  for agent in guardian augur medic scribe; do
    run run_runner "$agent" "$proj" --check-config
    [ "$status" -eq 0 ]
    jq -e . <<<"$output" >/dev/null
    [ "$(jq -r '.agent' <<<"$output")" = "$agent" ]
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
  run run_runner guardian "$p" --check-config
  [ "$status" -eq 0 ]
  [ "$(jq -r '.can_merge' <<<"$output")" = "false" ]
  [ "$(jq -r '.allow_no_ci' <<<"$output")" = "false" ]
  [ "$(jq -r '.trunk' <<<"$output")" = "main" ]   # detected from origin/HEAD
  [ -z "$(ls -A "$p/tmp")" ]
}

@test "1f: augur and scribe check-config include their scope globs" {
  proj="$(make_fixture_project cc3 allow-no-ci-true.toml)"
  run run_runner augur "$proj" --check-config
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

@test "1b: revert that cannot be pushed is reported as revert_failed" {
  make_fake_quartet
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" branch-present.toml m1bp
  topo_commit_all "$p"
  sha="$(topo_squash_merge "$p" feat-bad bad.txt "regression")"
  git -C "$p" push -q origin main

  # Local revert will succeed; the push to origin must not.
  git -C "$p" remote set-url --push origin "$BATS_TEST_TMPDIR/no-such-origin.git"

  prep_medic_loop "$p" m1bp "$sha"
  write_guardian_stub 1

  run_medic_scan "$p"
  [ "$status" -eq 0 ]

  # Origin still carries the bad change — that is what the fleet sees...
  run git -C "$p" show "origin/main:bad.txt"
  [ "$status" -eq 0 ]
  # ...so medic must NOT claim success.
  ev="$(events_json | jq -c 'select(.event=="medic.action.revert")')"
  [ -n "$ev" ]
  [ "$(jq -r '.outcome' <<<"$ev")" = "revert_failed" ]

  run notify_log
  [[ "$output" == *"revert_failed"* ]]
}

@test "phase3: synthetic incident with augur_can_merge absent — PR stays open, no merge" {
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  install_agents "$p" absent-keys.toml p3neg
  sed -i '/^\[augur\]/a in_scope_paths = ["*"]' "$p/.agents/config.toml"
  topo_commit_all "$p"
  prep_augur_incident "$p" p3neg

  run run_runner augur "$p" --mode incident --incident-file "$INC_FILE"
  [ "$status" -eq 0 ]

  # gh pr merge was never invoked — the PR is left open for human review.
  run stub_argv gh
  [[ "$output" != *"pr merge"* ]]
  # And the refusal is on the record.
  ev="$(events_json | jq -c 'select(.event=="augur.incident.merge_blocked")')"
  [ -n "$ev" ]
  [ "$(jq -r '.reason' <<<"$ev")" = "merge_disabled_by_config" ]
}
