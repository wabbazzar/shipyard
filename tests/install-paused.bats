#!/usr/bin/env bats
#
# install-paused.bats — `[install] paused = true`: a project whose scheduled
# crew is switched off on purpose (skills stay). Install must refuse to write
# or enable jobs; Doctor must flag only jobs that are STILL enabled, never
# report the intentionally missing ones as drift.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  DOCTOR_TEST_BASH="$(PATH="${SHIPYARD_TEST_COMMAND_PATH:-$PATH}" command -v bash)"
  quartet_setup
  quartet_memory_cache_setup
  UNITS="$HOME/.config/systemd/user"
  # systemctl: is-enabled <x> succeeds iff the unit file exists and no
  # sibling <x>.disabled marker (same stub shape as doctor.bats).
  make_stub_script systemctl '
u=""; for a in "$@"; do case "$a" in *.timer|*.service) u="$a";; esac; done
case "$*" in
  *is-enabled*)
    if [ -n "$u" ] && [ -f "$HOME/.config/systemd/user/$u" ] \
       && [ ! -f "$HOME/.config/systemd/user/$u.disabled" ]; then exit 0; else exit 1; fi ;;
  *) exit 0 ;;
esac'
  make_stub crontab 0 ""
  make_stub gh 0
  make_stub claude 0
  P="$(make_fixture_project pausedp clean-install.toml)"
}

do_install() {
  run env QUARTET_DIR="$QUARTET_ROOT" QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    QUARTET_NOTIFY_CMD="$NOTIFY_CMD" \
    "$DOCTOR_TEST_BASH" "$QUARTET_ROOT/install.sh" --project "$P" "$@"
}

run_doctor() {
  run env QUARTET_DIR="$QUARTET_ROOT" \
    "$DOCTOR_TEST_BASH" "$QUARTET_ROOT/install.sh" --doctor --project "$P"
}

pause_project() {
  printf '\n[install]\npaused = true\n' >>"$P/.agents/config.toml"
}

@test "paused: install refuses before writing any unit, even in --dry-run" {
  pause_project
  do_install --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"paused = true"* ]]
  do_install
  [ "$status" -eq 2 ]
  [ -z "$(ls "$UNITS" 2>/dev/null)" ]
  [ "$(stub_calls systemctl)" = "0" ]
}

@test "paused: doctor is clean when nothing is scheduled, flags a still-enabled job" {
  do_install                                  # real install first (not paused yet)
  [ "$status" -eq 0 ]
  ls "$UNITS"/pausedp-*.timer >/dev/null

  pause_project
  run_doctor                                  # timers still enabled → drift
  echo "$output"
  [ "$status" -eq 1 ]
  grep -q '^DOCTOR paused: .*still enabled while \[install\] paused = true' <<<"$output"
  ! grep -q "^DOCTOR unit:" <<<"$output"      # missing/disabled is NOT drift when paused

  for t in "$UNITS"/pausedp-*.timer; do : >"$t.disabled"; done
  run_doctor
  echo "$output"
  [ "$status" -eq 0 ]
  ! grep -q '^DOCTOR ' <<<"$output"
}
