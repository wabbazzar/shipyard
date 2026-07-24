#!/usr/bin/env bats
#
# relink.bats — install.sh --relink: a repair mode that recreates ONLY missing
# (or broken) installer-owned skill symlinks that --doctor flags as drift.
# Deterministic + reversible: touches nothing but $PROJECT_DIR/.claude/skills/
# symlinks — no systemd, no config, no gate file. Never clobbers a real
# file/dir. Honors --dry-run.

setup() {
  load helpers
  quartet_setup
  make_stub systemctl 0
  make_stub crontab 0 ""
  make_stub gh 0
  make_stub claude 0
  PROJ="$(make_fixture_project relinktest can-merge-true.toml)"
}

run_install() {
  QUARTET_DIR="$QUARTET_ROOT" \
  QUARTET_EVENTS_DIR="$EVENTS_DIR" \
  QUARTET_NOTIFY_CMD="$NOTIFY_CMD" \
    bash "$QUARTET_ROOT/install.sh" --project "$PROJ" "$@"
}

@test "--relink recreates a missing skill symlink (and --doctor then clean)" {
  run_install                       # baseline install: all symlinks present
  rm -f "$PROJ/.claude/skills/polish-ticket"   # simulate drift
  [ ! -e "$PROJ/.claude/skills/polish-ticket" ]
  # doctor sees the drift
  run run_install --doctor
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "skill: polish-ticket symlink missing"

  run run_install --relink
  [ "$status" -eq 0 ]
  [ -L "$PROJ/.claude/skills/polish-ticket" ]
  [ "$(readlink -f "$PROJ/.claude/skills/polish-ticket")" = "$(readlink -f "$QUARTET_ROOT/skills/polish-ticket")" ]
  # the skill-symlink drift is resolved: doctor no longer flags it (other
  # unrelated findings in the stubbed test env are not this test's concern).
  run run_install --doctor
  ! echo "$output" | grep -q "skill: polish-ticket symlink missing"
}

@test "--relink repairs a BROKEN symlink (points nowhere)" {
  run_install
  ln -sfn /nonexistent/gone "$PROJ/.claude/skills/write-ticket"
  [ ! -e "$PROJ/.claude/skills/write-ticket" ]   # broken: -e is false
  run run_install --relink
  [ "$status" -eq 0 ]
  [ "$(readlink -f "$PROJ/.claude/skills/write-ticket")" = "$(readlink -f "$QUARTET_ROOT/skills/write-ticket")" ]
}

@test "--relink NEVER clobbers a real (non-symlink) skill dir" {
  run_install
  rm -f "$PROJ/.claude/skills/bugfix"
  mkdir -p "$PROJ/.claude/skills/bugfix"
  echo "operator content" > "$PROJ/.claude/skills/bugfix/local.md"
  run run_install --relink
  [ "$status" -eq 0 ]
  [ ! -L "$PROJ/.claude/skills/bugfix" ]           # still a real dir
  [ -f "$PROJ/.claude/skills/bugfix/local.md" ]    # content untouched
  echo "$output" | grep -qi "kept.*bugfix"
}

@test "--relink --dry-run announces the repair but writes NOTHING" {
  run_install
  rm -f "$PROJ/.claude/skills/feature"
  run run_install --relink --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "would relink: $PROJ/.claude/skills/feature"
  [ ! -e "$PROJ/.claude/skills/feature" ]          # nothing created
}

@test "--relink on a clean install leaves every correct symlink as-is" {
  run_install
  run run_install --relink
  [ "$status" -eq 0 ]
  for s in polish-ticket execute-ticket coverage-audit write-ticket bugfix feature shipyard; do
    [ -L "$PROJ/.claude/skills/$s" ]
    echo "$output" | grep -q "ok: $s"
  done
}

@test "--relink rejects --theme (repair mode, like doctor/uninstall)" {
  run run_install --relink --theme spacetime
  [ "$status" -ne 0 ]
}
