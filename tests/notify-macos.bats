#!/usr/bin/env bats

setup() {
  load helpers
  quartet_setup
  export OSASCRIPT_ARGS="$BATS_TEST_TMPDIR/osascript.args"
  export OSASCRIPT_STDIN="$BATS_TEST_TMPDIR/osascript.stdin"
  OSASCRIPT_BIN="$BATS_TEST_TMPDIR/osascript"
  export OSASCRIPT_BIN
  cat >"$OSASCRIPT_BIN" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" >"$OSASCRIPT_ARGS"
cat >"$OSASCRIPT_STDIN"
STUB
  chmod +x "$OSASCRIPT_BIN"
}

@test "macOS notifier passes title and body as argv, not AppleScript source" {
  run /bin/bash "$QUARTET_ROOT/scripts/notify-macos.sh" \
    'Shipyard "alert"' 'body with $shell and \slashes'
  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$OSASCRIPT_ARGS")" = "-" ]
  [ "$(sed -n '2p' "$OSASCRIPT_ARGS")" = 'Shipyard "alert"' ]
  [ "$(sed -n '3p' "$OSASCRIPT_ARGS")" = 'body with $shell and \slashes' ]
  grep -q 'display notification (item 2 of argv)' "$OSASCRIPT_STDIN"
  ! grep -q 'Shipyard' "$OSASCRIPT_STDIN"
}

@test "macOS notifier check mode validates osascript without displaying" {
  run /bin/bash "$QUARTET_ROOT/scripts/notify-macos.sh" --check
  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$OSASCRIPT_ARGS")" = "-" ]
  grep -q 'notify-macos: ready' "$OSASCRIPT_STDIN"
  ! grep -q 'display notification' "$OSASCRIPT_STDIN"
}
