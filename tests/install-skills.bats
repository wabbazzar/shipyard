#!/usr/bin/env bats
#
# install-skills.bats — the installer's shared-skills symlink step + gate-file
# drop (install.sh step 4.5).
#
# Asserts:
#   * --dry-run announces it WOULD symlink the three generic skills and WOULD
#     drop gates.md, and writes NOTHING;
#   * a real run creates the three symlinks (pointing into this repo's skills/)
#     and writes .agents/gates.md;
#   * re-running is idempotent (skills "unchanged", gates.md left as-is);
#   * an existing gate file is NEVER clobbered;
#   * a real (non-symlink) .claude/skills/<name> dir is NEVER clobbered.
#
# systemctl/crontab/gh/claude are stubbed so the installer never touches the
# host's real user units or crontab.

setup() {
  load helpers
  quartet_setup
  # Neutralize every side-effecting external the installer calls.
  make_stub systemctl 0
  make_stub crontab 0 ""
  make_stub gh 0
  make_stub claude 0
  PROJ="$(make_fixture_project skilltest can-merge-true.toml)"
}

run_install() {
  QUARTET_DIR="$QUARTET_ROOT" \
  QUARTET_EVENTS_DIR="$EVENTS_DIR" \
  QUARTET_NOTIFY_CMD="$NOTIFY_CMD" \
    bash "$QUARTET_ROOT/install.sh" --project "$PROJ" "$@"
}

@test "dry-run announces the 3 skill symlinks + gates.md drop, writes nothing" {
  run run_install --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "would symlink: $PROJ/.claude/skills/polish-ticket"
  echo "$output" | grep -q "would symlink: $PROJ/.claude/skills/execute-ticket"
  echo "$output" | grep -q "would symlink: $PROJ/.claude/skills/coverage-audit"
  echo "$output" | grep -q "would drop: $PROJ/.agents/gates.md"
  # Nothing actually written.
  [ ! -e "$PROJ/.claude/skills/polish-ticket" ]
  [ ! -e "$PROJ/.agents/gates.md" ]
}

@test "real run symlinks the 3 skills into the repo skills/ and drops gates.md" {
  run run_install
  [ "$status" -eq 0 ]
  for s in polish-ticket execute-ticket coverage-audit; do
    [ -L "$PROJ/.claude/skills/$s" ]
    [ "$(readlink -f "$PROJ/.claude/skills/$s")" = "$(readlink -f "$QUARTET_ROOT/skills/$s")" ]
    [ -f "$PROJ/.claude/skills/$s/SKILL.md" ]   # resolves to a real skill
  done
  [ -f "$PROJ/.agents/gates.md" ]
  grep -q "skilltest" "$PROJ/.agents/gates.md"   # <PROJECT_NAME> substituted
}

@test "re-run is idempotent: skills unchanged, gates.md left as-is" {
  run_install >/dev/null
  # Mutate the gate file so a clobber would be detectable.
  echo "OPERATOR EDIT" >> "$PROJ/.agents/gates.md"
  run run_install
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "unchanged: $PROJ/.claude/skills/polish-ticket"
  echo "$output" | grep -q "gates.md: exists — leaving as-is"
  grep -q "OPERATOR EDIT" "$PROJ/.agents/gates.md"   # not clobbered
}

@test "an existing real .claude/skills/<name> dir is not clobbered" {
  mkdir -p "$PROJ/.claude/skills/polish-ticket"
  echo "mine" > "$PROJ/.claude/skills/polish-ticket/keep.txt"
  run run_install
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "SKIP (exists, not a symlink"
  [ -f "$PROJ/.claude/skills/polish-ticket/keep.txt" ]
  [ ! -L "$PROJ/.claude/skills/polish-ticket" ]
  # The other two still get symlinked.
  [ -L "$PROJ/.claude/skills/execute-ticket" ]
}
