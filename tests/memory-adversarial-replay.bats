#!/usr/bin/env bats
# Held-out, provider-free replay: historical mechanisms, not incident names,
# must transfer to a new race; a guarded diff must falsify the same candidates.

setup() {
  load helpers
  quartet_setup
  quartet_use_native_bash
  quartet_memory_cache_setup
  export CRITIC_IDLE_SEC=1 CRITIC_DIFF_MODE=staged
  export CRITIC_MODEL=review-v1 CRITIC_PROVIDER=local-test
}

WATCH="agents/release/critic-watch.sh"

run_watch() {
  QUARTET_DIR="$QUARTET_ROOT" QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    /bin/bash "$QUARTET_ROOT/$WATCH" --project "$1" --session replay --once
}

queue_generation() {
  local project="$1" path="$2"
  printf '%s %s\n' "$path" "$(date +%s)" >"$project/tmp/critic-queue-replay"
  fixture_set_mtime_ago 120 "$project/tmp/critic-queue-replay"
}

seed_earlier_incidents() {
  python3 - "$1/.agents/rules-ledger.jsonl" <<'PY'
from pathlib import Path
import json,sys
base={"schema_version":1,"occurred_at":"2026-08-10T12:00:00Z","kind":"regression",
"severity":"block","status":"active","associations":{"paths":["src/workflow.py"],
"symbols":["finalize_delivery"],"subsystems":["workflow-state"],
"state_transitions":["queued-to-published"],"technologies":["python"],
"tags":["race-condition"]},"sources":[{"kind":"ticket","ref":"docs/tickets/earlier-races.md"}]}
records=[]
records.append({**base,"id":"EARLY-RACE-1",
"summary":"A conditional publication overwrote a newer state.",
"mechanism":"A split read-check-write allowed a stale publisher after a competing transition.",
"rule":"Use one atomic version-bound state transition.",
"required_evidence":"Run a deterministic stale-writer interleaving test.",
"remediation":"Replace the split transition with compare-and-exchange on the observed version."})
records.append({**base,"id":"EARLY-RACE-2","occurred_at":"2026-08-12T12:00:00Z",
"summary":"A retry published from an obsolete snapshot.",
"mechanism":"The final write was not conditional on the version that the decision inspected.",
"rule":"Reject stale writers with an atomic compare-exchange guard.",
"required_evidence":"Prove a competing writer wins in a deterministic interleaving test.",
"remediation":"Make the state predicate and update one indivisible version-checked operation."})
p=Path(sys.argv[1]); p.write_text("".join(json.dumps(r,sort_keys=True,separators=(",",":"))+"\n" for r in records))
PY
}

stub_replay_reviewers() {
  REVIEW_CALLS="$BATS_TEST_TMPDIR/replay-review-calls"; export REVIEW_CALLS
  make_stub_script claude '
if [[ "$*" == *"HISTORICAL RULES MEMORY REVIEW"* ]]; then
  printf "memory\n" >>"$REVIEW_CALLS"
  if [[ "$*" == *"compare_exchange"* && "$*" == *"test_stale_writer_interleaving"* ]]; then
    result="disposition|EARLY-RACE-1|falsified|src/workflow.py|.agents/rules-ledger.jsonl:1|compare_exchange binds the observed version and a deterministic interleaving test is present
disposition|EARLY-RACE-2|falsified|src/workflow.py|.agents/rules-ledger.jsonl:2|the stale writer loses under the named deterministic test
TOKENS_HINT|<none>"
  else
    result="disposition|EARLY-RACE-1|requires_evidence|src/workflow.py|.agents/rules-ledger.jsonl:1|the hunk splits read check and unconditional write
block|src/workflow.py|EARLY-RACE-1|require an atomic version guard and deterministic interleaving test
disposition|EARLY-RACE-2|requires_evidence|src/workflow.py|.agents/rules-ledger.jsonl:2|the final write is not bound to the observed version
block|src/workflow.py|EARLY-RACE-2|prove the stale writer loses under deterministic interleaving
TOKENS_HINT|<none>"
  fi
else
  printf "generic\n" >>"$REVIEW_CALLS"
  result="note|src/workflow.py|generic review complete
TOKENS_HINT|<none>"
fi
jq -nc --arg result "$result" "{type:\"result\",result:\$result,usage:{input_tokens:7,output_tokens:5}}"'
  make_stub claude-note 0
  export CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note"
}

@test "held-out race transfers earlier rules, guarded diff falsifies them, unrelated prose skips memory review" {
  P="$(make_fixture_project memory-held-out-replay)"
  printf '\n[memory]\nmode = "required"\nledger = ".agents/rules-ledger.jsonl"\n' \
    >>"$P/.agents/config.toml"
  seed_earlier_incidents "$P"
  ! grep -q 'FINAL-RACE' "$P/.agents/rules-ledger.jsonl"
  stub_replay_reviewers

  mkdir -p "$P/src"
  printf '%s\n' \
    'def finalize_delivery(store, key):' \
    '    observed = store.read(key)' \
    '    if observed.state == "queued":' \
    '        store.write(key, {"state": "published"})' >"$P/src/workflow.py"
  git -C "$P" add src/workflow.py
  queue_generation "$P" src/workflow.py
  run run_watch "$P"; [ "$status" -eq 0 ]
  receipt="$P/tmp/critic-memory-receipt-replay.json"
  run jq -e '.state=="complete" and .verdict=="block"
    and .retrieved_ids==["EARLY-RACE-1","EARLY-RACE-2"]
    and ([.dispositions[].state]|unique)==["requires_evidence"]
    and ([.findings[].id]|sort)==["EARLY-RACE-1","EARLY-RACE-2"]' "$receipt"
  [ "$status" -eq 0 ]

  printf '%s\n' \
    'def finalize_delivery(store, key):' \
    '    observed = store.read(key)' \
    '    return store.compare_exchange(key, observed.version, "published")' \
    '' \
    'def test_stale_writer_interleaving(store):' \
    '    first = store.read("delivery")' \
    '    store.compare_exchange("delivery", first.version, "cancelled")' \
    '    assert not store.compare_exchange("delivery", first.version, "published")' >"$P/src/workflow.py"
  git -C "$P" add src/workflow.py
  queue_generation "$P" src/workflow.py
  run run_watch "$P"; [ "$status" -eq 0 ]
  run jq -e '.state=="complete" and .verdict=="clean" and .findings==[]
    and .retrieved_ids==["EARLY-RACE-1","EARLY-RACE-2"]
    and ([.dispositions[].state]|unique)==["falsified"]' "$receipt"
  [ "$status" -eq 0 ]

  git -C "$P" commit -q -m 'fixture: guarded transition'
  printf '\nCobalt release notes.\n' >>"$P/README.md"
  git -C "$P" add README.md
  queue_generation "$P" README.md
  run run_watch "$P"; [ "$status" -eq 0 ]

  [ "$(grep -c '^generic$' "$REVIEW_CALLS")" = 3 ]
  [ "$(grep -c '^memory$' "$REVIEW_CALLS")" = 2 ]
}
