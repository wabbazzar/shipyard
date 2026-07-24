#!/usr/bin/env bats
# tests/hunk-safe-gates.bats — the shoulder critic's CHANGED FILES list is a
# superset of the files that actually have hunks (a hook-queued but reverted
# tracked file lands in the list with zero delta). With
# [release].hunk_safe_gates=true such phantom entries are marked "(no hunks)"
# so a file-conditional check can key on real hunks; with the flag unset the
# prompt is byte-identical to before. No real LLM: `claude` is a PATH-shim stub
# that records the prompt it receives.

setup() {
  load helpers
  quartet_setup
}

WATCH="agents/release/critic-watch.sh"
CANNED_CLAUDE_JSON='{"type":"result","result":"note|-|clean\nTOKENS_HINT|<none>","usage":{"input_tokens":10,"output_tokens":5}}'

run_watch() {
  local project="$1"; shift
  QUARTET_DIR="$QUARTET_ROOT" \
  QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    bash "$QUARTET_ROOT/$WATCH" --project "$project" "$@"
}

# seed_phantom_and_real <project> — commit a tracked file (left UNCHANGED, so it
# is a zero-delta phantom), create a real untracked file (a genuine hunk via the
# --no-index synth), and queue BOTH so the union list carries a phantom + a real
# entry. Sets the queue mtime old enough to trigger the idle path.
seed_phantom_and_real() {
  local P="$1"
  mkdir -p "$P/src"
  printf 'export const x = 1;\n' > "$P/src/tracked.ts"
  git -C "$P" add src/tracked.ts
  git -C "$P" commit -q -m "add tracked"
  # real.ts: untracked new file → a real hunk reaches the critic via synth.
  printf 'export const y = 2;\n' > "$P/src/real.ts"
  # tracked.ts is NOT modified → it is a phantom (listed, no hunk).
  printf 'src/tracked.ts %s\nsrc/real.ts %s\n' "$(date +%s)" "$(date +%s)" \
    > "$P/tmp/critic-queue-s1"
  touch -d "2 minutes ago" "$P/tmp/critic-queue-s1"
}

@test "flag ON: phantom (no-hunk) entry is marked, real entry is not" {
  P="$(make_fixture_project hson hunk-safe-gates.toml)"
  make_stub claude 0 "$CANNED_CLAUDE_JSON"
  seed_phantom_and_real "$P"
  export CRITIC_BATCH_FILES=100 CRITIC_IDLE_SEC=1

  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]

  argv="$(stub_argv claude)"
  # the critic was actually invoked with a prompt
  echo "$argv" | grep -q "CHANGED FILES:"
  # the phantom is annotated (assert the filename+marker, not the bare marker —
  # critic-role.md's input-contract note also mentions "(no hunks)")
  echo "$argv" | grep -qF "src/tracked.ts (no hunks)"
  # the real file is NOT annotated
  ! echo "$argv" | grep -qF "src/real.ts (no hunks)"
}

@test "flag OFF (default): no marker — CHANGED FILES byte-identical to today" {
  P="$(make_fixture_project hsoff absent-keys.toml)"
  make_stub claude 0 "$CANNED_CLAUDE_JSON"
  seed_phantom_and_real "$P"
  export CRITIC_BATCH_FILES=100 CRITIC_IDLE_SEC=1

  run run_watch "$P" --session s1 --once
  [ "$status" -eq 0 ]

  argv="$(stub_argv claude)"
  echo "$argv" | grep -q "CHANGED FILES:"
  # both files present in the list
  echo "$argv" | grep -qF "src/tracked.ts"
  echo "$argv" | grep -qF "src/real.ts"
  # but the phantom is NOT annotated with the flag unset (byte-identical list).
  # Assert the filename+marker, not the bare marker — critic-role.md's own
  # input-contract note mentions "(no hunks)" and is part of every prompt.
  ! echo "$argv" | grep -qF "src/tracked.ts (no hunks)"
}
