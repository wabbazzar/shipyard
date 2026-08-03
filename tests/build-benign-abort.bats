#!/usr/bin/env bats
# tests/build-benign-abort.bats — the build runner must treat benign
# preconditions (dirty main checkout / not on trunk) as a clean SKIP (exit 0),
# not a failure (exit 1). An exit 1 fails the *-helldiver systemd unit, which
# the medic then reads as a self_failure and freezes 24h (ticket 041).

setup() {
  load helpers
  quartet_setup
}

@test "build: dirty main checkout is a benign skip -> exit 0, still emits abort/dirty" {
  P="$(make_fixture_project bldirty can-merge-false.toml)"
  echo "uncommitted" > "$P/DIRTY"          # untracked at repo root -> tree dirty
  run run_runner build "$P" --mode live
  [ "$status" -eq 0 ]                        # benign skip, NOT a unit failure
  # observability preserved: the skip is still recorded
  events_json | jq -e 'select(.event=="job.end" and .reason=="dirty")' >/dev/null
}

@test "build: not on trunk is a benign skip -> exit 0, emits abort/not_trunk" {
  P="$(make_fixture_project blbranch can-merge-false.toml)"
  git -C "$P" checkout -q -b feature/x       # clean but off trunk
  run run_runner build "$P" --mode live
  [ "$status" -eq 0 ]
  events_json | jq -e 'select(.event=="job.end" and .reason=="not_trunk")' >/dev/null
}

@test "build: a genuine failure (bad --mode) still exits nonzero" {
  P="$(make_fixture_project blbadmode can-merge-false.toml)"
  run run_runner build "$P" --mode bogus
  [ "$status" -ne 0 ]
}

@test "build: installer-owned skill links in both discovery roots are not dirty" {
  P="$(make_fixture_project blskills can-merge-false.toml)"
  for root in .claude/skills .agents/skills; do
    mkdir -p "$P/$root"
  done
  # .claude is wholly untracked: the runner must enumerate its contents instead
  # of treating Git's default collapsed `?? .claude/` row as real project dirt.
  ln -s "$QUARTET_ROOT/skills/bugfix" "$P/.claude/skills/bugfix"
  ln -s "$QUARTET_ROOT/skills/write-ticket" "$P/.agents/skills/write-ticket"

  # Stop deterministically immediately after pre-flight, without a model call.
  printf '%s\n' '{"svc":"blskills-build","event":"job.end","tokens":1000000}' \
    >> "$(events_file)"
  run run_runner build "$P" --mode live

  [ "$status" -eq 0 ]
  events_json | jq -e 'select(.event=="build.skipped" and .reason=="budget")' >/dev/null
  ! events_json | jq -e 'select(.event=="job.end" and .reason=="dirty")' >/dev/null
}

@test "build: a skill link resolving outside Shipyard remains dirty" {
  P="$(make_fixture_project bloutside can-merge-false.toml)"
  mkdir -p "$P/.claude/skills" "$P/not-shipyard"
  ln -s "$P/not-shipyard" "$P/.claude/skills/bugfix"

  run run_runner build "$P" --mode live

  [ "$status" -eq 0 ]
  events_json | jq -e 'select(.event=="job.end" and .reason=="dirty")' >/dev/null
}

@test "build: a broken installer-shaped skill link remains dirty" {
  P="$(make_fixture_project blbroken can-merge-false.toml)"
  mkdir -p "$P/.agents/skills"
  ln -s "$P/missing-skill" "$P/.agents/skills/bugfix"

  run run_runner build "$P" --mode live

  [ "$status" -eq 0 ]
  events_json | jq -e 'select(.event=="job.end" and .reason=="dirty")' >/dev/null
}
