#!/usr/bin/env bats
# Durable, per-session Codex release-critic mailbox and PostToolUse emission.
# All state is fixture-local; no Codex process, model, network, or live config.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  quartet_setup
  FEEDBACK="$QUARTET_ROOT/agents/release/critic-codex-feedback.sh"
  NOTE="$QUARTET_ROOT/agents/release/critic-note.sh"
  STOP="$QUARTET_ROOT/agents/release/critic-stop-gate-codex.sh"
  WATCH="$QUARTET_ROOT/agents/release/critic-watch.sh"
  export XDG_STATE_HOME="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/xdg-state"
}

checked_sha() {
  python3 -c '
import hashlib
import sys

print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())
'
}

set_mtime_ago() {
  python3 -c '
import os
import sys
import time

when = time.time() - int(sys.argv[1])
os.utime(sys.argv[2], (when, when))
' "$1" "$2"
}

set_mtime_ahead() {
  python3 -c '
import os
import sys
import time

when = time.time() + int(sys.argv[1])
os.utime(sys.argv[2], (when, when))
' "$1" "$2"
}

file_mode() {
  python3 -c '
import os
import stat
import sys

print(format(stat.S_IMODE(os.stat(sys.argv[1], follow_symlinks=False).st_mode), "o"))
' "$1"
}

monotonic_now() {
  python3 -c 'import time; print(time.monotonic())'
}

elapsed_under() {
  python3 -c '
import sys

raise SystemExit(0 if float(sys.argv[2]) - float(sys.argv[1]) < float(sys.argv[3]) else 1)
' "$1" "$2" "$3"
}

count_direct_json_files() {
  local dir="$1" candidate count=0
  for candidate in "$dir"/*.json; do
    [ -f "$candidate" ] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

project_hash() {
  printf 'shipyard-project-v1:%s' "$(cd "$1" && pwd -P)" | checked_sha
}

session_hash() {
  printf 'shipyard-session-v1:%s' "$1" | checked_sha
}

turn_hash() {
  printf 'shipyard-turn-v1:%s:%s' "$1" "$2" | checked_sha
}

mailbox_dir() {
  printf '%s/shipyard/critic-feedback/mailboxes/%s/%s\n' \
    "$XDG_STATE_HOME" "$(project_hash "$1")" "$(session_hash "$2")"
}

authorize() {
  CRITIC_FEEDBACK_ADMIN=1 bash "$FEEDBACK" --admin-allow-project "$1"
}

deposit() {
  local project="$1" session="$2" message="$3" critique_id="$4"
  authorize "$project" || return
  CRITIC_PROJECT_DIR="$project" CRITIC_NOTE_ID="$critique_id" \
    bash "$NOTE" --harness codex "$session" "$message"
}

drain() {
  local project="$1" session="$2"
  jq -nc --arg cwd "$project" --arg session "$session" \
    '{hook_event_name:"PostToolUse",cwd:$cwd,session_id:$session}' |
    bash "$FEEDBACK"
}

claim_stop() {
  bash "$FEEDBACK" --stop-claim "$1" "$2"
}

finish_stop_claim() {
  bash "$FEEDBACK" "--stop-$1" "$2" "$3" "$4"
}

stop_payload() {
  local project="$1" session="$2" turn="$3"
  local active="${4:-false}" last="${5:-}"
  jq -nc --arg cwd "$project" --arg session "$session" --arg turn "$turn" \
    --argjson active "$active" --arg last "$last" \
    '{hook_event_name:"Stop",cwd:$cwd,session_id:$session,turn_id:$turn,
      stop_hook_active:$active,last_assistant_message:$last}'
}

stop_hook() {
  stop_payload "$@" |
    CRITIC_STOP_WAIT_SEC="${CRITIC_STOP_WAIT_SEC:-0}" \
    CRITIC_STOP_POLL_SEC="${CRITIC_STOP_POLL_SEC:-0.01}" \
    bash "$STOP"
}

require_feedback() {
  printf '\n[shoulder]\nrequire_feedback = %s\n' "$2" \
    >>"$1/.agents/config.toml"
}

flush_file() {
  printf '%s/tmp/critic-flush-%s\n' "$1" "$(session_hash "$2")"
}

status_file() {
  printf '%s/tmp/critic-status-%s\n' "$1" "$(session_hash "$2")"
}

stop_state_file() {
  printf '%s/tmp/critic-stop-state-%s-%s\n' "$1" \
    "$(session_hash "$2")" "$(turn_hash "$2" "$3")"
}

write_status() {
  local project="$1" session="$2" turn="$3" state="$4"
  jq -cn --arg session_hash "$(session_hash "$session")" \
    --arg turn_hash "$(turn_hash "$session" "$turn")" --arg status "$state" \
    '{schema_version:1,session_hash:$session_hash,turn_hash:$turn_hash,
      status:$status,updated_at:1}' >"$(status_file "$project" "$session")"
  chmod 600 "$(status_file "$project" "$session")"
}

run_with_watchdog() {
  local ticks="$1" output_file="$BATS_TEST_TMPDIR/watchdog-$RANDOM.out"
  local pid finished=0 rc=0
  shift
  "$@" >"$output_file" 2>&1 &
  pid=$!
  for ((i=0; i<ticks; i++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      finished=1
      break
    fi
    sleep 0.01
  done
  if [ "$finished" -eq 0 ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    cat "$output_file"
    return 124
  fi
  wait "$pid" || rc=$?
  cat "$output_file"
  return "$rc"
}

pending_file() {
  local box candidate
  box="$(mailbox_dir "$1" "$2")"
  for candidate in "$box/pending"/*.json; do
    [ -f "$candidate" ] || continue
    printf '%s\n' "$candidate"
  done | LC_ALL=C sort | head -1
}

@test "no pending Codex feedback exits 0 silently" {
  P="$(make_fixture_project cfb-empty)"
  authorize "$P"
  run drain "$P" "session-empty"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "oversized streaming hook input is bounded and fails open promptly" {
  P="$(make_fixture_project cfb-hook-input-bound)"
  authorize "$P"
  STDOUT="$BATS_TEST_TMPDIR/hook-input.stdout"
  STDERR="$BATS_TEST_TMPDIR/hook-input.stderr"
  PAYLOAD="$BATS_TEST_TMPDIR/hook-input.json"

  # Materialize and independently parse the exact byte-valid JSON that will be
  # streamed. json.dump uses JSON quoting (not Python repr), including for cwd.
  python3 - "$P" "$PAYLOAD" <<'PY'
import json
import sys

project, path = sys.argv[1:]
payload = {
    "hook_event_name": "PostToolUse",
    "cwd": project,
    "session_id": "session-oversized",
    "padding": "x" * (200 * 65536),
}
with open(path, "w", encoding="utf-8") as stream:
    json.dump(payload, stream, separators=(",", ":"))
PY
  python3 - "$P" "$PAYLOAD" <<'PY'
import json
import os
import sys

project, path = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    payload = json.load(stream)
assert os.path.getsize(path) > 131072
assert payload["hook_event_name"] == "PostToolUse"
assert payload["cwd"] == project
assert payload["session_id"] == "session-oversized"
PY

  # Streaming the valid file over roughly ten seconds makes an unbounded read
  # observable without buffering it in Bats or in the production hook. The
  # hook must close after its cap and return success within three seconds. The
  # finite producer bounds a failure without GNU timeout (absent on macOS).
  STARTED="$(monotonic_now)"
  run bash -c '
    python3 - "$1" 2>/dev/null <<'"'"'PY'"'"' |
import sys
import time

try:
    with open(sys.argv[1], "rb") as payload:
        while True:
            chunk = payload.read(65536)
            if not chunk:
                break
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
            time.sleep(0.05)
except BrokenPipeError:
    pass
PY
      bash "$2" >"$3" 2>"$4"
  ' _ "$PAYLOAD" "$FEEDBACK" "$STDOUT" "$STDERR"
  FINISHED="$(monotonic_now)"

  [ "$status" -eq 0 ]
  elapsed_under "$STARTED" "$FINISHED" 3
  [ ! -s "$STDOUT" ]
  [ ! -e "$(mailbox_dir "$P" session-oversized)" ]
}

@test "Codex note deposits schema-v1 and hook emits exact model-visible JSON" {
  P="$(make_fixture_project cfb-json)"
  ID="$(printf 'a%.0s' {1..64})"

  run deposit "$P" "session-json" "1 block across 2 files" "$ID"
  [ "$status" -eq 0 ]
  ITEM="$(pending_file "$P" "session-json")"
  [ -f "$ITEM" ]
  jq -e --arg id "$ID" --arg sh "$(session_hash session-json)" '
    keys == ["created_ns","critique_id","schema_version","session_hash","summary"]
    and .schema_version == 1
    and .critique_id == $id
    and .session_hash == $sh
    and (.created_ns | type == "number")
    and .summary == "1 block across 2 files"
  ' "$ITEM"

  run drain "$P" "session-json"
  [ "$status" -eq 0 ]
  jq -e --arg expected "Release critic [$ID]: 1 block across 2 files" '
    keys == ["hookSpecificOutput"]
    and (.hookSpecificOutput | keys) == ["additionalContext","hookEventName"]
    and .hookSpecificOutput.hookEventName == "PostToolUse"
    and .hookSpecificOutput.additionalContext == $expected
  ' <<<"$output"
  [ "$(find "$(mailbox_dir "$P" session-json)/emitted" -type f | wc -l)" -eq 1 ]
  [ "$(find "$(mailbox_dir "$P" session-json)/pending" -type f | wc -l)" -eq 0 ]

  run drain "$P" "session-json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "feedback is isolated by exact opaque session" {
  P="$(make_fixture_project cfb-isolation)"
  ID1="$(printf '1%.0s' {1..64})"
  ID2="$(printf '2%.0s' {1..64})"
  deposit "$P" "session-one" "one" "$ID1"
  deposit "$P" "session-two" "two" "$ID2"

  run drain "$P" "session-one"
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")" == *"[$ID1]: one" ]]
  [ "$(find "$(mailbox_dir "$P" session-two)/pending" -type f | wc -l)" -eq 1 ]

  run drain "$P" "session-two"
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")" == *"[$ID2]: two" ]]
}

@test "installer-owned allowlist authorizes only the exact canonical project" {
  ALLOWED="$(make_fixture_project cfb-allowed)"
  FOREIGN="$(make_fixture_project cfb-foreign)"
  authorize "$ALLOWED"
  ID="$(printf '0%.0s' {1..64})"

  run env CRITIC_PROJECT_DIR="$FOREIGN" CRITIC_NOTE_ID="$ID" \
    bash "$NOTE" --harness codex session-foreign "must not persist"
  [ "$status" -eq 75 ]
  [ ! -e "$(mailbox_dir "$FOREIGN" session-foreign)" ]

  STDOUT="$BATS_TEST_TMPDIR/foreign.stdout"
  run bash -c "jq -nc --arg cwd '$FOREIGN' \
    '{hook_event_name:\"PostToolUse\",cwd:\$cwd,session_id:\"session-foreign\"}' |
    bash '$FEEDBACK' >'$STDOUT'"
  [ "$status" -eq 0 ]
  [ ! -s "$STDOUT" ]
}

@test "watcher derives stable ID from exact snapshot and deposits before consuming queue" {
  P="$(make_fixture_project cfb-watcher)"
  authorize "$P"
  RESULT=$'block|src/a.ts|unsafe\nwarn|src/a.ts|untested\nnote|src/a.ts|explain'
  CANNED="$(jq -cn --arg result "$RESULT" \
    '{type:"result",result:$result,usage:{input_tokens:10,output_tokens:5}}')"
  make_stub claude 0 "$CANNED"
  mkdir -p "$P/src"
  printf '// changed\n' >"$P/src/a.ts"
  Q="$P/tmp/critic-queue-session-watcher"
  printf 'src/a.ts %s\n' "$(date +%s)" >"$Q"
  SNAPSHOT="$BATS_TEST_TMPDIR/reviewed-snapshot"
  cp "$Q" "$SNAPSHOT"
  set_mtime_ago 120 "$Q"

  run env QUARTET_DIR="$QUARTET_ROOT" QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    CRITIC_IDLE_SEC=1 CRITIC_HARNESS=claude CRITIC_NOTE_HARNESS=codex \
    CLAUDE_NOTE_CMD="$NOTE --harness codex" \
    bash "$WATCH" --project "$P" --session session-watcher --once
  [ "$status" -eq 0 ]
  [ ! -e "$Q" ]

  SUMMARY=$'release critic: 1 block, 1 warn, 1 note across 1 files\nblock|src/a.ts|unsafe\nwarn|src/a.ts|untested'
  EXPECTED="$(
    {
      printf 'shipyard-codex-feedback-v1\0'
      cat "$SNAPSHOT"
      printf '\0'
      printf '%s\n' "$RESULT"
      printf '\0%s' "$SUMMARY"
    } | checked_sha
  )"
  ITEM="$(pending_file "$P" session-watcher)"
  jq -e --arg id "$EXPECTED" --arg summary "$SUMMARY" '
    .critique_id == $id and .summary == $summary
  ' "$ITEM"

  run drain "$P" session-watcher
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")" == *"[$EXPECTED]"* ]]
}

@test "retryable mailbox failure never acknowledges the reviewed edit queue" {
  P="$(make_fixture_project cfb-watcher-retry)"
  RESULT='warn|src/a.ts|untested'
  make_stub claude 0 \
    "{\"type\":\"result\",\"result\":\"$RESULT\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}"
  make_stub codex-note-unavailable 75
  mkdir -p "$P/src"
  printf '// changed\n' >"$P/src/a.ts"
  Q="$P/tmp/critic-queue-session-retry"
  printf 'src/a.ts %s\n' "$(date +%s)" >"$Q"
  set_mtime_ago 120 "$Q"

  for _ in 1 2; do
    set_mtime_ago 120 "$Q"
    run env QUARTET_DIR="$QUARTET_ROOT" QUARTET_EVENTS_DIR="$EVENTS_DIR" \
      CRITIC_IDLE_SEC=1 CRITIC_HARNESS=claude CRITIC_NOTE_HARNESS=codex \
      CLAUDE_NOTE_CMD="$SHIM_BIN/codex-note-unavailable" \
      bash "$WATCH" --project "$P" --session session-retry --once
    [ "$status" -eq 0 ]
    [ -s "$Q" ]
  done
  CALLS="$(grep -c '^session-retry release critic:' \
    "$SHIM_LOG/codex-note-unavailable.argv")"
  [ "$CALLS" -eq 2 ] || {
    printf 'expected 2 retryable note calls, got %s\n' "$CALLS" >&2
    false
  }
  [ ! -e "$P/tmp/critic-attempts-session-retry" ]
}

@test "stable critique ID deduplicates without overwriting older work" {
  P="$(make_fixture_project cfb-dedupe)"
  ID="$(printf 'd%.0s' {1..64})"
  deposit "$P" "session-dedupe" "original" "$ID"
  deposit "$P" "session-dedupe" "replacement must not overwrite" "$ID"
  BOX="$(mailbox_dir "$P" session-dedupe)"

  [ "$(find "$BOX/pending" -type f | wc -l)" -eq 1 ]
  jq -e '.summary == "original"' "$(pending_file "$P" session-dedupe)"

  drain "$P" "session-dedupe" >/dev/null
  deposit "$P" "session-dedupe" "replacement after emission" "$ID"
  [ "$(find "$BOX/emitted" -type f | wc -l)" -eq 1 ]
  [ "$(find "$BOX/pending" -type f | wc -l)" -eq 0 ]
}

@test "two immutable critiques queue without overwrite and emit oldest first" {
  P="$(make_fixture_project cfb-order)"
  # Deliberately reverse lexical ID order so sorting by critique ID is red.
  OLD="$(printf 'f%.0s' {1..64})"
  NEW="$(printf 'a%.0s' {1..64})"
  deposit "$P" "session-order" "oldest" "$OLD"
  sleep 0.01
  deposit "$P" "session-order" "newest" "$NEW"
  BOX="$(mailbox_dir "$P" session-order)"
  [ "$(find "$BOX/pending" -type f | wc -l)" -eq 2 ]

  run drain "$P" "session-order"
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")" == *"[$OLD]: oldest" ]]
  run drain "$P" "session-order"
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")" == *"[$NEW]: newest" ]]
}

@test "an ambiguous stale claim replays the same stable critique ID" {
  P="$(make_fixture_project cfb-replay)"
  ID="$(printf 'c%.0s' {1..64})"
  deposit "$P" "session-replay" "replay me" "$ID"
  BOX="$(mailbox_dir "$P" session-replay)"
  ITEM="$(pending_file "$P" session-replay)"
  mv "$ITEM" "$BOX/claims/$(basename "$ITEM")"
  set_mtime_ago 31 "$BOX/claims/$(basename "$ITEM")"

  run drain "$P" "session-replay"
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")" == *"[$ID]: replay me" ]]
  [ "$(find "$BOX/emitted" -type f | wc -l)" -eq 1 ]
  [ "$(find "$BOX/claims" -type f | wc -l)" -eq 0 ]
}

@test "a future-dated claim replays once instead of pinning feedback" {
  P="$(make_fixture_project cfb-future-claim)"
  ID="$(printf 'd%.0s' {1..64})"
  deposit "$P" session-future-claim "replay future claim" "$ID"
  BOX="$(mailbox_dir "$P" session-future-claim)"
  ITEM="$(pending_file "$P" session-future-claim)"
  CLAIM="$BOX/claims/$(basename "$ITEM")"
  mv "$ITEM" "$CLAIM"
  set_mtime_ahead 86400 "$CLAIM"

  run drain "$P" session-future-claim
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")" == *"[$ID]: replay future claim" ]]
  [ "$(find "$BOX/claims" -type f -name '*.json' | wc -l)" -eq 0 ]
  [ "$(find "$BOX/emitted" -type f -name '*.json' | wc -l)" -eq 1 ]

  run drain "$P" session-future-claim
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "invalid session and project paths are rejected without mailbox writes" {
  P="$(make_fixture_project cfb-invalid)"
  authorize "$P"
  STDOUT="$BATS_TEST_TMPDIR/invalid.stdout"
  STDERR="$BATS_TEST_TMPDIR/invalid.stderr"
  run bash -c "jq -nc --arg cwd '$P' '{cwd:\$cwd,session_id:\"bad\\nsession\"}' |
    bash '$FEEDBACK' >'$STDOUT' 2>'$STDERR'"
  [ "$status" -eq 0 ]
  [ ! -s "$STDOUT" ]
  [ ! -e "$P/tmp/critic-feedback" ]

  run bash -c "jq -nc '{cwd:\"/definitely/missing/project\",session_id:\"s\"}' |
    bash '$FEEDBACK' >'$STDOUT' 2>'$STDERR'"
  [ "$status" -eq 0 ]
  [ ! -s "$STDOUT" ]

  run env -u CRITIC_PROJECT_DIR -u CRITIC_NOTE_DELIVER_CMD \
    bash "$NOTE" --harness codex "session" "finding"
  [ "$status" -eq 75 ]
  [[ "$output" != *"no delivery channel"* ]]
}

@test "malformed claimed item fails open into quarantine and never emits" {
  P="$(make_fixture_project cfb-malformed)"
  ID="$(printf 'e%.0s' {1..64})"
  deposit "$P" "session-malformed" "valid first" "$ID"
  ITEM="$(pending_file "$P" session-malformed)"
  printf '{not-json\n' >"$ITEM"
  BOX="$(mailbox_dir "$P" session-malformed)"

  run drain "$P" "session-malformed"
  [ "$status" -eq 0 ]
  [[ "$output" != *"hookSpecificOutput"* ]]
  [ "$(find "$BOX/pending" -type f | wc -l)" -eq 0 ]
  [ "$(find "$BOX/claims" -type f | wc -l)" -eq 0 ]
  [ "$(find "$BOX/emitted" -type f | wc -l)" -eq 0 ]
  [ "$(find "$BOX/quarantine" -type f -name '*.json' | wc -l)" -ge 2 ]
}

@test "deposit streaming-bounds summaries to 8 KiB and 50 lines before persistence" {
  P="$(make_fixture_project cfb-bounds)"
  ID="$(printf 'f%.0s' {1..64})"
  MESSAGE="$(for ((i=1; i<=60; i++)); do printf 'line-%02d:' "$i"; printf 'x%.0s' {1..700}; printf '\n'; done)"

  run deposit "$P" "session-bounds" "$MESSAGE" "$ID"
  [ "$status" -eq 0 ]
  ITEM="$(pending_file "$P" session-bounds)"
  BYTES="$(jq -r '.summary' "$ITEM" | wc -c)"
  LINES="$(jq -r '.summary' "$ITEM" | awk 'END {print NR}')"
  [ "$BYTES" -le 8193 ]
  [ "$LINES" -le 50 ]
  jq -e '.summary | startswith("line-01:")' "$ITEM"
}

@test "deposit does not report success until item and pending directory are durable" {
  P="$(make_fixture_project cfb-fsync)"
  ID="$(printf 'd%.0s' {1..64})"
  authorize "$P"
  REAL_PYTHON="$(command -v python3)"
  SYNC_BIN="$BATS_TEST_TMPDIR/sync-bin"
  SYNC_LOG="$BATS_TEST_TMPDIR/sync.log"
  mkdir -p "$SYNC_BIN"
  cat >"$SYNC_BIN/python3" <<EOF
#!/bin/bash
if [ "\${1:-}" = "-" ] && [ "\$#" -eq 3 ] &&
    [[ "\$2" == */pending/*.json ]] && [[ "\$3" == */pending ]]; then
  printf '%s\n' "\$2" "\$3" >"$SYNC_LOG"
  exit 86
fi
exec "$REAL_PYTHON" "\$@"
EOF
  chmod +x "$SYNC_BIN/python3"

  run env PATH="$SYNC_BIN:$PATH" CRITIC_PROJECT_DIR="$P" CRITIC_NOTE_ID="$ID" \
    bash "$NOTE" --harness codex session-fsync "must remain retryable"

  [ "$status" -eq 75 ]
  [ -s "$SYNC_LOG" ]
  BOX="$(mailbox_dir "$P" session-fsync)"
  [ "$(count_direct_json_files "$BOX/pending")" -eq 0 ]
  [ ! -e "$BOX/.lock" ]

  run env CRITIC_PROJECT_DIR="$P" CRITIC_NOTE_ID="$ID" \
    bash "$NOTE" --harness codex session-fsync "must remain retryable"
  [ "$status" -eq 0 ]
  [ "$(count_direct_json_files "$BOX/pending")" -eq 1 ]

  # A crash after rename but before directory sync is indistinguishable from
  # an ordinary existing stable ID. Dedupe must re-prove durability rather
  # than assuming that finding the name makes it safe to acknowledge.
  run env PATH="$SYNC_BIN:$PATH" CRITIC_PROJECT_DIR="$P" CRITIC_NOTE_ID="$ID" \
    bash "$NOTE" --harness codex session-fsync "must remain retryable"
  [ "$status" -eq 75 ]
  [ "$(count_direct_json_files "$BOX/pending")" -eq 1 ]
}

@test "50 newline-terminated short lines persist exactly and a 51st is truncated" {
  P="$(make_fixture_project cfb-line-boundary)"
  FIFTY="$(
    for ((i=1; i<=50; i++)); do printf 'short-%02d\n' "$i"; done
    printf sentinel
  )"
  FIFTY="${FIFTY%sentinel}"
  FIFTY_ONE="${FIFTY}short-51"$'\n'
  ID50="$(printf 'a%.0s' {1..64})"
  ID51="$(printf 'b%.0s' {1..64})"

  deposit "$P" session-lines-50 "$FIFTY" "$ID50"
  ITEM50="$(pending_file "$P" session-lines-50)"
  jq -e '
    (.summary | endswith("\n"))
    and ((.summary | split("\n") | length) == 51)
    and (.summary | contains("short-50\n"))
  ' "$ITEM50"

  deposit "$P" session-lines-51 "$FIFTY_ONE" "$ID51"
  ITEM51="$(pending_file "$P" session-lines-51)"
  jq -e '
    (.summary | endswith("\n"))
    and ((.summary | split("\n") | length) == 51)
    and (.summary | contains("short-50\n"))
    and (.summary | contains("short-51") | not)
    and ((.summary | utf8bytelength) < 8192)
  ' "$ITEM51"
}

@test "emitted and abandoned temporary files older than seven days are collected" {
  P="$(make_fixture_project cfb-gc)"
  OLD="$(printf '7%.0s' {1..64})"
  NEW="$(printf '8%.0s' {1..64})"
  deposit "$P" "session-gc" "old" "$OLD"
  drain "$P" "session-gc" >/dev/null
  BOX="$(mailbox_dir "$P" session-gc)"
  OLD_FILE="$(find "$BOX/emitted" -type f | head -1)"
  set_mtime_ago 691200 "$OLD_FILE"
  printf 'stale\n' >"$BOX/pending/.tmp.stale"
  chmod 600 "$BOX/pending/.tmp.stale"
  set_mtime_ago 691200 "$BOX/pending/.tmp.stale"

  deposit "$P" "session-gc" "new" "$NEW"
  [ ! -e "$OLD_FILE" ]
  [ ! -e "$BOX/pending/.tmp.stale" ]
  [ "$(find "$BOX/pending" -type f -name '*.json' | wc -l)" -eq 1 ]
}

@test "cross-timezone simultaneous writers serialize without ps or corruption" {
  P="$(make_fixture_project cfb-writers)"
  authorize "$P"
  PS_BIN="$BATS_TEST_TMPDIR/no-ps-mailbox-bin"
  mkdir -p "$PS_BIN"
  cat >"$PS_BIN/ps" <<'EOF'
#!/bin/bash
exit 127
EOF
  cat >"$PS_BIN/cksum" <<'EOF'
#!/bin/bash
exit 127
EOF
  chmod +x "$PS_BIN/ps" "$PS_BIN/cksum"
  for ((i=1; i<=8; i++)); do
    ID="$(printf '%064x' "$i")"
    WRITER_TZ=UTC
    [ $((i % 2)) -eq 0 ] && WRITER_TZ=America/Chicago
    TZ="$WRITER_TZ" PATH="$PS_BIN:$PATH" \
      CRITIC_PROJECT_DIR="$P" CRITIC_NOTE_ID="$ID" \
        bash "$NOTE" --harness codex "session-writers" "writer $i" &
  done
  wait
  BOX="$(mailbox_dir "$P" session-writers)"
  [ "$(find "$BOX/pending" -type f -name '*.json' | wc -l)" -eq 8 ]
  run bash -c "jq -e '.schema_version == 1' '$BOX'/pending/*.json >/dev/null"
  [ "$status" -eq 0 ]
  [ ! -e "$BOX/.lock" ]
}

@test "a live lock owner is never stolen even after its lease age" {
  P="$(make_fixture_project cfb-live-lock)"
  FIRST="$(printf '1%.0s' {1..64})"
  SECOND="$(printf '2%.0s' {1..64})"
  deposit "$P" session-lock "first" "$FIRST"
  BOX="$(mailbox_dir "$P" session-lock)"
  mkdir "$BOX/.lock"
  chmod 700 "$BOX/.lock"
  printf '%s %s %s\n' "$$" "$(printf 'a%.0s' {1..32})" \
    "$(( $(date +%s) - 120 ))" >"$BOX/.lock/owner"
  chmod 600 "$BOX/.lock/owner"

  run env CRITIC_LOCK_WAIT_STEPS=2 CRITIC_LOCK_SLEEP_SEC=0.001 \
    CRITIC_PROJECT_DIR="$P" CRITIC_NOTE_ID="$SECOND" \
    bash "$NOTE" --harness codex session-lock "must wait"
  [ "$status" -eq 75 ]
  [ -d "$BOX/.lock" ]
  [ "$(find "$BOX/pending" -type f -name '*.json' | wc -l)" -eq 1 ]
  rm "$BOX/.lock/owner"
  rmdir "$BOX/.lock"
}

@test "a reused live PID with mismatched process start does not pin a stale lock" {
  P="$(make_fixture_project cfb-reused-pid)"
  FIRST="$(printf '2%.0s' {1..64})"
  SECOND="$(printf '3%.0s' {1..64})"
  deposit "$P" session-reused-pid "first" "$FIRST"
  BOX="$(mailbox_dir "$P" session-reused-pid)"
  mkdir "$BOX/.lock"
  chmod 700 "$BOX/.lock"
  # $$ is deliberately live, while 0-0 cannot equal its checked start
  # identity. Pre-hardening PID-only locking treats this stale owner as live.
  printf '%s %s %s %s\n' "$$" "$(printf 'd%.0s' {1..32})" "0-0" \
    "$(( $(date +%s) - 120 ))" >"$BOX/.lock/owner"
  chmod 600 "$BOX/.lock/owner"

  run env CRITIC_LOCK_WAIT_STEPS=4 CRITIC_LOCK_SLEEP_SEC=0.001 \
    CRITIC_CLAIM_LEASE_SEC=1 CRITIC_PROJECT_DIR="$P" CRITIC_NOTE_ID="$SECOND" \
    bash "$NOTE" --harness codex session-reused-pid "second"
  [ "$status" -eq 0 ]
  [ ! -e "$BOX/.lock" ]
  [ "$(find "$BOX/pending" -type f -name '*.json' | wc -l)" -eq 2 ]
}

@test "stale recovery never retires a successor lock installed at handoff" {
  P="$(make_fixture_project cfb-lock-handoff)"
  FIRST="$(printf '4%.0s' {1..64})"
  SECOND="$(printf '5%.0s' {1..64})"
  deposit "$P" session-lock-handoff "first" "$FIRST"
  BOX="$(mailbox_dir "$P" session-lock-handoff)"
  mkdir "$BOX/.lock"
  chmod 700 "$BOX/.lock"
  printf '%s %s %s\n' 2147483647 "$(printf 'e%.0s' {1..32})" \
    "$(( $(date +%s) - 120 ))" >"$BOX/.lock/owner"
  chmod 600 "$BOX/.lock/owner"

  HOOK="$BATS_TEST_TMPDIR/replace-lock-generation"
  HOOK_RAN="$BATS_TEST_TMPDIR/replace-lock-generation.ran"
  cat >"$HOOK" <<EOF
#!/bin/bash
set -e
lock="\$1"
[ ! -e "$HOOK_RAN" ] || exit 0
mv "\$lock" "\$lock.old"
mkdir "\$lock"
chmod 700 "\$lock"
printf '%s %s %s\n' "$$" "$(printf 'f%.0s' {1..32})" "\$(date +%s)" >"\$lock/owner"
chmod 600 "\$lock/owner"
rm "\$lock.old/owner"
rmdir "\$lock.old"
: >"$HOOK_RAN"
EOF
  chmod +x "$HOOK"

  # The seam replaces the observed stale generation after its last owner read.
  # A re-read-then-rename implementation steals this live successor and reports
  # a false successful deposit; generation-pinned recovery must leave it intact.
  run env CRITIC_LOCK_WAIT_STEPS=3 CRITIC_LOCK_SLEEP_SEC=0.001 \
    CRITIC_CLAIM_LEASE_SEC=1 CRITIC_LOCK_RECOVERY_TEST_HOOK="$HOOK" \
    CRITIC_PROJECT_DIR="$P" CRITIC_NOTE_ID="$SECOND" \
    bash "$NOTE" --harness codex session-lock-handoff "must remain pending"
  [ "$status" -eq 75 ]
  [ -e "$HOOK_RAN" ]
  [ -d "$BOX/.lock" ]
  [ "$(awk '{print $1}' "$BOX/.lock/owner")" = "$$" ]
  REAPER_FOUND=0
  for marker in "$BOX/.lock"/.reaper*; do
    [ -e "$marker" ] || [ -L "$marker" ] || continue
    REAPER_FOUND=1
  done
  [ "$REAPER_FOUND" -eq 0 ]
  [ "$(find "$BOX/pending" -type f -name '*.json' | wc -l)" -eq 1 ]
  rm "$BOX/.lock/owner"
  rmdir "$BOX/.lock"
}

@test "a reaper killed after marker publication is recovered without loss or duplication" {
  P="$(make_fixture_project cfb-reaper-crash)"
  FIRST="$(printf '6%.0s' {1..64})"
  SECOND="$(printf '7%.0s' {1..64})"
  deposit "$P" session-reaper-crash "first" "$FIRST"
  BOX="$(mailbox_dir "$P" session-reaper-crash)"
  mkdir "$BOX/.lock"
  chmod 700 "$BOX/.lock"
  printf '%s %s %s\n' 2147483647 "$(printf 'a%.0s' {1..32})" \
    "$(( $(date +%s) - 120 ))" >"$BOX/.lock/owner"
  chmod 600 "$BOX/.lock/owner"

  KILL_HOOK="$BATS_TEST_TMPDIR/kill-published-reaper"
  MARKER_LOG="$BATS_TEST_TMPDIR/published-reaper.path"
  cat >"$KILL_HOOK" <<EOF
#!/bin/bash
printf '%s\n' "\$1" >"$MARKER_LOG"
kill -KILL "\$PPID"
EOF
  chmod +x "$KILL_HOOK"

  run env CRITIC_LOCK_WAIT_STEPS=4 CRITIC_LOCK_SLEEP_SEC=0.001 \
    CRITIC_CLAIM_LEASE_SEC=1 CRITIC_REAPER_PUBLISHED_TEST_HOOK="$KILL_HOOK" \
    CRITIC_PROJECT_DIR="$P" CRITIC_NOTE_ID="$SECOND" \
    bash "$NOTE" --harness codex session-reaper-crash "second"
  [ "$status" -eq 75 ]
  MARKER="$(cat "$MARKER_LOG")"
  [ -d "$MARKER" ]
  [ "$(awk '{print NF}' "$MARKER/owner")" -eq 4 ]
  [ "$(find "$BOX/pending" -type f -name '*.json' | wc -l)" -eq 1 ]

  sleep 2
  run env CRITIC_LOCK_WAIT_STEPS=8 CRITIC_LOCK_SLEEP_SEC=0.001 \
    CRITIC_CLAIM_LEASE_SEC=1 CRITIC_PROJECT_DIR="$P" CRITIC_NOTE_ID="$SECOND" \
    bash "$NOTE" --harness codex session-reaper-crash "second"
  [ "$status" -eq 0 ]
  [ ! -e "$BOX/.lock" ]
  [ "$(find "$BOX/pending" -type f -name '*.json' | wc -l)" -eq 2 ]
  [ "$(jq -r '.critique_id' "$BOX"/pending/*.json | sort -u | wc -l)" -eq 2 ]
}

@test "every poisoned reaper marker shape is quarantined without blocking deposit" {
  P="$(make_fixture_project cfb-reaper-poison)"
  FIRST="$(printf '8%.0s' {1..64})"
  SECOND="$(printf '9%.0s' {1..64})"
  deposit "$P" session-reaper-poison "first" "$FIRST"
  BOX="$(mailbox_dir "$P" session-reaper-poison)"
  mkdir "$BOX/.lock"
  chmod 700 "$BOX/.lock"
  printf '%s %s %s\n' 2147483647 "$(printf 'b%.0s' {1..32})" \
    "$(( $(date +%s) - 120 ))" >"$BOX/.lock/owner"
  chmod 600 "$BOX/.lock/owner"

  mkdir "$BOX/.lock/.reaper-ownerless"
  chmod 700 "$BOX/.lock/.reaper-ownerless"
  set_mtime_ago 2 "$BOX/.lock/.reaper-ownerless"
  mkdir "$BOX/.lock/.reaper-malformed"
  chmod 700 "$BOX/.lock/.reaper-malformed"
  printf 'not an owner record\n' >"$BOX/.lock/.reaper-malformed/owner"
  chmod 600 "$BOX/.lock/.reaper-malformed/owner"
  set_mtime_ago 2 "$BOX/.lock/.reaper-malformed"
  ln -s /etc/passwd "$BOX/.lock/.reaper-symlink"
  printf 'plain marker\n' >"$BOX/.lock/.reaper-plain"
  chmod 600 "$BOX/.lock/.reaper-plain"
  set_mtime_ago 2 "$BOX/.lock/.reaper-plain"
  mkfifo "$BOX/.lock/.reaper-fifo"
  set_mtime_ago 2 "$BOX/.lock/.reaper-fifo"

  mkdir "$BOX/.lock/.reaper-wrong-mode-owner"
  chmod 700 "$BOX/.lock/.reaper-wrong-mode-owner"
  printf 'wrong mode\n' >"$BOX/.lock/.reaper-wrong-mode-owner/owner"
  chmod 644 "$BOX/.lock/.reaper-wrong-mode-owner/owner"
  set_mtime_ago 2 "$BOX/.lock/.reaper-wrong-mode-owner"
  mkdir "$BOX/.lock/.reaper-symlink-owner"
  chmod 700 "$BOX/.lock/.reaper-symlink-owner"
  ln -s /etc/passwd "$BOX/.lock/.reaper-symlink-owner/owner"
  set_mtime_ago 2 "$BOX/.lock/.reaper-symlink-owner"
  mkdir "$BOX/.lock/.reaper-oversize-owner"
  chmod 700 "$BOX/.lock/.reaper-oversize-owner"
  printf 'x%.0s' {1..300} >"$BOX/.lock/.reaper-oversize-owner/owner"
  chmod 600 "$BOX/.lock/.reaper-oversize-owner/owner"
  set_mtime_ago 2 "$BOX/.lock/.reaper-oversize-owner"
  mkdir "$BOX/.lock/.reaper-special-owner"
  chmod 700 "$BOX/.lock/.reaper-special-owner"
  mkfifo "$BOX/.lock/.reaper-special-owner/owner"
  set_mtime_ago 2 "$BOX/.lock/.reaper-special-owner"
  mkdir "$BOX/.lock/.reaper-wrong-marker-mode"
  chmod 755 "$BOX/.lock/.reaper-wrong-marker-mode"
  set_mtime_ago 2 "$BOX/.lock/.reaper-wrong-marker-mode"

  FUTURE_TOKEN="$(printf 'c%.0s' {1..32})"
  mkdir "$BOX/.lock/.reaper-$FUTURE_TOKEN"
  chmod 700 "$BOX/.lock/.reaper-$FUTURE_TOKEN"
  printf '%s %s %s %s\n' 2147483647 "$FUTURE_TOKEN" "0-0" \
    99999999999999999999 >"$BOX/.lock/.reaper-$FUTURE_TOKEN/owner"
  chmod 600 "$BOX/.lock/.reaper-$FUTURE_TOKEN/owner"
  set_mtime_ago 2 "$BOX/.lock/.reaper-$FUTURE_TOKEN"

  run run_with_watchdog 500 env \
    CRITIC_LOCK_WAIT_STEPS=8 CRITIC_LOCK_SLEEP_SEC=0.001 \
    CRITIC_CLAIM_LEASE_SEC=1 CRITIC_PROJECT_DIR="$P" CRITIC_NOTE_ID="$SECOND" \
    bash "$NOTE" --harness codex session-reaper-poison "second"
  [ "$status" -eq 0 ]
  [ ! -e "$BOX/.lock" ]
  [ -f /etc/passwd ]
  [ "$(find "$BOX/pending" -type f -name '*.json' | wc -l)" -eq 2 ]
  [ "$(jq -r '.critique_id' "$BOX"/pending/*.json | sort -u | wc -l)" -eq 2 ]
}

@test "a stale dead-owner lock is recovered without losing queued work" {
  P="$(make_fixture_project cfb-dead-lock)"
  FIRST="$(printf '3%.0s' {1..64})"
  SECOND="$(printf '4%.0s' {1..64})"
  deposit "$P" session-dead "first" "$FIRST"
  BOX="$(mailbox_dir "$P" session-dead)"
  mkdir "$BOX/.lock"
  chmod 700 "$BOX/.lock"
  printf '%s %s %s\n' 2147483647 "$(printf 'b%.0s' {1..32})" \
    "$(( $(date +%s) - 120 ))" >"$BOX/.lock/owner"
  chmod 600 "$BOX/.lock/owner"

  run env CRITIC_LOCK_WAIT_STEPS=4 CRITIC_LOCK_SLEEP_SEC=0.001 \
    CRITIC_CLAIM_LEASE_SEC=1 CRITIC_PROJECT_DIR="$P" CRITIC_NOTE_ID="$SECOND" \
    bash "$NOTE" --harness codex session-dead "second"
  [ "$status" -eq 0 ]
  [ ! -e "$BOX/.lock" ]
  [ "$(find "$BOX/pending" -type f -name '*.json' | wc -l)" -eq 2 ]
}

@test "a complete dead lock owner with future epoch cannot pin deposits" {
  P="$(make_fixture_project cfb-future-dead-lock)"
  FIRST="$(printf 'a%.0s' {1..64})"
  SECOND="$(printf 'b%.0s' {1..64})"
  deposit "$P" session-future-dead "first" "$FIRST"
  BOX="$(mailbox_dir "$P" session-future-dead)"
  TOKEN="$(printf 'd%.0s' {1..32})"
  mkdir "$BOX/.lock"
  chmod 700 "$BOX/.lock"
  printf '%s %s %s %s\n' 2147483647 "$TOKEN" "0-0" \
    "$(( $(date +%s) + 86400 ))" >"$BOX/.lock/owner"
  chmod 600 "$BOX/.lock/owner"

  run env CRITIC_LOCK_WAIT_STEPS=4 CRITIC_LOCK_SLEEP_SEC=0.001 \
    CRITIC_PROJECT_DIR="$P" CRITIC_NOTE_ID="$SECOND" \
    bash "$NOTE" --harness codex session-future-dead "second"
  [ "$status" -eq 0 ]
  [ ! -e "$BOX/.lock" ]
  [ "$(find "$BOX/pending" -type f -name '*.json' | wc -l)" -eq 2 ]
  [ "$(jq -r '.critique_id' "$BOX"/pending/*.json | sort -u | wc -l)" -eq 2 ]
}

@test "symlink and unsafe-mode mailbox items fail open into quarantine" {
  P="$(make_fixture_project cfb-poison-item)"
  ID="$(printf '5%.0s' {1..64})"
  deposit "$P" session-poison "safe" "$ID"
  BOX="$(mailbox_dir "$P" session-poison)"
  ITEM="$(pending_file "$P" session-poison)"
  chmod 644 "$ITEM"

  run drain "$P" session-poison
  [ "$status" -eq 0 ]
  [[ "$output" != *"hookSpecificOutput"* ]]
  [ "$(find "$BOX/quarantine" -type f | wc -l)" -ge 2 ]

  ln -s /etc/passwd "$BOX/pending/00000000000000000000-$(printf '6%.0s' {1..64}).json"
  run drain "$P" session-poison
  [ "$status" -eq 0 ]
  [[ "$output" != *"hookSpecificOutput"* ]]
  run find "$BOX" -type l -print
  [ -z "$output" ]
}

@test "directory and FIFO poison are quarantined without starving a valid item" {
  P="$(make_fixture_project cfb-inode-poison)"
  ID="$(printf '6%.0s' {1..64})"
  deposit "$P" session-inodes "valid behind poison" "$ID"
  BOX="$(mailbox_dir "$P" session-inodes)"
  mkdir "$BOX/pending/00000000000000000000-directory"
  mkfifo "$BOX/pending/00000000000000000001-fifo"

  run run_with_watchdog 500 drain "$P" session-inodes
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")" == *"[$ID]: valid behind poison" ]]
  [ ! -e "$BOX/pending/00000000000000000000-directory" ]
  [ ! -e "$BOX/pending/00000000000000000001-fifo" ]
  [ "$(find "$BOX/quarantine" -type f -name 'error-*.json' | wc -l)" -ge 2 ]
  run find "$BOX/quarantine" -type p -print
  [ -z "$output" ]
}

@test "symlinked or non-private state is rejected and hook errors stay fail-open" {
  P="$(make_fixture_project cfb-poison-state)"
  mkdir -p "$XDG_STATE_HOME"
  ln -s "$BATS_TEST_TMPDIR" "$XDG_STATE_HOME/shipyard"
  run env CRITIC_FEEDBACK_ADMIN=1 bash "$FEEDBACK" --admin-allow-project "$P"
  [ "$status" -eq 75 ]
  rm "$XDG_STATE_HOME/shipyard"
  chmod 700 "$XDG_STATE_HOME"

  authorize "$P"
  ID="$(printf '7%.0s' {1..64})"
  deposit "$P" session-private "safe" "$ID"
  BOX="$(mailbox_dir "$P" session-private)"
  chmod 755 "$BOX/pending"
  STDOUT="$BATS_TEST_TMPDIR/unsafe.stdout"
  run bash -c "jq -nc --arg cwd '$P' \
    '{hook_event_name:\"PostToolUse\",cwd:\$cwd,session_id:\"session-private\"}' |
    bash '$FEEDBACK' >'$STDOUT'"
  [ "$status" -eq 0 ]
  [ ! -s "$STDOUT" ]
  chmod 700 "$BOX/pending"
}

@test "symlinked XDG intermediate and world-writable XDG boundary are rejected" {
  P="$(make_fixture_project cfb-xdg-boundary)"
  mkdir -p "$BATS_TEST_TMPDIR/xdg-chain" "$BATS_TEST_TMPDIR/xdg-target"
  ln -s "$BATS_TEST_TMPDIR/xdg-target" "$BATS_TEST_TMPDIR/xdg-chain/link"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/xdg-chain/link/state"
  run env CRITIC_FEEDBACK_ADMIN=1 bash "$FEEDBACK" --admin-allow-project "$P"
  [ "$status" -eq 75 ]
  [ ! -e "$BATS_TEST_TMPDIR/xdg-target/state/shipyard" ]

  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/world-writable-xdg"
  mkdir "$XDG_STATE_HOME"
  chmod 777 "$XDG_STATE_HOME"
  run env CRITIC_FEEDBACK_ADMIN=1 bash "$FEEDBACK" --admin-allow-project "$P"
  [ "$status" -eq 75 ]
  [ ! -e "$XDG_STATE_HOME/shipyard" ]
}

@test "malformed timing environment fails open without touching pending feedback" {
  P="$(make_fixture_project cfb-timing-env)"
  ID="$(printf 'c%.0s' {1..64})"
  deposit "$P" session-timing "still pending" "$ID"
  BOX="$(mailbox_dir "$P" session-timing)"
  PAYLOAD="$(jq -nc --arg cwd "$P" \
    '{hook_event_name:"PostToolUse",cwd:$cwd,session_id:"session-timing"}')"

  for setting in \
    "CRITIC_CLAIM_LEASE_SEC=not-a-number" \
    "CRITIC_LOCK_WAIT_STEPS=1.5" \
    "CRITIC_LOCK_SLEEP_SEC=forever"; do
    STDOUT="$BATS_TEST_TMPDIR/${setting%%=*}.stdout"
    run env "$setting" XDG_STATE_HOME="$XDG_STATE_HOME" \
      bash -c "printf '%s' '$PAYLOAD' | bash '$FEEDBACK' >'$STDOUT'"
    [ "$status" -eq 0 ]
    [ ! -s "$STDOUT" ]
    [ "$(find "$BOX/pending" -type f -name '*.json' | wc -l)" -eq 1 ]
  done

  run drain "$P" session-timing
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")" == *"[$ID]: still pending" ]]
}

@test "Codex native deposit precedes and survives a failing custom injector" {
  P="$(make_fixture_project cfb-custom)"
  authorize "$P"
  ID="$(printf '8%.0s' {1..64})"
  BOX="$(mailbox_dir "$P" session-custom)"
  INJECTOR="$BATS_TEST_TMPDIR/custom-injector"
  LOG="$BATS_TEST_TMPDIR/custom.log"
  {
    printf '#!/bin/bash\n'
    printf 'for item in %q/pending/*.json; do\n' "$BOX"
    printf '  [ -f "$item" ] || continue\n'
    printf '  echo deposited-first >%q\n' "$LOG"
    printf '  break\n'
    printf 'done\n'
    printf 'exit 9\n'
  } >"$INJECTOR"
  chmod +x "$INJECTOR"

  run env CRITIC_PROJECT_DIR="$P" CRITIC_NOTE_ID="$ID" \
    CRITIC_NOTE_DELIVER_CMD="$INJECTOR" \
    bash "$NOTE" --harness codex session-custom "native first"
  [ "$status" -eq 0 ]
  [ "$(cat "$LOG")" = "deposited-first" ]
  [ "$(find "$BOX/pending" -type f -name '*.json' | wc -l)" -eq 1 ]
}

@test "simultaneous drainers claim each item once under the real lock" {
  P="$(make_fixture_project cfb-drainers)"
  for ((i=1; i<=4; i++)); do
    deposit "$P" "session-drainers" "item $i" "$(printf '%064x' "$i")"
  done
  OUT="$BATS_TEST_TMPDIR/drain-output"
  mkdir -p "$OUT"
  for ((i=1; i<=4; i++)); do
    drain "$P" "session-drainers" >"$OUT/$i.json" &
  done
  wait
  BOX="$(mailbox_dir "$P" session-drainers)"
  [ "$(find "$BOX/emitted" -type f -name '*.json' | wc -l)" -eq 4 ]
  [ "$(find "$BOX/pending" -type f -name '*.json' | wc -l)" -eq 0 ]
  run bash -c "jq -e '.hookSpecificOutput.hookEventName == \"PostToolUse\"' '$OUT'/*.json >/dev/null"
  [ "$status" -eq 0 ]
  IDS="$(jq -r '
    .hookSpecificOutput.additionalContext
    | capture("^Release critic \\[(?<id>[0-9a-f]{64})\\]:").id
  ' "$OUT"/*.json | sort -u | wc -l)"
  [ "$IDS" -eq 4 ]
}

@test "mailbox modes are private and atomic deposits leave no temporary file" {
  P="$(make_fixture_project cfb-modes)"
  ID="$(printf '9%.0s' {1..64})"
  deposit "$P" "session-modes" "private" "$ID"
  BOX="$(mailbox_dir "$P" session-modes)"
  ITEM="$(pending_file "$P" session-modes)"

  [ "$(file_mode "$XDG_STATE_HOME/shipyard/critic-feedback")" = "700" ]
  [ "$(file_mode "$BOX")" = "700" ]
  [ "$(file_mode "$BOX/pending")" = "700" ]
  [ "$(file_mode "$ITEM")" = "600" ]
  run find "$BOX" -type f -name '.tmp.*' -print
  [ -z "$output" ]
}

@test "former Codex log-and-skip false success is now retryable failure" {
  run env -u CRITIC_PROJECT_DIR -u CRITIC_NOTE_DELIVER_CMD \
    -u QUARTET_NOTIFY_CMD -u CRITIC_NOTE_TARGET \
    bash "$NOTE" --harness codex "session-false-success" "finding"
  [ "$status" -eq 75 ]
  [[ "$output" == *"deposit failed"* ]]
  [[ "$output" != *"skipping"* ]]
}

# ---------------------------------------------------------------------------
# Required-feedback Stop backstop
# ---------------------------------------------------------------------------

@test "unset and false require_feedback preserve the clean Stop path; non-boolean is rejected" {
  for mode in unset false; do
    P="$(make_fixture_project "cfb-stop-$mode")"
    [ "$mode" = unset ] || require_feedback "$P" false
    printf 'src/a.ts 1\n' >"$P/tmp/critic-queue-session-stop"
    run stop_hook "$P" session-stop turn-stop
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$(flush_file "$P" session-stop)" ]
  done

  P="$(make_fixture_project cfb-stop-invalid)"
  require_feedback "$P" '"yes"'
  run stop_hook "$P" session-stop turn-stop
  [ "$status" -eq 2 ]
  [[ "$output" == *"shoulder.require_feedback must be boolean"* ]]

  P="$(make_fixture_project cfb-stop-invalid-active)"
  run bash -c 'jq -nc --arg cwd "$1" \
      "{hook_event_name:\"Stop\",cwd:\$cwd,session_id:\"s\",turn_id:\"t\",
        stop_hook_active:\"true\"}" |
      CRITIC_STOP_WAIT_SEC=0 bash "$2"' _ "$P" "$STOP"
  [ "$status" -eq 2 ]
  [[ "$output" == *"stop_hook_active must be boolean"* ]]
}

@test "Stop emits completed Codex feedback in the exact continuation shape" {
  P="$(make_fixture_project cfb-stop-completed)"
  ID="$(printf 'a%.0s' {1..64})"
  deposit "$P" session-stop "completed review" "$ID"

  run stop_hook "$P" session-stop turn-completed
  [ "$status" -eq 0 ]
  jq -e --arg reason "Release critic [$ID]: completed review" '
    keys == ["decision","reason"]
    and .decision == "block"
    and .reason == $reason
  ' <<<"$output"
}

@test "Stop emits one whole oldest item and leaves later ready feedback pending" {
  P="$(make_fixture_project cfb-stop-multiple)"
  ID1="$(printf '1%.0s' {1..64})"
  ID2="$(printf '2%.0s' {1..64})"
  deposit "$P" session-stop "first review" "$ID1"
  deposit "$P" session-stop "second review" "$ID2"

  run stop_hook "$P" session-stop turn-multiple
  [ "$status" -eq 0 ]
  REASON="$(jq -r '.reason' <<<"$output")"
  [ "$REASON" = "Release critic [$ID1]: first review" ]
  [ "$(find "$(mailbox_dir "$P" session-stop)/pending" -type f | wc -l)" -eq 1 ]
  [ "$(find "$(mailbox_dir "$P" session-stop)/emitted" -type f | wc -l)" -eq 1 ]

  run stop_hook "$P" session-stop turn-multiple
  [ "$status" -eq 0 ]
  [ "$(jq -r '.reason' <<<"$output")" = \
    "Release critic [$ID2]: second review" ]
}

@test "maximum-size Stop summary is emitted whole before its claim commits" {
  P="$(make_fixture_project cfb-stop-max-summary)"
  ID="$(printf 'e%.0s' {1..64})"
  SUMMARY="$(python3 -c 'print("x" * 8192, end="")')"
  deposit "$P" session-max "$SUMMARY" "$ID"

  run stop_hook "$P" session-max turn-max
  [ "$status" -eq 0 ]
  REASON="$(jq -r '.reason' <<<"$output")"
  PREFIX="Release critic [$ID]: "
  [[ "$REASON" == "$PREFIX"* ]]
  ACTUAL="${REASON#"$PREFIX"}"
  [ "$(printf '%s' "$ACTUAL" | wc -c)" -eq 8192 ]
  [ "$ACTUAL" = "$SUMMARY" ]
  [ "$(find "$(mailbox_dir "$P" session-max)/claims" -type f | wc -l)" -eq 0 ]
  [ "$(find "$(mailbox_dir "$P" session-max)/emitted" -type f | wc -l)" -eq 1 ]
}

@test "abandoned pre-emission Stop claim replays the same stable ID after lease recovery" {
  P="$(make_fixture_project cfb-stop-claim-replay)"
  ID="$(printf 'c%.0s' {1..64})"
  deposit "$P" session-claim "must replay" "$ID"

  run claim_stop "$P" session-claim
  [ "$status" -eq 0 ]
  TOKEN="$(jq -r '.claim_token' <<<"$output")"
  [ "$(jq -r '.critique_id' <<<"$output")" = "$ID" ]
  CLAIM="$(mailbox_dir "$P" session-claim)/claims/$TOKEN"
  [ -f "$CLAIM" ]
  [ "$(find "$(mailbox_dir "$P" session-claim)/emitted" -type f | wc -l)" -eq 0 ]

  # No commit/rollback simulates an outer Stop crash before stdout. Once its
  # bounded lease is stale, the exact immutable item must be claimable again.
  set_mtime_ago 2 "$CLAIM"
  CRITIC_CLAIM_LEASE_SEC=1 run claim_stop "$P" session-claim
  [ "$status" -eq 0 ]
  [ "$(jq -r '.claim_token' <<<"$output")" = "$TOKEN" ]
  [ "$(jq -r '.critique_id' <<<"$output")" = "$ID" ]
  run finish_stop_claim rollback "$P" session-claim "$TOKEN"
  [ "$status" -eq 0 ]
}

@test "required Stop with no queue or completed item exits cleanly" {
  P="$(make_fixture_project cfb-stop-clean)"
  require_feedback "$P" true

  run stop_hook "$P" session-clean turn-clean
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$(flush_file "$P" session-clean)" ]
}

@test "completed and clean Stop paths clear prior state before the same turn is reused" {
  P="$(make_fixture_project cfb-stop-state-cleanup)"
  require_feedback "$P" true
  authorize "$P"
  printf 'src/a.ts 1\n' >"$P/tmp/critic-queue-session-cleanup"
  stop_hook "$P" session-cleanup turn-cleanup >/dev/null
  write_status "$P" session-cleanup turn-cleanup running
  [ -f "$(stop_state_file "$P" session-cleanup turn-cleanup)" ]

  ID="$(printf 'd%.0s' {1..64})"
  CRITIC_PROJECT_DIR="$P" CRITIC_NOTE_ID="$ID" \
    bash "$NOTE" --harness codex session-cleanup "completed cleanup"
  run stop_hook "$P" session-cleanup turn-cleanup true
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.reason' <<<"$output")" == *"[$ID]"* ]]
  [ ! -e "$(stop_state_file "$P" session-cleanup turn-cleanup)" ]
  [ ! -e "$(flush_file "$P" session-cleanup)" ]
  [ ! -e "$(status_file "$P" session-cleanup)" ]

  rm -f "$P/tmp/critic-queue-session-cleanup"
  run stop_hook "$P" session-cleanup turn-cleanup true
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  printf 'src/b.ts 2\n' >"$P/tmp/critic-queue-session-cleanup"
  run stop_hook "$P" session-cleanup turn-cleanup
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.reason' <<<"$output")" == *"release review is pending"* ]]
}

@test "first required Stop writes an atomic urgent marker and returns one pending continuation" {
  P="$(make_fixture_project cfb-stop-pending)"
  require_feedback "$P" true
  printf 'src/a.ts 1\n' >"$P/tmp/critic-queue-session-pending"

  run stop_hook "$P" session-pending turn-pending
  [ "$status" -eq 0 ]
  jq -e '
    .decision == "block"
    and (.reason | contains("release review is pending"))
    and (.reason | contains("no completion claim"))
  ' <<<"$output"
  F="$(flush_file "$P" session-pending)"
  [ -f "$F" ]
  [ "$(file_mode "$F")" = 600 ]
  jq -e --arg sh "$(session_hash session-pending)" \
    --arg th "$(turn_hash session-pending turn-pending)" '
    .schema_version == 1 and .session_hash == $sh and .turn_hash == $th
  ' "$F"
  run find "$P/tmp" -maxdepth 1 -name '.critic-flush-*' -print
  [ -z "$output" ]
}

@test "first required Stop polls for at most 20 seconds with clock and sleep shimmed" {
  P="$(make_fixture_project cfb-stop-timeout)"
  require_feedback "$P" true
  printf 'src/a.ts 1\n' >"$P/tmp/critic-queue-session-timeout"
  make_stub_script date '
count="$(cat "$SHIM_LOG/date.count" 2>/dev/null || echo 0)"
count=$((count + 1))
printf "%s\n" "$count" >"$SHIM_LOG/date.count"
case "$count" in 1|2|3) echo 100 ;; *) echo 120 ;; esac
'
  make_stub sleep 0

  run bash -c 'printf "%s" "$1" | env -u CRITIC_STOP_WAIT_SEC \
    -u CRITIC_STOP_POLL_SEC bash "$2"' _ \
    "$(stop_payload "$P" session-timeout turn-timeout)" "$STOP"
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.reason' <<<"$output")" == *"release review is pending"* ]]
  [ "$(wc -l <"$SHIM_LOG/sleep.argv")" -eq 1 ]
  [ "$(cat "$SHIM_LOG/date.count")" -eq 4 ]
}

@test "second required Stop names every terminal critic failure state" {
  for critic_state in budget spawn delivery running absent; do
    P="$(make_fixture_project "cfb-stop-terminal-$critic_state")"
    require_feedback "$P" true
    printf 'src/a.ts 1\n' >"$P/tmp/critic-queue-session-terminal"
    stop_hook "$P" session-terminal "turn-$critic_state" >/dev/null
    case "$critic_state" in
      absent) expected=watcher ;;
      running) write_status "$P" session-terminal "turn-$critic_state" running
               expected=timeout ;;
      *) write_status "$P" session-terminal "turn-$critic_state" "$critic_state"
         expected="$critic_state" ;;
    esac

    run stop_hook "$P" session-terminal "turn-$critic_state" true
    [ "$status" -eq 0 ]
    jq -e --arg reason \
      "Release critic unavailable ($expected); stop all implementation and report this hard blocker to the user." '
      .decision == "block" and .reason == $reason
    ' <<<"$output"
  done
}

@test "third Stop exits cleanly only after the hard blocker was the last assistant outcome" {
  P="$(make_fixture_project cfb-stop-third)"
  require_feedback "$P" true
  printf 'src/a.ts 1\n' >"$P/tmp/critic-queue-session-third"
  stop_hook "$P" session-third turn-third >/dev/null
  write_status "$P" session-third turn-third budget
  REASON='Release critic unavailable (budget); stop all implementation and report this hard blocker to the user.'
  run stop_hook "$P" session-third turn-third true
  [ "$status" -eq 0 ]
  [ "$(jq -r '.reason' <<<"$output")" = "$REASON" ]

  run stop_hook "$P" session-third turn-third true "$REASON"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "required Stop state is isolated by both opaque session and turn hashes" {
  P="$(make_fixture_project cfb-stop-isolation)"
  require_feedback "$P" true
  printf 'src/a.ts 1\n' >"$P/tmp/critic-queue-session-one"
  printf 'src/b.ts 1\n' >"$P/tmp/critic-queue-session-two"
  stop_hook "$P" session-one turn-one >/dev/null
  write_status "$P" session-one turn-one budget

  run stop_hook "$P" session-two turn-two
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.reason' <<<"$output")" == *"release review is pending"* ]]
  [ -f "$(flush_file "$P" session-one)" ]
  [ -f "$(flush_file "$P" session-two)" ]

  run stop_hook "$P" session-one turn-other
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.reason' <<<"$output")" == *"release review is pending"* ]]
}

@test "malformed watcher state fails closed as a delivery blocker without execution" {
  P="$(make_fixture_project cfb-stop-malformed)"
  require_feedback "$P" true
  printf 'src/a.ts 1\n' >"$P/tmp/critic-queue-session-malformed"
  stop_hook "$P" session-malformed turn-malformed >/dev/null
  printf '%s\n' '$(touch should-never-exist)' \
    >"$(status_file "$P" session-malformed)"
  chmod 600 "$(status_file "$P" session-malformed)"

  run stop_hook "$P" session-malformed turn-malformed true
  [ "$status" -eq 0 ]
  [ "$(jq -r '.reason' <<<"$output")" = \
    "Release critic unavailable (delivery); stop all implementation and report this hard blocker to the user." ]
  [ ! -e "$P/should-never-exist" ]
}

@test "hardlinked watcher state is rejected without modifying the other link" {
  P="$(make_fixture_project cfb-stop-hardlink)"
  require_feedback "$P" true
  printf 'src/a.ts 1\n' >"$P/tmp/critic-queue-session-hardlink"
  stop_hook "$P" session-hardlink turn-hardlink >/dev/null
  EXTERNAL="$BATS_TEST_TMPDIR/external-status"
  printf '%s\n' '{"schema_version":1,"status":"budget"}' >"$EXTERNAL"
  chmod 600 "$EXTERNAL"
  ln "$EXTERNAL" "$(status_file "$P" session-hardlink)"
  BEFORE="$(checked_sha <"$EXTERNAL")"

  run stop_hook "$P" session-hardlink turn-hardlink true
  [ "$status" -eq 0 ]
  [ "$(jq -r '.reason' <<<"$output")" = \
    "Release critic unavailable (delivery); stop all implementation and report this hard blocker to the user." ]
  [ "$(checked_sha <"$EXTERNAL")" = "$BEFORE" ]
  [ "$(stat -c '%h' "$EXTERNAL" 2>/dev/null || stat -f '%l' "$EXTERNAL")" -eq 2 ]
}

@test "Stop polling observes a concurrent durable deposit for the same session" {
  P="$(make_fixture_project cfb-stop-concurrent)"
  require_feedback "$P" true
  authorize "$P"
  printf 'src/a.ts 1\n' >"$P/tmp/critic-queue-session-concurrent"
  ID="$(printf 'b%.0s' {1..64})"
  (
    sleep 0.1
    CRITIC_PROJECT_DIR="$P" CRITIC_NOTE_ID="$ID" \
      bash "$NOTE" --harness codex session-concurrent "arrived while polling"
  ) &
  WRITER_PID=$!

  CRITIC_STOP_WAIT_SEC=2 run stop_hook \
    "$P" session-concurrent turn-concurrent
  wait "$WRITER_PID"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.reason' <<<"$output")" = \
    "Release critic [$ID]: arrived while polling" ]
}

@test "urgent marker bypasses watcher debounce and records successful deposit" {
  P="$(make_fixture_project cfb-stop-urgent)"
  require_feedback "$P" true
  authorize "$P"
  RESULT='warn|src/a.ts|urgent review'
  CANNED="$(jq -cn --arg result "$RESULT" \
    '{type:"result",result:$result,usage:{input_tokens:3,output_tokens:2}}')"
  make_stub claude 0 "$CANNED"
  mkdir -p "$P/src"
  printf '// changed\n' >"$P/src/a.ts"
  printf 'src/a.ts %s\n' "$(date +%s)" \
    >"$P/tmp/critic-queue-session-urgent"
  stop_hook "$P" session-urgent turn-urgent >/dev/null

  run env QUARTET_DIR="$QUARTET_ROOT" QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    XDG_STATE_HOME="$XDG_STATE_HOME" CRITIC_IDLE_SEC=999999 \
    CRITIC_BATCH_FILES=999999 CRITIC_HARNESS=claude \
    CRITIC_NOTE_HARNESS=codex \
    CLAUDE_NOTE_CMD="$NOTE --harness codex" \
    bash "$WATCH" --project "$P" --session session-urgent --once
  [ "$status" -eq 0 ]
  [ ! -e "$P/tmp/critic-queue-session-urgent" ]
  jq -e '.status == "deposited"' "$(status_file "$P" session-urgent)"
  [ -n "$(pending_file "$P" session-urgent)" ]
}

@test "required watcher reports budget and keeps the edit queue recoverable" {
  P="$(make_fixture_project cfb-stop-budget)"
  awk '
    { print }
    $0 == "[release]" { print "budget_tokens_daily = 0" }
  ' "$P/.agents/config.toml" >"$P/.agents/config.toml.next"
  mv "$P/.agents/config.toml.next" "$P/.agents/config.toml"
  require_feedback "$P" true
  printf 'src/a.ts 1\n' >"$P/tmp/critic-queue-session-budget"
  stop_hook "$P" session-budget turn-budget >/dev/null

  run env QUARTET_DIR="$QUARTET_ROOT" QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    CRITIC_IDLE_SEC=999999 CRITIC_BATCH_FILES=999999 \
    bash "$WATCH" --project "$P" --session session-budget --once
  [ "$status" -eq 0 ]
  [ -s "$P/tmp/critic-queue-session-budget" ]
  jq -e '.status == "budget"' "$(status_file "$P" session-budget)"
}

@test "required watcher keeps reviewed work after three-strike spawn and delivery failures" {
  for failure in spawn delivery; do
    P="$(make_fixture_project "cfb-stop-watcher-$failure")"
    require_feedback "$P" true
    mkdir -p "$P/src"
    printf '// changed\n' >"$P/src/a.ts"
    printf 'src/a.ts 1\n' >"$P/tmp/critic-queue-session-failure"
    stop_hook "$P" session-failure "turn-$failure" >/dev/null
    if [ "$failure" = spawn ]; then
      make_stub claude 1
      NOTE_CMD="$NOTE --harness codex"
    else
      CANNED="$(jq -cn --arg result 'warn|src/a.ts|delivery review' \
        '{type:"result",result:$result,usage:{input_tokens:3,output_tokens:2}}')"
      make_stub claude 0 "$CANNED"
      make_stub note-fail 1
      NOTE_CMD=note-fail
    fi

    for _ in 1 2 3; do
      run env QUARTET_DIR="$QUARTET_ROOT" QUARTET_EVENTS_DIR="$EVENTS_DIR" \
        CRITIC_IDLE_SEC=999999 CRITIC_BATCH_FILES=999999 \
        CRITIC_HARNESS=claude CRITIC_NOTE_HARNESS=codex \
        CLAUDE_NOTE_CMD="$NOTE_CMD" \
        bash "$WATCH" --project "$P" --session session-failure --once
      [ "$status" -eq 0 ]
    done
    [ -s "$P/tmp/critic-queue-session-failure" ]
    jq -e --arg failure "$failure" '.status == $failure' \
      "$(status_file "$P" session-failure)"

    if [ "$failure" = spawn ]; then
      CALLS_BEFORE="$(grep -c '^-p ' "$SHIM_LOG/claude.argv")"
      FAILED_EVENTS_BEFORE="$(events_json |
        jq -c 'select(.event=="release.critique.spawn_failed")' | wc -l)"
    else
      CALLS_BEFORE="$(grep -c '^session-failure release critic:' \
        "$SHIM_LOG/note-fail.argv")"
      FAILED_EVENTS_BEFORE="$(events_json |
        jq -c 'select(.event=="release.critique.delivery_failed")' | wc -l)"
    fi

    # The exhausted state is bounded for this exact queue + Stop turn: a
    # continuously polling watcher must not start another three-attempt cycle.
    run env QUARTET_DIR="$QUARTET_ROOT" QUARTET_EVENTS_DIR="$EVENTS_DIR" \
      CRITIC_IDLE_SEC=999999 CRITIC_BATCH_FILES=999999 \
      CRITIC_HARNESS=claude CRITIC_NOTE_HARNESS=codex \
      CLAUDE_NOTE_CMD="$NOTE_CMD" \
      bash "$WATCH" --project "$P" --session session-failure --once
    [ "$status" -eq 0 ]
    if [ "$failure" = spawn ]; then
      [ "$(grep -c '^-p ' "$SHIM_LOG/claude.argv")" = "$CALLS_BEFORE" ]
      FAILED_EVENTS_AFTER="$(events_json |
        jq -c 'select(.event=="release.critique.spawn_failed")' | wc -l)"
    else
      BOUNDED_CALLS="$(grep -c '^session-failure release critic:' \
        "$SHIM_LOG/note-fail.argv")"
      [ "$BOUNDED_CALLS" = "$CALLS_BEFORE" ] || {
        printf 'delivery bounded calls: before=%s after=%s state=' \
          "$CALLS_BEFORE" "$BOUNDED_CALLS" >&2
        cat "$P/tmp/critic-attempts-session-failure" >&2 || true
        false
      }
      FAILED_EVENTS_AFTER="$(events_json |
        jq -c 'select(.event=="release.critique.delivery_failed")' | wc -l)"
    fi
    [ "$FAILED_EVENTS_AFTER" = "$FAILED_EVENTS_BEFORE" ]

    # A later edit changes the reviewed generation and permits recovery after
    # an operator repairs the harness or delivery command.
    printf '// later edit\n' >"$P/src/b.ts"
    printf 'src/b.ts 2\n' >>"$P/tmp/critic-queue-session-failure"
    run env QUARTET_DIR="$QUARTET_ROOT" QUARTET_EVENTS_DIR="$EVENTS_DIR" \
      CRITIC_IDLE_SEC=999999 CRITIC_BATCH_FILES=999999 \
      CRITIC_HARNESS=claude CRITIC_NOTE_HARNESS=codex \
      CLAUDE_NOTE_CMD="$NOTE_CMD" \
      bash "$WATCH" --project "$P" --session session-failure --once
    [ "$status" -eq 0 ]
    if [ "$failure" = spawn ]; then
      CALLS_AFTER="$(grep -c '^-p ' "$SHIM_LOG/claude.argv")"
      [ "$CALLS_AFTER" -eq "$((CALLS_BEFORE + 1))" ] || {
        printf 'spawn recovery calls: before=%s after=%s\n' \
          "$CALLS_BEFORE" "$CALLS_AFTER" >&2
        false
      }
    else
      CALLS_AFTER="$(grep -c '^session-failure release critic:' \
        "$SHIM_LOG/note-fail.argv")"
      [ "$CALLS_AFTER" -eq "$((CALLS_BEFORE + 1))" ] || {
        printf 'delivery recovery calls: before=%s after=%s\n' \
          "$CALLS_BEFORE" "$CALLS_AFTER" >&2
        false
      }
    fi
  done
}
