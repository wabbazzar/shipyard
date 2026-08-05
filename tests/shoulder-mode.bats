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
  quartet_use_native_bash
}

teardown() {
  # Concurrency cases deliberately park background hooks behind marker files.
  # If readiness fails, release every marker and any held queue lock so Bats
  # reports the assertion instead of leaving an indefinitely paused process.
  find "$BATS_TEST_TMPDIR" -type f \
    \( -name '*.pause' -o -name '*.observe' \) -delete 2>/dev/null || true
  if declare -F cq_queue_lock_release >/dev/null 2>&1; then
    cq_queue_lock_release >/dev/null 2>&1 || true
  fi
  local attempt pid
  for ((attempt=0; attempt<200; attempt++)); do
    [ -z "$(jobs -pr)" ] && return 0
    sleep 0.01
  done
  for pid in $(jobs -pr); do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}

QUEUE_HOOK="agents/release/critic-queue.sh"
QUEUE_LIB="agents/release/critic-queue-lib.sh"
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
    /bin/bash "$QUARTET_ROOT/$WATCH" --project "$project" "$@"
}

@test "native Bash watcher treats an empty queue set as an idle no-op" {
  P="$(make_fixture_project critnativeidle)"

  run env QUARTET_DIR="$QUARTET_ROOT" QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    /bin/bash "$QUARTET_ROOT/$WATCH" --project "$P" --once
  [ "$status" -eq 0 ]
  [ ! -e "$(events_file)" ]
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
  fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
  export CRITIC_BATCH_FILES=100 CRITIC_IDLE_SEC=1

  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  [ "$(critique_events | wc -l)" -eq 1 ]
}

@test "critic prompt scopes to queued paths so a large unrelated branch diff cannot break Hermes" {
  P="$(make_fixture_project critc-scoped)"
  mkdir -p "$P/src"
  {
    printf 'UNRELATED_HISTORY_START\n'
    head -c 200000 /dev/zero | tr '\000' x
    printf '\nUNRELATED_HISTORY_END\n'
  } >"$P/README.md"
  queue_files "$P" s1 1
  fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
  PROMPT_LOG="$BATS_TEST_TMPDIR/hermes-prompt"
  make_stub_script hermes "if [ \"\$1\" = chat ]; then
shift
prompt=''
while [ \$# -gt 0 ]; do
  if [ \"\$1\" = '-q' ]; then prompt=\"\$2\"; break; fi
  shift
done
printf '%s' \"\$prompt\" > '$PROMPT_LOG'
printf '%s\\n' 'warn|src/f01.ts|scoped review'
printf '%s\\n' 'TOKENS_HINT|<none>'
printf '%s\\n' 'session_id: scoped-test' >&2
elif [ \"\$1\" = sessions ]; then
printf '%s' '{\"input_tokens\":10,\"output_tokens\":5}'
fi"
  export CRITIC_IDLE_SEC=1 CRITIC_HARNESS=hermes

  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  [ "$(critique_events | wc -l)" -eq 1 ]
  [ "$(wc -c <"$PROMPT_LOG")" -lt 100000 ]
  grep -Fq 'src/f01.ts' "$PROMPT_LOG"
  run grep -Fq 'UNRELATED_HISTORY_START' "$PROMPT_LOG"
  [ "$status" -ne 0 ]
}

@test "queued tracked deletion is reviewed even though the path no longer exists" {
  P="$(make_fixture_project critc-delete)"
  make_stub claude 0 "$CANNED_CLAUDE_JSON"
  git -C "$P" rm -q README.md
  printf 'README.md %s\n' "$(date +%s)" >"$P/tmp/critic-queue-s1"
  fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
  export CRITIC_IDLE_SEC=1

  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  [ "$(critique_events | wc -l)" -eq 1 ]
  [ "$(stub_calls claude)" -gt 0 ]
}

@test "queued git pathspec magic cannot expand review scope beyond the literal path" {
  P="$(make_fixture_project critc-pathspec)"
  make_stub claude 0 "$CANNED_CLAUDE_JSON"
  mkdir -p "$P/src"
  printf 'export const secret = 1;\n' >"$P/src/secret.ts"
  git -C "$P" add src/secret.ts
  git -C "$P" commit -q -m "track scoped file"
  printf 'export const secret = 2;\n' >"$P/src/secret.ts"
  printf ':(glob)src/*.ts %s\n' "$(date +%s)" >"$P/tmp/critic-queue-s1"
  fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
  export CRITIC_IDLE_SEC=1

  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  [ "$(critique_events | wc -l)" -eq 0 ]
  [ "$(stub_calls claude)" = "0" ]
}

@test "prompt section truncation preserves valid UTF-8 at a multibyte boundary" {
  P="$(make_fixture_project critc-utf8)"
  {
    head -c 15999 /dev/zero | tr '\000' x
    printf '😀trailing extension text\n'
  } >"$P/.agents/release.md"
  queue_files "$P" s1 1
  fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
  PROMPT_LOG="$BATS_TEST_TMPDIR/hermes-utf8-prompt"
  make_stub_script hermes "if [ \"\$1\" = chat ]; then
shift
while [ \$# -gt 0 ]; do
  if [ \"\$1\" = '-q' ]; then printf '%s' \"\$2\" > '$PROMPT_LOG'; break; fi
  shift
done
printf '%s\\n' 'note|src/f01.ts|utf8 review'
printf '%s\\n' 'session_id: utf8-test' >&2
elif [ \"\$1\" = sessions ]; then
printf '%s' '{\"input_tokens\":10,\"output_tokens\":5}'
fi"
  export CRITIC_IDLE_SEC=1 CRITIC_HARNESS=hermes

  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  python3 -c 'import pathlib, sys; pathlib.Path(sys.argv[1]).read_text()' \
    "$PROMPT_LOG"
  grep -Fq 'SHIPYARD: PROJECT EXTENSION omitted' "$PROMPT_LOG"
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
  fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
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

@test "critic-queue drops absolute paths outside the project" {
  P="$(make_fixture_project critq-xproj)"
  run bash -c "printf '%s' '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"/some/other/repo/src/a.ts\"}}' \
    | CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$QUEUE_HOOK'"
  [ "$status" -eq 0 ]
  run bash -c "ls '$P/tmp'/critic-queue-* 2>/dev/null"
  [ -z "$output" ]
}

@test "budget-exhausted queue is deferred, not discarded; skip event once per day" {
  P="$(make_fixture_project crite-defer)"
  make_stub claude 0 "$CANNED_CLAUDE_JSON"
  printf '%s\n' \
    '{"ts":"2026-01-01T00:00:00Z","svc":"crite-defer-release","event":"release.critique","tokens":999999999}' \
    >> "$(events_file)"
  queue_files "$P" s1 2
  export CRITIC_IDLE_SEC=1

  fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  [ -s "$P/tmp/critic-queue-s1" ]          # queue survives for next window
  [ "$(stub_calls claude)" = "0" ]

  fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  [ -s "$P/tmp/critic-queue-s1" ]
  # second pass on the same blown budget does not re-emit the skip event
  N="$(events_json | jq -c 'select(.event=="release.critique.skipped" and .reason=="budget")' | wc -l)"
  [ "$N" -eq 1 ]
}

@test "claude spawn failure gives up loudly after 3 attempts" {
  P="$(make_fixture_project critspawn)"
  make_stub_script claude 'printf "%s\n%s\n" "env: EACCES: permission denied, exec claude" "detail: denied" >&2; exit 126'
  queue_files "$P" s1 2
  export CRITIC_IDLE_SEC=1

  for i in 1 2; do
    fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
    run run_watch "$P" --session s1 --once
    [ "$status" -eq 0 ]
    [ -s "$P/tmp/critic-queue-s1" ]        # kept for retry
  done

  fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  [ ! -e "$P/tmp/critic-queue-s1" ]        # 3rd failure: gave up
  EV="$(events_json | jq -c 'select(.event=="release.critique.spawn_failed")')"
  [ -n "$EV" ]
  [ "$(jq -r '.attempts' <<<"$EV")" = "3" ]
  [[ "$output" == *"EACCES"* ]]
  [ "$(jq -r '.stderr' <<<"$EV")" = "env: EACCES: permission denied, exec claude detail: denied" ]
  [ "$(jq -r '.stderr | length' <<<"$EV")" -le 300 ]
}

# ---------------------------------------------------------------------------
# (d) severity parser + delivery
# ---------------------------------------------------------------------------

@test "critic rejects malformed response without clean sentinel and keeps queue" {
  P="$(make_fixture_project critmalformed)"
  make_stub claude 0 '{"type":"result","result":"this is not a finding","usage":{"input_tokens":10,"output_tokens":5}}'
  make_stub claude-note 0
  queue_files "$P" s1 2
  fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
  export CRITIC_IDLE_SEC=1 CRITIC_DIFF_MODE=staged CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"
  git -C "$P" add src/f01.ts src/f02.ts

  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  [ -s "$P/tmp/critic-queue-s1" ]
  [ ! -e "$P/tmp/critic-findings-s1" ]
  [ ! -e "$P/tmp/critic-valid-response-s1" ]
  [ "$(stub_calls claude-note)" = "0" ]
  [[ "$output" == *"malformed critic response"* ]]
}

@test "malformed response lifecycle reproduces a fourth invocation on one immutable snapshot" {
  P="$(make_fixture_project critmalformed-lifecycle)"
  MALFORMED_CALL_LOG="$BATS_TEST_TMPDIR/malformed-lifecycle-calls"
  make_stub_script claude "printf 'call\\n' >> '$MALFORMED_CALL_LOG'
printf '%s\\n' '{\"type\":\"result\",\"result\":\"unsafe prose without a sentinel\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}'"
  make_stub claude-note 0
  queue_files "$P" s1 2
  export CRITIC_IDLE_SEC=1 CRITIC_DIFF_MODE=staged \
    CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"
  git -C "$P" add src/f01.ts src/f02.ts
  SNAPSHOT_BEFORE="$(shasum -a 256 "$P/tmp/critic-queue-s1" | awk '{print $1}')"

  for _pass in 1 2 3 4; do
    fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
    run run_watch "$P" --session s1 --once
    [ "$status" -eq 0 ]
  done

  echo "pre-change malformed lifecycle model_calls=$(wc -l <"$MALFORMED_CALL_LOG" | tr -d ' ')" >&3
  [ "$(wc -l <"$MALFORMED_CALL_LOG" | tr -d ' ')" = "4" ]
  [ "$(events_json | jq -s '[.[] | select(.event == "release.critique.malformed_response")] | length')" = "4" ]
  [ "$(events_json | jq -s '[.[] | select(.event == "release.critique.malformed_response_exhausted")] | length')" = "0" ]
  [ "$SNAPSHOT_BEFORE" = "$(shasum -a 256 "$P/tmp/critic-queue-s1" | awk '{print $1}')" ]
  [ -z "$(find "$P/tmp" -maxdepth 1 -name 'critic-status-*' -print)" ]
  [ "$(events_json | jq -s '[.[] | select(.event == "release.critique") | (.tokens // 0)] | add // 0')" = "0" ]
}

@test "malformed response classification names every generic parser failure" {
  local -a case_names expected payloads
  local idx P EV DIAG
  case_names=(empty-text missing-sentinel duplicate-sentinel invalid-line envelope)
  expected=(empty_text missing_sentinel duplicate_sentinel invalid_line unnormalizable_envelope)
  payloads=(
    '{"type":"result","result":"","usage":{"input_tokens":10,"output_tokens":5}}'
    '{"type":"result","result":"private-missing-prose","usage":{"input_tokens":10,"output_tokens":5}}'
    '{"type":"result","result":"TOKENS_HINT|<none>\nTOKENS_HINT|<none>","usage":{"input_tokens":10,"output_tokens":5}}'
    '{"type":"result","result":"private-invalid-prose\nTOKENS_HINT|<none>","usage":{"input_tokens":10,"output_tokens":5}}'
    '{"type":"result","usage":{"input_tokens":10,"output_tokens":5}}'
  )

  for idx in 0 1 2 3 4; do
    P="$(make_fixture_project "critmalformed-${case_names[$idx]}")"
    make_stub claude 0 "${payloads[$idx]}"
    queue_files "$P" s1 1
    fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
    export CRITIC_IDLE_SEC=1 CRITIC_DIFF_MODE=staged
    git -C "$P" add src/f01.ts

    run run_watch "$P" --session s1 --once
    [ "$status" -eq 0 ]
    [ -s "$P/tmp/critic-queue-s1" ]
    EV="$(events_json | jq -c \
      'select(.event == "release.critique.malformed_response")' | tail -1)"
    [ "$(jq -r '.reason' <<<"$EV")" = "${expected[$idx]}" ]
    DIAG="$P/tmp/critic-malformed-diagnostic-s1"
    [ "$(jq -r '.reason' "$DIAG")" = "${expected[$idx]}" ]
  done
}

@test "malformed response diagnostic is private bounded and content-safe" {
  P="$(make_fixture_project critmalformed-diagnostic)"
  printf '%s\n' 'private-prompt-prose' >"$P/.agents/release.md"
  make_stub claude 0 '{"type":"result","result":"private-response-prose secret-filename.ts secret-finding\nTOKENS_HINT|<none>","usage":{"input_tokens":10,"output_tokens":5}}'
  queue_files "$P" s1 1
  fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
  export CRITIC_IDLE_SEC=1 CRITIC_DIFF_MODE=staged
  git -C "$P" add src/f01.ts

  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  DIAG="$P/tmp/critic-malformed-diagnostic-s1"
  [ -f "$DIAG" ]
  [ ! -L "$DIAG" ]
  [ "$(stat -c '%a' "$DIAG" 2>/dev/null || stat -f '%Lp' "$DIAG")" = "600" ]
  [ "$(stat -c '%u' "$DIAG" 2>/dev/null || stat -f '%u' "$DIAG")" = "$(id -u)" ]
  [ "$(stat -c '%h' "$DIAG" 2>/dev/null || stat -f '%l' "$DIAG")" = "1" ]
  jq -e '.schema_version == 1 and .reason == "invalid_line"
    and .sentinel_count == 1 and .invalid_line_count == 1
    and .response_bytes > 0 and (.response_hash | test("^[0-9a-f]{64}$"))
    and .harness == "claude" and .tokens == 15 and .attempt == 1
    and (.generation | test("^[0-9a-f]{64}$"))' "$DIAG" >/dev/null
  EV="$(events_json | jq -c \
    'select(.event == "release.critique.malformed_response")' | tail -1)"
  ! printf '%s\n%s\n' "$EV" "$(cat "$DIAG")" |
    grep -Eq 'private-(prompt|response)-prose|secret-(filename|finding)|src/f01\.ts|stub 01'

  # Unsafe existing artifacts are never reused or replaced.
  chmod 644 "$DIAG"
  fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$DIAG" 2>/dev/null || stat -f '%Lp' "$DIAG")" = "644" ]

  rm -f "$DIAG"
  TRAP="$BATS_TEST_TMPDIR/diagnostic-symlink-trap"
  printf 'do-not-replace\n' >"$TRAP"
  chmod 600 "$TRAP"
  ln -s "$TRAP" "$DIAG"
  fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  [ -L "$DIAG" ]
  [ "$(cat "$TRAP")" = "do-not-replace" ]

  rm -f "$DIAG"
  HARD="$BATS_TEST_TMPDIR/diagnostic-hardlink"
  printf 'do-not-replace\n' >"$HARD"
  chmod 600 "$HARD"
  ln "$HARD" "$DIAG"
  fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  [ "$(stat -c '%h' "$DIAG" 2>/dev/null || stat -f '%l' "$DIAG")" = "2" ]
  [ "$(cat "$HARD")" = "do-not-replace" ]
}

@test "explicit clean sentinel writes validation marker and consumes queue" {
  P="$(make_fixture_project critclean)"
  make_stub claude 0 '{"type":"result","result":"TOKENS_HINT|<none>","usage":{"input_tokens":10,"output_tokens":5}}'
  make_stub claude-note 0
  queue_files "$P" s1 2
  fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
  export CRITIC_IDLE_SEC=1 CRITIC_DIFF_MODE=staged CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"
  git -C "$P" add src/f01.ts src/f02.ts

  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  [ ! -e "$P/tmp/critic-queue-s1" ]
  [ -f "$P/tmp/critic-findings-s1" ]
  [ ! -s "$P/tmp/critic-findings-s1" ]
  [ "$(cat "$P/tmp/critic-valid-response-s1")" = "valid mode=staged" ]
}

@test "canned findings parse to block=1 warn=2 note=1 tokens=1545 and delivery fires" {
  P="$(make_fixture_project critd)"
  make_stub claude 0 "$CANNED_CLAUDE_JSON"
  make_stub claude-note 0
  queue_files "$P" s1 2
  fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
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

@test "outcome lineage: shoulder critique and deposited disposition share one opaque ID" {
  P="$(make_fixture_project critlineage)"
  printf '\n[telemetry]\noutcome_lineage = true\n' >>"$P/.agents/config.toml"
  make_stub claude 0 "$CANNED_CLAUDE_JSON"
  make_stub claude-note 0
  queue_files "$P" s1 2
  fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
  export CRITIC_IDLE_SEC=1 CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"

  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  critique="$(events_json | jq -c 'select(.event=="release.critique")')"
  delivery="$(events_json | jq -c 'select(.event=="release.critique.delivery")')"
  cid="$(jq -r '.critique_id' <<<"$critique")"
  [[ "$cid" =~ ^[0-9a-f]{64}$ ]]
  jq -e --arg id "$cid" \
    '.critique_id==$id and .disposition=="deposited"' <<<"$delivery" >/dev/null
  ! events_json | grep -qE 'PRIVATE_|prompt|message|diff|filename|summary|finding|result'
}

@test "outcome lineage: shoulder delivery records deferred expired and failed dispositions" {
  for disposition in deferred expired failed; do
    P="$(make_fixture_project "crit-$disposition")"
    printf '\n[telemetry]\noutcome_lineage = true\n' >>"$P/.agents/config.toml"
    make_stub claude 0 "$CANNED_CLAUDE_JSON"
    queue_files "$P" s1 1
    fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
    export CRITIC_IDLE_SEC=1
    case "$disposition" in
      deferred)
        make_stub claude-note 3
        export CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"
        run run_watch "$P" --session s1 --once ;;
      expired)
        unset CLAUDE_NOTE_CMD
        run run_watch "$P" --session s1 --once ;;
      failed)
        make_stub claude-note 127
        export CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"
        for _ in 1 2 3; do
          fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
          run run_watch "$P" --session s1 --once
          [ "$status" -eq 0 ]
        done ;;
    esac
    [ "$status" -eq 0 ]
    events_json | jq -s -e --arg disposition "$disposition" '
      any(.[]; .event=="release.critique.delivery" and
        .disposition==$disposition and
        (.critique_id | test("^[0-9a-f]{64}$")))
    ' >/dev/null
    : >"$(events_file)"
  done
}

@test "outcome lineage: critic preserves malformed TOML fallback but rejects malformed telemetry" {
  P="$(make_fixture_project critcfgfallback)"
  printf '[release\n' >"$P/.agents/config.toml"

  run run_watch "$P" --once
  [ "$status" -eq 0 ]
  [ ! -e "$(events_file)" ]

  P="$(make_fixture_project critcfglineage)"
  printf '\n[telemetry]\noutcome_lineage = "yes"\n' \
    >>"$P/.agents/config.toml"

  run run_watch "$P" --once
  [ "$status" -eq 2 ]
  [[ "$output" == *"telemetry.outcome_lineage must be boolean"* ]]
  [ ! -e "$(events_file)" ]
}

# ---------------------------------------------------------------------------
# (e) token budget
# ---------------------------------------------------------------------------

@test "daily token budget reached: skip event, claude never called" {
  P="$(make_fixture_project crite)"
  make_stub claude 0 "$CANNED_CLAUDE_JSON"
  # Pre-seed today's stream with a critique that already blew the budget.
  printf '%s\n' \
    '{"ts":"2026-01-01T00:00:00Z","svc":"crite-release","event":"release.critique","tokens":999999999}' \
    >> "$(events_file)"
  queue_files "$P" s1 2
  fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
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
  fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
  export CRITIC_IDLE_SEC=1 CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"

  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  [ -s "$P/tmp/critic-queue-s1" ]   # intact for retry

  make_stub claude-note 0                     # session freed up
  fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  [ ! -e "$P/tmp/critic-queue-s1" ]  # cleared after delivery
}

@test "claude-note exit 2 (ambiguous target) also keeps the queue" {
  P="$(make_fixture_project critf2)"
  make_stub claude 0 "$CANNED_CLAUDE_JSON"
  make_stub claude-note 2
  queue_files "$P" s1 2
  fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
  export CRITIC_IDLE_SEC=1 CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"

  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  [ -s "$P/tmp/critic-queue-s1" ]
}

@test "no CLAUDE_NOTE_CMD: delivery skipped with a log line, queue cleared" {
  P="$(make_fixture_project critf3)"
  make_stub claude 0 "$CANNED_CLAUDE_JSON"
  queue_files "$P" s1 2
  fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
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
    fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
    run run_watch "$P" --session s1 --once
    [ "$status" -eq 0 ]
    [ -s "$P/tmp/critic-queue-s1" ]        # kept for retry
  done

  fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  [ ! -e "$P/tmp/critic-queue-s1" ]        # 3rd failure: gave up
  [ -s "$P/tmp/critic-findings-s1" ]       # findings preserved on disk
  FAILEV="$(events_json | jq -c 'select(.event=="release.critique.delivery_failed")')"
  [ -n "$FAILEV" ]
  [ "$(jq -r '.rc' <<<"$FAILEV")" = "127" ]
}

@test "identical and distinct entries queued during critique both survive exact-prefix acknowledgement" {
  P="$(make_fixture_project crith)"
  STAMP="$(date +%s)"
  ORIGINAL="src/early.ts $STAMP"
  # The model stub simulates two mid-run captures: one byte-identical to the
  # reviewed line (same file and second), and one distinct. Both are later
  # queue positions and must survive acknowledgement of the reviewed prefix.
  cat > "$SHIM_BIN/claude" <<EOF
#!/bin/bash
printf '%s\n' '$ORIGINAL' 'src/late.ts 9999999999' >> "$P/tmp/critic-queue-s1"
printf '%s' '$CANNED_CLAUDE_JSON'
EOF
  chmod +x "$SHIM_BIN/claude"
  make_stub claude-note 0
  mkdir -p "$P/src"
  printf '// stub\n' > "$P/src/early.ts"
  printf '// stub\n' > "$P/src/late.ts"
  printf '%s\n' "$ORIGINAL" >> "$P/tmp/critic-queue-s1"
  fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
  export CRITIC_IDLE_SEC=1 CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"

  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]
  # delivery succeeded, but the late entry is still queued for the next pass
  [ -s "$P/tmp/critic-queue-s1" ]
  run grep -c '^src/late.ts ' "$P/tmp/critic-queue-s1"
  [ "$output" = "1" ]
  run grep -c '^src/early.ts ' "$P/tmp/critic-queue-s1"
  [ "$output" = "1" ]
}

@test "queue lock serializes exact-prefix consume with identical and distinct appenders" {
  P="$(make_fixture_project crith-lock)"
  Q="$P/tmp/critic-queue-s1"
  SNAP="$P/tmp/critic-snapshot-s1"
  ORIGINAL='src/same.ts 1111111111'
  DISTINCT='src/distinct.ts 2222222222'
  printf '%s\n' "$ORIGINAL" >"$Q"
  cp "$Q" "$SNAP"

  # Hold the shared lock until all three contenders are waiting. Whichever
  # order they acquire after release, the reviewed prefix alone disappears.
  # shellcheck source=agents/release/critic-queue-lib.sh
  . "$QUARTET_ROOT/$QUEUE_LIB"
  cq_queue_lock_acquire "$Q"
  REAL_PYTHON="$(command -v python3)"
  READY_BIN="$BATS_TEST_TMPDIR/contender-ready-bin"
  READY_DIR="$BATS_TEST_TMPDIR/contender-ready"
  mkdir -p "$READY_BIN" "$READY_DIR"
  cat >"$READY_BIN/python3" <<EOF
#!/bin/bash
if [ "\${2:-}" = "outer-lock-create" ] &&
    [ "\${3:-}" = "$Q.lock" ]; then
  : >"$READY_DIR/\$PPID"
fi
exec "$REAL_PYTHON" "\$@"
EOF
  chmod +x "$READY_BIN/python3"

  PATH="$READY_BIN:$PATH" \
    bash -c ". '$QUARTET_ROOT/$QUEUE_LIB'; cq_consume_snapshot_prefix '$Q' '$SNAP'" &
  CONSUMER=$!
  PATH="$READY_BIN:$PATH" \
    bash -c ". '$QUARTET_ROOT/$QUEUE_LIB'; cq_append_line '$Q' '$ORIGINAL'" &
  SAME_WRITER=$!
  PATH="$READY_BIN:$PATH" \
    bash -c ". '$QUARTET_ROOT/$QUEUE_LIB'; cq_append_line '$Q' '$DISTINCT'" &
  DISTINCT_WRITER=$!
  for ((i=0; i<500; i++)); do
    READY_COUNT="$(find "$READY_DIR" -type f | wc -l | tr -d ' ')"
    [ "$READY_COUNT" -eq 3 ] && break
    sleep 0.01
  done
  [ "$READY_COUNT" -eq 3 ]
  cq_queue_lock_release

  wait "$CONSUMER"
  wait "$SAME_WRITER"
  wait "$DISTINCT_WRITER"
  [ "$(grep -cFx "$ORIGINAL" "$Q")" -eq 1 ]
  [ "$(grep -cFx "$DISTINCT" "$Q")" -eq 1 ]
  [ "$(wc -l <"$Q" | tr -d ' ')" -eq 2 ]
  [ ! -e "$Q.lock" ]
}

@test "concurrency teardown releases pause markers and background jobs" {
  PAUSE="$BATS_TEST_TMPDIR/forced-cleanup.pause"
  : >"$PAUSE"
  bash -c "while [ -e '$PAUSE' ]; do sleep 0.01; done" &
  PAUSED_PID=$!
  kill -0 "$PAUSED_PID"

  teardown

  [ ! -e "$PAUSE" ]
  ! kill -0 "$PAUSED_PID" 2>/dev/null
}

@test "queue lock timing values normalize leading zeros as decimal" {
  run env CQ_LOCK_WAIT_STEPS=00000 CQ_REAP_GRACE_SEC=000 \
    bash -c ". '$QUARTET_ROOT/$QUEUE_LIB'; \
      printf '%s %s\\n' \"\$CQ_LOCK_WAIT_STEPS\" \"\$CQ_REAP_GRACE_SEC\""
  [ "$status" -eq 0 ]
  [ "$output" = "200 0" ]

  run env CQ_LOCK_WAIT_STEPS=00099 CQ_REAP_GRACE_SEC=007 \
    bash -c ". '$QUARTET_ROOT/$QUEUE_LIB'; \
      printf '%s %s\\n' \"\$CQ_LOCK_WAIT_STEPS\" \"\$CQ_REAP_GRACE_SEC\""
  [ "$status" -eq 0 ]
  [ "$output" = "99 7" ]

  run env CQ_LOCK_WAIT_STEPS=099 CQ_REAP_GRACE_SEC=099 \
    bash -c ". '$QUARTET_ROOT/$QUEUE_LIB'; \
      printf '%s %s\\n' \"\$CQ_LOCK_WAIT_STEPS\" \"\$CQ_REAP_GRACE_SEC\""
  [ "$status" -eq 0 ]
  [ "$output" = "99 1" ]
}

@test "default queue lock wait fails open within ten seconds" {
  P="$(make_fixture_project critq-default-bound)"
  Q="$P/tmp/critic-queue-s1"
  mkdir "$Q.lock"
  chmod 700 "$Q.lock"

  STARTED_AT="$SECONDS"
  bash -c "printf '%s' \
    '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/bounded-default.ts\"}}' \
    | CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$QUEUE_HOOK'" \
    >"$BATS_TEST_TMPDIR/default-bound.out" \
    2>"$BATS_TEST_TMPDIR/default-bound.err" &
  CAPTURE=$!
  CAPTURE_FINISHED=0
  while [ "$((SECONDS - STARTED_AT))" -lt 10 ]; do
    if ! kill -0 "$CAPTURE" 2>/dev/null; then
      CAPTURE_FINISHED=1
      break
    fi
    sleep 0.01
  done
  if [ "$CAPTURE_FINISHED" -eq 0 ]; then
    kill "$CAPTURE" 2>/dev/null || true
  fi
  wait "$CAPTURE" 2>/dev/null || true
  ELAPSED="$((SECONDS - STARTED_AT))"

  [ "$CAPTURE_FINISHED" -eq 1 ]
  [ "$ELAPSED" -lt 10 ]
  [ ! -e "$Q" ]
  [[ "$(cat "$BATS_TEST_TMPDIR/default-bound.err")" == *"failing open"* ]]
}

@test "queue lock dependencies fail open with a capability diagnostic" {
  P="$(make_fixture_project critq-capability)"
  Q="$P/tmp/critic-queue-s1"
  run bash -c "
    . '$QUARTET_ROOT/$QUEUE_LIB'
    command() {
      if [ \"\${1:-}\" = '-v' ] && [ \"\${2:-}\" = 'python3' ]; then
        return 1
      fi
      builtin command \"\$@\"
    }
    cq_queue_lock_acquire '$Q'
  "

  [ "$status" -ne 0 ]
  [[ "$output" == *"required lock capability unavailable: python3"* ]]
  [ ! -e "$Q.lock" ]
}

@test "process identity is high-resolution, timezone-independent, and ps-free" {
  # shellcheck source=agents/release/critic-queue-lib.sh
  . "$QUARTET_ROOT/$QUEUE_LIB"
  PS_BIN="$BATS_TEST_TMPDIR/no-ps-bin"
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

  UTC_ID="$(TZ=UTC PATH="$PS_BIN:$PATH" _cq_process_identity "$$")"
  LOCAL_ID="$(
    TZ=America/Chicago PATH="$PS_BIN:$PATH" _cq_process_identity "$$"
  )"

  [[ "$UTC_ID" =~ ^[0-9]+-[0-9]+$ ]]
  [ "$LOCAL_ID" = "$UTC_ID" ]
  run python3 - "$QUARTET_ROOT/agents/release/critic-process-identity.py" <<'PY'
import ctypes
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("critic_identity", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(ctypes.sizeof(module.ProcBsdInfo))
PY
  [ "$status" -eq 0 ]
  [ "$output" = "136" ]

  # A process can disappear between kill -0 and identity lookup. That normal
  # race is a quiet non-match, never a Python traceback that poisons the hook.
  run python3 "$QUARTET_ROOT/agents/release/critic-process-identity.py" \
    2147483647
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "a background subshell records its own PID instead of its parent" {
  P="$(make_fixture_project critq-subshell-owner)"
  Q="$P/tmp/critic-queue-s1"
  READY="$BATS_TEST_TMPDIR/subshell-owner.ready"
  HOLD="$BATS_TEST_TMPDIR/subshell-owner.hold"
  LAUNCHED="$BATS_TEST_TMPDIR/subshell-owner.launched"
  RECORDED="$BATS_TEST_TMPDIR/subshell-owner.recorded"
  : >"$HOLD"

  bash -c ". '$QUARTET_ROOT/$QUEUE_LIB'; \
    ( unset BASHPID; cq_queue_lock_acquire '$Q' || exit 1; \
      printf '%s\\n' \"\$CQ_LOCK_PID\" >'$RECORDED'; \
      : >'$READY'; \
      while [ -e '$HOLD' ]; do sleep 0.01; done; \
      cq_queue_lock_release ) & \
    worker=\$!; printf '%s\\n' \"\$worker\" >'$LAUNCHED'; wait \"\$worker\"" &
  DRIVER=$!

  for ((i=0; i<500; i++)); do
    [ -e "$READY" ] && [ -e "$LAUNCHED" ] && break
    sleep 0.01
  done
  [ -e "$READY" ]
  [ "$(cat "$RECORDED")" = "$(cat "$LAUNCHED")" ]
  [ "$(awk '{print $1}' "$Q.lock/owner")" = "$(cat "$LAUNCHED")" ]
  kill -0 "$(cat "$LAUNCHED")"

  rm "$HOLD"
  wait "$DRIVER"
  [ ! -e "$Q.lock" ]
}

@test "queue write failures are diagnosed separately from lock contention" {
  P="$(make_fixture_project critq-write-failure)"
  Q="$P/tmp/critic-queue-s1"
  mkdir "$Q"

  run bash -c "printf '%s' \
    '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/write.ts\"}}' \
    | CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$QUEUE_HOOK'"

  [ "$status" -eq 0 ]
  [[ "$output" == *"could not write the queue file; failing open"* ]]
  [[ "$output" != *"could not acquire the queue lock"* ]]
  [ -d "$Q" ]
  [ ! -e "$Q.lock" ]
}

@test "snapshot and consume propagate lock retirement failures" {
  REAL_MV="$(command -v mv)"
  FAIL_BIN="$BATS_TEST_TMPDIR/release-fail-bin"
  mkdir -p "$FAIL_BIN"
  cat >"$FAIL_BIN/mv" <<EOF
#!/bin/bash
if [[ "\${2:-}" == */.critic-retire.*/item ]]; then
  exit 1
fi
exec "$REAL_MV" "\$@"
EOF
  chmod +x "$FAIL_BIN/mv"

  for ACTION in snapshot consume; do
    P="$(make_fixture_project "critq-release-fail-$ACTION")"
    Q="$P/tmp/critic-queue-s1"
    SNAP="$P/tmp/critic-snapshot-s1"
    printf 'src/a.ts 1111111111\n' >"$Q"
    if [ "$ACTION" = "snapshot" ]; then
      COMMAND="cq_snapshot_queue '$Q' '$SNAP'"
    else
      cp "$Q" "$SNAP"
      COMMAND="cq_consume_snapshot_prefix '$Q' '$SNAP'"
    fi

    run env PATH="$FAIL_BIN:$PATH" bash -c \
      ". '$QUARTET_ROOT/$QUEUE_LIB'; $COMMAND"

    [ "$status" -ne 0 ]
    [ -d "$Q.lock" ]
  done
}

@test "a long-lived owner retains state and retries failed retirement" {
  P="$(make_fixture_project critq-release-retry)"
  Q="$P/tmp/critic-queue-s1"
  REAL_MV="$(command -v mv)"
  FAIL_BIN="$BATS_TEST_TMPDIR/release-retry-bin"
  mkdir -p "$FAIL_BIN"
  cat >"$FAIL_BIN/mv" <<EOF
#!/bin/bash
if [[ "\${2:-}" == */.critic-retire.*/item ]]; then
  exit 1
fi
exec "$REAL_MV" "\$@"
EOF
  chmod +x "$FAIL_BIN/mv"
  # shellcheck source=agents/release/critic-queue-lib.sh
  . "$QUARTET_ROOT/$QUEUE_LIB"
  cq_queue_lock_acquire "$Q"
  HELD_DIR="$CQ_LOCK_DIR"
  HELD_TOKEN="$CQ_LOCK_TOKEN"

  ! PATH="$FAIL_BIN:$PATH" cq_queue_lock_release

  [ "$CQ_LOCK_DIR" = "$HELD_DIR" ]
  [ "$CQ_LOCK_TOKEN" = "$HELD_TOKEN" ]
  [ -d "$Q.lock" ]

  cq_queue_lock_release
  [ -z "$CQ_LOCK_DIR" ]
  [ -z "$CQ_LOCK_TOKEN" ]
  [ ! -e "$Q.lock" ]
}

@test "busy owner coordination never publishes an ownerless lock" {
  P="$(make_fixture_project critq-owner-mutex-busy)"
  Q="$P/tmp/critic-queue-s1"
  MUTEX="$P/tmp/.critic-owner-mutex"
  READY="$BATS_TEST_TMPDIR/owner-mutex.ready"
  PAUSE="$BATS_TEST_TMPDIR/owner-mutex.pause"
  : >"$PAUSE"
  python3 - "$MUTEX" "$READY" "$PAUSE" <<'PY' &
import fcntl
import os
import sys
import time

mutex, ready, pause = sys.argv[1:]
fd = os.open(mutex, os.O_RDWR | os.O_CREAT, 0o600)
os.fchmod(fd, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
with open(ready, "w", encoding="ascii"):
    pass
while os.path.exists(pause):
    time.sleep(0.01)
os.close(fd)
PY
  MUTEX_HOLDER=$!
  for ((i=0; i<200; i++)); do
    [ -e "$READY" ] && break
    sleep 0.01
  done
  [ -e "$READY" ]

  bash -c "printf '%s' \
    '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/mutex.ts\"}}' \
    | CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$QUEUE_HOOK'" &
  CAPTURE=$!
  for ((i=0; i<50; i++)); do
    kill -0 "$CAPTURE" 2>/dev/null || break
    [ ! -e "$Q.lock" ]
    sleep 0.01
  done
  kill -0 "$CAPTURE" 2>/dev/null
  [ ! -e "$Q.lock" ]

  rm "$PAUSE"
  wait "$MUTEX_HOLDER"
  wait "$CAPTURE"
  [ "$(grep -cE '^src/mutex\.ts [0-9]+$' "$Q")" -eq 1 ]
  [ ! -e "$Q.lock" ]
}

@test "coordination state stays bounded across unique session queues" {
  P="$(make_fixture_project critq-bounded-mutex-state)"
  for SESSION_NUMBER in $(seq 1 20); do
    run bash -c "printf '%s' \
      '{\"session_id\":\"unique-$SESSION_NUMBER\",\"tool_input\":{\"file_path\":\"src/$SESSION_NUMBER.ts\"}}' \
      | CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$QUEUE_HOOK'"
    [ "$status" -eq 0 ]
  done

  [ "$(find "$P/tmp" -maxdepth 1 -type f \
      -name '.critic-*-mutex' | wc -l)" -eq 1 ]
  [ -f "$P/tmp/.critic-owner-mutex" ]
}

@test "outer and recovery lock directories are private from first publication" {
  P="$(make_fixture_project critq-private-outer)"
  Q="$P/tmp/critic-queue-s1"
  OUTER_MODE="$BATS_TEST_TMPDIR/outer.mode"
  CLAIM_MODE="$BATS_TEST_TMPDIR/claim.mode"
  OUTER_PAUSE="$BATS_TEST_TMPDIR/private-outer.pause"
  OUTER_LOG="$BATS_TEST_TMPDIR/private-outer.log"
  : >"$OUTER_PAUSE"
  bash -c "umask 000; printf '%s' \
    '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/private.ts\"}}' \
    | CQ_QUEUE_TEST_OUTER_CREATE_PAUSE='$OUTER_PAUSE' \
      CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$QUEUE_HOOK'" \
    >"$BATS_TEST_TMPDIR/private-outer.out" 2>"$OUTER_LOG" &
  OUTER_CAPTURE=$!
  for ((i=0; i<500; i++)); do
    grep -qFx 'critic-queue-test:outer-created' "$OUTER_LOG" 2>/dev/null &&
      break
    sleep 0.01
  done
  grep -qFx 'critic-queue-test:outer-created' "$OUTER_LOG"
  (stat -c '%a' "$Q.lock" 2>/dev/null ||
    stat -f '%Lp' "$Q.lock") >"$OUTER_MODE"
  [ "$(cat "$OUTER_MODE")" = "700" ]
  rm "$OUTER_PAUSE"
  wait "$OUTER_CAPTURE"

  P="$(make_fixture_project critq-private-claim)"
  Q="$P/tmp/critic-queue-s1"
  mkdir "$Q.lock"
  chmod 700 "$Q.lock"
  printf '%s %s %s\n' 2147483647 stale-generation dead-process \
    >"$Q.lock/owner"
  chmod 600 "$Q.lock/owner"
  CLAIM_PAUSE="$BATS_TEST_TMPDIR/private-claim.pause"
  CLAIM_LOG="$BATS_TEST_TMPDIR/private-claim.log"
  : >"$CLAIM_PAUSE"
  bash -c "umask 000; printf '%s' \
    '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/private-claim.ts\"}}' \
    | CQ_QUEUE_TEST_REAP_CLAIM_PAUSE='$CLAIM_PAUSE' \
      CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$QUEUE_HOOK'" \
    >"$BATS_TEST_TMPDIR/private-claim.out" 2>"$CLAIM_LOG" &
  CLAIM_CAPTURE=$!
  for ((i=0; i<500; i++)); do
    grep -qFx 'critic-queue-test:claim-ready' "$CLAIM_LOG" 2>/dev/null &&
      break
    sleep 0.01
  done
  grep -qFx 'critic-queue-test:claim-ready' "$CLAIM_LOG"
  (stat -c '%a' "$Q.lock/.reap" 2>/dev/null ||
    stat -f '%Lp' "$Q.lock/.reap") >"$CLAIM_MODE"
  [ "$(cat "$CLAIM_MODE")" = "700" ]
  rm "$CLAIM_PAUSE"
  wait "$CLAIM_CAPTURE"
  [ "$(grep -cE '^src/private-claim\.ts [0-9]+$' "$Q")" -eq 1 ]
  [ ! -e "$Q.lock" ]
}

@test "outer owner mode is exact even under a restrictive inherited umask" {
  P="$(make_fixture_project critq-private-owner-mode)"
  Q="$P/tmp/critic-queue-s1"
  : >"$Q"
  chmod 600 "$Q"

  run bash -c "umask 777; printf '%s' \
    '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/owner-mode.ts\"}}' \
    | CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$QUEUE_HOOK'"

  [ "$status" -eq 0 ]
  [ "$(grep -cE '^src/owner-mode\.ts [0-9]+$' "$Q")" -eq 1 ]
  [ ! -e "$Q.lock" ]
}

@test "unsafe outer lock state is never traversed or recursively deleted" {
  P="$(make_fixture_project critq-unsafe-outer)"
  Q="$P/tmp/critic-queue-s1"
  mkdir "$Q.lock"
  chmod 755 "$Q.lock"
  printf 'unrelated fixture content\n' >"$Q.lock/keep"
  mkdir "$Q.lock/.reap"
  chmod 700 "$Q.lock/.reap"
  printf '%s %s %s\n' 2147483647 stale-reaper dead-process \
    >"$Q.lock/.reap/owner"
  chmod 600 "$Q.lock/.reap/owner"
  KEEP_BYTES="$(od -An -tx1 "$Q.lock/keep")"

  run bash -c "printf '%s' \
    '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/unsafe.ts\"}}' \
    | CQ_LOCK_WAIT_STEPS=2 CLAUDE_PROJECT_DIR='$P' \
      bash '$QUARTET_ROOT/$QUEUE_HOOK'"

  [ "$status" -eq 0 ]
  [[ "$output" == *"could not acquire the queue lock; failing open"* ]]
  [ -d "$Q.lock" ]
  [ "$(stat -c '%a' "$Q.lock" 2>/dev/null ||
      stat -f '%Lp' "$Q.lock")" = "755" ]
  [ "$(od -An -tx1 "$Q.lock/keep")" = "$KEEP_BYTES" ]
  [ -f "$Q.lock/.reap/owner" ]
  [ ! -e "$Q" ]
}

@test "private stale lock with unexpected contents is preserved intact" {
  P="$(make_fixture_project critq-private-poison)"
  Q="$P/tmp/critic-queue-s1"
  mkdir "$Q.lock"
  chmod 700 "$Q.lock"
  printf '%s %s %s\n' 2147483647 stale-generation dead-process \
    >"$Q.lock/owner"
  chmod 600 "$Q.lock/owner"
  printf 'unrelated lock collision bytes\n' >"$Q.lock/keep"
  KEEP_BYTES="$(od -An -tx1 "$Q.lock/keep")"

  run bash -c "printf '%s' \
    '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/poison.ts\"}}' \
    | CQ_LOCK_WAIT_STEPS=2 CQ_REAP_GRACE_SEC=0 \
      CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$QUEUE_HOOK'"

  [ "$status" -eq 0 ]
  [[ "$output" == *"could not acquire the queue lock; failing open"* ]]
  [ -d "$Q.lock" ]
  [ "$(od -An -tx1 "$Q.lock/keep")" = "$KEEP_BYTES" ]
  [ -f "$Q.lock/owner" ]
  [ ! -e "$Q.lock/.reap" ]
  [ ! -e "$Q" ]
}

@test "directory retirement cannot nest into and delete a prior destination" {
  SOURCE="$BATS_TEST_TMPDIR/retire-source"
  CONTAINER="$BATS_TEST_TMPDIR/prior-retire-container"
  MKTEMP_BIN="$BATS_TEST_TMPDIR/retire-mktemp-bin"
  mkdir -p "$SOURCE" "$CONTAINER/item" "$MKTEMP_BIN"
  chmod 700 "$SOURCE"
  printf '1 owner-token process-identity\n' >"$SOURCE/owner"
  chmod 600 "$SOURCE/owner"
  printf 'unrelated bytes\n' >"$CONTAINER/item/unrelated"
  chmod 700 "$CONTAINER"
  cat >"$MKTEMP_BIN/mktemp" <<EOF
#!/bin/bash
printf '%s\\n' "$CONTAINER"
EOF
  chmod +x "$MKTEMP_BIN/mktemp"

  run env PATH="$MKTEMP_BIN:$PATH" bash -c \
    ". '$QUARTET_ROOT/$QUEUE_LIB'; _cq_retire_directory '$SOURCE' owner"

  [ "$status" -ne 0 ]
  [ "$(cat "$SOURCE/owner")" = "1 owner-token process-identity" ]
  [ "$(cat "$CONTAINER/item/unrelated")" = "unrelated bytes" ]

  run bash -c \
    ". '$QUARTET_ROOT/$QUEUE_LIB'; _cq_retire_directory '$SOURCE' owner"
  [ "$status" -eq 0 ]
  [ ! -e "$SOURCE" ]
  [ "$(cat "$CONTAINER/item/unrelated")" = "unrelated bytes" ]
}

@test "capture waits beyond one second for a live queue lock and does not lose the edit" {
  P="$(make_fixture_project critq-lock-wait)"
  Q="$P/tmp/critic-queue-s1"
  # shellcheck source=agents/release/critic-queue-lib.sh
  . "$QUARTET_ROOT/$QUEUE_LIB"
  cq_queue_lock_acquire "$Q"

  bash -c "printf '%s' \
    '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/waited.ts\"}}' \
    | CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$QUEUE_HOOK'" &
  WRITER=$!
  sleep 1.25
  WRITER_WAS_WAITING=0
  kill -0 "$WRITER" 2>/dev/null && WRITER_WAS_WAITING=1
  cq_queue_lock_release
  wait "$WRITER"

  [ "$WRITER_WAS_WAITING" -eq 1 ]
  [ "$(grep -cE '^src/waited\.ts [0-9]+$' "$Q")" -eq 1 ]
  [ ! -e "$Q.lock" ]
}

@test "a queue lock whose PID was reused is recovered instead of dropping the edit" {
  P="$(make_fixture_project critq-pid-reuse)"
  Q="$P/tmp/critic-queue-s1"
  mkdir "$Q.lock"
  chmod 700 "$Q.lock"
  printf '%s %s %s\n' "$$" stale-owner definitely-not-this-process \
    >"$Q.lock/owner"
  chmod 600 "$Q.lock/owner"

  run bash -c "printf '%s' \
    '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/reused.ts\"}}' \
    | CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$QUEUE_HOOK'"

  [ "$status" -eq 0 ]
  [ "$(grep -cE '^src/reused\.ts [0-9]+$' "$Q")" -eq 1 ]
  [ ! -e "$Q.lock" ]
}

@test "stale incomplete outer queue locks are reclaimed without following poison" {
  for KIND in ownerless malformed fifo owner-symlink future-ownerless; do
    P="$(make_fixture_project "critq-outer-poison-$KIND")"
    Q="$P/tmp/critic-queue-s1"
    mkdir "$Q.lock"
    chmod 700 "$Q.lock"
    case "$KIND" in
      malformed)
        printf 'partial owner publication\n' >"$Q.lock/owner"
        chmod 600 "$Q.lock/owner"
        ;;
      fifo)
        mkfifo "$Q.lock/owner"
        chmod 600 "$Q.lock/owner"
        ;;
      owner-symlink)
        OWNER_TARGET="$BATS_TEST_TMPDIR/outer-owner-target-$KIND"
        printf 'external owner target must stay byte exact\n' >"$OWNER_TARGET"
        chmod 640 "$OWNER_TARGET"
        TARGET_CONTENT_BEFORE="$(od -An -tx1 "$OWNER_TARGET")"
        TARGET_MODE_BEFORE="$(
          stat -c '%a' "$OWNER_TARGET" 2>/dev/null ||
            stat -f '%Lp' "$OWNER_TARGET"
        )"
        ln -s "$OWNER_TARGET" "$Q.lock/owner"
        ;;
    esac
    if [ "$KIND" = "future-ownerless" ]; then
      python3 - "$Q.lock" <<'PY'
import os
import sys
import time

future = time.time() + 86400
os.utime(sys.argv[1], (future, future))
PY
    else
      fixture_set_mtime_ago 120 "$Q.lock"
    fi

    bash -c "printf '%s' \
      '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/$KIND.ts\"}}' \
      | CQ_LOCK_WAIT_STEPS=4 CLAUDE_PROJECT_DIR='$P' \
        bash '$QUARTET_ROOT/$QUEUE_HOOK'" \
      >"$BATS_TEST_TMPDIR/$KIND.out" \
      2>"$BATS_TEST_TMPDIR/$KIND.err" &
    CAPTURE=$!
    CAPTURE_FINISHED=0
    CAPTURE_STARTED_AT="$SECONDS"
    while [ "$((SECONDS - CAPTURE_STARTED_AT))" -lt 10 ]; do
      if ! kill -0 "$CAPTURE" 2>/dev/null; then
        CAPTURE_FINISHED=1
        break
      fi
      sleep 0.01
    done
    CAPTURE_ELAPSED="$((SECONDS - CAPTURE_STARTED_AT))"
    if [ "$CAPTURE_FINISHED" -eq 0 ]; then
      if [ "$KIND" = "fifo" ]; then
        # Unblock the pre-fix reader so a failed assertion leaves no writer.
        printf 'poison\n' >"$Q.lock/owner" &
        FIFO_UNBLOCKER=$!
      fi
      kill "$CAPTURE" 2>/dev/null || true
    fi
    wait "$CAPTURE" 2>/dev/null || true
    if [ "${FIFO_UNBLOCKER:-}" ]; then
      kill "$FIFO_UNBLOCKER" 2>/dev/null || true
      wait "$FIFO_UNBLOCKER" 2>/dev/null || true
      unset FIFO_UNBLOCKER
    fi

    [ "$CAPTURE_FINISHED" -eq 1 ]
    [ "$CAPTURE_ELAPSED" -lt 10 ]
    [ "$(grep -cE "^src/$KIND\\.ts [0-9]+$" "$Q" || true)" -eq 1 ]
    [ ! -e "$Q.lock" ]
    if [ "$KIND" = "owner-symlink" ]; then
      [ "$(od -An -tx1 "$OWNER_TARGET")" = "$TARGET_CONTENT_BEFORE" ]
      TARGET_MODE_AFTER="$(
        stat -c '%a' "$OWNER_TARGET" 2>/dev/null ||
          stat -f '%Lp' "$OWNER_TARGET"
      )"
      [ "$TARGET_MODE_AFTER" = "$TARGET_MODE_BEFORE" ]
    fi
  done
}

@test "stale recovery cannot rename a live successor after validating the old owner" {
  P="$(make_fixture_project critq-generation-race)"
  Q="$P/tmp/critic-queue-s1"
  mkdir "$Q.lock"
  chmod 700 "$Q.lock"
  printf '%s %s %s\n' 2147483647 stale-generation dead-process \
    >"$Q.lock/owner"
  chmod 600 "$Q.lock/owner"

  # Pause only the first reaper at the exact old-owner-check -> rename
  # boundary. There is no production sleep/test hook: PATH intercepts the
  # portable mv used by recovery.
  REAL_MV="$(command -v mv)"
  REAL_PYTHON="$(command -v python3)"
  RACE_BIN="$BATS_TEST_TMPDIR/race-bin"
  SECOND_BIN="$BATS_TEST_TMPDIR/second-bin"
  READY="$BATS_TEST_TMPDIR/reaper.ready"
  PAUSE="$BATS_TEST_TMPDIR/reaper.pause"
  SECOND_ATTEMPTED="$BATS_TEST_TMPDIR/second-attempted"
  mkdir -p "$RACE_BIN" "$SECOND_BIN"
  : >"$PAUSE"
  cat >"$RACE_BIN/mv" <<EOF
#!/bin/bash
if [ "\${1:-}" = "$Q.lock" ] &&
    [[ "\${2:-}" == "$P/tmp/.critic-retire."*/item ]] &&
    [ ! -e "$READY" ]; then
  : >"$READY"
  while [ -e "$PAUSE" ]; do sleep 0.01; done
fi
exec "$REAL_MV" "\$@"
EOF
  chmod +x "$RACE_BIN/mv"
  cat >"$SECOND_BIN/python3" <<EOF
#!/bin/bash
if [ "\${2:-}" = "outer-lock-create" ] &&
    [ "\${3:-}" = "$Q.lock" ]; then
  : >"$SECOND_ATTEMPTED"
fi
exec "$REAL_PYTHON" "\$@"
EOF
  chmod +x "$SECOND_BIN/python3"

  bash -c "printf '%s' \
    '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/first.ts\"}}' \
    | PATH='$RACE_BIN':\"\$PATH\" CLAUDE_PROJECT_DIR='$P' \
      bash '$QUARTET_ROOT/$QUEUE_HOOK'" \
    >"$BATS_TEST_TMPDIR/first.out" 2>"$BATS_TEST_TMPDIR/first.err" &
  FIRST_WRITER=$!
  for ((i=0; i<200; i++)); do
    [ -e "$READY" ] && break
    sleep 0.01
  done
  [ -e "$READY" ]

  # A second legitimate actor attempts the stale handoff. Without a
  # generation claim it can reap the old lock and finish, allowing a live
  # successor to occupy the same path before the paused rename resumes.
  bash -c "printf '%s' \
    '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/second.ts\"}}' \
    | PATH='$SECOND_BIN':\"\$PATH\" CLAUDE_PROJECT_DIR='$P' \
      bash '$QUARTET_ROOT/$QUEUE_HOOK'" \
    >"$BATS_TEST_TMPDIR/second.out" 2>"$BATS_TEST_TMPDIR/second.err" &
  SECOND_WRITER=$!
  SECOND_FINISHED=0
  for ((i=0; i<500; i++)); do
    [ -e "$SECOND_ATTEMPTED" ] && break
    sleep 0.01
  done
  [ -e "$SECOND_ATTEMPTED" ]
  for ((i=0; i<100; i++)); do
    if ! kill -0 "$SECOND_WRITER" 2>/dev/null; then
      SECOND_FINISHED=1
      break
    fi
    sleep 0.01
  done

  # The live first reaper's in-generation claim must visibly serialize the
  # second contender. This assertion cannot silently become vacuous on a slow
  # CI worker: the second writer must still be waiting at the held boundary.
  [ "$SECOND_FINISHED" -eq 0 ]

  rm "$PAUSE"
  wait "$FIRST_WRITER"
  wait "$SECOND_WRITER"
  FIRST_COUNT="$(grep -cE '^src/first\.ts [0-9]+$' "$Q" || true)"
  SECOND_COUNT="$(grep -cE '^src/second\.ts [0-9]+$' "$Q" || true)"
  if [ "$FIRST_COUNT" -ne 1 ] || [ "$SECOND_COUNT" -ne 1 ]; then
    cat "$BATS_TEST_TMPDIR/first.err" "$BATS_TEST_TMPDIR/second.err" >&2
  fi
  [ "$FIRST_COUNT" -eq 1 ]
  [ "$SECOND_COUNT" -eq 1 ]
  [ ! -e "$Q.lock" ]
}

@test "outer owner publication cannot overwrite a reused lock pathname" {
  P="$(make_fixture_project critq-publish-reap-race)"
  Q="$P/tmp/critic-queue-s1"
  # shellcheck source=agents/release/critic-queue-lib.sh
  . "$QUARTET_ROOT/$QUEUE_LIB"
  SUCCESSOR_IDENTITY="$(_cq_process_identity "$$")"
  SUCCESSOR_OWNER="$$ successor-token $SUCCESSOR_IDENTITY"
  REAL_PYTHON="$(command -v python3)"
  PUBLISH_BIN="$BATS_TEST_TMPDIR/publish-bin"
  PUBLISH_READY="$BATS_TEST_TMPDIR/publisher.ready"
  PUBLISH_PAUSE="$BATS_TEST_TMPDIR/publisher.pause"
  PUBLISH_ATTEMPTED="$BATS_TEST_TMPDIR/publisher.attempted"
  OBSERVE_PAUSE="$BATS_TEST_TMPDIR/publisher.observe"
  PUBLISH_LOG="$BATS_TEST_TMPDIR/publisher.log"
  OLD_LOCK="$Q.lock.retired-by-test"
  SUCCESSOR_LOCK="$Q.lock.successor-by-test"
  mkdir -p "$PUBLISH_BIN"
  : >"$PUBLISH_PAUSE"
  : >"$OBSERVE_PAUSE"

  # Freeze the original creator after it snapshots the directory generation.
  # The fixed path pauses again after its inode-pinned publisher returns; the
  # vulnerable path pauses after its post-write ownership check.
  cat >"$PUBLISH_BIN/python3" <<EOF
#!/bin/bash
if [ "\${2:-}" = "$Q.lock" ] && [ "\${3:-}" = "generation" ] &&
    [ ! -e "$PUBLISH_READY" ]; then
  OUTPUT="\$("$REAL_PYTHON" "\$@")"
  RC=\$?
  : >"$PUBLISH_READY"
  while [ -e "$PUBLISH_PAUSE" ]; do sleep 0.01; done
  printf '%s\\n' "\$OUTPUT"
  exit \$RC
fi
if { [ "\${2:-}" = "outer-owner-publish" ] ||
     [ "\${3:-}" = "owned" ]; } && [ -e "$PUBLISH_READY" ]; then
  "$REAL_PYTHON" "\$@"
  RC=\$?
  : >"$PUBLISH_ATTEMPTED"
  while [ -e "$OBSERVE_PAUSE" ]; do sleep 0.01; done
  exit \$RC
fi
exec "$REAL_PYTHON" "\$@"
EOF
  chmod +x "$PUBLISH_BIN/python3"

  bash -c "printf '%s' \
    '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/publisher.ts\"}}' \
    | PATH='$PUBLISH_BIN':\"\$PATH\" CLAUDE_PROJECT_DIR='$P' \
      CQ_QUEUE_TEST_OUTER_CREATE_PAUSE='$PUBLISH_PAUSE' \
      CQ_QUEUE_TEST_OUTER_CREATE_OBSERVE_PAUSE='$OBSERVE_PAUSE' \
      bash '$QUARTET_ROOT/$QUEUE_HOOK'" \
    >"$BATS_TEST_TMPDIR/publisher.out" 2>"$PUBLISH_LOG" &
  PUBLISHER=$!
  for ((i=0; i<500; i++)); do
    if [ -e "$PUBLISH_READY" ] ||
        grep -qFx 'critic-queue-test:outer-created' \
          "$PUBLISH_LOG" 2>/dev/null; then
      break
    fi
    sleep 0.01
  done
  [ -e "$PUBLISH_READY" ] ||
    grep -qFx 'critic-queue-test:outer-created' "$PUBLISH_LOG"

  # Complete the stale-directory handoff before the creator resumes, then
  # reuse the exact lock pathname with a live successor owner.
  mv "$Q.lock" "$OLD_LOCK"
  (umask 077; mkdir "$Q.lock")
  printf '%s\n' "$SUCCESSOR_OWNER" >"$Q.lock/owner"
  chmod 600 "$Q.lock/owner"
  SUCCESSOR_BYTES="$(od -An -tx1 "$Q.lock/owner")"
  SUCCESSOR_MODE="$(
    stat -c '%a' "$Q.lock/owner" 2>/dev/null ||
      stat -f '%Lp' "$Q.lock/owner"
  )"
  rm "$PUBLISH_PAUSE"
  for ((i=0; i<500; i++)); do
    if [ -e "$PUBLISH_ATTEMPTED" ] ||
        grep -qFx 'critic-queue-test:outer-attempted' \
          "$PUBLISH_LOG" 2>/dev/null; then
      break
    fi
    sleep 0.01
  done
  [ -e "$PUBLISH_ATTEMPTED" ] ||
    grep -qFx 'critic-queue-test:outer-attempted' "$PUBLISH_LOG"
  [ "$(od -An -tx1 "$Q.lock/owner")" = "$SUCCESSOR_BYTES" ]
  [ "$(stat -c '%a' "$Q.lock/owner" 2>/dev/null ||
      stat -f '%Lp' "$Q.lock/owner")" = "$SUCCESSOR_MODE" ]

  # Retire only the exact fixture generations, then let the original creator
  # retry normally and append its edit under a fresh lock.
  mv "$Q.lock" "$SUCCESSOR_LOCK"
  rm -f "$SUCCESSOR_LOCK/owner"
  rmdir "$SUCCESSOR_LOCK"
  rm -f "$OLD_LOCK/owner"
  rmdir "$OLD_LOCK"
  rm "$OBSERVE_PAUSE"
  wait "$PUBLISHER"

  [ "$(grep -cE '^src/publisher\.ts [0-9]+$' "$Q")" -eq 1 ]
  [ ! -e "$Q.lock" ]
}

@test "a delayed reaper cannot claim after a live owner seals the generation" {
  P="$(make_fixture_project critq-owner-claim-handoff)"
  Q="$P/tmp/critic-queue-s1"
  REAL_PYTHON="$(command -v python3)"
  PUBLISH_BIN="$BATS_TEST_TMPDIR/owner-handoff-publish-bin"
  REAP_BIN="$BATS_TEST_TMPDIR/owner-handoff-reap-bin"
  PUBLISH_READY="$BATS_TEST_TMPDIR/owner-handoff-publish.ready"
  PUBLISH_PAUSE="$BATS_TEST_TMPDIR/owner-handoff-publish.pause"
  OWNER_ACQUIRED="$BATS_TEST_TMPDIR/owner-handoff.acquired"
  OWNER_HOLD="$BATS_TEST_TMPDIR/owner-handoff.pause"
  REAP_READY="$BATS_TEST_TMPDIR/owner-handoff-reaper.ready"
  REAP_PAUSE="$BATS_TEST_TMPDIR/owner-handoff-reaper.pause"
  REAP_ATTEMPTED="$BATS_TEST_TMPDIR/owner-handoff-reaper.attempted"
  REAP_ACQUIRED="$BATS_TEST_TMPDIR/owner-handoff-reaper.acquired"
  CLAIM_PAUSE="$BATS_TEST_TMPDIR/owner-handoff-claim.pause"
  PUBLISH_LOG="$BATS_TEST_TMPDIR/owner-handoff-publisher.log"
  REAP_LOG="$BATS_TEST_TMPDIR/owner-handoff-reaper.log"
  mkdir -p "$PUBLISH_BIN" "$REAP_BIN"
  : >"$PUBLISH_PAUSE"
  : >"$OWNER_HOLD"
  : >"$REAP_PAUSE"
  : >"$CLAIM_PAUSE"

  cat >"$PUBLISH_BIN/python3" <<EOF
#!/bin/bash
if [ "\${2:-}" = "$Q.lock" ] && [ "\${3:-}" = "generation" ] &&
    [ ! -e "$PUBLISH_READY" ]; then
  OUTPUT="\$("$REAL_PYTHON" "\$@")"
  RC=\$?
  : >"$PUBLISH_READY"
  while [ -e "$PUBLISH_PAUSE" ]; do sleep 0.01; done
  printf '%s\\n' "\$OUTPUT"
  exit \$RC
fi
exec "$REAL_PYTHON" "\$@"
EOF
  cat >"$REAP_BIN/python3" <<EOF
#!/bin/bash
if [ "\${2:-}" = "claim-publish" ] && [ ! -e "$REAP_READY" ]; then
  : >"$REAP_READY"
  while [ -e "$REAP_PAUSE" ]; do sleep 0.01; done
  "$REAL_PYTHON" "\$@"
  RC=\$?
  : >"$REAP_ATTEMPTED"
  exit \$RC
fi
exec "$REAL_PYTHON" "\$@"
EOF
  chmod +x "$PUBLISH_BIN/python3" "$REAP_BIN/python3"

  PATH="$PUBLISH_BIN:$PATH" \
    CQ_QUEUE_TEST_OUTER_CREATE_PAUSE="$PUBLISH_PAUSE" \
    bash -c \
    ". '$QUARTET_ROOT/$QUEUE_LIB'; \
      cq_queue_lock_acquire '$Q' || exit 1; \
      : >'$OWNER_ACQUIRED'; \
      while [ -e '$OWNER_HOLD' ]; do sleep 0.01; done; \
      cq_queue_lock_release" \
    >"$BATS_TEST_TMPDIR/owner-handoff-publisher.out" 2>"$PUBLISH_LOG" &
  OWNER=$!
  READY_STARTED_AT="$SECONDS"
  while [ "$((SECONDS - READY_STARTED_AT))" -lt 10 ]; do
    if [ -e "$PUBLISH_READY" ] ||
        grep -qFx 'critic-queue-test:outer-created' \
          "$PUBLISH_LOG" 2>/dev/null; then
      break
    fi
    sleep 0.01
  done
  [ -e "$PUBLISH_READY" ] ||
    grep -qFx 'critic-queue-test:outer-created' "$PUBLISH_LOG"
  fixture_set_mtime_ago 120 "$Q.lock"

  PATH="$REAP_BIN:$PATH" \
    CQ_QUEUE_TEST_REAP_CLAIM_PAUSE="$CLAIM_PAUSE" \
    bash -c ". '$QUARTET_ROOT/$QUEUE_LIB'; \
      cq_queue_lock_acquire '$Q' || exit 1; \
      : >'$REAP_ACQUIRED'; cq_queue_lock_release" \
    >"$BATS_TEST_TMPDIR/owner-handoff-reaper.out" 2>"$REAP_LOG" &
  REAPER=$!
  READY_STARTED_AT="$SECONDS"
  while [ "$((SECONDS - READY_STARTED_AT))" -lt 10 ]; do
    [ -e "$REAP_READY" ] && break
    sleep 0.01
  done
  [ -e "$REAP_READY" ]

  rm "$PUBLISH_PAUSE"
  READY_STARTED_AT="$SECONDS"
  while [ "$((SECONDS - READY_STARTED_AT))" -lt 10 ]; do
    [ -e "$OWNER_ACQUIRED" ] && break
    sleep 0.01
  done
  [ -e "$OWNER_ACQUIRED" ]

  rm "$REAP_PAUSE"
  READY_STARTED_AT="$SECONDS"
  while [ "$((SECONDS - READY_STARTED_AT))" -lt 10 ]; do
    if [ -e "$REAP_ATTEMPTED" ] ||
        grep -qFx 'critic-queue-test:claim-ready' "$REAP_LOG" 2>/dev/null; then
      break
    fi
    sleep 0.01
  done
  [ -e "$REAP_ATTEMPTED" ]
  ! grep -qFx 'critic-queue-test:claim-ready' "$REAP_LOG" 2>/dev/null
  [ ! -e "$Q.lock/.reap" ] && [ ! -L "$Q.lock/.reap" ]

  rm "$OWNER_HOLD" "$CLAIM_PAUSE"
  wait "$OWNER"
  wait "$REAPER"
  [ -e "$REAP_ACQUIRED" ]
  [ ! -e "$Q.lock" ]
}

@test "a retired claim cannot overwrite the owner of a reused recovery marker" {
  P="$(make_fixture_project critq-claim-reuse-race)"
  Q="$P/tmp/critic-queue-s1"
  mkdir "$Q.lock"
  chmod 700 "$Q.lock"
  printf '%s %s %s\n' 2147483647 stale-generation dead-process \
    >"$Q.lock/owner"
  chmod 600 "$Q.lock/owner"

  REAL_CHMOD="$(command -v chmod)"
  REAL_PYTHON="$(command -v python3)"
  FIRST_BIN="$BATS_TEST_TMPDIR/first-claim-bin"
  FIRST_READY="$BATS_TEST_TMPDIR/first-claim.ready"
  FIRST_PAUSE="$BATS_TEST_TMPDIR/first-claim.pause"
  FIRST_ATTEMPTED="$BATS_TEST_TMPDIR/first-claim.attempted"
  OBSERVE_PAUSE="$BATS_TEST_TMPDIR/first-claim.observe"
  FIRST_LOG="$BATS_TEST_TMPDIR/first-claim.log"
  mkdir -p "$FIRST_BIN"
  : >"$FIRST_PAUSE"
  : >"$OBSERVE_PAUSE"

  # The chmod seam catches the vulnerable implementation before its truncating
  # owner write. The Python seam catches the hardened publisher after it has
  # captured the old generation but before it opens the pinned claim dirfd.
  cat >"$FIRST_BIN/chmod" <<EOF
#!/bin/bash
if [ "\${1:-}" = "700" ] && [ "\${2:-}" = "$Q.lock/.reap" ]; then
  "$REAL_CHMOD" "\$@"
  : >"$FIRST_READY"
  while [ -e "$FIRST_PAUSE" ]; do sleep 0.01; done
  exit 0
fi
exec "$REAL_CHMOD" "\$@"
EOF
  cat >"$FIRST_BIN/python3" <<EOF
#!/bin/bash
if [ "\${3:-}" = "post" ] && [ -e "$FIRST_READY" ]; then
  "$REAL_PYTHON" "\$@"
  RC=\$?
  : >"$FIRST_ATTEMPTED"
  while [ -e "$OBSERVE_PAUSE" ]; do sleep 0.01; done
  exit \$RC
fi
exec "$REAL_PYTHON" "\$@"
EOF
  chmod +x "$FIRST_BIN/chmod" "$FIRST_BIN/python3"

  bash -c "printf '%s' \
    '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/first-claim.ts\"}}' \
    | PATH='$FIRST_BIN':\"\$PATH\" CQ_REAP_GRACE_SEC=0 \
      CQ_QUEUE_TEST_REAP_CLAIM_PAUSE='$FIRST_PAUSE' \
      CQ_QUEUE_TEST_REAP_CLAIM_OBSERVE_PAUSE='$OBSERVE_PAUSE' \
      CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$QUEUE_HOOK'" \
    >"$BATS_TEST_TMPDIR/first-claim.out" 2>"$FIRST_LOG" &
  FIRST=$!
  for ((i=0; i<500; i++)); do
    if [ -e "$FIRST_READY" ] ||
        grep -qFx 'critic-queue-test:claim-ready' "$FIRST_LOG" 2>/dev/null; then
      break
    fi
    sleep 0.01
  done
  [ -e "$FIRST_READY" ] ||
    grep -qFx 'critic-queue-test:claim-ready' "$FIRST_LOG"

  # Retire the paused claimant and reuse the exact marker pathname with an
  # ownerless successor generation.
  run bash -c ". '$QUARTET_ROOT/$QUEUE_LIB'; \
    CQ_REAP_GRACE_SEC=0; _cq_reap_orphan_recover '$Q.lock'"
  [ "$status" -eq 0 ]
  (umask 077; mkdir "$Q.lock/.reap")
  SUCCESSOR_GENERATION="$(
    python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(f"{s.st_dev}:{s.st_ino}")' \
      "$Q.lock/.reap"
  )"

  rm "$FIRST_PAUSE"
  for ((i=0; i<500; i++)); do
    if [ -e "$FIRST_ATTEMPTED" ] ||
        grep -qFx 'critic-queue-test:claim-attempted' \
          "$FIRST_LOG" 2>/dev/null; then
      break
    fi
    sleep 0.01
  done
  [ -e "$FIRST_ATTEMPTED" ] ||
    grep -qFx 'critic-queue-test:claim-attempted' "$FIRST_LOG"
  OWNERLESS_SUCCESSOR=0
  [ ! -e "$Q.lock/.reap/owner" ] && [ ! -L "$Q.lock/.reap/owner" ] &&
    OWNERLESS_SUCCESSOR=1
  CURRENT_GENERATION="$(
    python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(f"{s.st_dev}:{s.st_ino}")' \
      "$Q.lock/.reap"
  )"

  rm "$OBSERVE_PAUSE"
  wait "$FIRST" 2>/dev/null || true

  [ "$OWNERLESS_SUCCESSOR" -eq 1 ]
  [ "$CURRENT_GENERATION" = "$SUCCESSOR_GENERATION" ]
  [ "$(grep -cE '^src/first-claim\.ts [0-9]+$' "$Q")" -eq 1 ]
  [ ! -e "$Q.lock" ]

  run bash -c "printf '%s' \
    '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/later-claim.ts\"}}' \
    | CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$QUEUE_HOOK'"
  [ "$status" -eq 0 ]
  [ "$(grep -cE '^src/later-claim\.ts [0-9]+$' "$Q")" -eq 1 ]
  [ ! -e "$Q.lock" ]
}

@test "a failed post-publication probe retires its live recovery claim" {
  P="$(make_fixture_project critq-claim-probe-retry)"
  Q="$P/tmp/critic-queue-s1"
  mkdir "$Q.lock"
  chmod 700 "$Q.lock"
  printf '%s %s %s\n' 2147483647 stale-generation dead-process \
    >"$Q.lock/owner"
  chmod 600 "$Q.lock/owner"

  REAL_PYTHON="$(command -v python3)"
  PROBE_BIN="$BATS_TEST_TMPDIR/claim-probe-bin"
  FAILED_ONCE="$BATS_TEST_TMPDIR/claim-probe.failed"
  mkdir -p "$PROBE_BIN"
  cat >"$PROBE_BIN/python3" <<EOF
#!/bin/bash
if [ "\$#" -eq 7 ] && [ "\${3:-}" = "owned" ] &&
    [ ! -e "$FAILED_ONCE" ]; then
  : >"$FAILED_ONCE"
  exit 1
fi
exec "$REAL_PYTHON" "\$@"
EOF
  chmod +x "$PROBE_BIN/python3"

  run bash -c "printf '%s' \
    '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/probe-retry.ts\"}}' \
    | PATH='$PROBE_BIN':\"\$PATH\" CQ_REAP_GRACE_SEC=0 \
      CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$QUEUE_HOOK'"

  [ "$status" -eq 0 ]
  [ -e "$FAILED_ONCE" ]
  [ "$(grep -cE '^src/probe-retry\.ts [0-9]+$' "$Q")" -eq 1 ]
  [ ! -e "$Q.lock" ]
}

@test "a crash after claim mkdir leaves no permanent prepare-child wedge" {
  P="$(make_fixture_project critq-claim-mkdir-crash)"
  Q="$P/tmp/critic-queue-s1"
  mkdir "$Q.lock"
  chmod 700 "$Q.lock"
  printf '%s %s %s\n' 2147483647 stale-generation dead-process \
    >"$Q.lock/owner"
  chmod 600 "$Q.lock/owner"

  run bash -c "printf '%s' \
    '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/crashed.ts\"}}' \
    | CQ_LOCK_WAIT_STEPS=1 CQ_REAP_GRACE_SEC=0 \
      CQ_QUEUE_TEST_REAP_CLAIM_CRASH_AFTER_MKDIR=1 \
      CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$QUEUE_HOOK'"

  [ "$status" -eq 0 ]
  [[ "$output" == *"critic-queue-test:claim-crash-after-mkdir"* ]]
  [ -d "$Q.lock/.reap" ]
  [ -z "$(find "$Q.lock" -maxdepth 1 -name '.reap.prepare.*' -print)" ]
  [ ! -e "$Q" ]

  run bash -c "printf '%s' \
    '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/recovered-crash.ts\"}}' \
    | CQ_REAP_GRACE_SEC=0 CLAUDE_PROJECT_DIR='$P' \
      bash '$QUARTET_ROOT/$QUEUE_HOOK'"

  [ "$status" -eq 0 ]
  [ "$(grep -cE '^src/recovered-crash\.ts [0-9]+$' "$Q")" -eq 1 ]
  [ ! -e "$Q.lock" ]
}

@test "a reaper killed after claim publication does not permanently block later captures" {
  P="$(make_fixture_project critq-orphan-reap)"
  Q="$P/tmp/critic-queue-s1"
  mkdir "$Q.lock"
  chmod 700 "$Q.lock"
  printf '%s %s %s\n' 2147483647 stale-generation dead-process \
    >"$Q.lock/owner"
  chmod 600 "$Q.lock/owner"

  # Kill the queue-hook process from its mv child after the recovery claim is
  # fully published but before the stale lock rename. Kernel crash recovery,
  # not a polite shell cleanup path, must make the next capture progress.
  REAL_MV="$(command -v mv)"
  CRASH_BIN="$BATS_TEST_TMPDIR/crash-bin"
  READY="$BATS_TEST_TMPDIR/orphan-reaper.ready"
  mkdir -p "$CRASH_BIN"
  cat >"$CRASH_BIN/mv" <<EOF
#!/bin/bash
if [ "\${1:-}" = "$Q.lock" ] &&
    [[ "\${2:-}" == "$P/tmp/.critic-retire."*/item ]]; then
  : >"$READY"
  kill -9 "\$PPID"
  exit 137
fi
exec "$REAL_MV" "\$@"
EOF
  chmod +x "$CRASH_BIN/mv"

  bash -c "printf '%s' \
    '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/crashed.ts\"}}' \
    | PATH='$CRASH_BIN':\"\$PATH\" CLAUDE_PROJECT_DIR='$P' \
      bash '$QUARTET_ROOT/$QUEUE_HOOK'" \
    >"$BATS_TEST_TMPDIR/crashed.out" 2>"$BATS_TEST_TMPDIR/crashed.err" &
  CRASH_DRIVER=$!
  wait "$CRASH_DRIVER" 2>/dev/null || true
  [ -e "$READY" ]
  [ -d "$Q.lock/.reap" ]
  REAPER_PID="$(awk '{print $1}' "$Q.lock/.reap/owner")"
  ! kill -0 "$REAPER_PID" 2>/dev/null

  run bash -c "printf '%s' \
    '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/recovered.ts\"}}' \
    | CQ_LOCK_WAIT_STEPS=50 CLAUDE_PROJECT_DIR='$P' \
      bash '$QUARTET_ROOT/$QUEUE_HOOK'"

  [ "$status" -eq 0 ]
  [ "$(grep -cE '^src/recovered\.ts [0-9]+$' "$Q")" -eq 1 ]
  [ ! -e "$Q.lock" ]
}

@test "partial, legacy, and symlink-poisoned recovery markers are safely reclaimed" {
  for KIND in partial future-partial plain symlink legacy owner-symlink; do
    P="$(make_fixture_project "critq-reap-poison-$KIND")"
    Q="$P/tmp/critic-queue-s1"
    mkdir "$Q.lock"
    chmod 700 "$Q.lock"
    printf '%s %s %s\n' 2147483647 stale-generation dead-process \
      >"$Q.lock/owner"
    chmod 600 "$Q.lock/owner"
    case "$KIND" in
      partial)
        mkdir "$Q.lock/.reap"
        chmod 700 "$Q.lock/.reap"
        python3 -c 'import os, sys; os.utime(sys.argv[1], (0, 0))' \
          "$Q.lock/.reap"
        ;;
      future-partial)
        mkdir "$Q.lock/.reap"
        chmod 700 "$Q.lock/.reap"
        python3 -c '
import os
import sys
import time
future = time.time() + 86400
os.utime(sys.argv[1], (future, future))
' "$Q.lock/.reap"
        ;;
      plain) printf 'poison\n' >"$Q.lock/.reap" ;;
      symlink) ln -s "$BATS_TEST_TMPDIR" "$Q.lock/.reap" ;;
      legacy)
        mkdir "$Q.lock/.reap"
        chmod 700 "$Q.lock/.reap"
        printf '%s %s\n' "$$" legacy-token >"$Q.lock/.reap/owner"
        chmod 600 "$Q.lock/.reap/owner"
        fixture_set_mtime_ago 2 "$Q.lock/.reap"
        ;;
      owner-symlink)
        mkdir "$Q.lock/.reap"
        chmod 700 "$Q.lock/.reap"
        OWNER_TARGET="$BATS_TEST_TMPDIR/reap-owner-target"
        printf '%s %s\n' "$$" legacy-token >"$OWNER_TARGET"
        chmod 600 "$OWNER_TARGET"
        TARGET_CONTENT_BEFORE="$(od -An -tx1 "$OWNER_TARGET")"
        TARGET_MODE_BEFORE="$(
          stat -c '%a' "$OWNER_TARGET" 2>/dev/null ||
            stat -f '%Lp' "$OWNER_TARGET"
        )"
        ln -s "$OWNER_TARGET" "$Q.lock/.reap/owner"
        fixture_set_mtime_ago 2 "$Q.lock/.reap"
        ;;
    esac

    WAIT_STEPS=100
    [ "$KIND" = "future-partial" ] && WAIT_STEPS=2
    run bash -c "printf '%s' \
      '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/$KIND.ts\"}}' \
      | CQ_LOCK_WAIT_STEPS='$WAIT_STEPS' CLAUDE_PROJECT_DIR='$P' \
        bash '$QUARTET_ROOT/$QUEUE_HOOK'"

    [ "$status" -eq 0 ]
    if [ "$KIND" = "future-partial" ]; then
      # Two steps are enough to retire poison and the stale generation, but
      # deliberately not enough to acquire a third generation and append.
      [ ! -e "$Q.lock/.reap" ]
      run bash -c "printf '%s' \
        '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/$KIND.ts\"}}' \
        | CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$QUEUE_HOOK'"
      [ "$status" -eq 0 ]
    fi
    [ "$(grep -cE "^src/$KIND\\.ts [0-9]+$" "$Q")" -eq 1 ]
    [ ! -e "$Q.lock" ]
    [ ! -L "$Q.lock" ]
    if [ "$KIND" = "owner-symlink" ]; then
      [ -f "$OWNER_TARGET" ]
      [ "$(od -An -tx1 "$OWNER_TARGET")" = "$TARGET_CONTENT_BEFORE" ]
      TARGET_MODE_AFTER="$(
        stat -c '%a' "$OWNER_TARGET" 2>/dev/null ||
          stat -f '%Lp' "$OWNER_TARGET"
      )"
      [ "$TARGET_MODE_AFTER" = "$TARGET_MODE_BEFORE" ]
    fi
  done
}

@test "reaper fast-path rejects extra-line and hard-linked owner records" {
  # shellcheck source=agents/release/critic-queue-lib.sh
  . "$QUARTET_ROOT/$QUEUE_LIB"
  LIVE_IDENTITY="$(_cq_process_identity "$$")"
  for KIND in extra-line hardlink; do
    P="$(make_fixture_project "critq-reap-strict-$KIND")"
    Q="$P/tmp/critic-queue-s1"
    mkdir "$Q.lock"
    chmod 700 "$Q.lock"
    printf '%s %s %s\n' 2147483647 stale-generation dead-process \
      >"$Q.lock/owner"
    chmod 600 "$Q.lock/owner"
    mkdir "$Q.lock/.reap"
    chmod 700 "$Q.lock/.reap"
    if [ "$KIND" = "extra-line" ]; then
      printf '%s %s %s\npoison\n' \
        "$$" "$$-1-1" "$LIVE_IDENTITY" >"$Q.lock/.reap/owner"
    else
      OWNER_TARGET="$BATS_TEST_TMPDIR/hardlink-owner-target"
      printf '%s %s %s\n' \
        "$$" "$$-1-1" "$LIVE_IDENTITY" >"$OWNER_TARGET"
      ln "$OWNER_TARGET" "$Q.lock/.reap/owner"
    fi
    chmod 600 "$Q.lock/.reap/owner"
    fixture_set_mtime_ago 2 "$Q.lock/.reap"
    if [ "$KIND" = "hardlink" ]; then
      TARGET_CONTENT_BEFORE="$(od -An -tx1 "$OWNER_TARGET")"
      TARGET_MODE_BEFORE="$(
        stat -c '%a' "$OWNER_TARGET" 2>/dev/null ||
          stat -f '%Lp' "$OWNER_TARGET"
      )"
    fi

    run bash -c "printf '%s' \
      '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/$KIND.ts\"}}' \
      | CQ_LOCK_WAIT_STEPS=100 CLAUDE_PROJECT_DIR='$P' \
        bash '$QUARTET_ROOT/$QUEUE_HOOK'"

    [ "$status" -eq 0 ]
    [ "$(grep -cE "^src/$KIND\\.ts [0-9]+$" "$Q")" -eq 1 ]
    [ ! -e "$Q.lock" ]
    if [ "$KIND" = "hardlink" ]; then
      [ -f "$OWNER_TARGET" ]
      [ "$(stat -c '%h' "$OWNER_TARGET" 2>/dev/null ||
        stat -f '%l' "$OWNER_TARGET")" -eq 1 ]
      [ "$(od -An -tx1 "$OWNER_TARGET")" = "$TARGET_CONTENT_BEFORE" ]
      TARGET_MODE_AFTER="$(
        stat -c '%a' "$OWNER_TARGET" 2>/dev/null ||
          stat -f '%Lp' "$OWNER_TARGET"
      )"
      [ "$TARGET_MODE_AFTER" = "$TARGET_MODE_BEFORE" ]
    fi
  done
}

@test "a frozen recovery mutex stays within the hook bound and later recovery succeeds" {
  P="$(make_fixture_project critq-frozen-recovery-mutex)"
  Q="$P/tmp/critic-queue-s1"
  mkdir "$Q.lock"
  chmod 700 "$Q.lock"
  printf '%s %s %s\n' 2147483647 stale-generation dead-process \
    >"$Q.lock/owner"
  chmod 600 "$Q.lock/owner"
  mkdir "$Q.lock/.reap"
  chmod 700 "$Q.lock/.reap"
  printf '%s %s %s\n' 2147483647 stale-reaper dead-process \
    >"$Q.lock/.reap/owner"
  chmod 600 "$Q.lock/.reap/owner"

  MUTEX="$P/tmp/.critic-reap-mutex"
  READY="$BATS_TEST_TMPDIR/mutex-holder.ready"
  PAUSE="$BATS_TEST_TMPDIR/mutex-holder.pause"
  : >"$PAUSE"
  python3 - "$MUTEX" "$READY" "$PAUSE" <<'PY' &
import fcntl
import os
import sys
import time

mutex, ready, pause = sys.argv[1:]
fd = os.open(mutex, os.O_RDWR | os.O_CREAT, 0o600)
os.fchmod(fd, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
with open(ready, "w", encoding="ascii"):
    pass
while os.path.exists(pause):
    time.sleep(0.01)
os.close(fd)
PY
  MUTEX_HOLDER=$!
  READY_STARTED_AT="$SECONDS"
  while [ "$((SECONDS - READY_STARTED_AT))" -lt 10 ]; do
    [ -e "$READY" ] && break
    sleep 0.01
  done
  [ -e "$READY" ]

  bash -c "printf '%s' \
    '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/busy.ts\"}}' \
    | CQ_LOCK_WAIT_STEPS=5 CLAUDE_PROJECT_DIR='$P' \
      bash '$QUARTET_ROOT/$QUEUE_HOOK'" \
    >"$BATS_TEST_TMPDIR/busy.out" 2>"$BATS_TEST_TMPDIR/busy.err" &
  BUSY_CAPTURE=$!
  CAPTURE_FINISHED=0
  CAPTURE_STARTED_AT="$SECONDS"
  while [ "$((SECONDS - CAPTURE_STARTED_AT))" -lt 10 ]; do
    if ! kill -0 "$BUSY_CAPTURE" 2>/dev/null; then
      CAPTURE_FINISHED=1
      break
    fi
    sleep 0.01
  done
  CAPTURE_ELAPSED="$((SECONDS - CAPTURE_STARTED_AT))"

  rm "$PAUSE"
  wait "$MUTEX_HOLDER"
  if [ "$CAPTURE_FINISHED" -eq 0 ]; then
    kill "$BUSY_CAPTURE" 2>/dev/null || true
  fi
  wait "$BUSY_CAPTURE" 2>/dev/null || true
  [ "$CAPTURE_FINISHED" -eq 1 ]
  [ "$CAPTURE_ELAPSED" -lt 10 ]
  [ ! -e "$Q" ]
  [[ "$(cat "$BATS_TEST_TMPDIR/busy.err")" == *"failing open"* ]]

  fixture_set_mtime_ago 2 "$Q.lock/.reap"
  run bash -c "printf '%s' \
    '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/after-mutex.ts\"}}' \
    | CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$QUEUE_HOOK'"
  [ "$status" -eq 0 ]
  [ "$(grep -cE '^src/after-mutex\.ts [0-9]+$' "$Q")" -eq 1 ]
  [ ! -e "$Q.lock" ]
}

@test "a FIFO recovery-marker owner cannot escape the hook bound" {
  P="$(make_fixture_project critq-fifo-reap-owner)"
  Q="$P/tmp/critic-queue-s1"
  mkdir "$Q.lock"
  chmod 700 "$Q.lock"
  printf '%s %s %s\n' 2147483647 stale-generation dead-process \
    >"$Q.lock/owner"
  chmod 600 "$Q.lock/owner"
  mkdir "$Q.lock/.reap"
  chmod 700 "$Q.lock/.reap"
  mkfifo "$Q.lock/.reap/owner"
  chmod 600 "$Q.lock/.reap/owner"
  python3 - "$Q.lock/.reap" <<'PY'
import os
import sys
import time

# Start comfortably inside the grace window so shell startup cannot make the
# marker stale before acquisition begins. The bounded retry still carries wall
# time past the edge and must retain its frozen eligibility decision.
stamp = time.time() - 0.2
os.utime(sys.argv[1], (stamp, stamp))
PY

  FIFO_STARTED_AT="$SECONDS"
  bash -c "printf '%s' \
    '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/fifo-busy.ts\"}}' \
    | CQ_LOCK_WAIT_STEPS=5 CLAUDE_PROJECT_DIR='$P' \
      bash '$QUARTET_ROOT/$QUEUE_HOOK'" \
    >"$BATS_TEST_TMPDIR/fifo.out" 2>"$BATS_TEST_TMPDIR/fifo.err" &
  FIFO_CAPTURE=$!
  CAPTURE_FINISHED=0
  while [ "$((SECONDS - FIFO_STARTED_AT))" -lt 10 ]; do
    if ! kill -0 "$FIFO_CAPTURE" 2>/dev/null; then
      CAPTURE_FINISHED=1
      break
    fi
    sleep 0.01
  done

  if [ "$CAPTURE_FINISHED" -eq 0 ]; then
    # Unblock a pre-fix FIFO reader without letting the fallback writer become
    # an orphan when no reader remains at the deadline.
    printf 'poison\n' >"$Q.lock/.reap/owner" 2>/dev/null &
    FIFO_UNBLOCKER=$!
    kill "$FIFO_CAPTURE" 2>/dev/null || true
  fi
  wait "$FIFO_CAPTURE" 2>/dev/null || true
  if [ -n "${FIFO_UNBLOCKER:-}" ]; then
    kill "$FIFO_UNBLOCKER" 2>/dev/null || true
    wait "$FIFO_UNBLOCKER" 2>/dev/null || true
  fi
  FIFO_ELAPSED="$((SECONDS - FIFO_STARTED_AT))"
  [ "$CAPTURE_FINISHED" -eq 1 ]
  [ "$FIFO_ELAPSED" -lt 10 ]
  [ ! -e "$Q" ]
  [[ "$(cat "$BATS_TEST_TMPDIR/fifo.err")" == *"failing open"* ]]

  fixture_set_mtime_ago 2 "$Q.lock/.reap"
  run bash -c "printf '%s' \
    '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/after-fifo.ts\"}}' \
    | CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$QUEUE_HOOK'"
  [ "$status" -eq 0 ]
  [ "$(grep -cE '^src/after-fifo\.ts [0-9]+$' "$Q")" -eq 1 ]
  [ ! -e "$Q.lock" ]
}

@test "a frozen live queue owner is bounded, visible, and the capture hook fails open" {
  P="$(make_fixture_project critq-lock-timeout)"
  Q="$P/tmp/critic-queue-s1"
  # shellcheck source=agents/release/critic-queue-lib.sh
  . "$QUARTET_ROOT/$QUEUE_LIB"
  cq_queue_lock_acquire "$Q"

  run bash -c "printf '%s' \
    '{\"session_id\":\"s1\",\"tool_input\":{\"file_path\":\"src/bounded.ts\"}}' \
    | CQ_LOCK_WAIT_STEPS=2 CLAUDE_PROJECT_DIR='$P' \
      bash '$QUARTET_ROOT/$QUEUE_HOOK'"
  cq_queue_lock_release

  [ "$status" -eq 0 ]
  [[ "$output" == *"edit capture could not acquire the queue lock; failing open"* ]]
  [ ! -e "$Q" ]
  [ ! -e "$Q.lock" ]

  run bash -c "printf '%s' \
    '{\"session_id\":\"s2\",\"tool_input\":{\"file_path\":\"src/config.ts\"}}' \
    | CQ_LOCK_WAIT_STEPS=not-a-number CLAUDE_PROJECT_DIR='$P' \
      bash '$QUARTET_ROOT/$QUEUE_HOOK'"
  [ "$status" -eq 0 ]
  [ "$(grep -cE '^src/config\.ts [0-9]+$' "$P/tmp/critic-queue-s2")" -eq 1 ]
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
