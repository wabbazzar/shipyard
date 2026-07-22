#!/bin/bash
# agents/lib/mentat-proposal.sh — shared design-loop proposal writer.
#
# The design runner (mentat) drafts proposals nightly from an LLM reply and
# merges them into <project>/<result_dir>/<project>-<designdisplay>-result.json.
# Medic (D-L15) writes an IMMEDIATE incident-repair proposal into the SAME
# file, deterministically (no model spend). To keep the schema + merge
# semantics identical across both writers, the deterministic single-proposal
# merge lives here.
#
# Proposal schema (one object in the result file's `proposals` array):
#   {id:"mentat:<project>:<8hex sha256(ts+title)>", type, title, rationale,
#    evidence, suggested_scope, severity, status:"open"}
# Result file shape: {ts, project, proposals:[...]}.

# mentat_merge_proposal <result_file> <project> <ts> <proposal_json>
#
# <proposal_json> is a compact JSON object supplying at least `title`; the
# recognized fields are type/title/rationale/evidence/suggested_scope/severity.
# Dedup is by title against proposals already in the result file. On a NEW
# proposal the merged file is (re)written and the assigned id is printed on
# stdout. On a duplicate (title already present) nothing is written and stdout
# is EMPTY. Exit non-zero only on a malformed proposal (no usable title).
mentat_merge_proposal() {
  local result_file="$1" project="$2" ts="$3" proposal_json="$4"
  RESULT_FILE="$result_file" PROJECT_NAME="$project" TS="$ts" PROPOSAL="$proposal_json" \
  python3 - <<'PY'
import os, sys, json, hashlib

result_file = os.environ["RESULT_FILE"]
project     = os.environ["PROJECT_NAME"]
ts          = os.environ["TS"]
try:
    incoming = json.loads(os.environ.get("PROPOSAL", ""))
except Exception:
    sys.exit(1)
if not isinstance(incoming, dict):
    sys.exit(1)

title = str(incoming.get("title", "")).strip()
if not title:
    sys.exit(1)

existing = []
if os.path.exists(result_file):
    try:
        with open(result_file) as f:
            existing = (json.load(f) or {}).get("proposals", []) or []
    except Exception:
        existing = []
existing_titles = {p.get("title") for p in existing}

# Dedup by title — an identical proposal is already open. No write, no id.
if title in existing_titles:
    sys.exit(0)

pid = "mentat:%s:%s" % (
    project, hashlib.sha256((ts + title).encode()).hexdigest()[:8])
obj = {
    "id": pid,
    "type": str(incoming.get("type", "feature")),
    "title": title,
    "rationale": str(incoming.get("rationale", "")),
    "evidence": str(incoming.get("evidence", "")),
    "suggested_scope": str(incoming.get("suggested_scope", "")),
    "severity": str(incoming.get("severity", "med")),
    "status": "open",
}
merged = existing + [obj]
with open(result_file, "w") as f:
    json.dump({"ts": ts, "project": project, "proposals": merged}, f, indent=2)
sys.stdout.write(pid + "\n")
PY
}
