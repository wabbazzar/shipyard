#!/bin/bash
# Install, inspect, or remove Shipyard's single machine-local dashboard service.

set -uo pipefail
umask 077

MODE="install"
DRY_RUN=0
EVENTS_ARG=""
PORT_ARG=""
SCHEDULER_ARG=""

usage() {
  cat <<'EOF'
Usage: scripts/install-dashboard.sh [--install|--doctor|--uninstall] [options]

Options:
  --events-dir PATH  Bake the existing Shipyard JSONL event directory.
  --port PORT        Loopback port (default: SHIPYARD_DASHBOARD_PORT or 8765).
  --scheduler NAME   auto, launchd, or systemd.
  --dry-run          Print the exact plan without writing or calling a scheduler.
EOF
  exit "${1:-2}"
}

mode_seen=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --install|--doctor|--uninstall)
      [ "$mode_seen" -eq 0 ] || { echo "choose exactly one mode" >&2; usage; }
      MODE="${1#--}"; mode_seen=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --events-dir)
      [ "$#" -ge 2 ] || { echo "--events-dir requires a value" >&2; usage; }
      EVENTS_ARG="$2"; shift 2 ;;
    --port)
      [ "$#" -ge 2 ] || { echo "--port requires a value" >&2; usage; }
      PORT_ARG="$2"; shift 2 ;;
    --scheduler)
      [ "$#" -ge 2 ] || { echo "--scheduler requires a value" >&2; usage; }
      SCHEDULER_ARG="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

[ "$MODE" != "doctor" ] || [ "$DRY_RUN" -eq 0 ] || {
  echo "--dry-run is unnecessary with read-only --doctor" >&2
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || exit 2
ROOT="${SHIPYARD_DASHBOARD_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
ROOT="$(cd "$ROOT" 2>/dev/null && pwd -P)" || {
  echo "dashboard source root is unavailable" >&2; exit 2; }
SOURCE="$ROOT/dashboard/server.py"
ASSETS="$ROOT/dashboard/static"
[ -f "$SOURCE" ] && [ ! -L "$SOURCE" ] || {
  echo "unsafe dashboard source: $SOURCE" >&2; exit 2; }
[ -d "$ASSETS" ] && [ ! -L "$ASSETS" ] || {
  echo "unsafe dashboard assets: $ASSETS" >&2; exit 2; }

PYTHON_BIN="${SHIPYARD_DASHBOARD_PYTHON:-$(command -v python3 2>/dev/null || true)}"
[ -n "$PYTHON_BIN" ] && [ -x "$PYTHON_BIN" ] || {
  echo "safe executable python3 is required" >&2; exit 2; }
PYTHON_BIN="$($PYTHON_BIN -c 'import pathlib,sys; print(pathlib.Path(sys.executable).resolve())')" || {
  echo "could not resolve python3" >&2; exit 2; }
[ -x "$PYTHON_BIN" ] && [ ! -L "$PYTHON_BIN" ] || {
  echo "safe executable python3 is required" >&2; exit 2; }

BUILD_VERSION="$($PYTHON_BIN - "$SOURCE" <<'PY'
import ast
import pathlib
import sys

tree = ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
for node in tree.body:
    if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "BUILD_VERSION" for t in node.targets):
        if isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
            print(node.value.value)
            break
else:
    raise SystemExit(2)
PY
)" || { echo "could not read dashboard build version" >&2; exit 2; }

asset_digest() {
  "$PYTHON_BIN" - "$ROOT" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
paths = [
    root / "dashboard" / "reader.py",
    root / "dashboard" / "operator.py",
    root / "dashboard" / "server.py",
    root / "dashboard" / "static" / "index.html",
    root / "dashboard" / "static" / "favicon.svg",
    root / "dashboard" / "static" / "styles.css",
    root / "dashboard" / "static" / "renderer.css",
    root / "dashboard" / "static" / "app.js",
    root / "dashboard" / "static" / "renderer.js",
]
digest = hashlib.sha256()
for path in paths:
    if not path.is_file() or path.is_symlink():
        raise SystemExit(2)
    digest.update(path.relative_to(root).as_posix().encode("utf-8") + b"\0")
    digest.update(path.read_bytes())
print(digest.hexdigest())
PY
}
ASSET_DIGEST="$(asset_digest)" || {
  echo "could not fingerprint dashboard source/assets" >&2; exit 2; }

REQUESTED_SCHEDULER="${SCHEDULER_ARG:-${SHIPYARD_DASHBOARD_SCHEDULER:-${SHIPYARD_SCHEDULER:-auto}}}"
case "$REQUESTED_SCHEDULER" in
  launchd|systemd) SCHEDULER="$REQUESTED_SCHEDULER" ;;
  auto)
    case "$(uname -s)" in
      Darwin) SCHEDULER="launchd" ;;
      Linux) SCHEDULER="systemd" ;;
      *) echo "unsupported platform (need launchd or systemd)" >&2; exit 2 ;;
    esac ;;
  *) echo "scheduler must be auto, launchd, or systemd" >&2; exit 2 ;;
esac

case "$PORT_ARG" in
  "") PORT="${SHIPYARD_DASHBOARD_PORT:-8765}" ;;
  *) PORT="$PORT_ARG" ;;
esac
case "$PORT" in *[!0-9]*|"") echo "port must be an integer from 1 to 65535" >&2; exit 2 ;; esac
[ "$PORT" -ge 1 ] 2>/dev/null && [ "$PORT" -le 65535 ] 2>/dev/null || {
  echo "port must be an integer from 1 to 65535" >&2; exit 2; }
PORT=$((10#$PORT))
HOST="127.0.0.1"
DASH_HOME="${SHIPYARD_DASHBOARD_HOME:-$HOME}"
SYSTEMCTL="${SHIPYARD_DASHBOARD_SYSTEMCTL:-systemctl}"
LAUNCHCTL="${SHIPYARD_DASHBOARD_LAUNCHCTL:-launchctl}"

if [ "$SCHEDULER" = "launchd" ]; then
  MANIFEST_DIR="${SHIPYARD_DASHBOARD_LAUNCHD_DIR:-$DASH_HOME/Library/LaunchAgents}"
  LOG_DIR="${SHIPYARD_DASHBOARD_LOG_DIR:-$DASH_HOME/Library/Logs/Shipyard}"
  MANIFEST="$MANIFEST_DIR/com.shipyard.dashboard.plist"
  SERVICE_ID="com.shipyard.dashboard"
  DOMAIN="gui/${SHIPYARD_DASHBOARD_UID:-$(id -u)}"
else
  MANIFEST_DIR="${SHIPYARD_DASHBOARD_SYSTEMD_DIR:-$DASH_HOME/.config/systemd/user}"
  STATE_HOME="${XDG_STATE_HOME:-$DASH_HOME/.local/state}"
  LOG_DIR="${SHIPYARD_DASHBOARD_LOG_DIR:-$STATE_HOME/shipyard/logs}"
  MANIFEST="$MANIFEST_DIR/shipyard-dashboard.service"
  SERVICE_ID="shipyard-dashboard.service"
  DOMAIN=""
fi
LOG_OUT="$LOG_DIR/dashboard.log"
LOG_ERR="$LOG_DIR/dashboard.err.log"

if [ "$MODE" = "doctor" ] || [ "$DRY_RUN" -eq 0 ]; then
  if [ "$SCHEDULER" = "launchd" ]; then scheduler_command="$LAUNCHCTL"
  else scheduler_command="$SYSTEMCTL"
  fi
  command -v "$scheduler_command" >/dev/null 2>&1 || {
    echo "missing scheduler command: $scheduler_command" >&2; exit 2; }
fi

unsafe_text() {
  case "$1" in ""|*$'\n'*|*$'\r'*|*$'\t'*) return 0 ;; *) return 1 ;; esac
}

safe_target() {
  local label="$1" path="$2"
  case "$path" in /*) ;; *) echo "unsafe $label path (must be absolute): $path" >&2; return 2 ;; esac
  unsafe_text "$path" && { echo "unsafe $label path" >&2; return 2; }
  [ "$path" != "/" ] || { echo "unsafe $label path: /" >&2; return 2; }
  [ ! -L "$path" ] || { echo "unsafe $label symlink: $path" >&2; return 2; }
  return 0
}

safe_target "manifest directory" "$MANIFEST_DIR" || exit $?
if [ "$MODE" != "uninstall" ]; then
  safe_target "log directory" "$LOG_DIR" || exit $?
fi
[ ! -e "$MANIFEST" ] || [ -f "$MANIFEST" ] || {
  echo "unsafe manifest target: $MANIFEST" >&2; exit 2; }
[ ! -L "$MANIFEST" ] || { echo "unsafe manifest symlink: $MANIFEST" >&2; exit 2; }

manifest_value() {
  "$PYTHON_BIN" - "$1" "$2" <<'PY'
import pathlib
import plistlib
import re
import sys

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
if not path.is_file() or path.is_symlink():
    raise SystemExit(1)
if path.suffix == ".plist":
    with path.open("rb") as source:
        value = plistlib.load(source).get("EnvironmentVariables", {}).get(key, "")
else:
    value = ""
    prefix = "Environment=\"" + key + "="
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith(prefix) and line.endswith('"'):
            raw = line[len(prefix):-1]
            value = re.sub(r"\\(.)", r"\1", raw).replace("%%", "%")
            break
if isinstance(value, str):
    print(value)
PY
}

discover_crew_events() {
  local candidate value found="" manifest_name
  if [ "$SCHEDULER" = "launchd" ]; then
    for candidate in "$MANIFEST_DIR"/*.plist; do
      [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
      [ "$candidate" != "$MANIFEST" ] || continue
      grep -Fq '/agents/' "$candidate" 2>/dev/null || continue
      grep -Fq '/runner.sh' "$candidate" 2>/dev/null || continue
      value="$(manifest_value "$candidate" QUARTET_EVENTS_DIR 2>/dev/null || true)"
      [ -n "$value" ] || continue
      case "$found" in
        "") found="$value" ;;
        "$value") : ;;
        *) echo "multiple crew event directories found; pass --events-dir" >&2; return 2 ;;
      esac
    done
  else
    for candidate in "$MANIFEST_DIR"/*.service; do
      [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
      [ "$candidate" != "$MANIFEST" ] || continue
      grep -Fq '/agents/' "$candidate" 2>/dev/null || continue
      grep -Fq '/runner.sh' "$candidate" 2>/dev/null || continue
      value="$(manifest_value "$candidate" QUARTET_EVENTS_DIR 2>/dev/null || true)"
      [ -n "$value" ] || continue
      case "$found" in
        "") found="$value" ;;
        "$value") : ;;
        *) echo "multiple crew event directories found; pass --events-dir" >&2; return 2 ;;
      esac
    done
  fi
  printf '%s\n' "$found"
}

EVENTS_ORIGIN=""
if [ -n "$EVENTS_ARG" ]; then
  EVENTS_DIR="$EVENTS_ARG"; EVENTS_ORIGIN="--events-dir"
elif [ -n "${QUARTET_EVENTS_DIR:-}" ]; then
  EVENTS_DIR="$QUARTET_EVENTS_DIR"; EVENTS_ORIGIN="QUARTET_EVENTS_DIR"
else
  CREW_EVENTS="$(discover_crew_events)" || exit $?
  if [ -n "$CREW_EVENTS" ]; then
    EVENTS_DIR="$CREW_EVENTS"; EVENTS_ORIGIN="crew manifest"
  elif [ -f "$MANIFEST" ]; then
    EVENTS_DIR="$(manifest_value "$MANIFEST" QUARTET_EVENTS_DIR 2>/dev/null || true)"
    [ -n "$EVENTS_DIR" ] || {
      echo "installed dashboard manifest has no event directory" >&2; exit 2; }
    EVENTS_ORIGIN="existing dashboard manifest"
  elif [ "$SCHEDULER" = "launchd" ]; then
    EVENTS_DIR="$DASH_HOME/Library/Application Support/Shipyard/events"
    EVENTS_ORIGIN="clean-install fallback"
  else
    EVENTS_DIR="${XDG_STATE_HOME:-$DASH_HOME/.local/state}/shipyard/events"
    EVENTS_ORIGIN="clean-install fallback"
  fi
fi

case "$EVENTS_DIR" in /*) ;; *) echo "event directory must be absolute" >&2; exit 2 ;; esac
unsafe_text "$EVENTS_DIR" && { echo "unsafe event directory" >&2; exit 2; }
[ "$EVENTS_DIR" != "/" ] || { echo "unsafe event directory: /" >&2; exit 2; }
if [ "$MODE" != "uninstall" ]; then
  [ ! -L "$EVENTS_DIR" ] || { echo "unsafe event-directory symlink: $EVENTS_DIR" >&2; exit 2; }
  if [ -e "$EVENTS_DIR" ] && [ ! -d "$EVENTS_DIR" ]; then
    echo "event path is not a directory: $EVENTS_DIR" >&2; exit 2
  fi
fi
if [ "$MODE" = "install" ] && [ ! -d "$EVENTS_DIR" ] && [ "$EVENTS_ORIGIN" != "clean-install fallback" ]; then
  echo "selected event directory does not exist: $EVENTS_DIR" >&2; exit 2
fi

systemd_quote() {
  "$PYTHON_BIN" - "$1" <<'PY'
import sys
s = sys.argv[1].replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%")
print('"' + s + '"', end="")
PY
}

systemd_escape() {
  "$PYTHON_BIN" - "$1" <<'PY'
import sys
print(sys.argv[1].replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%"), end="")
PY
}

systemd_path() {
  "$PYTHON_BIN" - "$1" <<'PY'
import sys

safe = frozenset(b"/ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.:-")
parts = []
for byte in sys.argv[1].encode("utf-8"):
    if byte == ord("%"):
        parts.append("%%")
    elif byte in safe:
        parts.append(chr(byte))
    else:
        parts.append(f"\\x{byte:02x}")
print("".join(parts), end="")
PY
}

xml_escape() {
  "$PYTHON_BIN" - "$1" <<'PY'
import html
import sys
print(html.escape(sys.argv[1], quote=True), end="")
PY
}

render_manifest() {
  local q_python q_source q_events q_root q_log_out q_log_err
  if [ "$SCHEDULER" = "systemd" ]; then
    q_python="$(systemd_quote "$PYTHON_BIN")"
    q_source="$(systemd_quote "$SOURCE")"
    q_events="$(systemd_quote "$EVENTS_DIR")"
    q_root="$(systemd_path "$ROOT")"
    q_log_out="append:$(systemd_path "$LOG_OUT")"
    q_log_err="append:$(systemd_path "$LOG_ERR")"
    cat <<EOF
# Managed by Shipyard. Re-run scripts/install-dashboard.sh to change.
[Unit]
Description=Shipyard local operations dashboard
After=network.target

[Service]
Type=simple
WorkingDirectory=$q_root
ExecStart=$q_python $q_source --events-dir $q_events --host $HOST --port $PORT
Restart=on-failure
RestartSec=2
Environment="HOME=$(systemd_escape "$DASH_HOME")"
Environment="PYTHONUNBUFFERED=1"
Environment="QUARTET_EVENTS_DIR=$(systemd_escape "$EVENTS_DIR")"
Environment="SHIPYARD_DASHBOARD_HOST=$HOST"
Environment="SHIPYARD_DASHBOARD_PORT=$PORT"
Environment="SHIPYARD_DASHBOARD_SOURCE=$(systemd_escape "$SOURCE")"
Environment="SHIPYARD_DASHBOARD_ASSETS=$(systemd_escape "$ASSETS")"
Environment="SHIPYARD_DASHBOARD_BUILD_VERSION=$BUILD_VERSION"
Environment="SHIPYARD_DASHBOARD_ASSET_DIGEST=$ASSET_DIGEST"
StandardOutput=$q_log_out
StandardError=$q_log_err

[Install]
WantedBy=default.target
EOF
  else
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.shipyard.dashboard</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "$PYTHON_BIN")</string>
    <string>$(xml_escape "$SOURCE")</string>
    <string>--events-dir</string><string>$(xml_escape "$EVENTS_DIR")</string>
    <string>--host</string><string>$HOST</string>
    <string>--port</string><string>$PORT</string>
  </array>
  <key>WorkingDirectory</key><string>$(xml_escape "$ROOT")</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$(xml_escape "$DASH_HOME")</string>
    <key>PYTHONUNBUFFERED</key><string>1</string>
    <key>QUARTET_EVENTS_DIR</key><string>$(xml_escape "$EVENTS_DIR")</string>
    <key>SHIPYARD_DASHBOARD_HOST</key><string>$HOST</string>
    <key>SHIPYARD_DASHBOARD_PORT</key><string>$PORT</string>
    <key>SHIPYARD_DASHBOARD_SOURCE</key><string>$(xml_escape "$SOURCE")</string>
    <key>SHIPYARD_DASHBOARD_ASSETS</key><string>$(xml_escape "$ASSETS")</string>
    <key>SHIPYARD_DASHBOARD_BUILD_VERSION</key><string>$(xml_escape "$BUILD_VERSION")</string>
    <key>SHIPYARD_DASHBOARD_ASSET_DIGEST</key><string>$ASSET_DIGEST</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$(xml_escape "$LOG_OUT")</string>
  <key>StandardErrorPath</key><string>$(xml_escape "$LOG_ERR")</string>
</dict>
</plist>
EOF
  fi
}

EXPECTED="$(render_manifest)" || { echo "could not render manifest" >&2; exit 2; }

write_manifest() {
  local tmp
  mkdir -p "$MANIFEST_DIR" "$LOG_DIR" || return 2
  [ "$EVENTS_ORIGIN" != "clean-install fallback" ] || mkdir -p "$EVENTS_DIR" || return 2
  [ ! -L "$MANIFEST_DIR" ] && [ ! -L "$LOG_DIR" ] && [ ! -L "$EVENTS_DIR" ] || {
    echo "unsafe symlink appeared during install" >&2; return 2; }
  tmp="$(mktemp "$MANIFEST_DIR/.shipyard-dashboard.XXXXXX")" || return 2
  if ! printf '%s\n' "$EXPECTED" >"$tmp" || ! chmod 0644 "$tmp" || ! mv -f "$tmp" "$MANIFEST"; then
    unlink "$tmp" 2>/dev/null || true
    return 2
  fi
  chmod 0644 "$MANIFEST" || return 2
}

activate_service() {
  if [ "$SCHEDULER" = "launchd" ]; then
    "$LAUNCHCTL" bootout "$DOMAIN/$SERVICE_ID" >/dev/null 2>&1 || true
    "$LAUNCHCTL" bootstrap "$DOMAIN" "$MANIFEST" || return 2
    "$LAUNCHCTL" enable "$DOMAIN/$SERVICE_ID" >/dev/null 2>&1 || return 2
    "$LAUNCHCTL" kickstart -k "$DOMAIN/$SERVICE_ID" || return 2
  else
    "$SYSTEMCTL" --user daemon-reload || return 2
    "$SYSTEMCTL" --user enable "$SERVICE_ID" || return 2
    "$SYSTEMCTL" --user restart "$SERVICE_ID" || return 2
  fi
}

run_install() {
  echo "dashboard install: scheduler=$SCHEDULER service=$SERVICE_ID"
  echo "events_dir=$EVENTS_DIR (source=$EVENTS_ORIGIN)"
  echo "url=http://$HOST:$PORT"
  echo "manifest=$MANIFEST"
  echo "asset_digest=$ASSET_DIGEST"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY RUN: would write manifest mode 0644 and activate only $SERVICE_ID"
    return 0
  fi
  write_manifest || { echo "could not install dashboard manifest" >&2; return 2; }
  activate_service || { echo "could not activate dashboard service" >&2; return 2; }
  echo "installed: $SERVICE_ID"
}

doctor_finding() {
  DOCTOR_FINDINGS=$((DOCTOR_FINDINGS + 1))
  printf 'DOCTOR %s: %s\n' "$1" "$2"
}

check_value() {
  local key="$1" expected="$2" class="$3" actual
  actual="$(manifest_value "$MANIFEST" "$key" 2>/dev/null || true)"
  [ "$actual" = "$expected" ] || doctor_finding "$class" "$key is '$actual' (expected '$expected')"
}

run_doctor() {
  DOCTOR_FINDINGS=0
  if [ ! -f "$MANIFEST" ] || [ -L "$MANIFEST" ]; then
    doctor_finding "manifest" "safe $SERVICE_ID manifest is missing"
  else
    mode="$($PYTHON_BIN - "$MANIFEST" <<'PY'
import os
import stat
import sys
print(oct(stat.S_IMODE(os.stat(sys.argv[1], follow_symlinks=False).st_mode))[2:])
PY
)"
    [ "$mode" = "644" ] || doctor_finding "manifest" "mode is $mode (expected 644)"
    check_value SHIPYARD_DASHBOARD_HOST "$HOST" "wrong-host"
    check_value SHIPYARD_DASHBOARD_PORT "$PORT" "wrong-port"
    check_value QUARTET_EVENTS_DIR "$EVENTS_DIR" "wrong-event-dir"
    check_value SHIPYARD_DASHBOARD_SOURCE "$SOURCE" "stale-asset-version"
    check_value SHIPYARD_DASHBOARD_ASSETS "$ASSETS" "stale-asset-version"
    check_value SHIPYARD_DASHBOARD_BUILD_VERSION "$BUILD_VERSION" "stale-asset-version"
    check_value SHIPYARD_DASHBOARD_ASSET_DIGEST "$ASSET_DIGEST" "stale-asset-version"
    current="$(render_manifest)" || current=""
    [ "$(printf '%s\n' "$current")" = "$(cat "$MANIFEST" 2>/dev/null)" ] ||
      doctor_finding "manifest" "definition differs from the deterministic template"
  fi
  [ -d "$EVENTS_DIR" ] && [ ! -L "$EVENTS_DIR" ] ||
    doctor_finding "wrong-event-dir" "selected event directory is unavailable: $EVENTS_DIR"
  if [ "$SCHEDULER" = "launchd" ]; then
    "$LAUNCHCTL" print "$DOMAIN/$SERVICE_ID" >/dev/null 2>&1 ||
      doctor_finding "stopped" "$SERVICE_ID is not loaded/running"
  else
    "$SYSTEMCTL" --user is-enabled "$SERVICE_ID" >/dev/null 2>&1 ||
      doctor_finding "stopped" "$SERVICE_ID is not enabled"
    "$SYSTEMCTL" --user is-active "$SERVICE_ID" >/dev/null 2>&1 ||
      doctor_finding "stopped" "$SERVICE_ID is not active"
  fi
  if [ "$DOCTOR_FINDINGS" -eq 0 ]; then
    echo "doctor: dashboard install clean"
    return 0
  fi
  echo "doctor: dashboard — $DOCTOR_FINDINGS finding(s)" >&2
  return 1
}

run_uninstall() {
  echo "dashboard uninstall: service=$SERVICE_ID"
  echo "leave in place: events=$EVENTS_DIR logs=$LOG_DIR"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY RUN: would disable and remove only $SERVICE_ID"
    return 0
  fi
  if [ "$SCHEDULER" = "launchd" ]; then
    "$LAUNCHCTL" bootout "$DOMAIN/$SERVICE_ID" >/dev/null 2>&1 || true
  else
    "$SYSTEMCTL" --user disable --now "$SERVICE_ID" >/dev/null 2>&1 || true
  fi
  if [ -L "$MANIFEST" ]; then
    echo "refusing unsafe manifest symlink: $MANIFEST" >&2
    return 2
  fi
  [ ! -e "$MANIFEST" ] || unlink "$MANIFEST" || return 2
  [ "$SCHEDULER" != "systemd" ] || "$SYSTEMCTL" --user daemon-reload || return 2
  echo "removed: $SERVICE_ID"
}

case "$MODE" in
  install) run_install ;;
  doctor) run_doctor ;;
  uninstall) run_uninstall ;;
esac
