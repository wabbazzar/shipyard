#!/usr/bin/env bats
#
# harness.bats — tests for the test harness itself.
#
# These assert that the tools Phase 1 will lean on actually work: the PATH
# shim really shadows a real binary and records argv, the fixture configs
# really parse through the shared loader, the fixture git topology really
# produces both trunk commit shapes with the `git revert` semantics we claim,
# and run_runner really drives a runner with a captured environment.

setup() {
  load helpers
  quartet_setup
}

# ---------------------------------------------------------------------------
# PATH shim
# ---------------------------------------------------------------------------

@test "PATH shim shadows a real binary on PATH" {
  # git is unquestionably installed; if the shim works, this one wins.
  run command -v git
  [ "$status" -eq 0 ]
  [ "$output" != "$SHIM_BIN/git" ]   # the real one, before stubbing
  real_git="$output"

  make_stub git 0 "stub-git 9.9.9"

  run command -v git
  [ "$status" -eq 0 ]
  [ "$output" = "$SHIM_BIN/git" ]

  run git --version
  [ "$status" -eq 0 ]
  [ "$output" = "stub-git 9.9.9" ]

  # ...and the real binary is still there, unharmed.
  run "$real_git" --version
  [ "$status" -eq 0 ]
  [[ "$output" == "git version"* ]]
}

@test "stub records its argv and call count" {
  make_stub gh 0 "[]"

  run gh pr checks 123 --json state
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  run gh api /repos/x/y

  [ "$(stub_calls gh)" = "2" ]
  run stub_argv gh
  [[ "$output" == *"pr checks 123 --json state"* ]]
  [[ "$output" == *"api /repos/x/y"* ]]
}

@test "stub honours a non-zero exit code" {
  make_stub claude 7 "boom"
  run claude -p "hello"
  [ "$status" -eq 7 ]
  [ "$output" = "boom" ]
  [ "$(stub_calls claude)" = "1" ]
}

@test "make_stub_script can branch on argv" {
  make_stub_script systemctl '
case "$*" in
  *is-active*) echo active; exit 0 ;;
  *) echo unknown; exit 3 ;;
esac'
  run systemctl --user is-active fake.service
  [ "$status" -eq 0 ]
  [ "$output" = "active" ]
  run systemctl --user restart fake.service
  [ "$status" -eq 3 ]
  [ "$(stub_calls systemctl)" = "2" ]
}

@test "notify stub records title and body via quartet_notify" {
  source "$QUARTET_ROOT/agents/lib/load-config.sh"
  quartet_notify "fixture title" "fixture body"
  run notify_log
  [ "$output" = "fixture title|fixture body" ]
}

# ---------------------------------------------------------------------------
# Fixture projects
# ---------------------------------------------------------------------------

@test "make_fixture_project builds a complete .agents install with a git repo" {
  proj="$(make_fixture_project demo)"
  [ -f "$proj/.agents/config.toml" ]
  for a in release build medic scribe design; do
    [ -f "$proj/.agents/$a.md" ]
  done
  [ -d "$proj/tmp" ]
  run git -C "$proj" rev-parse --abbrev-ref HEAD
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
  run git -C "$proj" status --porcelain
  [ "$output" = "" ]
  # project_name substitution happened
  run jq -r '.project_name' <<<"$(source "$QUARTET_ROOT/agents/lib/load-config.sh"; load_config_json "$proj/.agents/config.toml")"
  [ "$output" = "demo" ]
}

@test "make_fixture_project accepts an alternate config fixture" {
  proj="$(make_fixture_project demo2 can-merge-false.toml)"
  cfg="$(source "$QUARTET_ROOT/agents/lib/load-config.sh"; load_config_json "$proj/.agents/config.toml")"
  [ "$(jq -r '.medic.can_merge' <<<"$cfg")" = "false" ]
  [ "$(jq -r '.project_name' <<<"$cfg")" = "demo2" ]
}

# ---------------------------------------------------------------------------
# Config fixtures through the real loader
# ---------------------------------------------------------------------------

@test "absent-keys fixture: branch, can_merge and allow_no_ci are all absent" {
  cfg="$(load_fixture_config absent-keys.toml)"
  [ -n "$cfg" ]
  [ "$(jq -r '.branch // "ABSENT"' <<<"$cfg")" = "ABSENT" ]
  [ "$(jq -r '.medic.can_merge // "ABSENT"' <<<"$cfg")" = "ABSENT" ]
  [ "$(jq -r '.build.allow_no_ci // "ABSENT"' <<<"$cfg")" = "ABSENT" ]
  [ "$(jq -r 'has("branch")' <<<"$cfg")" = "false" ]
  [ "$(jq -r '.medic | has("can_merge")' <<<"$cfg")" = "false" ]
  [ "$(jq -r '.build | has("allow_no_ci")' <<<"$cfg")" = "false" ]
  # canonical config has no legacy sections at all
  [ "$(jq -r --arg k "au""gur" 'has($k)' <<<"$cfg")" = "false" ]
  [ "$(jq -r --arg k "guar""dian" 'has($k)' <<<"$cfg")" = "false" ]
}

@test "branch-present fixture: branch parses as main" {
  cfg="$(load_fixture_config branch-present.toml)"
  [ "$(jq -r '.branch' <<<"$cfg")" = "main" ]
}

@test "can_merge fixtures parse as true and false" {
  cfg_true="$(load_fixture_config can-merge-true.toml)"
  cfg_false="$(load_fixture_config can-merge-false.toml)"
  [ "$(jq -r '.medic.can_merge' <<<"$cfg_true")" = "true" ]
  [ "$(jq -r '.medic.can_merge' <<<"$cfg_false")" = "false" ]
  # booleans, not strings — the runners compare against literal true/false
  [ "$(jq -r '.medic.can_merge | type' <<<"$cfg_true")" = "boolean" ]
}

@test "allow-no-ci fixture: present-true parses, absent variant has no key" {
  cfg_true="$(load_fixture_config allow-no-ci-true.toml)"
  cfg_absent="$(load_fixture_config absent-keys.toml)"
  [ "$(jq -r '.build.allow_no_ci' <<<"$cfg_true")" = "true" ]
  [ "$(jq -r '.build.allow_no_ci | type' <<<"$cfg_true")" = "boolean" ]
  [ "$(jq -r '.build | has("allow_no_ci")' <<<"$cfg_absent")" = "false" ]
}

@test "load_config_json fails loudly on a missing file" {
  source "$QUARTET_ROOT/agents/lib/load-config.sh"
  run load_config_json "$BATS_TEST_TMPDIR/nope.toml"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Git topology — both trunk commit shapes
# ---------------------------------------------------------------------------

@test "make_git_topology creates a bare origin and a clone tracking trunk" {
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  [ -d "$BATS_TEST_TMPDIR/topo/origin.git" ]
  run git -C "$BATS_TEST_TMPDIR/topo/origin.git" rev-parse --is-bare-repository
  [ "$output" = "true" ]
  run git -C "$p" rev-parse --abbrev-ref HEAD
  [ "$output" = "main" ]
  run git -C "$p" rev-parse --abbrev-ref '@{upstream}'
  [ "$status" -eq 0 ]
  [ "$output" = "origin/main" ]
  # local trunk and origin trunk agree
  [ "$(git -C "$p" rev-parse main)" = "$(git -C "$p" rev-parse origin/main)" ]
}

@test "true merge produces a two-parent commit" {
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  sha="$(topo_true_merge "$p" feat-true bad.txt "regression")"
  [ "$(commit_parent_count "$p" "$sha")" = "2" ]
  run git -C "$p" rev-parse --verify --quiet "$sha^2"
  [ "$status" -eq 0 ]
  [ -f "$p/bad.txt" ]
}

@test "squash merge produces a single-parent commit" {
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  sha="$(topo_squash_merge "$p" feat-squash bad.txt "regression")"
  [ "$(commit_parent_count "$p" "$sha")" = "1" ]
  run git -C "$p" rev-parse --verify --quiet "$sha^2"
  [ "$status" -ne 0 ]
  [ -f "$p/bad.txt" ]
}

@test "git revert -m 1 succeeds on a true merge and removes the change" {
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  sha="$(topo_true_merge "$p" feat-true bad.txt "regression")"
  run git -C "$p" revert --no-edit -m 1 "$sha"
  [ "$status" -eq 0 ]
  [ ! -f "$p/bad.txt" ]
}

@test "squash merge: parent probe is the discriminator, plain revert works" {
  # NOTE (measured on git 2.43.0, 2026-07-21): `git revert -m 1 <squash-sha>`
  # does NOT fail — upstream relaxed the "mainline was specified but commit is
  # not a merge" error for -m 1. So the reliable discriminator for the Phase 1
  # revert fix is the PARENT PROBE (`rev-parse --verify <sha>^2`), not the exit
  # code of `revert -m 1`. Asking for a mainline that truly doesn't exist
  # (-m 2) still fails, which pins the commit shape.
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  sha="$(topo_squash_merge "$p" feat-squash bad.txt "regression")"

  run git -C "$p" rev-parse --verify --quiet "$sha^2"
  [ "$status" -ne 0 ]

  run git -C "$p" revert --no-edit -m 2 "$sha"
  [ "$status" -ne 0 ]
  [ -f "$p/bad.txt" ]          # nothing was reverted
  git -C "$p" revert --quit 2>/dev/null || true

  run git -C "$p" revert --no-edit "$sha"
  [ "$status" -eq 0 ]
  [ ! -f "$p/bad.txt" ]
}

@test "true merge: plain revert without -m FAILS, -m 1 is required" {
  # The mirror-image constraint: a two-parent commit cannot be reverted
  # without naming a mainline. This is what makes the Phase 1 branch a real
  # branch and not a no-op.
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  sha="$(topo_true_merge "$p" feat-true bad.txt "regression")"

  run git -C "$p" revert --no-edit "$sha"
  [ "$status" -ne 0 ]
  [[ "$output" == *"merge"* ]]
  [ -f "$p/bad.txt" ]
  git -C "$p" revert --quit 2>/dev/null || true

  run git -C "$p" revert --no-edit -m 1 "$sha"
  [ "$status" -eq 0 ]
  [ ! -f "$p/bad.txt" ]
}

@test "both topologies can coexist on one trunk" {
  p="$(make_git_topology "$BATS_TEST_TMPDIR/topo")"
  s1="$(topo_squash_merge "$p" feat-a a.txt "a")"
  s2="$(topo_true_merge "$p" feat-b b.txt "b")"
  [ "$(commit_parent_count "$p" "$s1")" = "1" ]
  [ "$(commit_parent_count "$p" "$s2")" = "2" ]
  [ "$s1" != "$s2" ]
}

# ---------------------------------------------------------------------------
# run_runner
# ---------------------------------------------------------------------------

@test "run_runner passes --project through to the runner" {
  proj="$(make_fixture_project rr)"
  # No --mode: the runner must reach its own mode validation, which proves
  # --project was accepted (a bad --project exits earlier, with a different
  # message).
  run run_runner release "$proj"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--mode required"* ]]

  run run_runner release "$BATS_TEST_TMPDIR/does-not-exist" --mode daily
  [ "$status" -eq 2 ]
  [[ "$output" == *"project dir missing"* ]]
}

@test "run_runner captures events into the per-test events dir" {
  proj="$(make_fixture_project ev)"
  head_sha="$(git -C "$proj" rev-parse HEAD)"

  run run_runner release "$proj" --mode post-merge --merge-sha "$head_sha"
  [ "$status" -eq 0 ]

  # Nothing leaked into the repo's own data/events.
  [ ! -d "$QUARTET_ROOT/data/events" ] || \
    [ -z "$(find "$QUARTET_ROOT/data/events" -newer "$proj/.agents/config.toml" -name '*.jsonl' 2>/dev/null)" ]

  [ -f "$(events_file)" ]
  line="$(events_json | jq -c 'select(.event=="job.end")')"
  [ -n "$line" ]
  [ "$(jq -r '.svc' <<<"$line")" = "ev-release" ]
  [ "$(jq -r '.status' <<<"$line")" = "ok" ]
  [ "$(jq -r '.mode' <<<"$line")" = "post-merge" ]
  [ "$(jq -r '.merge_sha' <<<"$line")" = "$head_sha" ]

  start_line="$(events_json | jq -c 'select(.event=="job.start")')"
  [ -n "$start_line" ]
  [ "$(jq -r '.source' <<<"$start_line")" = "test" ]
}

@test "run_runner surfaces a failing deterministic gate as a fail event" {
  proj="$(make_fixture_project evfail)"
  # Make the test command fail — post-merge must report status=fail, exit 1.
  sed -i 's/^test_cmd .*/test_cmd     = "false"/' "$proj/.agents/config.toml"

  run run_runner release "$proj" --mode post-merge --merge-sha "$(git -C "$proj" rev-parse HEAD)"
  [ "$status" -eq 1 ]

  line="$(events_json | jq -c 'select(.event=="job.end")')"
  [ "$(jq -r '.status' <<<"$line")" = "fail" ]
  [[ "$(jq -r '.reason' <<<"$line")" == *"vitest_failed"* ]]
}
