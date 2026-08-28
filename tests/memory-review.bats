#!/usr/bin/env bats
# Provider-free contract tests for exact-diff memory review receipts.

setup() {
  load helpers
  quartet_setup
  export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
  P="$(make_fixture_project memory-review-helper)"
  printf '\n[memory]\nmode = "required"\nledger = ".agents/rules-ledger.jsonl"\n' \
    >>"$P/.agents/config.toml"
  python3 - "$P/.agents/rules-ledger.jsonl" <<'PY'
from pathlib import Path
import json,sys
record={"schema_version":1,"id":"RACE-1","occurred_at":"2026-08-27T12:30:00Z",
"kind":"regression","severity":"block","status":"active",
"summary":"A conditional publication raced.",
"mechanism":"A stale publisher overwrote a newer state.",
"rule":"Use one atomic compare-and-publish transition.",
"required_evidence":"Run a deterministic interleaving regression test.",
"associations":{"paths":["src/*.ts"],"tags":["race-condition"]},
"remediation":"Bind the write to the observed version.",
"sources":[{"kind":"ticket","ref":"docs/tickets/RACE-1.md"}]}
Path(sys.argv[1]).write_text(json.dumps(record,separators=(",",":"),sort_keys=True)+"\n")
PY
  mkdir -p "$P/src"
  printf 'old\n' >"$P/src/state.ts"
  git -C "$P" add src/state.ts && git -C "$P" commit -qm state-base
  printf 'unsafe conditional publish\n' >"$P/src/state.ts"
  git -C "$P" diff -- src/state.ts >"$BATS_TEST_TMPDIR/diff"
  QUERY="$BATS_TEST_TMPDIR/query.json"
  CONTEXT="$BATS_TEST_TMPDIR/context.json"
  RECEIPT="$BATS_TEST_TMPDIR/receipt.json"
  FINDINGS="$BATS_TEST_TMPDIR/findings"
  INVOCATION_ARGS=(--resolved-model review-v1 \
    --resolved-provider local-test --started-at 2026-08-27T12:31:00Z \
    --ended-at 2026-08-27T12:31:01Z --tokens 7 --rc 0 \
    --identity-source spawn-dispatcher-v1)
  python3 "$QUARTET_ROOT/agents/lib/rules-memory.py" query --project "$P" \
    --diff-file "$BATS_TEST_TMPDIR/diff" >"$QUERY"
  python3 "$QUARTET_ROOT/agents/release/memory-review.py" prepare \
    --project "$P" --query-file "$QUERY" --diff-file "$BATS_TEST_TMPDIR/diff" \
    --base "$(git -C "$P" rev-parse HEAD)" --diff-mode branch \
    --config "$P/.agents/config.toml" --gates "$P/.agents/gates.md" \
    --harness claude --model review-v1 --provider local-test --output "$CONTEXT" \
    >/dev/null
}

@test "strict normalization requires one cited disposition and converts ID only after validation" {
  RESPONSE="$BATS_TEST_TMPDIR/response"
  printf '%s\n' \
    'disposition|RACE-1|requires_evidence|src/state.ts|.agents/rules-ledger.jsonl:1|no atomic guard or interleaving evidence in the current hunk' \
    'block|src/state.ts|RACE-1|require an atomic guard and deterministic interleaving test' \
    'TOKENS_HINT|<none>' >"$RESPONSE"
  run python3 "$QUARTET_ROOT/agents/release/memory-review.py" normalize \
    --context "$CONTEXT" --response "$RESPONSE" --receipt "$RECEIPT" \
    "${INVOCATION_ARGS[@]}"
  [ "$status" -eq 0 ]
  [ "$output" = 'block|src/state.ts|[RACE-1] require an atomic guard and deterministic interleaving test' ]
  printf '%s\n' "$output" >"$FINDINGS"
  python3 "$QUARTET_ROOT/agents/release/memory-review.py" bind-findings \
    --receipt "$RECEIPT" --findings "$FINDINGS"
  jq -e '.state=="complete" and .verdict=="block"
    and .retrieved_ids==["RACE-1"] and .review_set_ids==["RACE-1"]
    and .dispositions[0].citation==".agents/rules-ledger.jsonl:1"
    and .candidate_evidence[0].channels.vector
    and .reviewer.requested.model=="review-v1"
    and .reviewer.resolved.model=="review-v1"
    and (.reviewer.invocation.identity|test("^[0-9a-f]{64}$"))
    and .reviewer.invocation.tokens==7 and .reviewer.invocation.rc==0' \
    "$RECEIPT" >/dev/null

  sed 's#rules-ledger.jsonl:1#wrong.jsonl:9#' "$RESPONSE" >"$BATS_TEST_TMPDIR/bad"
  run python3 "$QUARTET_ROOT/agents/release/memory-review.py" normalize \
    --context "$CONTEXT" --response "$BATS_TEST_TMPDIR/bad" \
    --receipt "$BATS_TEST_TMPDIR/bad-receipt" "${INVOCATION_ARGS[@]}"
  [ "$status" -eq 2 ]
  [ ! -e "$BATS_TEST_TMPDIR/bad-receipt" ]
}

@test "cache reuse binds exact project diff ledger index config gates and reviewer" {
  RESPONSE="$BATS_TEST_TMPDIR/response"
  printf '%s\n' \
    'disposition|RACE-1|falsified|src/state.ts|.agents/rules-ledger.jsonl:1|the hunk uses one atomic transition' \
    'TOKENS_HINT|<none>' >"$RESPONSE"
  python3 "$QUARTET_ROOT/agents/release/memory-review.py" normalize \
    --context "$CONTEXT" --response "$RESPONSE" --receipt "$RECEIPT" \
    "${INVOCATION_ARGS[@]}" >"$FINDINGS"
  python3 "$QUARTET_ROOT/agents/release/memory-review.py" bind-findings \
    --receipt "$RECEIPT" --findings "$FINDINGS"
  run python3 "$QUARTET_ROOT/agents/release/memory-review.py" validate-cache \
    --context "$CONTEXT" --receipt "$RECEIPT" --findings "$FINDINGS"
  [ "$status" -eq 0 ]

  jq '.binding.gates_digest="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' \
    "$CONTEXT" >"$BATS_TEST_TMPDIR/changed-context"
  run python3 "$QUARTET_ROOT/agents/release/memory-review.py" validate-cache \
    --context "$BATS_TEST_TMPDIR/changed-context" --receipt "$RECEIPT" \
    --findings "$FINDINGS"
  [ "$status" -eq 1 ]

  jq '.reviewer.invocation.identity=null' "$RECEIPT" >"$BATS_TEST_TMPDIR/no-identity"
  run python3 "$QUARTET_ROOT/agents/release/memory-review.py" validate-cache \
    --context "$CONTEXT" --receipt "$BATS_TEST_TMPDIR/no-identity" \
    --findings "$FINDINGS"
  [ "$status" -eq 1 ]

  jq '.binding.project_identity="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
    "$CONTEXT" >"$BATS_TEST_TMPDIR/copied-context"
  run python3 "$QUARTET_ROOT/agents/release/memory-review.py" validate-cache \
    --context "$BATS_TEST_TMPDIR/copied-context" --receipt "$RECEIPT" \
    --findings "$FINDINGS"
  [ "$status" -eq 1 ]
}

@test "implicit requested identity and empty dispatcher identity can never authorize reuse" {
  IMPLICIT_CONTEXT="$BATS_TEST_TMPDIR/implicit-context"
  python3 "$QUARTET_ROOT/agents/release/memory-review.py" prepare \
    --project "$P" --query-file "$QUERY" --diff-file "$BATS_TEST_TMPDIR/diff" \
    --base base --diff-mode branch --config "$P/.agents/config.toml" \
    --gates "$P/.agents/gates.md" --harness claude --model '' --provider '' \
    --output "$IMPLICIT_CONTEXT" >/dev/null
  RESPONSE="$BATS_TEST_TMPDIR/response"
  printf '%s\n' \
    'disposition|RACE-1|falsified|src/state.ts|.agents/rules-ledger.jsonl:1|atomic guard present' \
    'TOKENS_HINT|<none>' >"$RESPONSE"
  python3 "$QUARTET_ROOT/agents/release/memory-review.py" normalize \
    --context "$IMPLICIT_CONTEXT" --response "$RESPONSE" --receipt "$RECEIPT" \
    --resolved-model actual-v1 --resolved-provider actual-provider \
    --started-at 2026-08-27T12:31:00Z --ended-at 2026-08-27T12:31:01Z \
    --tokens 2 --rc 0 --identity-source spawn-dispatcher-v1 >"$FINDINGS"
  python3 "$QUARTET_ROOT/agents/release/memory-review.py" bind-findings \
    --receipt "$RECEIPT" --findings "$FINDINGS"
  run python3 "$QUARTET_ROOT/agents/release/memory-review.py" validate-cache \
    --context "$IMPLICIT_CONTEXT" --receipt "$RECEIPT" --findings "$FINDINGS"
  [ "$status" -eq 1 ]

  run python3 "$QUARTET_ROOT/agents/release/memory-review.py" normalize \
    --context "$IMPLICIT_CONTEXT" --response "$RESPONSE" \
    --receipt "$BATS_TEST_TMPDIR/empty-identity-receipt" \
    --resolved-model '' --resolved-provider actual-provider \
    --started-at 2026-08-27T12:31:00Z --ended-at 2026-08-27T12:31:01Z \
    --tokens 2 --rc 0 --identity-source spawn-dispatcher-v1
  [ "$status" -eq 2 ]
  [ ! -e "$BATS_TEST_TMPDIR/empty-identity-receipt" ]
}

@test "deletion-only diffs retain the old path and malformed query identities are rejected" {
  rm "$P/src/state.ts"
  git -C "$P" diff -- src/state.ts >"$BATS_TEST_TMPDIR/delete-diff"
  python3 "$QUARTET_ROOT/agents/lib/rules-memory.py" query --project "$P" \
    --diff-file "$BATS_TEST_TMPDIR/delete-diff" >"$BATS_TEST_TMPDIR/delete-query"
  python3 "$QUARTET_ROOT/agents/release/memory-review.py" prepare \
    --project "$P" --query-file "$BATS_TEST_TMPDIR/delete-query" \
    --diff-file "$BATS_TEST_TMPDIR/delete-diff" --base "$(git -C "$P" rev-parse HEAD)" \
    --diff-mode branch --config "$P/.agents/config.toml" \
    --gates "$P/.agents/gates.md" --harness claude --model '' --provider '' \
    --output "$BATS_TEST_TMPDIR/delete-context" >/dev/null
  jq -e '.diff_paths==["src/state.ts"]
    and .binding.reviewer.model=="<implicit-unresolved>"
    and .binding.reviewer.provider=="<implicit-unresolved>"
    and .binding.reviewer.model_explicit==false
    and .binding.reviewer.provider_explicit==false' \
    "$BATS_TEST_TMPDIR/delete-context" >/dev/null

  for mutation in \
    '.candidates[0].id="bad"' \
    '.candidates[0].severity="urgent"' \
    '.candidates[0].status="superseded"' \
    '.query_input.bytes += 1'; do
    jq "$mutation" "$QUERY" >"$BATS_TEST_TMPDIR/malformed-query"
    run python3 "$QUARTET_ROOT/agents/release/memory-review.py" prepare \
      --project "$P" --query-file "$BATS_TEST_TMPDIR/malformed-query" \
      --diff-file "$BATS_TEST_TMPDIR/diff" --base base --diff-mode branch \
      --config "$P/.agents/config.toml" --gates "$P/.agents/gates.md" \
      --harness claude --output "$BATS_TEST_TMPDIR/rejected-context"
    [ "$status" -eq 2 ]
  done
}

@test "raw advisory degradation atomically replaces stale evidence" {
  printf '{"schema_version":1,"state":"complete"}\n' >"$RECEIPT"
  chmod 600 "$RECEIPT"
  old_inode="$(ls -i "$RECEIPT" | awk '{print $1}')"
  printf '{bad json\n' >"$BATS_TEST_TMPDIR/bad-query"
  python3 "$QUARTET_ROOT/agents/release/memory-review.py" degraded-input \
    --project "$P" --query-file "$BATS_TEST_TMPDIR/bad-query" \
    --diff-file "$BATS_TEST_TMPDIR/diff" --base base --diff-mode branch \
    --config "$P/.agents/config.toml" --gates "$P/.agents/gates.md" \
    --mode advisory --harness claude --model '' --provider '' \
    --receipt "$RECEIPT" --code query --message 'query failed'
  new_inode="$(ls -i "$RECEIPT" | awk '{print $1}')"
  [ "$old_inode" != "$new_inode" ]
  [ "$(stat -f '%Lp' "$RECEIPT" 2>/dev/null || stat -c '%a' "$RECEIPT")" = 600 ]
  jq -e '.state=="degraded" and .error.code=="query"
    and .binding.diff_digest and .reviewer.invocation.state=="not_started"
    and .reviewer.requested.model=="<implicit-unresolved>"' "$RECEIPT" >/dev/null
}

@test "missing and empty config or gates have distinct receipt bindings" {
  MISSING="$BATS_TEST_TMPDIR/not-present"
  EMPTY="$BATS_TEST_TMPDIR/present-empty"
  : >"$EMPTY"
  for kind in config gates; do
    if [ "$kind" = config ]; then
      missing_args=(--config "$MISSING" --gates "$P/.agents/gates.md")
      empty_args=(--config "$EMPTY" --gates "$P/.agents/gates.md")
    else
      missing_args=(--config "$P/.agents/config.toml" --gates "$MISSING")
      empty_args=(--config "$P/.agents/config.toml" --gates "$EMPTY")
    fi
    python3 "$QUARTET_ROOT/agents/release/memory-review.py" prepare \
      --project "$P" --query-file "$QUERY" --diff-file "$BATS_TEST_TMPDIR/diff" \
      --base base --diff-mode branch "${missing_args[@]}" \
      --harness claude --model review-v1 --provider local-test \
      --output "$BATS_TEST_TMPDIR/$kind-missing" >/dev/null
    python3 "$QUARTET_ROOT/agents/release/memory-review.py" prepare \
      --project "$P" --query-file "$QUERY" --diff-file "$BATS_TEST_TMPDIR/diff" \
      --base base --diff-mode branch "${empty_args[@]}" \
      --harness claude --model review-v1 --provider local-test \
      --output "$BATS_TEST_TMPDIR/$kind-empty" >/dev/null
    [ "$(jq -r ".binding.${kind}_identity.state" "$BATS_TEST_TMPDIR/$kind-missing")" = missing ]
    [ "$(jq -r ".binding.${kind}_identity.digest" "$BATS_TEST_TMPDIR/$kind-missing")" = null ]
    [ "$(jq -r ".binding.${kind}_identity.state" "$BATS_TEST_TMPDIR/$kind-empty")" = present ]
    [ "$(jq -r ".binding.${kind}_identity.digest" "$BATS_TEST_TMPDIR/$kind-empty")" = \
      e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ]
  done
}

@test "citations and absolute diff paths must match the validated ledger layout" {
  for mutation in \
    '.candidates[0].citation.ledger_path="other-ledger.jsonl"' \
    '.candidates[0].citation.line=99' \
    '.index.source_layout_digest="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'; do
    jq "$mutation" "$QUERY" >"$BATS_TEST_TMPDIR/bad-layout-query"
    run python3 "$QUARTET_ROOT/agents/release/memory-review.py" prepare \
      --project "$P" --query-file "$BATS_TEST_TMPDIR/bad-layout-query" \
      --diff-file "$BATS_TEST_TMPDIR/diff" --base base --diff-mode branch \
      --config "$P/.agents/config.toml" --gates "$P/.agents/gates.md" \
      --harness claude --model review-v1 --provider local-test \
      --output "$BATS_TEST_TMPDIR/rejected-layout"
    [ "$status" -eq 2 ]
  done

  printf '%s\n' 'diff --git a/src/state.ts b/src/state.ts' \
    '--- /outside/project/state.ts' '+++ /dev/null' '@@ -1 +0,0 @@' '-old' \
    >"$BATS_TEST_TMPDIR/outside-diff"
  python3 "$QUARTET_ROOT/agents/lib/rules-memory.py" query --project "$P" \
    --diff-file "$BATS_TEST_TMPDIR/outside-diff" >"$BATS_TEST_TMPDIR/outside-query"
  run python3 "$QUARTET_ROOT/agents/release/memory-review.py" prepare \
    --project "$P" --query-file "$BATS_TEST_TMPDIR/outside-query" \
    --diff-file "$BATS_TEST_TMPDIR/outside-diff" --base base --diff-mode branch \
    --config "$P/.agents/config.toml" --gates "$P/.agents/gates.md" \
    --harness claude --model review-v1 --provider local-test \
    --output "$BATS_TEST_TMPDIR/outside-context"
  [ "$status" -eq 2 ]
  [ ! -e "$BATS_TEST_TMPDIR/outside-context" ]
}

@test "degradation is explicit and cannot satisfy cache validation" {
  python3 "$QUARTET_ROOT/agents/release/memory-review.py" degraded \
    --context "$CONTEXT" --receipt "$RECEIPT" \
    --code malformed_reviewer_output --message 'strict parser rejected output'
  jq -e '.state=="degraded" and .coverage=="incomplete"
    and .error.code=="malformed_reviewer_output"
    and .delivery.status=="not_delivered"' "$RECEIPT" >/dev/null
  : >"$FINDINGS"
  run python3 "$QUARTET_ROOT/agents/release/memory-review.py" validate-cache \
    --context "$CONTEXT" --receipt "$RECEIPT" --findings "$FINDINGS"
  [ "$status" -eq 1 ]

  jq '.response_digest="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    | .reviewed_at="2026-08-27T12:31:01Z"' "$RECEIPT" \
    >"$BATS_TEST_TMPDIR/impossible-hybrid-receipt"
  run python3 - "$QUARTET_ROOT/agents/lib/rules-memory.py" \
    "$BATS_TEST_TMPDIR/impossible-hybrid-receipt" <<'PY'
import importlib.util,json,sys
spec=importlib.util.spec_from_file_location("rules_memory",sys.argv[1])
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
with open(sys.argv[2],encoding="utf-8") as handle:
    receipt=json.load(handle)
raise SystemExit(0 if not module.validate_receipt_schema(receipt) else 1)
PY
  [ "$status" -eq 0 ]
}

@test "required memory mode arms the existing required-feedback stop path" {
  run bash -c '. "$1/agents/release/critic-stop-gate-lib.sh";
    QUARTET_DIR="$1" csg_read_required_feedback "$2";
    printf "%s" "$CSG_REQUIRE_FEEDBACK"' _ "$QUARTET_ROOT" "$P"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
}
