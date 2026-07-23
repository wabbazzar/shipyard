#!/usr/bin/env bats
# tests/shipyard-learn.bats — `/shipyard learn "<lesson>"` routes a lesson
# through the ADAPTING.md taxonomy (project-specific / generic / install-time)
# to a deterministic destination. No model call — routing is deterministic
# (explicit --to, else a keyword heuristic; ambiguous/empty ⇒ exit 2).

setup() {
  load helpers
  quartet_setup
}

SH="skills/shipyard/shipyard.sh"
run_shipyard() { QUARTET_DIR="$QUARTET_ROOT" bash "$QUARTET_ROOT/$SH" "$@"; }

@test "empty lesson exits 2" {
  P="$(make_fixture_project l1)"
  run run_shipyard learn "" --project "$P"
  [ "$status" -eq 2 ]
}

@test "ambiguous lesson (no --to, no signal) exits 2" {
  P="$(make_fixture_project l2)"
  run run_shipyard learn "some vague thing" --project "$P"
  [ "$status" -eq 2 ]
}

@test "project-specific route appends a note to .agents/<role>.md" {
  P="$(make_fixture_project l3)"
  run run_shipyard learn --to project --role release "prefer small diffs" --project "$P"
  [ "$status" -eq 0 ]
  grep -qF "shipyard:learn:" "$P/.agents/release.md"
  grep -qF "prefer small diffs" "$P/.agents/release.md"
}

@test "generic route drafts a docs/tickets stub (not a direct core edit)" {
  P="$(make_fixture_project l4)"
  run run_shipyard learn --to generic "cap every model call" --project "$P"
  [ "$status" -eq 0 ]
  run bash -c "ls '$P'/docs/tickets/learned-*.md 2>/dev/null | wc -l"
  [ "$output" -eq 1 ]
  grep -qi "generic" "$P"/docs/tickets/learned-*.md
}

@test "install-time route drafts an installer-question proposal" {
  P="$(make_fixture_project l5)"
  run run_shipyard learn --to install "ask about theme at setup" --project "$P"
  [ "$status" -eq 0 ]
  run bash -c "ls '$P'/docs/tickets/installer-question-*.md 2>/dev/null | wc -l"
  [ "$output" -eq 1 ]
}

@test "heuristic: 'every project' classifies as generic without --to" {
  P="$(make_fixture_project l6)"
  run run_shipyard learn "this applies to every project in the fleet" --project "$P"
  [ "$status" -eq 0 ]
  run bash -c "ls '$P'/docs/tickets/learned-*.md 2>/dev/null | wc -l"
  [ "$output" -eq 1 ]
}

@test "invalid --to value exits 2" {
  P="$(make_fixture_project l7)"
  run run_shipyard learn --to bogus "x" --project "$P"
  [ "$status" -eq 2 ]
}

@test "invalid --role exits 2" {
  P="$(make_fixture_project l8)"
  run run_shipyard learn --to project --role nope "x" --project "$P"
  [ "$status" -eq 2 ]
}
