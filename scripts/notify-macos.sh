#!/bin/bash
# Native macOS Notification Center transport for QUARTET_NOTIFY_CMD.
# The notification text is passed as argv to AppleScript, avoiding source-code
# interpolation and its quoting/injection hazards.

set -uo pipefail

OSASCRIPT_BIN="${OSASCRIPT_BIN:-/usr/bin/osascript}"
[ -x "$OSASCRIPT_BIN" ] || {
  echo "notify-macos: osascript not executable: $OSASCRIPT_BIN" >&2
  exit 2
}

if [ "${1:-}" = "--check" ]; then
  printf 'return "notify-macos: ready"\n' | "$OSASCRIPT_BIN" -
  exit $?
fi

[ "$#" -ge 2 ] || {
  echo "usage: notify-macos.sh <title> <body>" >&2
  exit 2
}

"$OSASCRIPT_BIN" - "$1" "$2" <<'APPLESCRIPT'
on run argv
  display notification (item 2 of argv) with title (item 1 of argv)
end run
APPLESCRIPT
