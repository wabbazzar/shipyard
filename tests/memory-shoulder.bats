#!/usr/bin/env bats
# Exact-diff rules-memory integration for the release shoulder watcher.

setup() {
  load helpers
  quartet_setup
  quartet_use_native_bash
  export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
  export CRITIC_IDLE_SEC=1 CRITIC_DIFF_MODE=staged
}

WATCH="agents/release/critic-watch.sh"
STOP_GATE="agents/release/critic-stop-gate.sh"

run_watch() {
  QUARTET_DIR="$QUARTET_ROOT" QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    /bin/bash "$QUARTET_ROOT/$WATCH" --project "$1" --session s1 --once
}

queue_code() {
  local project="$1" text="${2:-unsafe conditional publish}"
  mkdir -p "$project/src"
  printf '%s\n' "$text" >"$project/src/state.ts"
  git -C "$project" add src/state.ts
  printf 'src/state.ts %s\n' "$(date +%s)" >"$project/tmp/critic-queue-s1"
  fixture_set_mtime_ago 120 "$project/tmp/critic-queue-s1"
}

enable_memory() {
  local project="$1" mode="${2:-advisory}"
  printf '\n[memory]\nmode = "%s"\nledger = ".agents/rules-ledger.jsonl"\n' \
    "$mode" >>"$project/.agents/config.toml"
  : >"$project/.agents/rules-ledger.jsonl"
}

seed_rule() {
  export CRITIC_MODEL=review-v1 CRITIC_PROVIDER=local-test
  python3 - "$1/.agents/rules-ledger.jsonl" <<'PY'
from pathlib import Path
import json,sys
r={"schema_version":1,"id":"RACE-1","occurred_at":"2026-08-27T12:30:00Z",
"kind":"regression","severity":"block","status":"active",
"summary":"A conditional state publication raced.",
"mechanism":"Read-check-write allowed a stale publisher to overwrite a newer state.",
"rule":"Use one atomic compare-and-publish transition.",
"required_evidence":"Run a deterministic interleaving regression test.",
"associations":{"paths":["src/*.ts"],"symbols":["publish_state"],"tags":["race-condition"]},
"remediation":"Bind the conditional write to the observed version.",
"sources":[{"kind":"ticket","ref":"docs/tickets/RACE-1.md"}]}
Path(sys.argv[1]).write_text(json.dumps(r,sort_keys=True,separators=(",",":"))+"\n")
PY
}

stub_reviews() {
  REVIEW_CALLS="$BATS_TEST_TMPDIR/review-calls"; export REVIEW_CALLS
  make_stub_script claude '
if [[ "$*" == *"HISTORICAL RULES MEMORY REVIEW"* ]]; then
  printf "memory\n" >>"$REVIEW_CALLS"
  result="disposition|RACE-1|requires_evidence|src/state.ts|.agents/rules-ledger.jsonl:1|the changed hunk has no atomic guard
block|src/state.ts|RACE-1|require an atomic guard and deterministic interleaving test
TOKENS_HINT|<none>"
  jq -nc --arg result "$result" "{type:\"result\",result:\$result,usage:{input_tokens:4,output_tokens:3}}"
else
  printf "generic\n" >>"$REVIEW_CALLS"
  result="warn|src/state.ts|generic state warning
TOKENS_HINT|<none>"
  jq -nc --arg result "$result" "{type:\"result\",result:\$result,usage:{input_tokens:10,output_tokens:5}}"
fi'
}

supersede_only_rule() {
  jq -c '.status="superseded"' "$1/.agents/rules-ledger.jsonl" \
    >"$BATS_TEST_TMPDIR/superseded-ledger"
  mv "$BATS_TEST_TMPDIR/superseded-ledger" "$1/.agents/rules-ledger.jsonl"
}

@test "unconfigured and empty advisory memory preserve one legacy model call and prompt bytes" {
  stub_reviews
  make_stub claude-note 0
  hashes=""
  for kind in off empty; do
    P="$(make_fixture_project "memory-legacy-$kind")"
    [ "$kind" = off ] || enable_memory "$P" advisory
    queue_code "$P"
    export CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"
    run run_watch "$P"
    [ "$status" -eq 0 ]
    [ ! -e "$P/tmp/critic-memory-receipt-s1.json" ]
    hashes="$hashes$(grep -A999 '^generic$' "$REVIEW_CALLS" | tail -1)"
  done
  [ "$(grep -c '^generic$' "$REVIEW_CALLS")" = "2" ]
  [ "$(grep -c '^memory$' "$REVIEW_CALLS" || true)" = "0" ]
}

@test "applicable rule produces cited stop-gate finding and deposited exact-diff receipt" {
  P="$(make_fixture_project memory-block)"
  enable_memory "$P" required; seed_rule "$P"; queue_code "$P"
  stub_reviews; make_stub claude-note 0
  export CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"

  run run_watch "$P"
  [ "$status" -eq 0 ]
  [ "$(cat "$REVIEW_CALLS")" = $'generic\nmemory' ]
  grep -Fq 'block|src/state.ts|[RACE-1] require an atomic guard' \
    "$P/tmp/critic-findings-s1"
  RECEIPT="$P/tmp/critic-memory-receipt-s1.json"
  jq -e --arg head "$(git -C "$P" rev-parse HEAD)" \
    '.schema_version==1 and .state=="complete" and .verdict=="block"
    and .delivery.status=="deposited" and .binding.policy_mode=="required"
    and (.binding.project_identity|test("^[0-9a-f]{64}$"))
    and (.binding.diff_digest|test("^[0-9a-f]{64}$"))
    and .retrieved_ids==["RACE-1"] and .review_set_ids==["RACE-1"]
    and .binding.base_identity==$head
    and .dispositions[0].id=="RACE-1" and .dispositions[0].citation==".agents/rules-ledger.jsonl:1"' \
    "$RECEIPT" >/dev/null
  EVENT="$(events_json | jq -c 'select(.event=="release.critique")')"
  [ "$(jq -r '.tokens' <<<"$EVENT")" = "22" ]
  run bash -c "printf '%s' '{\"session_id\":\"s1\"}' | CRITIC_BLOCK=1 CLAUDE_PROJECT_DIR='$P' bash '$QUARTET_ROOT/$STOP_GATE'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"RACE-1"* ]]
}

@test "default Claude memory review pins Sonnet and Claude in the receipt" {
  P="$(make_fixture_project memory-default-identity)"
  enable_memory "$P" advisory; seed_rule "$P"; queue_code "$P"
  unset CRITIC_MODEL CRITIC_PROVIDER
  stub_reviews; make_stub claude-note 0
  export CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"

  run run_watch "$P"; [ "$status" -eq 0 ]
  jq -e '.state=="complete"
    and .binding.reviewer.model=="sonnet"
    and .binding.reviewer.provider=="claude"
    and .reviewer.resolved.model=="sonnet"
    and .reviewer.resolved.provider=="claude"' \
    "$P/tmp/critic-memory-receipt-s1.json" >/dev/null
  grep -Fq -- '--model sonnet' "$SHIM_LOG/claude.argv"
}

@test "required mid-review gate mutation invalidates receipt before delivery" {
  P="$(make_fixture_project memory-mid-review-mutation)"
  enable_memory "$P" required; seed_rule "$P"; queue_code "$P"
  MUTATE_GATES="$P/.agents/gates.md"; export MUTATE_GATES
  make_stub_script claude '
if [[ "$*" == *"HISTORICAL RULES MEMORY REVIEW"* ]]; then
  printf "# concurrent gate mutation\n" >>"$MUTATE_GATES"
  result="disposition|RACE-1|requires_evidence|src/state.ts|.agents/rules-ledger.jsonl:1|the changed hunk has no atomic guard
block|src/state.ts|RACE-1|require an atomic guard and deterministic interleaving test
TOKENS_HINT|<none>"
else
  result="note|src/state.ts|generic clean
TOKENS_HINT|<none>"
fi
jq -nc --arg result "$result" "{type:\"result\",result:\$result,usage:{input_tokens:2,output_tokens:1}}"'
  make_stub claude-note 0; export CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"

  run run_watch "$P"; [ "$status" -eq 0 ]
  [ -s "$P/tmp/critic-queue-s1" ]
  [ "$(stub_calls claude-note)" = 0 ]
  jq -e '.state=="degraded" and .error.code=="stale_binding"
    and .delivery.status=="not_delivered"' \
    "$P/tmp/critic-memory-receipt-s1.json" >/dev/null
}

@test "live advisory-to-required promotion fails closed in the running watcher" {
  P="$(make_fixture_project memory-live-promotion)"
  enable_memory "$P" advisory; seed_rule "$P"; queue_code "$P"
  MUTATE_CONFIG="$P/.agents/config.toml"; export MUTATE_CONFIG
  make_stub_script claude '
if [[ "$*" == *"HISTORICAL RULES MEMORY REVIEW"* ]]; then
  sed "s/mode = \"advisory\"/mode = \"required\"/" "$MUTATE_CONFIG" >"$MUTATE_CONFIG.next"
  mv "$MUTATE_CONFIG.next" "$MUTATE_CONFIG"
  result="disposition|RACE-1|requires_evidence|src/state.ts|.agents/rules-ledger.jsonl:1|the changed hunk has no atomic guard
block|src/state.ts|RACE-1|require an atomic guard and deterministic interleaving test
TOKENS_HINT|<none>"
else
  result="note|src/state.ts|generic clean
TOKENS_HINT|<none>"
fi
jq -nc --arg result "$result" "{type:\"result\",result:\$result,usage:{input_tokens:2,output_tokens:1}}"'
  make_stub claude-note 0; export CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"

  run run_watch "$P"; [ "$status" -eq 0 ]
  [ -s "$P/tmp/critic-queue-s1" ]
  [ "$(stub_calls claude-note)" = 0 ]
  jq -e '.state=="degraded" and .binding.policy_mode=="required"
    and .error.code=="stale_binding"' \
    "$P/tmp/critic-memory-receipt-s1.json" >/dev/null
}

@test "required memory without a delivery command preserves reviewed queue" {
  P="$(make_fixture_project memory-required-no-delivery)"
  enable_memory "$P" required; seed_rule "$P"; queue_code "$P"
  stub_reviews
  unset CLAUDE_NOTE_CMD

  run run_watch "$P"; [ "$status" -eq 0 ]
  [ -s "$P/tmp/critic-queue-s1" ]
  jq -e '.state=="complete" and .delivery.status=="deferred"' \
    "$P/tmp/critic-memory-receipt-s1.json" >/dev/null
}

@test "required deposited-receipt write failure keeps the queue after notification" {
  P="$(make_fixture_project memory-delivery-receipt-failure)"
  enable_memory "$P" required; seed_rule "$P"; queue_code "$P"
  stub_reviews; make_stub claude-note 0
  REAL_PYTHON="$(command -v python3)"; export REAL_PYTHON
  make_stub_script python3 '
if [[ "$*" == *"memory-review.py delivery"* && "$*" == *"--status deposited"* ]]; then exit 2; fi
exec "$REAL_PYTHON" "$@"'
  export CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"

  run run_watch "$P"; [ "$status" -eq 0 ]
  [ -s "$P/tmp/critic-queue-s1" ]
  [ -s "$SHIM_LOG/claude-note.argv" ]
  jq -e '.state=="complete" and .delivery.status=="delivery"' \
    "$P/tmp/critic-memory-receipt-s1.json" >/dev/null
}

@test "advisory deposited-receipt write failure degrades and consumes once" {
  P="$(make_fixture_project memory-advisory-delivery-receipt-failure)"
  enable_memory "$P" advisory; seed_rule "$P"; queue_code "$P"
  stub_reviews; make_stub claude-note 0
  REAL_PYTHON="$(command -v python3)"; export REAL_PYTHON
  make_stub_script python3 '
if [[ "$*" == *"memory-review.py delivery"* && "$*" == *"--status deposited"* ]]; then exit 2; fi
exec "$REAL_PYTHON" "$@"'
  export CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"

  run run_watch "$P"; [ "$status" -eq 0 ]
  [ ! -e "$P/tmp/critic-queue-s1" ]
  [ -s "$SHIM_LOG/claude-note.argv" ]
  jq -e '.state=="degraded" and .error.code=="delivery_receipt_failed"
    and .delivery.status=="deposited"
    and .coverage=="full" and .reviewer.invocation.state=="complete"
    and .reviewer.invocation.identity_source=="spawn-dispatcher-v1"
    and (.reviewer.invocation.tokens | type)=="number"
    and (.dispositions | length)==1
    and .dispositions[0].id=="RACE-1"
    and (.findings | length)==1 and .findings[0].id=="RACE-1"
    and (.response_digest | type)=="string"
    and (.reviewed_at | type)=="string"' \
    "$P/tmp/critic-memory-receipt-s1.json" >/dev/null
  run env QUARTET_DIR="$QUARTET_ROOT" bash \
    "$QUARTET_ROOT/skills/shipyard/shipyard.sh" memory status --project "$P"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.receipt.state + ":" + .receipt.delivery' <<<"$output")" = \
    "degraded:deposited" ]
}

@test "failed memory-stage spend is counted by the next budget gate" {
  P="$(make_fixture_project memory-failed-spend-budget)"
  enable_memory "$P" required; seed_rule "$P"; queue_code "$P"
  python3 - "$P/.agents/config.toml" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); text=p.read_text()
p.write_text(text.replace("[release]\n", "[release]\nbudget_tokens_daily = 6\n", 1))
PY
  REVIEW_CALLS="$BATS_TEST_TMPDIR/failed-spend-review-calls"; export REVIEW_CALLS
  make_stub_script claude '
if [[ "$*" == *"HISTORICAL RULES MEMORY REVIEW"* ]]; then
  printf "memory\n" >>"$REVIEW_CALLS"
  result="disposition|RACE-1|applies|src/state.ts|wrong:9|uncited
TOKENS_HINT|<none>"
else
  printf "generic\n" >>"$REVIEW_CALLS"
  result="note|src/state.ts|generic clean
TOKENS_HINT|<none>"
fi
jq -nc --arg result "$result" "{type:\"result\",result:\$result,usage:{input_tokens:2,output_tokens:1}}"'
  make_stub claude-note 0; export CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"

  run run_watch "$P"; [ "$status" -eq 0 ]
  event="$(events_json | jq -c 'select(.event=="release.critique.memory_failed")' | tail -1)"
  [ "$(jq -r '.tokens' <<<"$event")" = 6 ]
  [ "$(wc -l <"$REVIEW_CALLS" | tr -d ' ')" = 2 ]
  run run_watch "$P"; [ "$status" -eq 0 ]
  [ "$(wc -l <"$REVIEW_CALLS" | tr -d ' ')" = 2 ]
  events_json | jq -e 'select(.event=="release.critique.skipped" and .reason=="budget")' >/dev/null
}

@test "advisory failure tokens are billed exactly once through final critique" {
  P="$(make_fixture_project memory-advisory-spend-once)"
  enable_memory "$P" advisory; seed_rule "$P"; queue_code "$P"
  python3 - "$P/.agents/config.toml" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); text=p.read_text()
p.write_text(text.replace("[release]\n", "[release]\nbudget_tokens_daily = 10\n", 1))
PY
  REVIEW_CALLS="$BATS_TEST_TMPDIR/advisory-spend-review-calls"; export REVIEW_CALLS
  make_stub_script claude '
if [[ "$*" == *"HISTORICAL RULES MEMORY REVIEW"* ]]; then
  printf "memory\n" >>"$REVIEW_CALLS"
  result="disposition|RACE-1|applies|src/state.ts|wrong:9|uncited
TOKENS_HINT|<none>"
else
  printf "generic\n" >>"$REVIEW_CALLS"
  result="note|src/state.ts|generic clean
TOKENS_HINT|<none>"
fi
jq -nc --arg result "$result" "{type:\"result\",result:\$result,usage:{input_tokens:2,output_tokens:1}}"'
  make_stub claude-note 0; export CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"

  run run_watch "$P"; [ "$status" -eq 0 ]
  events_json | jq -s -e 'map(select(.event=="release.critique.memory_failed"))
    | last | .tokens==6 and .billable_tokens==0' >/dev/null
  queue_code "$P" "unsafe conditional publish again"
  run run_watch "$P"; [ "$status" -eq 0 ]
  [ "$(wc -l <"$REVIEW_CALLS" | tr -d ' ')" = 4 ]
}

@test "cached delivery reuse validates every receipt binding before skipping fresh reviews" {
  P="$(make_fixture_project memory-cache-receipt)"
  enable_memory "$P" advisory; seed_rule "$P"; queue_code "$P"
  stub_reviews; make_stub claude-note 3
  export CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"

  run run_watch "$P"; [ "$status" -eq 0 ]
  [ "$(wc -l <"$REVIEW_CALLS" | tr -d ' ')" = "2" ]
  FIRST="$(jq -r '.binding | [.diff_digest,.ledger_digest,.config_digest,.gates_digest,.reviewer.model] | @tsv' "$P/tmp/critic-memory-receipt-s1.json")"
  run run_watch "$P"; [ "$status" -eq 0 ]
  [ "$(wc -l <"$REVIEW_CALLS" | tr -d ' ')" = "2" ]

  printf '# gate change\n' >"$P/.agents/gates.md"
  run run_watch "$P"; [ "$status" -eq 0 ]
  [ "$(wc -l <"$REVIEW_CALLS" | tr -d ' ')" = "4" ]
  SECOND="$(jq -r '.binding | [.diff_digest,.ledger_digest,.config_digest,.gates_digest,.reviewer.model] | @tsv' "$P/tmp/critic-memory-receipt-s1.json")"
  [ "$FIRST" != "$SECOND" ]

  export CRITIC_MODEL=review-model-v2
  run run_watch "$P"; [ "$status" -eq 0 ]
  [ "$(wc -l <"$REVIEW_CALLS" | tr -d ' ')" = "6" ]
  [ "$(jq -r '.binding.reviewer.model' "$P/tmp/critic-memory-receipt-s1.json")" = review-model-v2 ]

  queue_code "$P" "unsafe conditional publish changed"
  run run_watch "$P"; [ "$status" -eq 0 ]
  [ "$(wc -l <"$REVIEW_CALLS" | tr -d ' ')" = "8" ]
}

@test "required malformed memory output preserves queue while advisory records degradation" {
  for mode in required advisory; do
    P="$(make_fixture_project "memory-malformed-$mode")"
    enable_memory "$P" "$mode"; seed_rule "$P"; queue_code "$P"
    make_stub_script claude '
if [[ "$*" == *"HISTORICAL RULES MEMORY REVIEW"* ]]; then
  jq -nc --arg result "disposition|RACE-1|applies|src/state.ts|wrong:9|uncited
TOKENS_HINT|<none>" "{type:\"result\",result:\$result,usage:{input_tokens:2,output_tokens:1}}"
else
  jq -nc --arg result "note|src/state.ts|generic clean
TOKENS_HINT|<none>" "{type:\"result\",result:\$result,usage:{input_tokens:2,output_tokens:1}}"
fi'
    make_stub claude-note 0; export CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"
    run run_watch "$P"; [ "$status" -eq 0 ]
    if [ "$mode" = required ]; then
      [ -s "$P/tmp/critic-queue-s1" ]
      [ "$(stub_calls claude-note)" = "0" ]
      [ ! -e "$P/tmp/critic-valid-response-s1" ]
    else
      [ ! -e "$P/tmp/critic-queue-s1" ]
      jq -e '.state=="degraded" and .error.code=="malformed_reviewer_output"' \
        "$P/tmp/critic-memory-receipt-s1.json" >/dev/null
    fi
    rm -f "$SHIM_LOG/claude-note.argv"
  done
}

@test "receipt identity prevents copied cross-project reuse" {
  P1="$(make_fixture_project memory-project-one)"
  enable_memory "$P1" advisory; seed_rule "$P1"; queue_code "$P1"
  stub_reviews; make_stub claude-note 3; export CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"
  run run_watch "$P1"; [ "$status" -eq 0 ]

  P2="$(make_fixture_project memory-project-two)"
  enable_memory "$P2" advisory; seed_rule "$P2"; queue_code "$P2"
  cp "$P1/tmp/critic-findings-s1" "$P2/tmp/critic-findings-s1"
  cp "$P1/tmp/critic-findings-files-s1" "$P2/tmp/critic-findings-files-s1"
  cp "$P2/tmp/critic-queue-s1" "$P2/tmp/critic-snapshot-s1"
  cp "$P1/tmp/critic-memory-receipt-s1.json" "$P2/tmp/critic-memory-receipt-s1.json"
  touch -t 203001010101 "$P2/tmp/critic-findings-s1"
  run run_watch "$P2"; [ "$status" -eq 0 ]
  [ "$(grep -c '^generic$' "$REVIEW_CALLS")" = "2" ]
  [ "$(grep -c '^memory$' "$REVIEW_CALLS")" = "2" ]
  [ "$(jq -r '.binding.project_root' "$P2/tmp/critic-memory-receipt-s1.json")" = "$(cd "$P2" && pwd -P)" ]
}

@test "one whole-review deadline is passed to generic and memory spawns and exhaustion fails closed" {
  P="$(make_fixture_project memory-deadline)"
  enable_memory "$P" required; seed_rule "$P"; queue_code "$P"
  DEADLINE_CALLS="$BATS_TEST_TMPDIR/deadline-calls"; export DEADLINE_CALLS
  REAL_TIMEOUT="$(command -v timeout)"; export REAL_TIMEOUT
  make_stub_script timeout '
if [ "${2##*/}" = claude ]; then printf "%s\n" "$1" >>"$DEADLINE_CALLS"; fi
exec "$REAL_TIMEOUT" "$@"'
  make_stub_script claude '
if [[ "$*" == *"HISTORICAL RULES MEMORY REVIEW"* ]]; then sleep 20; else sleep 1; fi
if [[ "$*" == *"HISTORICAL RULES MEMORY REVIEW"* ]]; then result="TOKENS_HINT|<none>"; else result="TOKENS_HINT|<none>"; fi
jq -nc --arg result "$result" "{type:\"result\",result:\$result,usage:{input_tokens:2,output_tokens:1}}"'
  make_stub claude-note 0; export CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note" CRITIC_REVIEW_TIMEOUT_SEC=8

  started="$(date +%s)"; run run_watch "$P"; elapsed=$(( $(date +%s) - started ))
  [ "$status" -eq 0 ]
  # Fixture/project setup before the review deadline is platform-dependent;
  # the 20-second memory stub itself must still be cut off well before 20s.
  [ "$elapsed" -lt 18 ]
  [ "$(wc -l <"$DEADLINE_CALLS" | tr -d ' ')" = "2" ]
  first="$(sed -n '1p' "$DEADLINE_CALLS")"; second="$(sed -n '2p' "$DEADLINE_CALLS")"
  [ "$first" -le 8 ] && [ "$second" -lt "$first" ]
  [ -s "$P/tmp/critic-queue-s1" ]
  [ "$(stub_calls claude-note)" = "0" ]
}

@test "advisory query failure replaces stale receipt with degradation and continues generic delivery" {
  P="$(make_fixture_project memory-advisory-query-failure)"
  enable_memory "$P" advisory; seed_rule "$P"; queue_code "$P"
  printf '{bad json\n' >"$P/.agents/rules-ledger.jsonl"
  printf '{"schema_version":1,"state":"complete"}\n' \
    >"$P/tmp/critic-memory-receipt-s1.json"
  stub_reviews; make_stub claude-note 0
  export CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"

  run run_watch "$P"
  [ "$status" -eq 0 ]
  [ ! -e "$P/tmp/critic-queue-s1" ]
  [ "$(cat "$REVIEW_CALLS")" = generic ]
  jq -e '.state=="degraded" and .coverage=="incomplete"
    and .error.code=="query" and .binding.diff_digest
    and .delivery.status=="not_delivered"' \
    "$P/tmp/critic-memory-receipt-s1.json" >/dev/null
}

@test "deterministic retrieval consumes the whole-review deadline and required mode preserves queue" {
  P="$(make_fixture_project memory-query-deadline)"
  enable_memory "$P" required; seed_rule "$P"; queue_code "$P"
  REAL_PYTHON="$(command -v python3)"; export REAL_PYTHON
  make_stub_script python3 '
if [[ "$*" == *"rules-memory.py query"* ]]; then exec sleep 8; fi
exec "$REAL_PYTHON" "$@"'
  make_stub claude 0
  make_stub claude-note 0
  export CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note" CRITIC_REVIEW_TIMEOUT_SEC=1

  started="$(date +%s)"; run run_watch "$P"; elapsed=$(( $(date +%s) - started ))
  [ "$status" -eq 0 ]
  [ "$elapsed" -lt 6 ]
  [ -s "$P/tmp/critic-queue-s1" ]
  [ "$(stub_calls claude)" = "0" ]
  [ "$(stub_calls claude-note)" = "0" ]
  jq -e '.state=="degraded" and .error.code=="deadline"
    and .binding.diff_digest' "$P/tmp/critic-memory-receipt-s1.json" >/dev/null
}

@test "advisory malformed prepared context replaces stale receipt and continues" {
  P="$(make_fixture_project memory-advisory-context-failure)"
  enable_memory "$P" advisory; seed_rule "$P"; queue_code "$P"
  REAL_PYTHON="$(command -v python3)"; export REAL_PYTHON
  make_stub_script python3 '
if [[ "$*" == *"memory-review.py prepare"* ]]; then
  output=""; previous=""
  for value in "$@"; do
    [[ "$previous" != "--output" ]] || output="$value"
    previous="$value"
  done
  "$REAL_PYTHON" "$@" || exit $?
  printf "{}\n" >"$output"
  exit 0
fi
exec "$REAL_PYTHON" "$@"'
  stub_reviews; make_stub claude-note 0
  export CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"

  run run_watch "$P"
  [ "$status" -eq 0 ]
  [ ! -e "$P/tmp/critic-queue-s1" ]
  jq -e '.state=="degraded" and .error.code=="context"
    and .delivery.status=="not_delivered"' \
    "$P/tmp/critic-memory-receipt-s1.json" >/dev/null
}

@test "advisory preparation failure atomically replaces stale receipt and continues" {
  P="$(make_fixture_project memory-advisory-prepare-failure)"
  enable_memory "$P" advisory; seed_rule "$P"; queue_code "$P"
  printf '{"schema_version":1,"state":"complete"}\n' \
    >"$P/tmp/critic-memory-receipt-s1.json"
  old_inode="$(ls -i "$P/tmp/critic-memory-receipt-s1.json" | awk '{print $1}')"
  REAL_PYTHON="$(command -v python3)"; export REAL_PYTHON
  make_stub_script python3 '
if [[ "$*" == *"memory-review.py prepare"* ]]; then exit 2; fi
exec "$REAL_PYTHON" "$@"'
  stub_reviews; make_stub claude-note 0
  export CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"

  run run_watch "$P"
  [ "$status" -eq 0 ]
  [ ! -e "$P/tmp/critic-queue-s1" ]
  new_inode="$(ls -i "$P/tmp/critic-memory-receipt-s1.json" | awk '{print $1}')"
  [ "$old_inode" != "$new_inode" ]
  jq -e '.state=="degraded" and .error.code=="prepare"
    and .delivery.status=="not_delivered"' \
    "$P/tmp/critic-memory-receipt-s1.json" >/dev/null
}

@test "advisory zero and bind receipt failures replace evidence and continue" {
  for failed_command in zero bind-findings; do
    P="$(make_fixture_project "memory-advisory-$failed_command")"
    enable_memory "$P" advisory; seed_rule "$P"; supersede_only_rule "$P"
    queue_code "$P"
    REAL_PYTHON="$(command -v python3)"; export REAL_PYTHON FAILED_COMMAND="$failed_command"
    make_stub_script python3 '
if [[ "$*" == *"memory-review.py $FAILED_COMMAND"* ]]; then exit 2; fi
exec "$REAL_PYTHON" "$@"'
    stub_reviews; make_stub claude-note 0
    export CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"

    run run_watch "$P"
    [ "$status" -eq 0 ]
    [ ! -e "$P/tmp/critic-queue-s1" ]
    if [ "$failed_command" = zero ]; then expected=zero_receipt_failed
    else expected=bind_findings_failed
    fi
    [ "$(jq -r '.state + ":" + .error.code' \
      "$P/tmp/critic-memory-receipt-s1.json")" = "degraded:$expected" ]
    rm -f "$SHIM_LOG/claude.argv" "$SHIM_LOG/claude-note.argv"
  done
}

@test "mktemp and diff-write failures share raw degradation fallback" {
  REAL_MKTEMP="$(PATH="${PATH#*:}" command -v mktemp)"; export REAL_MKTEMP
  for failed_setup in mktemp_query diff_write; do
    P="$(make_fixture_project "memory-advisory-$failed_setup")"
    enable_memory "$P" advisory; seed_rule "$P"; queue_code "$P"
    printf '{"schema_version":1,"state":"complete"}\n' \
      >"$P/tmp/critic-memory-receipt-s1.json"
    if [ "$failed_setup" = mktemp_query ]; then
      make_stub_script mktemp '
if [[ "$*" == *".critic-memory-query."* ]]; then exit 1; fi
exec "$REAL_MKTEMP" "$@"'
    else
      BAD_DIFF_DIR="$BATS_TEST_TMPDIR/bad-diff-target"
      BAD_DIFF_LINK="$BATS_TEST_TMPDIR/bad-diff-link"
      mkdir "$BAD_DIFF_DIR"
      export BAD_DIFF_DIR BAD_DIFF_LINK
      make_stub_script mktemp '
if [[ "$*" == *".critic-memory-diff."* ]]; then
  ln -s "$BAD_DIFF_DIR" "$BAD_DIFF_LINK"
  printf "%s\n" "$BAD_DIFF_LINK"
  exit 0
fi
exec "$REAL_MKTEMP" "$@"'
    fi
    stub_reviews; make_stub claude-note 0
    export CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"

    run run_watch "$P"
    [ "$status" -eq 0 ]
    [ ! -e "$P/tmp/critic-queue-s1" ]
    [ "$(cat "$REVIEW_CALLS")" = generic ]
    jq -e --arg code "$failed_setup" '.state=="degraded"
      and .error.code==$code and .binding.diff_digest
      and .delivery.status=="not_delivered"' \
      "$P/tmp/critic-memory-receipt-s1.json" >/dev/null
    rm -f "$SHIM_LOG/claude.argv" "$SHIM_LOG/claude-note.argv" "$REVIEW_CALLS"
  done
}

@test "required mktemp failure preserves queue without model or delivery" {
  P="$(make_fixture_project memory-required-mktemp)"
  enable_memory "$P" required; seed_rule "$P"; queue_code "$P"
  REAL_MKTEMP="$(PATH="${PATH#*:}" command -v mktemp)"; export REAL_MKTEMP
  make_stub_script mktemp '
if [[ "$*" == *".critic-memory-query."* ]]; then exit 1; fi
exec "$REAL_MKTEMP" "$@"'
  make_stub claude 0; make_stub claude-note 0
  export CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"

  run run_watch "$P"
  [ "$status" -eq 0 ]
  [ -s "$P/tmp/critic-queue-s1" ]
  [ "$(stub_calls claude)" = 0 ]
  [ "$(stub_calls claude-note)" = 0 ]
  jq -e '.state=="degraded" and .error.code=="mktemp_query"' \
    "$P/tmp/critic-memory-receipt-s1.json" >/dev/null
}
