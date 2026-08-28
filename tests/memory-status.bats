#!/usr/bin/env bats
# Deterministic, read-only status/doctor evidence for project rules memory.

setup() {
  load helpers
  quartet_setup
  quartet_memory_cache_setup
}

SH="skills/shipyard/shipyard.sh"
run_shipyard() { QUARTET_DIR="$QUARTET_ROOT" bash "$QUARTET_ROOT/$SH" "$@"; }

enable_memory() {
  local project="$1" mode="${2:-advisory}"
  printf '\n[memory]\nmode = "%s"\nledger = ".agents/rules-ledger.jsonl"\n' \
    "$mode" >>"$project/.agents/config.toml"
  : >"$project/.agents/rules-ledger.jsonl"
}

seed_race_rule() {
  python3 - "$1/.agents/rules-ledger.jsonl" <<'PY'
from pathlib import Path
import json, sys
r={"schema_version":1,"id":"EARLY-RACE-1","occurred_at":"2026-08-20T12:30:00Z",
"kind":"regression","severity":"block","status":"active",
"summary":"An earlier conditional transition lost a concurrent update.",
"mechanism":"A read-check-write sequence admitted a stale writer.",
"rule":"Use an atomic version-bound state transition.",
"required_evidence":"Run a deterministic stale-writer interleaving test.",
"associations":{"paths":["src/state.py"],"symbols":["publish_state"],
"state_transitions":["pending-to-delivered"],"tags":["race-condition"]},
"remediation":"Bind the conditional write to the observed version.",
"sources":[{"kind":"ticket","ref":"docs/tickets/EARLY-RACE-1.md"}]}
Path(sys.argv[1]).write_text(json.dumps(r,sort_keys=True,separators=(",",":"))+"\n")
PY
}

build_index() {
  local project="$1" scope="$BATS_TEST_TMPDIR/status-scope"
  printf 'publish_state pending-to-delivered stale writer atomic transition\n' >"$scope"
  run run_shipyard memory query --project "$project" --scope-file "$scope"
  [ "$status" -eq 0 ]
  QUERY="$output"
}

write_current_receipt() {
  local project="$1" state="${2:-complete}" delivery="${3:-deposited}"
  run run_shipyard memory status --project "$project"
  [ "$status" -eq 0 ]
  STATUS_DOC="$output"
  python3 - "$project" "$STATUS_DOC" "$QUERY" "$state" "$delivery" <<'PY'
from pathlib import Path
import hashlib, json, os, sys
root=Path(sys.argv[1]).resolve(); status=json.loads(sys.argv[2]); query=json.loads(sys.argv[3])
state=sys.argv[4]; delivery=sys.argv[5]
def identity(path):
    if not path.exists(): return {"state":"missing","digest":None,"bytes":None}
    data=path.read_bytes()
    return {"state":"present","digest":hashlib.sha256(data).hexdigest(),"bytes":len(data)}
config=identity(root/".agents/config.toml"); gates=identity(root/".agents/gates.md")
ledger=(root/status["ledger_path"]).read_bytes()
requested={"harness":"claude","model":"review-v1","provider":"local-test",
           "model_explicit":True,"provider_explicit":True,
           "contract_version":"rules-memory-review-v1"}
binding={
    "project_root":str(root),
    "project_identity":hashlib.sha256(str(root).encode()).hexdigest(),
    "diff_digest":hashlib.sha256(b"fixture diff").hexdigest(),
    "base_identity":"fixture-base","diff_mode":"staged",
    "ledger_digest":status["ledger_digest"],
    "source_layout_digest":hashlib.sha256(ledger).hexdigest(),
    "ledger_line_count":status["record_count"],
    "index_digest":status["index"]["expected_digest"],
    "index_schema_version":status["index"]["schema_version"],
    "normalizer_version":status["index"]["normalizer_version"],
    "vector_backend":status["index"]["vector_backend"],
    "config_identity":config,"config_digest":config["digest"],"config_state":config["state"],
    "gates_identity":gates,"gates_digest":gates["digest"],"gates_state":gates["state"],
    "policy_mode":status["mode"],
    "query_features":query["query_features"],"limits":query["limits"],
    "reviewer":requested,
}
candidate_evidence=[]
for candidate in query["candidates"]:
    candidate_evidence.append({"id":candidate["id"],"severity":candidate["severity"],
      "status":candidate["status"],
      "citation":f'{candidate["citation"]["ledger_path"]}:{candidate["citation"]["line"]}',
      "sources":candidate["citation"]["sources"],"channels":candidate["channels"],
      "excerpt":candidate["excerpt"]})
retrieved=[item["id"] for item in candidate_evidence]
review_set=retrieved[:binding["limits"]["max_prompt_records"]]
receipt={"schema_version":1,"binding":binding,"retrieved_ids":retrieved,
         "review_set_ids":review_set,"omitted_ids":retrieved[len(review_set):],
         "candidate_evidence":candidate_evidence,
         "prompt_digest":hashlib.sha256(b"fixture prompt").hexdigest(),"state":state,
         "dispositions":[],"findings":[],"findings_digest":None,
         "delivery":{"status":delivery}}
if state=="complete":
    receipt.update(coverage="bounded" if receipt["omitted_ids"] else "full",verdict="clean",
      response_digest=hashlib.sha256(b"fixture response").hexdigest(),
      findings_digest=hashlib.sha256(b"").hexdigest(),reviewed_at="2026-08-27T19:30:00Z")
    receipt["delivery"]["updated_at"]="2026-08-27T19:30:01Z"
    receipt["dispositions"]=[{"id":item["id"],"state":"falsified","path":"src/state.py",
      "citation":item["citation"],"evidence":"the exact diff contains an atomic guard"}
      for item in candidate_evidence[:len(review_set)]]
    receipt["reviewer"]={"requested":requested,
      "resolved":{"model":"review-v1","provider":"local-test"},
      "invocation":{"state":"complete","identity":hashlib.sha256(b"invocation").hexdigest(),
      "started_at":"2026-08-27T19:29:59Z","ended_at":"2026-08-27T19:30:00Z",
      "tokens":7,"rc":0,"identity_source":"spawn-dispatcher-v1"}}
else:
    # Canonical degraded-input/raw receipts cannot always establish a ledger
    # line count before the failed query, unlike degraded prepared contexts.
    binding.pop("ledger_line_count")
    receipt.update(coverage="incomplete",verdict="incomplete",
      error={"code":"review_timeout","message":"PRIVATE-REVIEWER-PROSE"})
    receipt["reviewer"]={"requested":requested,"resolved":{"model":None,"provider":None},
      "invocation":{"state":"not_started","identity":None,"started_at":None,"ended_at":None,
      "tokens":0,"rc":None,"identity_source":None}}
path=root/"tmp/critic-memory-receipt-status.json"
path.write_text(json.dumps(receipt,sort_keys=True,separators=(",",":"))+"\n")
os.chmod(path,0o600)
PY
}

@test "configured empty status is ready without creating an index or exposing prose" {
  P="$(make_fixture_project memory-status-empty)"
  enable_memory "$P"
  before="$(find "$P/.agents" "$P/tmp" -printf '%p %T@\n' | sort)"
  run run_shipyard memory status --project "$P"
  [ "$status" -eq 0 ]
  after="$(find "$P/.agents" "$P/tmp" -printf '%p %T@\n' | sort)"
  [ "$before" = "$after" ]
  [ ! -e "$XDG_CACHE_HOME" ]
  run python3 -c 'import json,sys; d=json.load(sys.stdin)
assert d["configured"] and d["state"]=="ready" and d["valid"]
assert d["record_count"]==d["active_count"]==d["superseded_count"]==0
assert d["index"]["state"]=="not_applicable"
assert d["embedding"]=={"available":True,"backend":"stdlib-hash-ngram-v1","dimensions":2048}
assert d["receipt"]["state"]=="absent" and d["receipt"]["count"]==0' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "status distinguishes absent fresh stale and corrupt derived indexes without rebuilding" {
  P="$(make_fixture_project memory-status-index)"
  enable_memory "$P" required; seed_race_rule "$P"

  run run_shipyard memory status --project "$P"; [ "$status" -eq 0 ]
  [ "$(jq -r '.index.state' <<<"$output")" = absent ]
  [ ! -e "$XDG_CACHE_HOME" ]

  build_index "$P"
  key="$(jq -r '.index.cache_key' <<<"$QUERY")"
  digest="$(jq -r '.index.digest' <<<"$QUERY")"
  index="$XDG_CACHE_HOME/shipyard/memory/$key/index-$digest.sqlite3"
  snapshot="$(python3 - "$XDG_CACHE_HOME" <<'PY'
from pathlib import Path
import sys
for p in sorted(Path(sys.argv[1]).rglob("*")):
    print(p, p.stat().st_mtime_ns)
PY
)"
  run run_shipyard memory status --project "$P"; [ "$status" -eq 0 ]
  [ "$(jq -r '.index.state' <<<"$output")" = fresh ]
  [ "$(jq -r '.index.actual_digest' <<<"$output")" = "$digest" ]
  current="$(python3 - "$XDG_CACHE_HOME" <<'PY'
from pathlib import Path
import sys
for p in sorted(Path(sys.argv[1]).rglob("*")):
    print(p, p.stat().st_mtime_ns)
PY
)"
  [ "$snapshot" = "$current" ]

  python3 - "$P/.agents/rules-ledger.jsonl" <<'PY'
from pathlib import Path
import json, sys
p=Path(sys.argv[1]); r=json.loads(p.read_text())
r["summary"]="A revised earlier transition lost a concurrent update."
p.write_text(json.dumps(r,sort_keys=True,separators=(",",":"))+"\n")
PY
  run run_shipyard memory status --project "$P"; [ "$status" -eq 0 ]
  [ "$(jq -r '.index.state' <<<"$output")" = stale ]

  # Restore the indexed layout, then prove a corrupt expected artifact is invalid.
  seed_race_rule "$P"
  printf 'not sqlite\n' >"$index"
  chmod 600 "$index"
  run run_shipyard memory status --project "$P"; [ "$status" -eq 0 ]
  [ "$(jq -r '.index.state' <<<"$output")" = invalid ]
  [ "$(jq -r '.index.error_code' <<<"$output")" = index_invalid ]
}

@test "latest receipt reports complete degraded stale and invalid without ledger or reviewer prose" {
  P="$(make_fixture_project memory-status-receipt)"
  enable_memory "$P" advisory; seed_race_rule "$P"; build_index "$P"
  write_current_receipt "$P" complete deposited

  run run_shipyard memory status --project "$P"; [ "$status" -eq 0 ]
  [[ "$output" != *"LEDGER-PROSE-MUST-NOT-LEAK"* ]]
  [[ "$output" != *"PRIVATE-REVIEWER-PROSE"* ]]
  run python3 -c 'import json,sys; r=json.load(sys.stdin)["receipt"]
assert r["state"]=="complete" and r["coverage"]=="full"
assert r["verdict"]=="clean" and r["delivery"]=="deposited"
assert r["diff_freshness"]=="unverified"' <<<"$output"
  [ "$status" -eq 0 ]

  write_current_receipt "$P" degraded not_delivered
  run run_shipyard memory status --project "$P"; [ "$status" -eq 0 ]
  [ "$(jq -r '.receipt.state' <<<"$output")" = degraded ]
  [ "$(jq -r '.receipt.error_code' <<<"$output")" = review_timeout ]
  [[ "$output" != *"PRIVATE-REVIEWER-PROSE"* ]]

  write_current_receipt "$P" complete deposited
  printf '\n# changed gate identity\n' >>"$P/.agents/gates.md"
  run run_shipyard memory status --project "$P"; [ "$status" -eq 0 ]
  [ "$(jq -r '.receipt.state' <<<"$output")" = stale ]
  [ "$(jq -r '.receipt.error_code' <<<"$output")" = receipt_binding_stale ]

  chmod 644 "$P/tmp/critic-memory-receipt-status.json"
  run run_shipyard memory status --project "$P"; [ "$status" -eq 0 ]
  [ "$(jq -r '.receipt.state' <<<"$output")" = invalid ]
  [ "$(jq -r '.receipt.error_code' <<<"$output")" = receipt_invalid ]
}

@test "truncated or internally mismatched receipts are invalid while current-binding changes are stale" {
  P="$(make_fixture_project memory-status-schema)"
  enable_memory "$P" advisory; seed_race_rule "$P"; build_index "$P"
  write_current_receipt "$P" complete deposited
  receipt="$P/tmp/critic-memory-receipt-status.json"

  for mutation in \
    'del(.reviewer.invocation)' \
    '.retrieved_ids=[]' \
    '.findings_digest=null' \
    '.binding.diff_digest="bad"' \
    '.delivery.status="unknown"'; do
    jq "$mutation" "$receipt" >"$BATS_TEST_TMPDIR/mutated-receipt"
    mv "$BATS_TEST_TMPDIR/mutated-receipt" "$receipt"; chmod 600 "$receipt"
    run run_shipyard memory status --project "$P"; [ "$status" -eq 0 ]
    [ "$(jq -r '.receipt.state' <<<"$output")" = invalid ]
    [ "$(jq -r '.receipt.error_code' <<<"$output")" = receipt_schema_invalid ]
    write_current_receipt "$P" complete deposited
  done

  jq '.binding.limits.max_prompt_records += 1' "$receipt" >"$BATS_TEST_TMPDIR/mutated-receipt"
  mv "$BATS_TEST_TMPDIR/mutated-receipt" "$receipt"; chmod 600 "$receipt"
  run run_shipyard memory status --project "$P"; [ "$status" -eq 0 ]
  [ "$(jq -r '.receipt.state' <<<"$output")" = stale ]
  [ "$(jq -r '.receipt.error_code' <<<"$output")" = receipt_binding_stale ]

  write_current_receipt "$P" complete pending
  run run_shipyard memory status --project "$P"; [ "$status" -eq 0 ]
  [ "$(jq -r '.receipt.state' <<<"$output")" = stale ]
  [ "$(jq -r '.receipt.error_code' <<<"$output")" = receipt_delivery_incomplete ]
}

@test "canonical implicit reviewer identities remain observable but malformed contrasts are invalid" {
  P="$(make_fixture_project memory-status-implicit)"
  enable_memory "$P" advisory; seed_race_rule "$P"; build_index "$P"
  write_current_receipt "$P" complete deposited
  receipt="$P/tmp/critic-memory-receipt-status.json"

  # A nonzero review may resolve an implicit request at dispatch time. Status
  # accepts the canonical actual identity; Phase-4 cache reuse remains stricter.
  jq '.binding.reviewer.model="<implicit-unresolved>"
      | .binding.reviewer.provider="<implicit-unresolved>"
      | .binding.reviewer.model_explicit=false
      | .binding.reviewer.provider_explicit=false
      | .reviewer.requested=.binding.reviewer
      | .reviewer.resolved={"model":"actual-review-v2","provider":"actual-provider"}' \
    "$receipt" >"$BATS_TEST_TMPDIR/implicit-nonzero"
  mv "$BATS_TEST_TMPDIR/implicit-nonzero" "$receipt"; chmod 600 "$receipt"
  run run_shipyard memory status --project "$P"; [ "$status" -eq 0 ]
  [ "$(jq -r '.receipt.state' <<<"$output")" = complete ]

  # Leaving the sentinel unresolved after an actual nonzero invocation is not
  # canonical observability evidence.
  jq '.reviewer.resolved.model="<implicit-unresolved>"' "$receipt" \
    >"$BATS_TEST_TMPDIR/implicit-bad"
  mv "$BATS_TEST_TMPDIR/implicit-bad" "$receipt"; chmod 600 "$receipt"
  run run_shipyard memory status --project "$P"; [ "$status" -eq 0 ]
  [ "$(jq -r '.receipt.state' <<<"$output")" = invalid ]

  # Canonical zero-candidate review records an implicit request and the exact
  # not-required invocation without pretending a dispatcher resolved it.
  write_current_receipt "$P" complete deposited
  jq '.binding.reviewer.model="<implicit-unresolved>"
      | .binding.reviewer.provider="<implicit-unresolved>"
      | .binding.reviewer.model_explicit=false
      | .binding.reviewer.provider_explicit=false
      | .reviewer.requested=.binding.reviewer
      | .reviewer.resolved={"model":"<implicit-unresolved>","provider":"<implicit-unresolved>"}
      | .reviewer.invocation={"state":"not_required","identity":"rules-memory-zero-candidate-v1","started_at":null,"ended_at":null,"tokens":0,"rc":null,"identity_source":"not_applicable"}
      | .retrieved_ids=[] | .review_set_ids=[] | .omitted_ids=[]
      | .candidate_evidence=[] | .dispositions=[] | .findings=[]
      | .response_digest=null' "$receipt" >"$BATS_TEST_TMPDIR/implicit-zero"
  mv "$BATS_TEST_TMPDIR/implicit-zero" "$receipt"; chmod 600 "$receipt"
  run run_shipyard memory status --project "$P"; [ "$status" -eq 0 ]
  [ "$(jq -r '.receipt.state' <<<"$output")" = complete ]

  jq '.reviewer.resolved.model="invented-resolution"' "$receipt" \
    >"$BATS_TEST_TMPDIR/implicit-zero-bad"
  mv "$BATS_TEST_TMPDIR/implicit-zero-bad" "$receipt"; chmod 600 "$receipt"
  run run_shipyard memory status --project "$P"; [ "$status" -eq 0 ]
  [ "$(jq -r '.receipt.state' <<<"$output")" = invalid ]

  write_current_receipt "$P" complete deposited
  jq '.reviewer.resolved.model="wrong-explicit-model"' "$receipt" \
    >"$BATS_TEST_TMPDIR/explicit-bad"
  mv "$BATS_TEST_TMPDIR/explicit-bad" "$receipt"; chmod 600 "$receipt"
  run run_shipyard memory status --project "$P"; [ "$status" -eq 0 ]
  [ "$(jq -r '.receipt.state' <<<"$output")" = invalid ]
}

@test "status stops cache and receipt enumeration at configured hard bounds" {
  P="$(make_fixture_project memory-status-bounds)"
  enable_memory "$P" advisory; seed_race_rule "$P"; build_index "$P"
  cache_dir="$XDG_CACHE_HOME/shipyard/memory/$(jq -r '.index.cache_key' <<<"$QUERY")"
  python3 - "$cache_dir" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
for n in range(1025): (root/f"extra-{n:04d}").touch()
PY
  run run_shipyard memory status --project "$P"; [ "$status" -eq 0 ]
  [ "$(jq -r '.index.state' <<<"$output")" = invalid ]
  [ "$(jq -r '.index.error_code' <<<"$output")" = index_invalid ]

  # A bounded receipt scan fails before attempting to parse any of the 257 files.
  python3 - "$P/tmp" <<'PY'
from pathlib import Path
import os, sys
root=Path(sys.argv[1])
for n in range(257):
    p=root/f"critic-memory-receipt-bound-{n:03d}.json"; p.write_text("{}\n"); os.chmod(p,0o600)
PY
  run run_shipyard memory status --project "$P"; [ "$status" -eq 0 ]
  [ "$(jq -r '.receipt.state' <<<"$output")" = invalid ]
  [ "$(jq -r '.receipt.error_code' <<<"$output")" = receipt_bound_exceeded ]
}
