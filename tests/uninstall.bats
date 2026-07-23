#!/usr/bin/env bats
#
# uninstall.bats — `install.sh --uninstall --project <p> [--dry-run]`
# (ticket: shipyard-doctor-uninstall). Removes exactly the installer-owned
# surface (crew units/timers + shared-skill symlinks that resolve into
# $QUARTET_DIR/skills), leaves .agents/ + data/ untouched, and reinstall
# converges to a fresh install's unit set.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  quartet_setup
  UNITS="$HOME/.config/systemd/user"
  make_stub_script systemctl '
u=""; for a in "$@"; do case "$a" in *.timer) u="$a";; esac; done
case "$*" in
  *is-enabled*)
    if [ -n "$u" ] && [ -f "$HOME/.config/systemd/user/$u" ] \
       && [ ! -f "$HOME/.config/systemd/user/$u.disabled" ]; then exit 0; else exit 1; fi ;;
  *) exit 0 ;;
esac'
  make_stub crontab 0 ""
  make_stub gh 0
  make_stub claude 0
  P="$(make_fixture_project unp clean-install.toml)"
}

do_install() {
  QUARTET_DIR="$QUARTET_ROOT" QUARTET_EVENTS_DIR="$EVENTS_DIR" \
  QUARTET_NOTIFY_CMD="$NOTIFY_CMD" \
    bash "$QUARTET_ROOT/install.sh" --project "$P" "$@" >/dev/null 2>&1
}
run_uninstall() {
  run env QUARTET_DIR="$QUARTET_ROOT" \
    bash "$QUARTET_ROOT/install.sh" --uninstall --project "$P" "$@"
}
unit_set() { ls "$UNITS" 2>/dev/null | grep -E "^unp-.*\.(service|timer)$" | sort; }
agents_digest() { find "$P/.agents" -type f -exec md5sum {} \; | sort; }

# ---------------------------------------------------------------------------

@test "uninstall removes all crew units/timers + owned symlinks" {
  do_install
  [ -n "$(unit_set)" ]
  [ -L "$P/.claude/skills/execute-ticket" ]

  run_uninstall
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$(unit_set)" ]                                  # every crew unit gone
  for s in polish-ticket execute-ticket coverage-audit write-ticket bugfix feature; do
    [ ! -L "$P/.claude/skills/$s" ]
  done
  [[ "$output" == *"left in place"* ]]
  [[ "$output" == *".agents/"* ]]
}

@test "uninstall leaves .agents/ (config + prompts + gates.md) byte-identical" {
  do_install
  before="$(agents_digest)"
  [ -f "$P/.agents/gates.md" ]
  run_uninstall
  [ "$status" -eq 0 ]
  after="$(agents_digest)"
  [ "$before" = "$after" ]
}

@test "uninstall leaves project data/ untouched" {
  do_install
  mkdir -p "$P/data"
  echo '{"keep":true}' >"$P/data/decisions.jsonl"
  run_uninstall
  [ "$status" -eq 0 ]
  [ -f "$P/data/decisions.jsonl" ]
  [ "$(cat "$P/data/decisions.jsonl")" = '{"keep":true}' ]
}

@test "uninstall --dry-run prints the plan and writes NOTHING" {
  do_install
  before_units="$(unit_set)"
  run_uninstall --dry-run
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"would disable + remove"* ]]
  [[ "$output" == *"DRY RUN"* ]]
  [ "$(unit_set)" = "$before_units" ]                  # units untouched
  [ -L "$P/.claude/skills/execute-ticket" ]            # symlink untouched
}

@test "uninstall calls disable --now per timer + a daemon-reload" {
  do_install
  : > "$SHIM_LOG/systemctl.argv"
  run_uninstall
  [ "$status" -eq 0 ]
  run grep -c 'disable --now unp-.*\.timer' "$SHIM_LOG/systemctl.argv"
  [ "$output" -ge 1 ]
  grep -q 'daemon-reload' "$SHIM_LOG/systemctl.argv"
}

@test "uninstall then install == fresh install unit set (reinstall convergence)" {
  do_install
  fresh="$(unit_set)"
  [ -n "$fresh" ]
  run_uninstall
  [ "$status" -eq 0 ]
  [ -z "$(unit_set)" ]
  do_install
  [ "$(unit_set)" = "$fresh" ]
}

@test "uninstall keeps a real (non-symlink) skill dir" {
  do_install
  rm "$P/.claude/skills/bugfix"
  mkdir -p "$P/.claude/skills/bugfix"
  echo mine >"$P/.claude/skills/bugfix/keep.txt"
  run_uninstall
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$P/.claude/skills/bugfix/keep.txt" ]           # not clobbered
  [[ "$output" == *"kept (real file/dir"* ]]
}

@test "uninstall keeps a skill symlink resolving OUTSIDE shipyard skills" {
  do_install
  ln -sfn /etc/hostname "$P/.claude/skills/feature"
  run_uninstall
  echo "$output"
  [ "$status" -eq 0 ]
  [ -L "$P/.claude/skills/feature" ]                   # foreign target left alone
  [[ "$output" == *"resolves outside"* ]]
}
