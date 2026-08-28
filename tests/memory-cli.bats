#!/usr/bin/env bats
# tests/memory-cli.bats — deterministic Phase-1 project rules-memory contract.

setup() {
  load helpers
  quartet_setup
}

SH="skills/shipyard/shipyard.sh"
run_shipyard() { QUARTET_DIR="$QUARTET_ROOT" bash "$QUARTET_ROOT/$SH" "$@"; }

enable_memory() {
  local project="$1" mode="${2:-advisory}"
  printf '\n[memory]\nmode = "%s"\nledger = ".agents/rules-ledger.jsonl"\n' \
    "$mode" >>"$project/.agents/config.toml"
  : >"$project/.agents/rules-ledger.jsonl"
}

valid_record() {
  local id="${1:-LT-361}" status="${2:-active}" supersedes="${3:-}"
  python3 - "$id" "$status" "$supersedes" <<'PY'
import json, sys

record = {
    "schema_version": 1,
    "id": sys.argv[1],
    "occurred_at": "2026-08-27T12:30:00Z",
    "kind": "regression",
    "severity": "block",
    "status": sys.argv[2],
    "summary": "A concurrent patch overwrote a newer state.",
    "mechanism": "Read-check-write occurred without one atomic transition.",
    "rule": "Use one atomic state transition for conditional updates.",
    "required_evidence": "Run a deterministic interleaving regression test.",
    "associations": {
        "paths": ["agents/release/*.sh"],
        "symbols": ["publish_receipt"],
        "subsystems": ["release"],
        "phases": ["shoulder-review"],
        "state_transitions": ["pending-to-delivered"],
        "error_signatures": ["stale receipt"],
        "technologies": ["bash"],
        "tags": ["race-condition"],
    },
    "remediation": "Serialize the transition and bind the write to its observed version.",
    "sources": [{"kind": "ticket", "ref": "docs/tickets/T61.md"}],
}
if sys.argv[3]:
    record["supersedes"] = sys.argv[3].split(",")
print(json.dumps(record, separators=(",", ":"), sort_keys=True))
PY
}

@test "unconfigured memory status is a stable off document and legacy status is unchanged" {
  P="$(make_fixture_project legacy-off)"
  run run_shipyard memory status --project "$P"
  [ "$status" -eq 0 ]
  run python3 -c 'import json,sys; d=json.load(sys.stdin); assert d == {
    "active_count":0,"command":"status","configured":False,"errors":[],
    "ledger_digest":None,"ledger_path":None,"mode":None,"project_root":__import__("os").path.realpath(sys.argv[1]),
    "record_count":0,"schema_version":1,"state":"off","superseded_count":0,
    "valid":True}' "$P" <<<"$output"
  [ "$status" -eq 0 ]

  run run_shipyard status --project "$P"
  [ "$status" -eq 3 ]
  [[ "$output" == *"no crew installed"* ]]
  [[ "$output" != *"memory:"* ]]
  [[ "$output" != *"rules-ledger"* ]]
}

@test "memory init adds the exact advisory config and empty tracked ledger idempotently" {
  P="$(make_fixture_project memory-init)"
  run run_shipyard memory init --project "$P"
  [ "$status" -eq 0 ]
  first="$output"
  [ -f "$P/.agents/rules-ledger.jsonl" ]
  [ ! -s "$P/.agents/rules-ledger.jsonl" ]
  run python3 - "$P/.agents/config.toml" <<'PY'
import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
assert d["memory"] == {"mode": "advisory", "ledger": ".agents/rules-ledger.jsonl"}
PY
  [ "$status" -eq 0 ]
  run run_shipyard memory init --project "$P"
  [ "$status" -eq 0 ]
  second="$output"
  [ "$(grep -c '^\[memory\]$' "$P/.agents/config.toml")" -eq 1 ]
  run python3 -c 'import json,sys; a=json.loads(sys.argv[1]); b=json.loads(sys.argv[2]);
assert a["changes"] == {"config_created":False,"ledger_created":True,"memory_table_added":True}
assert b["changes"] == {"config_created":False,"ledger_created":False,"memory_table_added":False}
assert b["state"] == "ready" and b["record_count"] == 0' "$first" "$second"
  [ "$status" -eq 0 ]
}

@test "validate accepts a complete record and emits stable counts and digest" {
  P="$(make_fixture_project memory-valid)"
  enable_memory "$P"
  valid_record >"$P/.agents/rules-ledger.jsonl"
  run run_shipyard memory validate --project "$P"
  [ "$status" -eq 0 ]
  run python3 -c 'import json,sys; d=json.load(sys.stdin);
assert d["schema_version"] == 1 and d["command"] == "validate"
assert d["state"] == "ready" and d["valid"] is True
assert (d["record_count"],d["active_count"],d["superseded_count"]) == (1,1,0)
assert len(d["ledger_digest"]) == 64 and d["errors"] == []' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "strict config rejects unknown memory keys and unsafe ledger paths" {
  P="$(make_fixture_project memory-bad-config)"
  printf '\n[memory]\nmode = "required"\nledger = "../escape.jsonl"\nhope = true\n' \
    >>"$P/.agents/config.toml"
  run run_shipyard memory validate --project "$P"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"code":"config_unknown_key"'* ]]
  [[ "$output" == *'"code":"unsafe_ledger_path"'* ]]
}

@test "validator rejects malformed JSON duplicate IDs unknown keys and unsafe source paths" {
  P="$(make_fixture_project memory-invalid)"
  enable_memory "$P"
  valid_record LT-100 >"$P/.agents/rules-ledger.jsonl"
  valid_record LT-100 >>"$P/.agents/rules-ledger.jsonl"
  printf '{not-json}\n' >>"$P/.agents/rules-ledger.jsonl"
  valid_record LT-101 | python3 -c 'import json,sys; d=json.load(sys.stdin); d["extra"]=1; print(json.dumps(d))' \
    >>"$P/.agents/rules-ledger.jsonl"
  valid_record LT-102 | python3 -c 'import json,sys; d=json.load(sys.stdin); d["sources"]=[{"kind":"path","ref":"../customer.txt"}]; print(json.dumps(d))' \
    >>"$P/.agents/rules-ledger.jsonl"
  run run_shipyard memory validate --project "$P"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"code":"duplicate_id"'* ]]
  [[ "$output" == *'"code":"invalid_json"'* ]]
  [[ "$output" == *'"code":"unknown_key"'* ]]
  [[ "$output" == *'"code":"unsafe_source_path"'* ]]
  [[ "$output" == *'"line":2'* ]]
  [[ "$output" == *'"record_id":"LT-100"'* ]]
}

@test "validator enforces line and prose limits without truncation" {
  P="$(make_fixture_project memory-oversized)"
  enable_memory "$P"
  valid_record LT-200 | python3 -c 'import json,sys; d=json.load(sys.stdin); d["summary"]="x"*2049; print(json.dumps(d))' \
    >"$P/.agents/rules-ledger.jsonl"
  run run_shipyard memory validate --project "$P"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"code":"prose_too_long"'* ]]

  python3 - "$P/.agents/rules-ledger.jsonl" <<'PY'
from pathlib import Path
import json, sys
d={"schema_version":1,"id":"LT-201","padding":"x"*(256*1024)}
Path(sys.argv[1]).write_text(json.dumps(d)+"\n")
PY
  run run_shipyard memory validate --project "$P"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"code":"line_too_large"'* ]]
}

@test "supersession validation rejects missing self multiple-active and cyclic links" {
  P="$(make_fixture_project memory-supersession)"
  enable_memory "$P"
  valid_record LT-300 active LT-999 >"$P/.agents/rules-ledger.jsonl"
  valid_record LT-301 active LT-301 >>"$P/.agents/rules-ledger.jsonl"
  valid_record LT-302 active LT-304 >>"$P/.agents/rules-ledger.jsonl"
  valid_record LT-303 active LT-304 >>"$P/.agents/rules-ledger.jsonl"
  valid_record LT-304 superseded LT-302 >>"$P/.agents/rules-ledger.jsonl"
  run run_shipyard memory validate --project "$P"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"code":"missing_supersedes_target"'* ]]
  [[ "$output" == *'"code":"self_supersedes"'* ]]
  [[ "$output" == *'"code":"multiple_active_superseders"'* ]]
  [[ "$output" == *'"code":"supersession_cycle"'* ]]
}

@test "empty advisory and required ledgers are valid and query family parses exactly one input" {
  for mode in advisory required; do
    P="$(make_fixture_project memory-empty-$mode)"
    enable_memory "$P" "$mode"
    run run_shipyard memory status --project "$P"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"record_count":0'* ]]
    [[ "$output" == *'"state":"ready"'* ]]
  done

  S="$BATS_TEST_TMPDIR/scope.txt"; D="$BATS_TEST_TMPDIR/diff.txt"
  printf 'scope\n' >"$S"; printf 'diff\n' >"$D"
  run run_shipyard memory query --project "$P" --scope-file "$S"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"candidate_count":0'* ]]
  [[ "$output" == *'"state":"ready"'* ]]
  run run_shipyard memory query --project "$P" --scope-file "$S" --diff-file "$D"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"code":"query_input_count"'* ]]
  run run_shipyard memory query --project "$P"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"code":"query_input_count"'* ]]
}

@test "untrusted enum containers and boolean schema versions return diagnostics, not tracebacks" {
  P="$(make_fixture_project memory-enum-types)"
  printf '\n[memory]\nmode = ["required"]\n' >>"$P/.agents/config.toml"
  run run_shipyard memory validate --project "$P"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"code":"config_mode"'* ]]
  [[ "$output" != *"Traceback"* ]]

  fixture_replace_in_place "$P/.agents/config.toml" \
    '^mode = \["required"\]$' 'mode = "required"'
  : >"$P/.agents/rules-ledger.jsonl"
  valid_record LT-400 | python3 -c 'import json,sys; d=json.load(sys.stdin); d["schema_version"]=True; d["kind"]=[]; d["severity"]={}; d["status"]=[]; d["sources"][0]["kind"]=[]; print(json.dumps(d))' \
    >"$P/.agents/rules-ledger.jsonl"
  run run_shipyard memory validate --project "$P"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"code":"schema_version"'* ]]
  [[ "$output" == *'"code":"invalid_kind"'* ]]
  [[ "$output" == *'"code":"invalid_severity"'* ]]
  [[ "$output" == *'"code":"invalid_status"'* ]]
  [[ "$output" == *'"code":"invalid_source_kind"'* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "lone Unicode surrogates are rejected before canonical UTF-8 encoding" {
  P="$(make_fixture_project memory-surrogate)"
  enable_memory "$P"
  valid_record LT-401 | python3 -c 'import json,sys; d=json.load(sys.stdin); d["summary"]="\ud800"; print(json.dumps(d))' \
    >"$P/.agents/rules-ledger.jsonl"
  run run_shipyard memory validate --project "$P"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"code":"unicode_surrogate"'* ]]
  [[ "$output" != *"UnicodeEncodeError"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "configured ledger symlinks and non-regular files fail before opening" {
  P="$(make_fixture_project memory-file-types)"
  enable_memory "$P"
  mv "$P/.agents/rules-ledger.jsonl" "$P/.agents/real-ledger.jsonl"
  ln -s real-ledger.jsonl "$P/.agents/rules-ledger.jsonl"
  run run_shipyard memory validate --project "$P"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"code":"ledger_symlink"'* ]]

  rm "$P/.agents/rules-ledger.jsonl"
  mkfifo "$P/.agents/rules-ledger.jsonl"
  run run_shipyard memory validate --project "$P"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"code":"ledger_not_regular"'* ]]
}

@test "ledger content screening matches every existing leak-check signature" {
  P="$(make_fixture_project memory-leak-parity)"
  enable_memory "$P"
  python3 - >"$P/.agents/rules-ledger.jsonl" <<'PY'
import json

signatures = [
    "+1" + "3125550199",
    "/home/" + "alice",
    "person" + "@" + "gmail" + ".com",
    "private-host" + ".ts" + ".net",
    "sk-ant-" + "A" * 8,
    "sk-" + "A" * 32,
    "ghp_" + "A" * 20,
    "AKIA" + "A" * 16,
    "xoxb-" + "A" * 10,
    "-----BEGIN " + "PRIVATE KEY-----",
    "sourceUuid=" +
    "12345678-1234-1234-1234-123456789abc",
]
for index, signature in enumerate(signatures):
    record = {
        "schema_version": 1,
        "id": f"LEAK-{index}",
        "occurred_at": "2026-08-27T12:30:00Z",
        "kind": "incident",
        "severity": "block",
        "status": "active",
        "summary": signature,
        "mechanism": "Unsafe content entered a tracked engineering record.",
        "rule": "Keep sensitive content outside the engineering ledger.",
        "required_evidence": "Run the project content safety gate.",
        "associations": {},
        "remediation": "Replace sensitive content with aggregate evidence.",
        "sources": [{"kind": "ticket", "ref": f"SAFE-{index}"}],
    }
    print(json.dumps(record, sort_keys=True))
PY
  run run_shipyard memory validate --project "$P"
  [ "$status" -eq 2 ]
  run python3 -c 'import json,sys; d=json.load(sys.stdin); errors=[e for e in d["errors"] if e["code"]=="secret_shaped_content"]; assert len(errors)==11, errors' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "ledger validation consumes the same descriptor after a pathname symlink swap" {
  P="$(make_fixture_project memory-descriptor)"
  enable_memory "$P"
  valid_record LT-500 >"$P/.agents/rules-ledger.jsonl"
  printf '{not-json}\n' >"$P/.agents/swapped-ledger.jsonl"
  ln -s swapped-ledger.jsonl "$P/.agents/swap-link"

  run python3 -B - "$QUARTET_ROOT/agents/lib/rules-memory.py" "$P" <<'PY'
import importlib.util
import os
from pathlib import Path
import sys

helper, project = Path(sys.argv[1]), Path(sys.argv[2]).resolve()
spec = importlib.util.spec_from_file_location("rules_memory_descriptor_test", helper)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

ledger = project / ".agents/rules-ledger.jsonl"
swap_link = project / ".agents/swap-link"
real_open = module.os.open
calls = []

def swapping_open(path, flags):
    descriptor = real_open(path, flags)
    calls.append((Path(path), flags))
    os.replace(swap_link, ledger)
    return descriptor

module.os.open = swapping_open
document, exit_code = module.inspect_project("validate", project)
assert len(calls) == 1, calls
assert calls[0][0] == ledger, calls
if getattr(os, "O_NOFOLLOW", 0):
    assert calls[0][1] & os.O_NOFOLLOW
assert ledger.is_symlink()
assert exit_code == 0, document
assert document["valid"] is True, document
assert document["record_count"] == 1, document
assert document["errors"] == [], document
PY
  [ "$status" -eq 0 ]
}
