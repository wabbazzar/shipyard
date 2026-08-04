#!/usr/bin/env bats
# Dashboard API and deterministic `shipyard dashboard`/`status` integration.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  quartet_setup
  TEST_ROOT="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  DASH_HOME="$TEST_ROOT/dashboard-home"
  DASH_UNITS="$TEST_ROOT/dashboard-units"
  DASH_LOGS="$TEST_ROOT/dashboard-logs"
  DASH_EVENTS="$TEST_ROOT/dashboard-events"
  DASH_STATE="$TEST_ROOT/dashboard-active"
  DASH_PORT_FILE="$TEST_ROOT/dashboard-port"
  DASH_SERVER_LOG="$TEST_ROOT/dashboard-server.log"
  INSTALLER="$QUARTET_ROOT/scripts/install-dashboard.sh"
  SHIPYARD="$QUARTET_ROOT/skills/shipyard/shipyard.sh"
  SERVER_PID=""
  mkdir -p "$DASH_UNITS" "$DASH_EVENTS"
  export DASH_STATE

  make_stub_script systemctl '
case "$*" in
  *"restart shipyard-dashboard.service"*) : >"$DASH_STATE"; exit 0 ;;
  *"is-enabled shipyard-dashboard.service"*|*"is-active shipyard-dashboard.service"*)
    [ -f "$DASH_STATE" ]; exit $? ;;
  *"disable --now shipyard-dashboard.service"*) unlink "$DASH_STATE" 2>/dev/null || true; exit 0 ;;
  *) exit 0 ;;
esac'
  make_stub_script launchctl '
case "$*" in
  *"bootstrap gui/4242 "*) : >"$DASH_STATE"; exit 0 ;;
  *"enable gui/4242/com.shipyard.dashboard"*|*"kickstart -k gui/4242/com.shipyard.dashboard"*) exit 0 ;;
  *"print gui/4242/com.shipyard.dashboard"*)
    [ -f "$DASH_STATE" ] || exit 1
    printf "%s\n" "state = running" "pid = 42420"
    exit 0 ;;
  *"bootout gui/4242/com.shipyard.dashboard"*) unlink "$DASH_STATE" 2>/dev/null || true; exit 0 ;;
  *) exit 0 ;;
esac'
  make_stub_script dashboard-open 'exit 0'
  export SHIPYARD_DASHBOARD_HOME="$DASH_HOME"
  export SHIPYARD_DASHBOARD_SYSTEMD_DIR="$DASH_UNITS"
  export SHIPYARD_DASHBOARD_LOG_DIR="$DASH_LOGS"
  export SHIPYARD_DASHBOARD_SYSTEMCTL="$SHIM_BIN/systemctl"
  export SHIPYARD_DASHBOARD_OPEN="$SHIM_BIN/dashboard-open"
  export SHIPYARD_SCHEDULER=systemd
}

teardown() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}

run_shipyard() {
  QUARTET_DIR="$QUARTET_ROOT" /bin/bash "$SHIPYARD" "$@"
}

start_dashboard() {
  local today stamp
  today="$(date -u +%Y-%m-%d)"
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\n' \
    "{\"ts\":\"$stamp\",\"event\":\"job.end\",\"project\":\"fixture\",\"role\":\"build\",\"svc\":\"fixture-build\",\"status\":\"ok\",\"duration_s\":2}" \
    "{\"ts\":\"$stamp\",\"event\":\"dashboard.fixture\",\"project\":\"fixture\",\"role\":\"release\",\"svc\":\"fixture-release\",\"status\":\"ok\"}" \
    >"$DASH_EVENTS/$today.jsonl"
  "${DASHBOARD_PYTHON:-python3}" "$QUARTET_ROOT/dashboard/server.py" \
    --events-dir "$DASH_EVENTS" --host 127.0.0.1 --port 0 \
    --port-file "$DASH_PORT_FILE" >"$DASH_SERVER_LOG" 2>&1 &
  SERVER_PID=$!
  export SERVER_PID
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$DASH_PORT_FILE" ] && break
    sleep 0.05
  done
  [ -s "$DASH_PORT_FILE" ]
  DASH_PORT="$(tr -d '\n' <"$DASH_PORT_FILE")"
  export DASH_PORT SHIPYARD_DASHBOARD_PORT="$DASH_PORT"
}

@test "operator loader preserves the dashboard Python when ambient python3 is incompatible" {
  good_python="$(command -v python3)"
  project="$(make_fixture_project dashboard-interpreter clean-install.toml)"
  export SHIPYARD_SYSTEMD_DIR="$DASH_UNITS"
  export CLAUDE_PROJECTS_DIR="$TEST_ROOT/no-claude-transcripts"
  export CODEX_SESSIONS_DIR="$TEST_ROOT/no-codex-transcripts"
  mkdir -p "$CLAUDE_PROJECTS_DIR" "$CODEX_SESSIONS_DIR"
  cat >"$DASH_UNITS/dashboard-interpreter-build.service" <<EOF
[Service]
WorkingDirectory=$project
ExecStart=/bin/bash $QUARTET_ROOT/agents/build/runner.sh --project $project --mode fixture
EOF
  make_stub_script python3 '
printf "%s\n" "ambient python3 cannot import tomllib" >&2
exit 71
'

  DASHBOARD_PYTHON="$good_python" start_dashboard
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
    21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
    payload="$(curl --fail --silent --show-error \
      "http://127.0.0.1:$DASH_PORT/api/operator?window=24h")"
    [ "$(jq -r '.metadata.inspection_state' <<<"$payload")" = "fresh" ] && break
    sleep 0.1
  done

  jq -e '
    .metadata.inspection_state == "fresh" and
    .metadata.inspection_rule_version == "shipyard-inspect-v1" and
    (.metadata.limitations | index("inspection_refresh_failed") | not)
  ' <<<"$payload"

  run run_shipyard inspect --json
  [ "$status" -eq 71 ]
  [[ "$output" == *"ambient python3 cannot import tomllib"* ]]
}

install_dashboard_fixture() {
  /bin/bash "$INSTALLER" --scheduler systemd --install \
    --events-dir "$DASH_EVENTS" --port "$DASH_PORT" >/dev/null
}

@test "dashboard command reports precise absent guidance without opening" {
  export SHIPYARD_DASHBOARD_PORT=8766
  run run_shipyard dashboard
  [ "$status" -eq 3 ]
  [[ "$output" == *"service=shipyard-dashboard.service"* ]]
  [[ "$output" == *"loaded=false"* ]]
  [[ "$output" == *"running=false"* ]]
  [[ "$output" == *"url=http://127.0.0.1:8766"* ]]
  [[ "$output" == *"health=absent"* ]]
  [[ "$output" == *"install_command=/bin/bash $QUARTET_ROOT/scripts/install-dashboard.sh --install --port 8766"* ]]
  [ ! -s "$SHIM_LOG/dashboard-open.argv" ]
}

@test "dashboard command reports live health and opens only with --open" {
  start_dashboard
  install_dashboard_fixture

  run run_shipyard dashboard
  [ "$status" -eq 0 ]
  [[ "$output" == *"loaded=true"* ]]
  [[ "$output" == *"running=true"* ]]
  [[ "$output" == *"url=http://127.0.0.1:$DASH_PORT"* ]]
  [[ "$output" == *"health=ready"* ]]
  [[ "$output" == *"event_path=$DASH_EVENTS"* ]]
  [[ "$output" == *"latest_event="* ]]
  [ ! -s "$SHIM_LOG/dashboard-open.argv" ]

  run run_shipyard dashboard --open
  [ "$status" -eq 0 ]
  [ "$(stub_argv dashboard-open)" = "http://127.0.0.1:$DASH_PORT" ]
}

@test "dashboard command recognizes a running launchd service under pipefail" {
  start_dashboard
  export SHIPYARD_SCHEDULER=launchd
  export SHIPYARD_DASHBOARD_LAUNCHD_DIR="$DASH_UNITS"
  export SHIPYARD_DASHBOARD_LAUNCHCTL="$SHIM_BIN/launchctl"
  export SHIPYARD_DASHBOARD_UID=4242
  /bin/bash "$INSTALLER" --scheduler launchd --install \
    --events-dir "$DASH_EVENTS" --port "$DASH_PORT" >/dev/null

  run run_shipyard dashboard
  [ "$status" -eq 0 ]
  [[ "$output" == *"loaded=true"* ]]
  [[ "$output" == *"running=true"* ]]
  [[ "$output" == *"health=ready"* ]]
}

@test "dashboard command does not probe HTTP when the service is stopped" {
  start_dashboard
  install_dashboard_fixture
  unlink "$DASH_STATE"
  before="$(wc -l <"$DASH_SERVER_LOG" | tr -d ' ')"
  run run_shipyard dashboard
  [ "$status" -eq 0 ]
  [[ "$output" == *"loaded=false"* ]]
  [[ "$output" == *"running=false"* ]]
  [[ "$output" == *"health=unavailable"* ]]
  after="$(wc -l <"$DASH_SERVER_LOG" | tr -d ' ')"
  [ "$after" -eq "$before" ]
}

@test "status adds dashboard state without changing project crew semantics" {
  start_dashboard
  install_dashboard_fixture
  project="$(make_fixture_project dashboard-status)"
  unlink "$project/.agents/config.toml"
  mkdir -p "$HOME/.config/systemd/user"
  printf '%s\n' '[Timer]' >"$HOME/.config/systemd/user/dashboard-status-release.timer"

  run run_shipyard status --project "$project"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dashboard-status-release"* ]]
  [[ "$output" == *"dashboard:"* ]]
  [[ "$output" == *"  loaded=true"* ]]
  [[ "$output" == *"  running=true"* ]]
  [[ "$output" == *"  url=http://127.0.0.1:$DASH_PORT"* ]]
  [[ "$output" == *"  health=ready"* ]]
  [[ "$output" == *"  event_path=$DASH_EVENTS"* ]]
}

@test "dashboard flags are explicit and mutation-free" {
  run run_shipyard status --open
  [ "$status" -eq 2 ]
  [[ "$output" == *"--open applies only to dashboard"* ]]
  run run_shipyard dashboard --json
  [ "$status" -eq 2 ]
  [[ "$output" == *"--json/--days apply only to inspect"* ]]
  run run_shipyard dashboard unexpected
  [ "$status" -eq 2 ]
  [[ "$output" == *"unexpected positional argument"* ]]

  start_dashboard
  install_dashboard_fixture
  make_stub dashboard-open-fail 7
  export SHIPYARD_DASHBOARD_OPEN="$SHIM_BIN/dashboard-open-fail"
  run run_shipyard dashboard --open
  [ "$status" -eq 2 ]
  [[ "$output" == *"opener failed"* ]]
}

@test "real loopback API serves health summary events and static UI read-only" {
  start_dashboard
  before="$(cksum "$DASH_EVENTS/$(date -u +%Y-%m-%d).jsonl")"
  lsof -nP -a -p "$SERVER_PID" -iTCP -sTCP:LISTEN | grep -Fq "127.0.0.1:$DASH_PORT"

  run curl --fail --silent --show-error "http://127.0.0.1:$DASH_PORT/api/health"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.ready == true and .row_count == 2 and .error_count == 0' >/dev/null
  run curl --fail --silent --show-error "http://127.0.0.1:$DASH_PORT/api/summary?window=24h"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.counts.healthy == 1' >/dev/null
  run curl --fail --silent --show-error \
    "http://127.0.0.1:$DASH_PORT/api/events?window=24h&project=fixture&role=release&event=dashboard&limit=10"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.count == 1 and .events[0].event == "dashboard.fixture"' >/dev/null
  run curl --fail --silent --show-error "http://127.0.0.1:$DASH_PORT/api/operator?window=24h"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .schema_version == 1 and .kind == "shipyard.operator" and
    .metadata.window == "24h" and
    (.metadata.inspection_state == "fresh" or
     .metadata.inspection_state == "stale" or
     .metadata.inspection_state == "unavailable") and
    (.promises | length == 8) and
    (.topology.nodes | length > 0) and
    ((tostring | contains("project_path") or contains("source_ref") or
      contains("/home/") or contains("/Users/") or contains(".jsonl")) | not)
  ' >/dev/null
  run curl --silent --show-error -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:$DASH_PORT/api/operator"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
  run curl --fail --silent --show-error "http://127.0.0.1:$DASH_PORT/"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<h1>Shipyard</h1>"* ]]
  [ "$(cksum "$DASH_EVENTS/$(date -u +%Y-%m-%d).jsonl")" = "$before" ]
}

@test "loopback HTTP rejects hostile Host and mutation without CORS" {
  start_dashboard
  headers="$TEST_ROOT/headers"
  body="$TEST_ROOT/body"
  code="$(curl --silent --show-error -D "$headers" -o "$body" -w '%{http_code}' \
    -H 'Host: example.com' "http://127.0.0.1:$DASH_PORT/api/health")"
  [ "$code" = "400" ]
  jq -e '.error.code == "invalid_host"' "$body" >/dev/null
  grep -Fqi 'Cache-Control: no-store' "$headers"
  grep -Fqi 'X-Content-Type-Options: nosniff' "$headers"
  ! grep -Fqi 'Access-Control-Allow-Origin:' "$headers"

  code="$(curl --silent --show-error -o "$body" -w '%{http_code}' \
    -X POST "http://127.0.0.1:$DASH_PORT/api/events")"
  [ "$code" = "405" ]
  jq -e '.error.code == "method_not_allowed"' "$body" >/dev/null
}
