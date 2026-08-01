#!/usr/bin/env bats
# Hermetic dashboard service installer coverage. Scheduler commands are stubs;
# no test starts, stops, loads, or contacts a real user service.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  TEST_ROOT="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  SHIM_BIN="$TEST_ROOT/shim-bin"
  SHIM_LOG="$TEST_ROOT/shim-log"
  mkdir -p "$SHIM_BIN" "$SHIM_LOG"
  export SHIM_BIN SHIM_LOG PATH="$SHIM_BIN:$PATH"

  DASH_HOME="$TEST_ROOT/dashboard home"
  SYSTEMD_DIR="$TEST_ROOT/systemd-user"
  LAUNCHD_DIR="$TEST_ROOT/LaunchAgents"
  LOG_DIR="$TEST_ROOT/dashboard-logs"
  EVENTS_DIR="$TEST_ROOT/preserved-events"
  SERVICE_STATE="$TEST_ROOT/service-active"
  INSTALLER="$QUARTET_ROOT/scripts/install-dashboard.sh"
  mkdir -p "$SYSTEMD_DIR" "$LAUNCHD_DIR" "$EVENTS_DIR"

  export SHIPYARD_DASHBOARD_ROOT="$QUARTET_ROOT"
  export SHIPYARD_DASHBOARD_HOME="$DASH_HOME"
  export SHIPYARD_DASHBOARD_SYSTEMD_DIR="$SYSTEMD_DIR"
  export SHIPYARD_DASHBOARD_LAUNCHD_DIR="$LAUNCHD_DIR"
  export SHIPYARD_DASHBOARD_LOG_DIR="$LOG_DIR"
  export SHIPYARD_DASHBOARD_UID=4242
  export SHIPYARD_DASHBOARD_PYTHON
  SHIPYARD_DASHBOARD_PYTHON="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.executable).resolve())')"
  export DASHBOARD_TEST_STATE="$SERVICE_STATE"

  make_stub_script systemctl '
case "$*" in
  *"restart shipyard-dashboard.service"*) : >"$DASHBOARD_TEST_STATE"; exit 0 ;;
  *"is-enabled shipyard-dashboard.service"*|*"is-active shipyard-dashboard.service"*)
    [ -f "$DASHBOARD_TEST_STATE" ]; exit $? ;;
  *"disable --now shipyard-dashboard.service"*) unlink "$DASHBOARD_TEST_STATE" 2>/dev/null || true; exit 0 ;;
  *) exit 0 ;;
esac'
  make_stub_script launchctl '
case "$*" in
  *"bootstrap gui/4242 "*) : >"$DASHBOARD_TEST_STATE"; exit 0 ;;
  *"kickstart -k gui/4242/com.shipyard.dashboard"*) [ -f "$DASHBOARD_TEST_STATE" ]; exit $? ;;
  *"print gui/4242/com.shipyard.dashboard"*) [ -f "$DASHBOARD_TEST_STATE" ]; exit $? ;;
  *"bootout gui/4242/com.shipyard.dashboard"*) unlink "$DASHBOARD_TEST_STATE" 2>/dev/null || true; exit 0 ;;
  *) exit 0 ;;
esac'
  export SHIPYARD_DASHBOARD_SYSTEMCTL="$SHIM_BIN/systemctl"
  export SHIPYARD_DASHBOARD_LAUNCHCTL="$SHIM_BIN/launchctl"

  CREW_SERVICE="$SYSTEMD_DIR/fixture-build.service"
  CREW_TIMER="$SYSTEMD_DIR/fixture-build.timer"
  cat >"$CREW_SERVICE" <<EOF
[Service]
ExecStart=/bin/bash $QUARTET_ROOT/agents/build/runner.sh --project /fixture --mode build
Environment="QUARTET_EVENTS_DIR=$EVENTS_DIR"
EOF
  printf '%s\n' '[Timer]' 'OnCalendar=daily' >"$CREW_TIMER"
}

dashboard() {
  /bin/bash "$INSTALLER" --scheduler systemd --port 8766 "$@"
}

launch_dashboard() {
  /bin/bash "$INSTALLER" --scheduler launchd --port 8766 "$@"
}

crew_digest() {
  cksum "$CREW_SERVICE" "$CREW_TIMER"
}

manifest_digest() {
  cksum "$1" | awk '{print $1 ":" $2}'
}

replace_text() {
  python3 - "$1" "$2" "$3" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
if sys.argv[2] not in text:
    raise SystemExit("replacement source missing")
path.write_text(text.replace(sys.argv[2], sys.argv[3]))
PY
}

@test "dry-run writes nothing and never calls a scheduler" {
  before="$(find "$SYSTEMD_DIR" -type f -exec cksum {} \; | sort)"
  run dashboard --install --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]]
  [[ "$output" == *"source=crew manifest"* ]]
  [ ! -e "$SYSTEMD_DIR/shipyard-dashboard.service" ]
  [ ! -e "$LOG_DIR" ]
  [ "$(find "$SYSTEMD_DIR" -type f -exec cksum {} \; | sort)" = "$before" ]
  [ ! -s "$SHIM_LOG/systemctl.argv" ]
}

@test "systemd install bakes loopback paths and is byte-stable at mode 0644" {
  run dashboard --install
  [ "$status" -eq 0 ]
  unit="$SYSTEMD_DIR/shipyard-dashboard.service"
  [ -f "$unit" ]
  first="$(manifest_digest "$unit")"
  [ "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$unit")" = "644" ]
  grep -Fxq "WorkingDirectory=$QUARTET_ROOT" "$unit"
  ! grep -Fq 'WorkingDirectory="' "$unit"
  grep -Fq 'ExecStart=' "$unit"
  grep -Fq -- '--host 127.0.0.1 --port 8766' "$unit"
  grep -Fq "Environment=\"QUARTET_EVENTS_DIR=$EVENTS_DIR\"" "$unit"
  grep -Fq "Environment=\"SHIPYARD_DASHBOARD_SOURCE=$QUARTET_ROOT/dashboard/server.py\"" "$unit"
  grep -Eq 'Environment="SHIPYARD_DASHBOARD_ASSET_DIGEST=[0-9a-f]{64}"' "$unit"
  grep -Fq 'root / "dashboard" / "operator.py",' "$INSTALLER"
  grep -Fxq "StandardOutput=append:$LOG_DIR/dashboard.log" "$unit"
  grep -Fxq "StandardError=append:$LOG_DIR/dashboard.err.log" "$unit"
  ! grep -Fq 'StandardOutput="' "$unit"

  run dashboard --install
  [ "$status" -eq 0 ]
  second="$(manifest_digest "$unit")"
  [ "$first" = "$second" ]
  grep -Fq -- '--user enable shipyard-dashboard.service' "$SHIM_LOG/systemctl.argv"
  grep -Fq -- '--user restart shipyard-dashboard.service' "$SHIM_LOG/systemctl.argv"
  echo "systemd_first=$first systemd_reinstall=$second"

  run dashboard --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"doctor: dashboard install clean"* ]]
}

@test "D-3 uses crew path first and preserves existing dashboard path without crew" {
  run dashboard --install
  [ "$status" -eq 0 ]
  grep -Fq "QUARTET_EVENTS_DIR=$EVENTS_DIR" "$SYSTEMD_DIR/shipyard-dashboard.service"

  ALT_EVENTS="$TEST_ROOT/owner-selected-events"
  mkdir -p "$ALT_EVENTS"
  run dashboard --install --events-dir "$ALT_EVENTS"
  [ "$status" -eq 0 ]
  unlink "$CREW_SERVICE"
  unlink "$CREW_TIMER"
  run dashboard --install
  [ "$status" -eq 0 ]
  [[ "$output" == *"source=existing dashboard manifest"* ]]
  grep -Fq "QUARTET_EVENTS_DIR=$ALT_EVENTS" "$SYSTEMD_DIR/shipyard-dashboard.service"
}

@test "clean installs create only the platform event fallback" {
  unlink "$CREW_SERVICE"
  unlink "$CREW_TIMER"
  run dashboard --install
  [ "$status" -eq 0 ]
  linux_events="$DASH_HOME/.local/state/shipyard/events"
  [ -d "$linux_events" ]
  grep -Fq "QUARTET_EVENTS_DIR=$linux_events" "$SYSTEMD_DIR/shipyard-dashboard.service"

  unlink "$SYSTEMD_DIR/shipyard-dashboard.service"
  unlink "$SERVICE_STATE" 2>/dev/null || true
  run launch_dashboard --install
  [ "$status" -eq 0 ]
  mac_events="$DASH_HOME/Library/Application Support/Shipyard/events"
  [ -d "$mac_events" ]
  python3 - "$LAUNCHD_DIR/com.shipyard.dashboard.plist" "$mac_events" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as source:
    manifest = plistlib.load(source)
assert manifest["Label"] == "com.shipyard.dashboard"
assert manifest["EnvironmentVariables"]["QUARTET_EVENTS_DIR"] == sys.argv[2]
PY
}

@test "launchd manifest is stable, correctly identified, and doctor-clean" {
  run launch_dashboard --install --events-dir "$EVENTS_DIR"
  [ "$status" -eq 0 ]
  plist="$LAUNCHD_DIR/com.shipyard.dashboard.plist"
  first="$(manifest_digest "$plist")"
  [ "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$plist")" = "644" ]
  run launch_dashboard --install --events-dir "$EVENTS_DIR"
  [ "$status" -eq 0 ]
  second="$(manifest_digest "$plist")"
  [ "$first" = "$second" ]
  echo "launchd_first=$first launchd_reinstall=$second"
  grep -Fq 'bootstrap gui/4242' "$SHIM_LOG/launchctl.argv"
  grep -Fq 'kickstart -k gui/4242/com.shipyard.dashboard' "$SHIM_LOG/launchctl.argv"
  run launch_dashboard --doctor --events-dir "$EVENTS_DIR"
  [ "$status" -eq 0 ]
}

@test "launchd D-3 discovery preserves the event path baked into crew plists" {
  crew_plist="$LAUNCHD_DIR/fixture-build.plist"
  cat >"$crew_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>Label</key><string>com.shipyard.fixture-build</string>
<key>ProgramArguments</key><array>
<string>/bin/bash</string><string>$QUARTET_ROOT/agents/build/runner.sh</string>
<string>--project</string><string>/fixture</string>
</array>
<key>EnvironmentVariables</key><dict>
<key>QUARTET_EVENTS_DIR</key><string>$EVENTS_DIR</string>
</dict>
</dict></plist>
EOF
  run launch_dashboard --install
  [ "$status" -eq 0 ]
  [[ "$output" == *"source=crew manifest"* ]]
  python3 - "$LAUNCHD_DIR/com.shipyard.dashboard.plist" "$EVENTS_DIR" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as source:
    value = plistlib.load(source)["EnvironmentVariables"]["QUARTET_EVENTS_DIR"]
assert value == sys.argv[2]
PY
}

@test "systemd defaults logs beneath XDG state when no override is supplied" {
  unset SHIPYARD_DASHBOARD_LOG_DIR
  export XDG_STATE_HOME="$TEST_ROOT/xdg-state"
  run dashboard --install
  [ "$status" -eq 0 ]
  expected="$XDG_STATE_HOME/shipyard/logs/dashboard.log"
  grep -Fxq "StandardOutput=append:$expected" "$SYSTEMD_DIR/shipyard-dashboard.service"
}

@test "installer refuses symlink and unsafe targets" {
  LINK_EVENTS="$TEST_ROOT/events-link"
  ln -s "$EVENTS_DIR" "$LINK_EVENTS"
  run dashboard --install --events-dir "$LINK_EVENTS"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unsafe event-directory symlink"* ]]

  run dashboard --install --events-dir /
  [ "$status" -eq 2 ]
  [[ "$output" == *"unsafe event directory: /"* ]]

  ln -s "$CREW_SERVICE" "$SYSTEMD_DIR/shipyard-dashboard.service"
  run dashboard --install
  [ "$status" -eq 2 ]
  [[ "$output" == *"unsafe manifest symlink"* ]]
}

@test "ambiguous fleet event roots require an explicit owner selection" {
  OTHER_EVENTS="$TEST_ROOT/other-events"
  mkdir -p "$OTHER_EVENTS"
  cat >"$SYSTEMD_DIR/fixture-release.service" <<EOF
[Service]
ExecStart=/bin/bash $QUARTET_ROOT/agents/release/runner.sh --project /other --mode release
Environment="QUARTET_EVENTS_DIR=$OTHER_EVENTS"
EOF
  run dashboard --install
  [ "$status" -eq 2 ]
  [[ "$output" == *"multiple crew event directories found"* ]]
  [ ! -e "$SYSTEMD_DIR/shipyard-dashboard.service" ]
}

@test "doctor reports stopped service" {
  dashboard --install >/dev/null
  unlink "$SERVICE_STATE"
  run dashboard --doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR stopped:"* ]]
}

@test "doctor classifies host port event and stale asset-version drift" {
  unit="$SYSTEMD_DIR/shipyard-dashboard.service"
  dashboard --install >/dev/null

  replace_text "$unit" "127.0.0.1" "0.0.0.0"
  run dashboard --doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR wrong-host:"* ]]
  dashboard --install >/dev/null

  replace_text "$unit" "SHIPYARD_DASHBOARD_PORT=8766" "SHIPYARD_DASHBOARD_PORT=9999"
  run dashboard --doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR wrong-port:"* ]]
  dashboard --install >/dev/null

  WRONG_EVENTS="$TEST_ROOT/wrong-events"
  mkdir -p "$WRONG_EVENTS"
  replace_text "$unit" "QUARTET_EVENTS_DIR=$EVENTS_DIR" "QUARTET_EVENTS_DIR=$WRONG_EVENTS"
  run dashboard --doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR wrong-event-dir:"* ]]
  dashboard --install >/dev/null

  version_line="$(grep 'SHIPYARD_DASHBOARD_BUILD_VERSION=' "$unit")"
  replace_text "$unit" "$version_line" 'Environment="SHIPYARD_DASHBOARD_BUILD_VERSION=stale"'
  run dashboard --doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR stale-asset-version:"* ]]
}

@test "uninstall removes only dashboard and leaves crew events and logs byte-identical" {
  dashboard --install >/dev/null
  printf '%s\n' '{"keep":"event"}' >"$EVENTS_DIR/keep.jsonl"
  printf '%s\n' 'keep stdout' >"$LOG_DIR/dashboard.log"
  printf '%s\n' 'keep stderr' >"$LOG_DIR/dashboard.err.log"
  crew_before="$(crew_digest)"
  event_before="$(cksum "$EVENTS_DIR/keep.jsonl")"
  logs_before="$(cksum "$LOG_DIR/dashboard.log" "$LOG_DIR/dashboard.err.log")"

  run dashboard --uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$SYSTEMD_DIR/shipyard-dashboard.service" ]
  [ "$(crew_digest)" = "$crew_before" ]
  [ "$(cksum "$EVENTS_DIR/keep.jsonl")" = "$event_before" ]
  [ "$(cksum "$LOG_DIR/dashboard.log" "$LOG_DIR/dashboard.err.log")" = "$logs_before" ]
  ! grep -q 'fixture-' "$SHIM_LOG/systemctl.argv"
  [[ "$output" == *"leave in place: events="* ]]
  echo "crew_before=$crew_before"
  echo "crew_after=$(crew_digest)"
}

@test "uninstall dry-run leaves manifest and activation byte-identical" {
  dashboard --install >/dev/null
  unit="$SYSTEMD_DIR/shipyard-dashboard.service"
  before="$(manifest_digest "$unit")"
  : >"$SHIM_LOG/systemctl.argv"
  run dashboard --uninstall --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]]
  [ "$(manifest_digest "$unit")" = "$before" ]
  [ -f "$SERVICE_STATE" ]
  [ ! -s "$SHIM_LOG/systemctl.argv" ]
}

@test "uninstall still removes the exact service after its event and log directories moved" {
  dashboard --install >/dev/null
  moved="$TEST_ROOT/events-moved"
  moved_logs="$TEST_ROOT/logs-moved"
  mv "$EVENTS_DIR" "$moved"
  mv "$LOG_DIR" "$moved_logs"
  ln -s "$moved" "$EVENTS_DIR"
  ln -s "$moved_logs" "$LOG_DIR"
  run dashboard --uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$SYSTEMD_DIR/shipyard-dashboard.service" ]
  [ -d "$moved" ]
  [ -d "$moved_logs" ]
  [ -L "$EVENTS_DIR" ]
  [ -L "$LOG_DIR" ]
  [ -f "$CREW_SERVICE" ]
  [[ "$output" == *"leave in place"* ]]
}
