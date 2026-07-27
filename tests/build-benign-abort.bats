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

@test "build: an untracked shipyard skill symlink alone is NOT dirty -> proceeds past pre-flight" {
  P="$(make_fixture_project blskill can-merge-false.toml)"
  # A sibling skill already tracked (real fleet state) so git reports the new
  # symlink as its own line, not a collapsed untracked ".claude/" directory.
  mkdir -p "$P/.claude/skills"
  ln -s "$QUARTET_ROOT/skills/feature" "$P/.claude/skills/feature"
  git -C "$P" add .claude/skills/feature
  git -C "$P" commit -q -m "track feature skill"
  ln -s "$QUARTET_ROOT/skills/bugfix" "$P/.claude/skills/bugfix"   # untracked, resolves into shipyard
  run run_runner build "$P" --mode live
  # Not the benign dirty-abort: install drift alone must not block the run.
  ! events_json | jq -e 'select(.event=="job.end" and .reason=="dirty")' >/dev/null
}

@test "build: a real edit alongside a skill symlink still aborts dirty" {
  P="$(make_fixture_project blskillreal can-merge-false.toml)"
  mkdir -p "$P/.claude/skills"
  ln -s "$QUARTET_ROOT/skills/feature" "$P/.claude/skills/feature"
  git -C "$P" add .claude/skills/feature
  git -C "$P" commit -q -m "track feature skill"
  ln -s "$QUARTET_ROOT/skills/bugfix" "$P/.claude/skills/bugfix"   # benign, exempt
  echo "uncommitted" > "$P/DIRTY"                                  # real edit, not exempt
  run run_runner build "$P" --mode live
  [ "$status" -eq 0 ]                        # still a benign skip (exit 0), not a failure
  events_json | jq -e 'select(.event=="job.end" and .reason=="dirty")' >/dev/null
}
