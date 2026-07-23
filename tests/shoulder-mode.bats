#!/usr/bin/env bats
# tests/shoulder-mode.bats — shoulder-mode critic: queue hook, debounced
# watcher, severity parser, token budget, delivery retry, stop gate.
#
# No real LLM anywhere: `claude` is a PATH-shim stub returning canned
# `--output-format json` payloads; `claude-note` delivery is a recording
# stub with scripted exit codes.

setup() {
  load helpers
  quartet_setup
}

QUEUE_HOOK="agents/release/critic-queue.sh"
WATCH="agents/release/critic-watch.sh"
STOP_GATE="agents/release/critic-stop-gate.sh"

# Canned critic reply: 1 block, 2 warn, 1 note. 1200+345 = 1545 tokens.
CANNED_CLAUDE_JSON='{"type":"result","result":"block|src/auth.ts|removes session check on /admin\nwarn|src/api.ts|changed behavior without a test\nwarn|package.json|new dependency leftpad\nnote|README.md|doc gap\nTOKENS_HINT|<none>","usage":{"input_tokens":1200,"output_tokens":345}}'

# run_watch <project> [extra args] — critic-watch with the captured env.
# Debounce/budget knobs come from the test's exported CRITIC_* vars.
run_watch() {
  local project="$1"; shift
  QUARTET_DIR="$QUARTET_ROOT" \
  QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    bash "$QUARTET_ROOT/$WATCH" --project "$project" "$@"
}

# queue_files <project> <session> <n> — append n distinct entries, creating
# each file on disk (untracked) so the watcher has real hunks to grade: an
# empty-diff queue is skipped without spawning the critic.
queue_files() {
  local project="$1" session="$2" n="$3" i
  mkdir -p "$project/src"
  for i in $(seq 1 "$n"); do
    printf '// stub %02d\n' "$i" > "$project/src/f$(printf '%02d' "$i").ts"
    printf 'src/f%02d.ts %s\n' "$i" "$(date +%s)" \
      >> "$project/tmp/critic-queue-$session"
  done
}

critique_events() {
  events_json | jq -c 'select(.event=="release.critique")'
}

# ---------------------------------------------------------------------------
# (a) queue hook
# ---------------------------------------------------------------------------

@test "critic-queue appends file path + epoch and exits 0" {
  P="$(make_fixture_project critq)"
  run bash -c "printf '%s' '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/a.ts\"}}' \
    | CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$QUEUE_HOOK'"
  [ "$status" -eq 0 ]
  Q="$P/tmp/critic-queue-s1"
  [ -f "$Q" ]
  run grep -cE '^src/a\.ts [0-9]+$' "$Q"
  [ "$output" = "1" ]
}

@test "critic-queue exits 0 on garbage stdin and queues nothing" {
  P="$(make_fixture_project critq-garbage)"
  run bash -c "printf 'not json {{{[' | CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$QUEUE_HOOK'"
  [ "$status" -eq 0 ]
  run bash -c "ls '$P/tmp'/critic-queue-* 2>/dev/null"
  [ -z "$output" ]
}

@test "critic-queue exits 0 when tool_input has no file_path" {
  P="$(make_fixture_project critq-nofile)"
  run bash -c "printf '%s' '{\"session_id\":\"s1\",\"tool_input\":{\"command\":\"ls\"}}' \
    | CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$QUEUE_HOOK'"
  [ "$status" -eq 0 ]
  run bash -c "ls '$P/tmp'/critic-queue-* 2>/dev/null"
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# (b) debounce math — a burst becomes ONE critique, not one per file
# ---------------------------------------------------------------------------

@test "20-file burst with batch=8 yields at most 2 critique events across 2 passes" {
  P="$(make_fixture_project critb)"
  make_stub claude 0 "$CANNED_CLAUDE_JSON"
  queue_files "$P" s1 20
  export CRITIC_BATCH_FILES=8 CRITIC_IDLE_SEC=99999

  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]

  N="$(critique_events | wc -l)"
  [ "$N" -ge 1 ]
  [ "$N" -le 2 ]
  # the single critique covered the whole 20-file batch
  EV="$(critique_events | head -1)"
  [ "$(jq -r '.files' <<<"$EV")" = "20" ]
}

# ---------------------------------------------------------------------------
# (c) idle trigger
# ---------------------------------------------------------------------------

@test "idle queue below batch size still triggers one critique" {
  P="$(make_fixture_project critc)"
  make_stub claude 0 "$CANNED_CLAUDE_JSON"
  queue_files "$P" s1 2
  touch -d "2 minutes ago" "$P/tmp/critic-queue-s1"
  export CRITIC_BATCH_FILES=100 CRITIC_IDLE_SEC=1

  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  [ "$(critique_events | wc -l)" -eq 1 ]
}

@test "fresh queue below both thresholds does NOT trigger" {
  P="$(make_fixture_project critc-fresh)"
  make_stub claude 0 "$CANNED_CLAUDE_JSON"
  queue_files "$P" s1 2
  export CRITIC_BATCH_FILES=100 CRITIC_IDLE_SEC=99999

  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  [ "$(critique_events | wc -l)" -eq 0 ]
  [ -s "$P/tmp/critic-queue-s1" ]
}

@test "critic-queue drops gitignored file paths at enqueue time" {
  P="$(make_fixture_project critq-ign)"
  printf 'tmp/\n' > "$P/.gitignore"
  run bash -c "printf '%s' '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"tmp/medic-result.json\"}}' \
    | CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$QUEUE_HOOK'"
  [ "$status" -eq 0 ]
  run bash -c "ls '$P/tmp'/critic-queue-* 2>/dev/null"
  [ -z "$output" ]
}

@test "empty diff (queued file gone from disk) skips critic, drops queue" {
  P="$(make_fixture_project critq-empty)"
  make_stub claude 0 "$CANNED_CLAUDE_JSON"
  printf 'src/ghost.ts %s\n' "$(date +%s)" >> "$P/tmp/critic-queue-s1"
  touch -d "2 minutes ago" "$P/tmp/critic-queue-s1"
  export CRITIC_IDLE_SEC=1 CRITIC_BATCH_FILES=100

  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  [ "$(critique_events | wc -l)" -eq 0 ]
  [ "$(stub_calls claude)" = "0" ]
  SKIP="$(events_json | jq -c 'select(.event=="release.critique.skipped")')"
  [ -n "$SKIP" ]
  [ "$(jq -r '.reason' <<<"$SKIP")" = "empty_diff" ]
  [ ! -e "$P/tmp/critic-queue-s1" ]
}

# ---------------------------------------------------------------------------
# (d) severity parser + delivery
# ---------------------------------------------------------------------------

@test "canned findings parse to block=1 warn=2 note=1 tokens=1545 and delivery fires" {
  P="$(make_fixture_project critd)"
  make_stub claude 0 "$CANNED_CLAUDE_JSON"
  make_stub claude-note 0
  queue_files "$P" s1 2
  touch -d "2 minutes ago" "$P/tmp/critic-queue-s1"
  export CRITIC_IDLE_SEC=1 CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"

  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]

  EV="$(critique_events | head -1)"
  [ -n "$EV" ]
  [ "$(jq -r '.block'  <<<"$EV")" = "1" ]
  [ "$(jq -r '.warn'   <<<"$EV")" = "2" ]
  [ "$(jq -r '.note'   <<<"$EV")" = "1" ]
  [ "$(jq -r '.tokens' <<<"$EV")" = "1545" ]
  [ "$(jq -r '.files'  <<<"$EV")" = "2" ]
  [ "$(jq -r '.svc'    <<<"$EV")" = "critd-release" ]
  [ "$(jq -r '.source' <<<"$EV")" = "shoulder" ]

  # delivery invoked: target session first, findings summary after
  run grep -c '^s1 release critic: 1 block, 2 warn, 1 note' "$SHIM_LOG/claude-note.argv"
  [ "$output" = "1" ]

  # findings file written beside the queue for the stop gate
  run grep -c '^block|src/auth.ts|' "$P/tmp/critic-findings-s1"
  [ "$output" = "1" ]

  # successful delivery clears the queue
  [ ! -e "$P/tmp/critic-queue-s1" ]
}

# ---------------------------------------------------------------------------
# (e) token budget
# ---------------------------------------------------------------------------

@test "daily token budget reached: skip event, claude never called" {
  P="$(make_fixture_project crite)"
  make_stub claude 0 "$CANNED_CLAUDE_JSON"
  # Pre-seed today's stream with a critique that already blew the budget.
  printf '%s\n' \
    '{"ts":"2026-01-01T00:00:00Z","svc":"crite-guardian","event":"release.critique","tokens":999999999}' \
    >> "$(events_file)"
  queue_files "$P" s1 2
  touch -d "2 minutes ago" "$P/tmp/critic-queue-s1"
  export CRITIC_IDLE_SEC=1

  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]

  SKIP="$(events_json | jq -c 'select(.event=="release.critique.skipped")')"
  [ -n "$SKIP" ]
  [ "$(jq -r '.reason' <<<"$SKIP")" = "budget" ]
  # only the pre-seeded critique event exists — no new one
  [ "$(critique_events | wc -l)" -eq 1 ]
  [ "$(stub_calls claude)" = "0" ]
}

# ---------------------------------------------------------------------------
# (f) delivery retry semantics
# ---------------------------------------------------------------------------

@test "claude-note exit 3 keeps the queue; a later exit-0 delivery clears it" {
  P="$(make_fixture_project critf)"
  make_stub claude 0 "$CANNED_CLAUDE_JSON"
  make_stub claude-note 3
  queue_files "$P" s1 2
  touch -d "2 minutes ago" "$P/tmp/critic-queue-s1"
  export CRITIC_IDLE_SEC=1 CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"

  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  [ -s "$P/tmp/critic-queue-s1" ]   # intact for retry

  make_stub claude-note 0                     # session freed up
  touch -d "2 minutes ago" "$P/tmp/critic-queue-s1"
  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  [ ! -e "$P/tmp/critic-queue-s1" ]  # cleared after delivery
}

@test "claude-note exit 2 (ambiguous target) also keeps the queue" {
  P="$(make_fixture_project critf2)"
  make_stub claude 0 "$CANNED_CLAUDE_JSON"
  make_stub claude-note 2
  queue_files "$P" s1 2
  touch -d "2 minutes ago" "$P/tmp/critic-queue-s1"
  export CRITIC_IDLE_SEC=1 CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"

  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  [ -s "$P/tmp/critic-queue-s1" ]
}

@test "no CLAUDE_NOTE_CMD: delivery skipped with a log line, queue cleared" {
  P="$(make_fixture_project critf3)"
  make_stub claude 0 "$CANNED_CLAUDE_JSON"
  queue_files "$P" s1 2
  touch -d "2 minutes ago" "$P/tmp/critic-queue-s1"
  export CRITIC_IDLE_SEC=1
  unset CLAUDE_NOTE_CMD

  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLAUDE_NOTE_CMD unset"* ]]
  [ ! -e "$P/tmp/critic-queue-s1" ]
  [ "$(critique_events | wc -l)" -eq 1 ]
}

@test "broken note command (exit 127) keeps queue, gives up loudly after 3 attempts" {
  P="$(make_fixture_project critf4)"
  make_stub claude 0 "$CANNED_CLAUDE_JSON"
  make_stub claude-note 127
  queue_files "$P" s1 2
  export CRITIC_IDLE_SEC=1 CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"

  for i in 1 2; do
    touch -d "2 minutes ago" "$P/tmp/critic-queue-s1"
    run run_watch "$P" --session s1 --once
    [ "$status" -eq 0 ]
    [ -s "$P/tmp/critic-queue-s1" ]        # kept for retry
  done

  touch -d "2 minutes ago" "$P/tmp/critic-queue-s1"
  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  [ ! -e "$P/tmp/critic-queue-s1" ]        # 3rd failure: gave up
  [ -s "$P/tmp/critic-findings-s1" ]       # findings preserved on disk
  FAILEV="$(events_json | jq -c 'select(.event=="release.critique.delivery_failed")')"
  [ -n "$FAILEV" ]
  [ "$(jq -r '.rc' <<<"$FAILEV")" = "127" ]
}

@test "entries queued during the claude run survive delivery (snapshot race)" {
  P="$(make_fixture_project crith)"
  # claude stub simulates a mid-run hook append: while the "model" runs, a
  # new edit lands in the queue. It must NOT be consumed by this delivery.
  cat > "$SHIM_BIN/claude" <<EOF
#!/bin/bash
echo 'src/late.ts 9999999999' >> "$P/tmp/critic-queue-s1"
printf '%s' '$CANNED_CLAUDE_JSON'
EOF
  chmod +x "$SHIM_BIN/claude"
  make_stub claude-note 0
  mkdir -p "$P/src"
  printf '// stub\n' > "$P/src/early.ts"
  printf '// stub\n' > "$P/src/late.ts"
  printf 'src/early.ts %s\n' "$(date +%s)" >> "$P/tmp/critic-queue-s1"
  touch -d "2 minutes ago" "$P/tmp/critic-queue-s1"
  export CRITIC_IDLE_SEC=1 CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"

  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  # delivery succeeded, but the late entry is still queued for the next pass
  [ -s "$P/tmp/critic-queue-s1" ]
  run grep -c '^src/late.ts ' "$P/tmp/critic-queue-s1"
  [ "$output" = "1" ]
  run grep -c '^src/early.ts ' "$P/tmp/critic-queue-s1"
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# (g) stop gate
# ---------------------------------------------------------------------------

@test "stop-gate: disarmed (no env) exits 0 even with block findings" {
  P="$(make_fixture_project critg-off)"
  printf 'block|src/auth.ts|removes session check\n' \
    >"$P/tmp/critic-findings-s1"
  run bash -c "printf '%s' '{\"session_id\":\"s1\"}' \
    | CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$STOP_GATE'"
  [ "$status" -eq 0 ]
}

@test "stop-gate: armed + block findings exits 2 and names the finding" {
  P="$(make_fixture_project critg-block)"
  printf 'block|src/auth.ts|removes session check\nwarn|src/api.ts|no test\n' \
    >"$P/tmp/critic-findings-s1"
  run bash -c "printf '%s' '{\"session_id\":\"s1\"}' \
    | CRITIC_BLOCK=1 CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$STOP_GATE'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"removes session check"* ]]
  [[ "$output" != *"src/api.ts"* ]]   # warn findings don't gate
}

@test "stop-gate: armed + only warn/note findings exits 0" {
  P="$(make_fixture_project critg-warn)"
  printf 'warn|src/api.ts|no test\nnote|README.md|doc gap\n' \
    >"$P/tmp/critic-findings-s1"
  run bash -c "printf '%s' '{\"session_id\":\"s1\"}' \
    | CRITIC_BLOCK=1 CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$STOP_GATE'"
  [ "$status" -eq 0 ]
}
