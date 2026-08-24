#!/usr/bin/env bats
#
# install-skills.bats — the installer's shared-skills symlink step + gate-file
# drop (install.sh step 4.5). Claude/Hermes use .claude/skills; Codex natively
# discovers repository skills from .agents/skills.
#
# Asserts:
#   * --dry-run announces it WOULD symlink the nine installed skills and WOULD
#     drop gates.md, and writes NOTHING;
#   * a real run creates every shared skill link in both discovery locations
#     and writes .agents/gates.md;
#   * re-running is idempotent (skills "unchanged", gates.md left as-is);
#   * an existing gate file is NEVER clobbered;
#   * a real skill dir in either discovery root is NEVER clobbered.
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

@test "dry-run announces Claude/Hermes and Codex skill links + gates.md drop, writes nothing" {
  run run_install --dry-run
  [ "$status" -eq 0 ]
  for s in polish-ticket execute-ticket coverage-audit write-ticket bugfix feature shipyard ui-design eda; do
    echo "$output" | grep -q "would symlink: $PROJ/.claude/skills/$s"
    echo "$output" | grep -q "would symlink: $PROJ/.agents/skills/$s"
  done
  echo "$output" | grep -q "would drop: $PROJ/.agents/gates.md"
  # Nothing actually written.
  [ ! -e "$PROJ/.claude/skills/polish-ticket" ]
  [ ! -e "$PROJ/.claude/skills/write-ticket" ]
  [ ! -e "$PROJ/.claude/skills/eda" ]
  [ ! -e "$PROJ/.agents/skills/polish-ticket" ]
  [ ! -e "$PROJ/.agents/skills/eda" ]
  [ ! -e "$PROJ/.agents/gates.md" ]
}

@test "real run symlinks every skill into both discovery roots and drops gates.md" {
  run run_install
  [ "$status" -eq 0 ]
  for s in polish-ticket execute-ticket coverage-audit write-ticket bugfix feature shipyard ui-design eda; do
    [ -L "$PROJ/.claude/skills/$s" ]
    [ "$(readlink -f "$PROJ/.claude/skills/$s")" = "$(readlink -f "$QUARTET_ROOT/skills/$s")" ]
    [ -f "$PROJ/.claude/skills/$s/SKILL.md" ]   # resolves to a real skill
    [ -L "$PROJ/.agents/skills/$s" ]
    [ "$(readlink -f "$PROJ/.agents/skills/$s")" = "$(readlink -f "$QUARTET_ROOT/skills/$s")" ]
    [ -f "$PROJ/.agents/skills/$s/SKILL.md" ]   # Codex discovery path
  done
  [ -f "$PROJ/.agents/gates.md" ]
  grep -q "skilltest" "$PROJ/.agents/gates.md"   # <PROJECT_NAME> substituted
}

@test "shipyard discovery roots for Codex and Claude Hermes resolve one core" {
  run run_install
  [ "$status" -eq 0 ]
  claude_root="$(readlink -f "$PROJ/.claude/skills/shipyard")"
  codex_root="$(readlink -f "$PROJ/.agents/skills/shipyard")"
  core_root="$(readlink -f "$QUARTET_ROOT/skills/shipyard")"
  [ "$claude_root" = "$core_root" ]
  [ "$codex_root" = "$core_root" ]
  [ "$claude_root" = "$codex_root" ]
}

@test "re-run is idempotent: skills unchanged, gates.md left as-is" {
  run_install >/dev/null
  # Mutate the gate file so a clobber would be detectable.
  echo "OPERATOR EDIT" >> "$PROJ/.agents/gates.md"
  run run_install
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "unchanged: $PROJ/.claude/skills/polish-ticket"
  echo "$output" | grep -q "unchanged: $PROJ/.claude/skills/eda"
  echo "$output" | grep -q "unchanged: $PROJ/.agents/skills/eda"
  echo "$output" | grep -q "gates.md: exists — leaving as-is"
  grep -q "OPERATOR EDIT" "$PROJ/.agents/gates.md"   # not clobbered
}

@test "existing real ui-design dirs in both discovery roots are not clobbered" {
  mkdir -p "$PROJ/.claude/skills/ui-design" "$PROJ/.agents/skills/ui-design"
  echo "claude owner content" > "$PROJ/.claude/skills/ui-design/keep.txt"
  echo "codex owner content" > "$PROJ/.agents/skills/ui-design/keep.txt"
  run run_install
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "SKIP.*$PROJ/.claude/skills/ui-design"
  echo "$output" | grep -q "SKIP.*$PROJ/.agents/skills/ui-design"
  [ -f "$PROJ/.claude/skills/ui-design/keep.txt" ]
  [ -f "$PROJ/.agents/skills/ui-design/keep.txt" ]
  [ ! -L "$PROJ/.claude/skills/ui-design" ]
  [ ! -L "$PROJ/.agents/skills/ui-design" ]
  [ -L "$PROJ/.claude/skills/execute-ticket" ]
}

@test "existing real eda dirs in both discovery roots are not clobbered" {
  mkdir -p "$PROJ/.claude/skills/eda" "$PROJ/.agents/skills/eda"
  echo "claude owner analysis" > "$PROJ/.claude/skills/eda/keep.txt"
  echo "codex owner analysis" > "$PROJ/.agents/skills/eda/keep.txt"
  run run_install
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "SKIP.*$PROJ/.claude/skills/eda"
  echo "$output" | grep -q "SKIP.*$PROJ/.agents/skills/eda"
  grep -Fxq "claude owner analysis" "$PROJ/.claude/skills/eda/keep.txt"
  grep -Fxq "codex owner analysis" "$PROJ/.agents/skills/eda/keep.txt"
  [ ! -L "$PROJ/.claude/skills/eda" ]
  [ ! -L "$PROJ/.agents/skills/eda" ]
  [ -L "$PROJ/.claude/skills/ui-design" ]
}
