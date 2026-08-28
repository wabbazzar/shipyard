#!/usr/bin/env bats
# tests/memory-retrieval.bats — deterministic Phase-2 hybrid memory retrieval.

setup() {
  load helpers
  quartet_setup
  quartet_memory_cache_setup
}

SH="skills/shipyard/shipyard.sh"
HELPER="agents/lib/rules-memory.py"
run_shipyard() { QUARTET_DIR="$QUARTET_ROOT" bash "$QUARTET_ROOT/$SH" "$@"; }

enable_memory() {
  local project="$1" extra="${2:-}"
  printf '\n[memory]\nmode = "required"\nledger = ".agents/rules-ledger.jsonl"\n%s' \
    "$extra" >>"$project/.agents/config.toml"
  : >"$project/.agents/rules-ledger.jsonl"
}

record() {
  python3 - "$@" <<'PY'
import json, sys

record_id, summary, mechanism, rule, path, symbol = sys.argv[1:]
associations = {"tags": [record_id.lower()]}
if path != "-":
    associations["paths"] = [path]
if symbol != "-":
    associations["symbols"] = [symbol]
print(json.dumps({
    "schema_version": 1,
    "id": record_id,
    "occurred_at": "2026-08-27T12:30:00Z",
    "kind": "regression",
    "severity": "block" if record_id != "TEXT-ONLY" else "warn",
    "status": "active",
    "summary": summary,
    "mechanism": mechanism,
    "rule": rule,
    "required_evidence": "Run a deterministic regression test for this mechanism.",
    "associations": associations,
    "remediation": "Make the guarded transition atomic and verify the observed version.",
    "sources": [{"kind": "ticket", "ref": f"docs/tickets/{record_id}.md"}],
}, sort_keys=True, separators=(",", ":")))
PY
}

golden_ledger() {
  local ledger="$1"
  record RACE-EXACT \
    "A release receipt was overwritten." \
    "A check and later write raced with another publisher." \
    "Use one atomic compare-and-publish transition." \
    "agents/release/critic-watch.sh" "publish_receipt" >"$ledger"
  record TEXT-ONLY \
    "Lease epoch fencing rejected a stale writer." \
    "The stale writer retained an obsolete epoch lease." \
    "Fence every write with the current lease epoch." \
    "services/lease.py" "fence_epoch" >>"$ledger"
  record VECTOR-RENAMED \
    "Synchronize concurrent publication with versioned compare exchange." \
    "Conditional publication was not serialized against competing publishers." \
    "Version every publication and compare exchange the observed value." \
    "lib/state.py" "conditional_publish" >>"$ledger"
  record UNRELATED \
    "A stylesheet used an inaccessible contrast ratio." \
    "Foreground and background colors were too similar." \
    "Check visual contrast in the rendered dashboard." \
    "docs/styles.css" "render_theme" >>"$ledger"
}

@test "hybrid query returns stable schema-v1 ranking citations and channel explanations" {
  P="$(make_fixture_project memory-hybrid)"
  enable_memory "$P"
  golden_ledger "$P/.agents/rules-ledger.jsonl"
  D="$BATS_TEST_TMPDIR/change.diff"
  printf '%s\n' \
    'diff --git a/agents/release/critic-watch.sh b/agents/release/critic-watch.sh' \
    '--- a/agents/release/critic-watch.sh' \
    '+++ b/agents/release/critic-watch.sh' \
    '@@ -1 +1 @@' \
    '-publish_receipt "$old"' \
    '+publish_receipt "$new" # synchronized concurrently publishing by version comparison exchanging' >"$D"

  run run_shipyard memory query --project "$P" --diff-file "$D"
  [ "$status" -eq 0 ]
  first="$output"
  run python3 -c 'import json,sys
d=json.load(sys.stdin)
assert d["schema_version"] == 1 and d["command"] == "query" and d["valid"]
assert d["query_input"]["kind"] == "diff" and len(d["query_input"]["digest"]) == 64
assert d["index"]["vector_backend"] == "stdlib-hash-ngram-v1"
assert d["index"]["normalizer_version"] == "rules-memory-document-v1"
assert d["index"]["rebuilt"] is True
assert d["candidates"][0]["id"] == "RACE-EXACT", [x["id"] for x in d["candidates"]]
exact=d["candidates"][0]
assert exact["citation"]["ledger_path"] == ".agents/rules-ledger.jsonl"
assert exact["citation"]["line"] == 1 and exact["citation"]["sources"][0]["kind"] == "ticket"
assert exact["channels"]["exact"]["matches"]
assert "fts" in exact["channels"] and "vector" in exact["channels"]
vector=next(x for x in d["candidates"] if x["id"] == "VECTOR-RENAMED")
assert "vector" in vector["channels"]
assert set(vector["excerpt"]) == {"mechanism","remediation","required_evidence","rule","summary"}
assert d["limits"] == {"max_channel_candidates":20,"max_fused_candidates":12,"max_prompt_records":8}' <<<"$first"
  [ "$status" -eq 0 ]

  run run_shipyard memory query --project "$P" --diff-file "$D"
  [ "$status" -eq 0 ]
  run python3 -c 'import json,sys
a=json.loads(sys.argv[1]); b=json.load(sys.stdin)
assert b["index"]["rebuilt"] is False
assert [(x["id"],x["fused_score"],x["channels"]) for x in a["candidates"]] == [(x["id"],x["fused_score"],x["channels"]) for x in b["candidates"]]' "$first" <<<"$output"
  [ "$status" -eq 0 ]
}

@test "pure Python BM25 fallback and configured candidate limits are deterministic" {
  P="$(make_fixture_project memory-bm25)"
  enable_memory "$P" $'vector_backend = "stdlib-hash-ngram-v1"\nmax_channel_candidates = 2\nmax_fused_candidates = 3\nmax_prompt_records = 2\n'
  golden_ledger "$P/.agents/rules-ledger.jsonl"
  S="$BATS_TEST_TMPDIR/scope.txt"
  printf 'lease epoch fencing stale writer obsolete lease\n' >"$S"

  run env SHIPYARD_MEMORY_DISABLE_FTS5=1 QUARTET_DIR="$QUARTET_ROOT" \
    bash "$QUARTET_ROOT/$SH" memory query --project "$P" --scope-file "$S"
  [ "$status" -eq 0 ]
  run python3 -c 'import json,sys
d=json.load(sys.stdin)
assert d["index"]["fts_backend"] == "python-bm25-v1"
assert len(d["candidates"]) <= 3
text=next(x for x in d["candidates"] if x["id"] == "TEXT-ONLY")
assert text["channels"]["fts"]["backend"] == "python-bm25-v1"
assert text["channels"]["fts"]["terms"][:2] == sorted(text["channels"]["fts"]["terms"])[:2]
assert d["limits"]["max_prompt_records"] == 2' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "query input is descriptor-bound regular UTF-8 text with a hard size limit" {
  P="$(make_fixture_project memory-input)"
  enable_memory "$P"
  golden_ledger "$P/.agents/rules-ledger.jsonl"
  printf 'safe scope\n' >"$BATS_TEST_TMPDIR/real-scope"
  ln -s real-scope "$BATS_TEST_TMPDIR/scope-link"

  run run_shipyard memory query --project "$P" --scope-file "$BATS_TEST_TMPDIR/scope-link"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"code":"query_input_symlink"'* ]]

  mkfifo "$BATS_TEST_TMPDIR/scope-fifo"
  run run_shipyard memory query --project "$P" --scope-file "$BATS_TEST_TMPDIR/scope-fifo"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"code":"query_input_not_regular"'* ]]

  python3 - "$BATS_TEST_TMPDIR/scope-large" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(b"x" * (4 * 1024 * 1024 + 1))
PY
  run run_shipyard memory query --project "$P" --scope-file "$BATS_TEST_TMPDIR/scope-large"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"code":"query_input_too_large"'* ]]

  printf '\377\376\n' >"$BATS_TEST_TMPDIR/scope-binary"
  run run_shipyard memory query --project "$P" --scope-file "$BATS_TEST_TMPDIR/scope-binary"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"code":"query_input_utf8"'* ]]
}

@test "cache is outside worktree and rebuilds after ledger model or corruption mismatch" {
  P="$(make_fixture_project memory-cache)"
  enable_memory "$P"
  golden_ledger "$P/.agents/rules-ledger.jsonl"
  S="$BATS_TEST_TMPDIR/cache-scope"; printf 'lease epoch stale writer\n' >"$S"

  run run_shipyard memory query --project "$P" --scope-file "$S"
  [ "$status" -eq 0 ]
  one="$output"
  CACHE_KEY="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["index"]["cache_key"])' <<<"$one")"
  INDEX_DIGEST="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["index"]["digest"])' <<<"$one")"
  INDEX="$XDG_CACHE_HOME/shipyard/memory/$CACHE_KEY/index-$INDEX_DIGEST.sqlite3"
  [ -f "$INDEX" ]
  case "$INDEX" in "$P"/*) false ;; esac
  [ ! -e "$P/.agents/memory" ]

  record NEW-RULE "A newer stale lease recurred." "A stale epoch wrote state." \
    "Reject obsolete epochs before write." "lib/new.py" "write_epoch" >>"$P/.agents/rules-ledger.jsonl"
  run run_shipyard memory query --project "$P" --scope-file "$S"
  [ "$status" -eq 0 ]
  two="$output"
  run python3 -c 'import json,sys
a=json.loads(sys.argv[1]); b=json.load(sys.stdin)
assert b["index"]["rebuilt"] is True
assert a["ledger_digest"] != b["ledger_digest"] and a["index"]["digest"] != b["index"]["digest"]' "$one" <<<"$two"
  [ "$status" -eq 0 ]
  INDEX_DIGEST="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["index"]["digest"])' <<<"$two")"
  INDEX="$XDG_CACHE_HOME/shipyard/memory/$CACHE_KEY/index-$INDEX_DIGEST.sqlite3"

  printf 'partial-not-sqlite\n' >"$INDEX"
  printf 'orphan\n' >"$(dirname "$INDEX")/.index-partial"
  run run_shipyard memory query --project "$P" --scope-file "$S"
  [ "$status" -eq 0 ]
  run python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["index"]["rebuilt"] is True and d["candidates"]' <<<"$output"
  [ "$status" -eq 0 ]
  run python3 - "$INDEX" <<'PY'
import sqlite3, sys
db=sqlite3.connect(sys.argv[1])
db.execute("update metadata set value='wrong-model' where key='vector_backend'")
db.commit(); db.close()
PY
  [ "$status" -eq 0 ]
  run run_shipyard memory query --project "$P" --scope-file "$S"
  [ "$status" -eq 0 ]
  run python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["index"]["rebuilt"] is True; assert d["index"]["vector_backend"] == "stdlib-hash-ngram-v1"' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "concurrent cold-cache builders publish one complete equivalent index" {
  P="$(make_fixture_project memory-concurrent)"
  enable_memory "$P"
  golden_ledger "$P/.agents/rules-ledger.jsonl"
  S="$BATS_TEST_TMPDIR/concurrent-scope"; printf 'atomic publish stale writer compare exchange\n' >"$S"
  OUT="$BATS_TEST_TMPDIR/parallel"; mkdir "$OUT"

  run bash -c '
    set -e
    for n in 1 2 3 4 5 6; do
      XDG_CACHE_HOME="$1" python3 -B "$2" query --project "$3" --scope-file "$4" >"$5/$n.json" &
    done
    wait
  ' _ "$XDG_CACHE_HOME" "$QUARTET_ROOT/$HELPER" "$P" "$S" "$OUT"
  [ "$status" -eq 0 ]
  run python3 - "$OUT" "$XDG_CACHE_HOME" <<'PY'
from pathlib import Path
import json, sqlite3, sys
docs=[json.loads(path.read_text()) for path in sorted(Path(sys.argv[1]).glob("*.json"))]
assert len(docs) == 6
assert all(doc["valid"] and doc["state"] == "ready" for doc in docs)
assert len({doc["index"]["digest"] for doc in docs}) == 1
assert len({tuple(item["id"] for item in doc["candidates"]) for doc in docs}) == 1
assert sum(bool(doc["index"]["rebuilt"]) for doc in docs) == 1
index=Path(sys.argv[2]) / "shipyard" / "memory" / docs[0]["index"]["cache_key"] / f"index-{docs[0]['index']['digest']}.sqlite3"
db=sqlite3.connect(f"file:{index}?mode=ro", uri=True)
assert db.execute("pragma quick_check").fetchone()[0] == "ok"
assert db.execute("select count(*) from records").fetchone()[0] == 4
db.close()
assert not list(index.parent.glob("*.tmp-*"))
PY
  [ "$status" -eq 0 ]
}

@test "ledger source layout and every cached row are cryptographically bound" {
  P="$(make_fixture_project memory-layout)"
  enable_memory "$P"
  golden_ledger "$P/.agents/rules-ledger.jsonl"
  S="$BATS_TEST_TMPDIR/layout-scope"; printf 'publish_receipt agents/release/critic-watch.sh\n' >"$S"

  run run_shipyard memory query --project "$P" --scope-file "$S"
  [ "$status" -eq 0 ]
  first="$output"
  KEY="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["index"]["cache_key"])' <<<"$first")"
  DIGEST="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["index"]["digest"])' <<<"$first")"
  INDEX="$XDG_CACHE_HOME/shipyard/memory/$KEY/index-$DIGEST.sqlite3"

  run python3 - "$INDEX" <<'PY'
import sqlite3, sys
db=sqlite3.connect(sys.argv[1])
db.execute("update records set document='valid sqlite but falsified retrieval document' where id='RACE-EXACT'")
db.commit(); db.close()
PY
  [ "$status" -eq 0 ]
  run run_shipyard memory query --project "$P" --scope-file "$S"
  [ "$status" -eq 0 ]
  repaired="$output"
  run python3 -c 'import json,sys
d=json.load(sys.stdin); assert d["index"]["rebuilt"] is True
r=next(x for x in d["candidates"] if x["id"]=="RACE-EXACT")
assert r["citation"]["line"] == 1' <<<"$repaired"
  [ "$status" -eq 0 ]

  python3 - "$P/.agents/rules-ledger.jsonl" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); lines=p.read_bytes().splitlines(keepends=True)
p.write_bytes(b"".join(lines[1:] + lines[:1]))
PY
  run run_shipyard memory query --project "$P" --scope-file "$S"
  [ "$status" -eq 0 ]
  run python3 -c 'import json,sys
a=json.loads(sys.argv[1]); b=json.load(sys.stdin)
assert a["ledger_digest"] == b["ledger_digest"]
assert a["index"]["source_layout_digest"] != b["index"]["source_layout_digest"]
assert a["index"]["digest"] != b["index"]["digest"] and b["index"]["rebuilt"] is True
r=next(x for x in b["candidates"] if x["id"]=="RACE-EXACT")
assert r["citation"]["line"] == 4' "$repaired" <<<"$output"
  [ "$status" -eq 0 ]
}

@test "different validated ledger digests publish and query immutable separate artifacts" {
  P="$(make_fixture_project memory-cross-digest)"
  enable_memory "$P"
  golden_ledger "$P/.agents/rules-ledger.jsonl"

  run python3 -B - "$QUARTET_ROOT/$HELPER" "$P" <<'PY'
from concurrent.futures import ThreadPoolExecutor
import hashlib, importlib.util, json, os
from pathlib import Path
import sys

helper, root = Path(sys.argv[1]), Path(sys.argv[2]).resolve()
spec=importlib.util.spec_from_file_location("rules_memory_cross_digest", helper)
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
base=[json.loads(line) for line in (root/".agents/rules-ledger.jsonl").read_text().splitlines()]
variant=base + [{**base[0], "id":"NEW-DIGEST", "summary":"A separate immutable snapshot."}]

def snapshot(values):
    raw=[json.dumps(v,sort_keys=True,separators=(",",":" )).encode()+b"\n" for v in values]
    records=m.ValidatedRecords(values,{v["id"]:i+1 for i,v in enumerate(values)},
                               {v["id"]:raw[i] for i,v in enumerate(values)},b"".join(raw))
    canonical=b"".join(json.dumps(v,sort_keys=True,separators=(",",":")).encode()+b"\n" for v in sorted(values,key=lambda x:x["id"]))
    return records,hashlib.sha256(canonical).hexdigest(),hashlib.sha256(records.ledger_bytes).hexdigest()

def build(values):
    records,ledger,layout=snapshot(values)
    docs=m.normalized_records(records,".agents/rules-ledger.jsonl")
    path,connection,metadata,rebuilt,key=m.ensure_index(root,ledger,layout,docs)
    ids=[row[0] for row in connection.execute("select id from records order by id")]
    connection.close()
    return path.name,metadata["ledger_digest"],metadata["index_digest"],ids

with ThreadPoolExecutor(max_workers=2) as pool:
    results=list(pool.map(build,(base,variant)))
assert results[0][0] != results[1][0]
assert results[0][1] != results[1][1] and results[0][2] != results[1][2]
assert "NEW-DIGEST" not in results[0][3] and "NEW-DIGEST" in results[1][3]
assert all((Path(os.environ["XDG_CACHE_HOME"])/"shipyard"/"memory"/m.project_cache_identity(root)/name).is_file() for name,_,_,_ in results)
PY
  [ "$status" -eq 0 ]
}

@test "cache rejects worktree and symlink roots and repairs only marked private nodes" {
  fixture_project="$(make_fixture_project memory-cache-safety)"
  P="$MEMORY_CACHE_TEST_ROOT/project"
  mv "$fixture_project" "$P"
  chmod 0700 "$P" "$P/.agents"
  enable_memory "$P"
  golden_ledger "$P/.agents/rules-ledger.jsonl"
  S="$BATS_TEST_TMPDIR/safety-scope"; printf 'stale writer\n' >"$S"

  run env XDG_CACHE_HOME="$P/.agents/cache" QUARTET_DIR="$QUARTET_ROOT" \
    bash "$QUARTET_ROOT/$SH" memory query --project "$P" --scope-file "$S"
  [ "$status" -eq 2 ]
  [[ "$output" == *'cache root must be outside'* ]]

  mkdir "$MEMORY_CACHE_TEST_ROOT/real-cache"
  ln -s "$MEMORY_CACHE_TEST_ROOT/real-cache" "$MEMORY_CACHE_TEST_ROOT/cache-link"
  run env XDG_CACHE_HOME="$MEMORY_CACHE_TEST_ROOT/cache-link/child" QUARTET_DIR="$QUARTET_ROOT" \
    bash "$QUARTET_ROOT/$SH" memory query --project "$P" --scope-file "$S"
  [ "$status" -eq 2 ]
  [[ "$output" == *'symlink component'* ]]

  run run_shipyard memory query --project "$P" --scope-file "$S"
  [ "$status" -eq 0 ]
  KEY="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["index"]["cache_key"])' <<<"$output")"
  DIGEST="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["index"]["digest"])' <<<"$output")"
  DIR="$XDG_CACHE_HOME/shipyard/memory/$KEY"; INDEX="$DIR/index-$DIGEST.sqlite3"
  chmod 0777 "$XDG_CACHE_HOME/shipyard" "$XDG_CACHE_HOME/shipyard/memory" "$DIR"
  chmod 0666 "$INDEX"
  run run_shipyard memory query --project "$P" --scope-file "$S"
  [ "$status" -eq 0 ]
  repaired="$output"
  run python3 - "$XDG_CACHE_HOME/shipyard" "$XDG_CACHE_HOME/shipyard/memory" "$DIR" "$INDEX" <<'PY'
from pathlib import Path
import stat,sys
for path, expected in ((Path(sys.argv[1]),0o700),(Path(sys.argv[2]),0o700),(Path(sys.argv[3]),0o700),(Path(sys.argv[4]),0o600)):
    assert stat.S_IMODE(path.stat().st_mode) == expected, (path,oct(stat.S_IMODE(path.stat().st_mode)))
PY
  [ "$status" -eq 0 ]
  run python3 -c 'import json,sys; assert json.load(sys.stdin)["index"]["rebuilt"] is True' <<<"$repaired"
  [ "$status" -eq 0 ]
}

@test "foreign non-root cache symlinks and writable caller roots fail without repair" {
  P="$(make_fixture_project memory-cache-owner)"
  enable_memory "$P"
  golden_ledger "$P/.agents/rules-ledger.jsonl"
  S="$BATS_TEST_TMPDIR/owner-scope"; printf 'stale writer\n' >"$S"

  BAD="$MEMORY_CACHE_TEST_ROOT/writable-xdg"; mkdir "$BAD"; chmod 0777 "$BAD"
  run env XDG_CACHE_HOME="$BAD" QUARTET_DIR="$QUARTET_ROOT" \
    bash "$QUARTET_ROOT/$SH" memory query --project "$P" --scope-file "$S"
  [ "$status" -eq 2 ]
  [[ "$output" == *'must not be group/world-writable'* ]]
  [ "$(stat -c '%a' "$BAD" 2>/dev/null || stat -f '%Lp' "$BAD")" = "777" ]

  UNMARKED="$MEMORY_CACHE_TEST_ROOT/unmarked-xdg"; mkdir -p "$UNMARKED/shipyard"; chmod 0700 "$UNMARKED"; chmod 0777 "$UNMARKED/shipyard"
  run env XDG_CACHE_HOME="$UNMARKED" QUARTET_DIR="$QUARTET_ROOT" \
    bash "$QUARTET_ROOT/$SH" memory query --project "$P" --scope-file "$S"
  [ "$status" -eq 2 ]
  [[ "$output" == *'unmarked Shipyard cache root is group/world-writable'* ]]
  [ "$(stat -c '%a' "$UNMARKED/shipyard" 2>/dev/null || stat -f '%Lp' "$UNMARKED/shipyard")" = "777" ]

  mkdir "$MEMORY_CACHE_TEST_ROOT/foreign-target"
  ln -s "$MEMORY_CACHE_TEST_ROOT/foreign-target" "$MEMORY_CACHE_TEST_ROOT/foreign-link"
  run python3 -B - "$QUARTET_ROOT/$HELPER" "$MEMORY_CACHE_TEST_ROOT/foreign-link/child" <<'PY'
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import os, stat, sys
spec=importlib.util.spec_from_file_location("rules_memory_foreign_symlink", Path(sys.argv[1]))
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
target=Path(sys.argv[2]).absolute(); link=target.parent
real_lstat=m.Path.lstat
def foreign_lstat(path):
    value=real_lstat(path)
    if path == link:
        return SimpleNamespace(st_mode=value.st_mode, st_uid=os.getuid()+1000)
    return value
m.Path.lstat=foreign_lstat
try:
    m.reject_symlink_components(target)
except OSError as exc:
    assert "symlink component" in str(exc)
else:
    raise AssertionError("foreign non-root-owned symlink was accepted")
PY
  [ "$status" -eq 0 ]
}

@test "writable ancestors and active marked-subtree replacement fail closed" {
  P="$(make_fixture_project memory-cache-swap)"
  enable_memory "$P"
  golden_ledger "$P/.agents/rules-ledger.jsonl"
  S="$BATS_TEST_TMPDIR/swap-scope"; printf 'stale writer\n' >"$S"

  PARENT="$MEMORY_CACHE_TEST_ROOT/writable-parent"; BASE="$PARENT/private-base"
  mkdir -p "$BASE"; chmod 0777 "$PARENT"; chmod 0700 "$BASE"
  run env XDG_CACHE_HOME="$BASE" QUARTET_DIR="$QUARTET_ROOT" \
    bash "$QUARTET_ROOT/$SH" memory query --project "$P" --scope-file "$S"
  [ "$status" -eq 2 ]
  [[ "$output" == *'non-sticky writable directory'* ]]

  run run_shipyard memory query --project "$P" --scope-file "$S"
  [ "$status" -eq 0 ]
  SHIPYARD_ROOT="$XDG_CACHE_HOME/shipyard"
  chmod 0777 "$SHIPYARD_ROOT"
  run python3 -B - "$QUARTET_ROOT/$HELPER" "$SHIPYARD_ROOT" <<'PY'
import importlib.util
from pathlib import Path
import os, sys
helper, root = Path(sys.argv[1]), Path(sys.argv[2])
spec=importlib.util.spec_from_file_location("rules_memory_subtree_swap", helper)
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
real_fchmod=m.os.fchmod
displaced=root.with_name("shipyard-displaced")
def swapping_fchmod(descriptor, mode):
    os.rename(root, displaced)
    os.mkdir(root, 0o700)
    real_fchmod(descriptor, mode)
m.os.fchmod=swapping_fchmod
try:
    m.privatize_marked_shipyard_root(root)
except OSError as exc:
    assert "changed while being privatized" in str(exc), exc
else:
    raise AssertionError("active Shipyard subtree replacement was accepted")
PY
  [ "$status" -eq 0 ]
}
