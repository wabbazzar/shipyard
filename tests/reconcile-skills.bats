#!/usr/bin/env bats
# tests/reconcile-skills.bats — scripts/reconcile-skills.sh brings an installed
# project's skill symlinks up to the current GENERIC_SKILLS without a full
# reinstall: it creates missing symlinks, refreshes stale ones, never clobbers a
# real dir, and never touches units/config. --all discovers projects from the
# systemd user units' --project arg (HOME redirected → hermetic).

setup() {
  load helpers
  quartet_setup
}

SCRIPT="scripts/reconcile-skills.sh"
run_reconcile() { QUARTET_DIR="$QUARTET_ROOT" bash "$QUARTET_ROOT/$SCRIPT" "$@"; }

# generic_skills — the list reconcile targets, read the same way it does.
generic_skills() {
  grep -m1 -oE 'GENERIC_SKILLS="[^"]*"' "$QUARTET_ROOT/install.sh" \
    | sed 's/^GENERIC_SKILLS="//;s/"$//'
}

@test "no --project and no --all exits 2" {
  run run_reconcile
  [ "$status" -eq 2 ]
}

@test "unknown arg exits 2" {
  run run_reconcile --bogus
  [ "$status" -eq 2 ]
}

@test "creates a missing generic-skill symlink for a project" {
  P="$(make_fixture_project rc1)"
  mkdir -p "$P/.claude/skills"
  # a skill that must exist after reconcile
  local one; one="$(generic_skills | awk '{print $1}')"
  [ ! -e "$P/.claude/skills/$one" ]
  run run_reconcile --project "$P"
  [ "$status" -eq 0 ]
  [ -L "$P/.claude/skills/$one" ]
  [ "$(readlink -f "$P/.claude/skills/$one")" = "$(readlink -f "$QUARTET_ROOT/skills/$one")" ]
}

@test "does NOT clobber a real (non-symlink) skill dir" {
  P="$(make_fixture_project rc2)"
  local one; one="$(generic_skills | awk '{print $1}')"
  mkdir -p "$P/.claude/skills/$one"          # a real dir the operator owns
  printf 'mine\n' > "$P/.claude/skills/$one/keep.md"
  run run_reconcile --project "$P"
  [ "$status" -eq 0 ]
  [ ! -L "$P/.claude/skills/$one" ]          # still a real dir
  [ -f "$P/.claude/skills/$one/keep.md" ]    # content intact
}

@test "is idempotent — second run reports up-to-date, changes nothing" {
  P="$(make_fixture_project rc3)"
  run_reconcile --project "$P" >/dev/null
  run run_reconcile --project "$P"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "up-to-date"
}

@test "--all discovers a project from a unit's --project arg and relinks it" {
  P="$(make_fixture_project rc4)"
  mkdir -p "$HOME/.config/systemd/user"
  printf 'ExecStart=/bin/bash %s/agents/scribe/runner.sh --project %s --mode nightly\n' \
    "$QUARTET_ROOT" "$P" > "$HOME/.config/systemd/user/rc4-chronicler.service"
  local one; one="$(generic_skills | awk '{print $1}')"
  run run_reconcile --all
  [ "$status" -eq 0 ]
  [ -L "$P/.claude/skills/$one" ]
}
