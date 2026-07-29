#!/usr/bin/env bats
# Native macOS scheduler coverage. The suite forces launchd while keeping HOME
# hermetic and stubs launchctl/plutil, so it runs on Linux CI too.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  quartet_setup
  export SHIPYARD_SCHEDULER=launchd
  JOBS="$HOME/Library/LaunchAgents"
  make_stub launchctl 0
  make_stub plutil 0
  make_stub crontab 0 ""
  make_stub gh 0
  make_stub claude 0
}

launchd_fixture() {
  P="$(make_fixture_project macp clean-install.toml)"
  grep -v '^scribe[[:space:]]*=' "$P/.agents/config.toml" >"$P/.agents/config.toml.next"
  mv "$P/.agents/config.toml.next" "$P/.agents/config.toml"
}

do_install() {
  QUARTET_DIR="$QUARTET_ROOT" QUARTET_EVENTS_DIR="$EVENTS_DIR" \
  QUARTET_NOTIFY_CMD="$NOTIFY_CMD" \
    /bin/bash "$QUARTET_ROOT/install.sh" --project "$P" \
      --agents build,release,medic "$@"
}

@test "launchd install emits and loads exactly the requested role subset" {
  launchd_fixture
  do_install >/dev/null

  [ -f "$JOBS/macp-build.plist" ]
  [ -f "$JOBS/macp-release.plist" ]
  [ -f "$JOBS/macp-medic.plist" ]
  [ ! -e "$JOBS/macp-scribe.plist" ]

  grep -Fq "<string>$P</string>" "$JOBS/macp-build.plist"
  grep -Fq "$QUARTET_ROOT/agents/build/runner.sh" "$JOBS/macp-build.plist"
  grep -Fq '<key>Hour</key><integer>3</integer>' "$JOBS/macp-build.plist"
  grep -Fq '<key>Minute</key><integer>30</integer>' "$JOBS/macp-build.plist"
  grep -Fq '<key>StartInterval</key>' "$JOBS/macp-medic.plist"
  grep -Fq '<integer>600</integer>' "$JOBS/macp-medic.plist"
  grep -Fq '<key>QUARTET_EVENTS_DIR</key>' "$JOBS/macp-build.plist"

  [ "$(grep -c '^bootstrap ' "$SHIM_LOG/launchctl.argv")" -eq 3 ]
  grep -Fq "bootstrap gui/" "$SHIM_LOG/launchctl.argv"
}

@test "launchd install is idempotent and doctor sees a clean loaded crew" {
  launchd_fixture
  do_install >/dev/null
  first_config="$(cksum "$P/.agents/config.toml")"
  do_install >/dev/null
  [ "$(find "$JOBS" -maxdepth 1 -name 'macp-*.plist' | wc -l | tr -d ' ')" -eq 3 ]
  [ "$(cksum "$P/.agents/config.toml")" = "$first_config" ]

  run env QUARTET_DIR="$QUARTET_ROOT" SHIPYARD_SCHEDULER=launchd \
    /bin/bash "$QUARTET_ROOT/install.sh" --doctor --project "$P"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$(printf '%s' "$output" | grep '^DOCTOR ' || true)" ]
}

@test "launchd uninstall boots out jobs and removes plists but keeps config" {
  launchd_fixture
  do_install >/dev/null
  before="$(cksum "$P/.agents/config.toml")"

  run env QUARTET_DIR="$QUARTET_ROOT" SHIPYARD_SCHEDULER=launchd \
    /bin/bash "$QUARTET_ROOT/install.sh" --uninstall --project "$P"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$(find "$JOBS" -maxdepth 1 -name 'macp-*.plist' -print -quit)" ]
  [ "$(cksum "$P/.agents/config.toml")" = "$before" ]
  grep -q '^bootout ' "$SHIM_LOG/launchctl.argv"
}

@test "launchd rejects a schedule it cannot represent" {
  launchd_fixture
  # Replace build's supported daily expression with a weekday-only systemd
  # expression. launchd could represent it, but Shipyard intentionally accepts
  # only the documented portable subset.
  awk '{sub(/build   = "\*-\*-\* 03:30:00"/, "build   = \"Mon..Fri 03:30:00\""); print}' \
    "$P/.agents/config.toml" >"$P/.agents/config.toml.next"
  mv "$P/.agents/config.toml.next" "$P/.agents/config.toml"

  run do_install
  [ "$status" -eq 2 ]
  [[ "$output" == *"launchd cannot translate schedule"* ]]
}
