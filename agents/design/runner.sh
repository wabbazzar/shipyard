#!/bin/bash
# agents/design/runner.sh — mentat, the design-loop agent (role id `design`).
#
# Nightly, per project: mine existing telemetry, draft <=3 evidence-backed
# proposals via `claude -p`, and record them for the ice dispatch to gate.
# Mentat DRAFTS ONLY — it never writes code, never touches the repo. The
# ONLY file it writes is its own result JSON under the project's tmp/.
#
# Usage:
#   runner.sh --project DIR [--mode design]   # draft proposals (default)
#   runner.sh --project DIR --check-config     # read-only effective config
#   runner.sh --project DIR --collect-only     # print telemetry summary only
#   runner.sh --self-test                      # hermetic self-check, exit 0/1
#
# Prompt = agents/design/role.md + <project>/.agents/gates.md (if present)
# + RUN CONTEXT (the collector summary + config). Result file:
# <project>/tmp/<project>-mentat-result.json, schema:
#   {ts, project, proposals:[{id,type,title,rationale,evidence,
#                             suggested_scope,severity,status:"open"}]}
# id = mentat:<project>:<8 hex of sha256(ts+title)>.
#
# Gates, in order, before any model spend:
#   * budget   — sum today's design.* event `tokens` vs
#                [design] budget_tokens_daily (default 1000000). At/over →
#                skip + design.proposal.skipped reason=budget.
#   * open cap — >= [design] max_open_proposals (default 3) UNDECIDED
#                proposals already open (in the result file, not yet in
#                <project>/data/decisions.jsonl) → skip drafting +
#                design.proposal.skipped reason=open_cap.
# Each NEW proposal emits one design.proposal.opened event.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUARTET_DIR="${QUARTET_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
LOG_EVENT="$QUARTET_DIR/agents/lib/log_event.sh"

export QUARTET_SOURCE="${QUARTET_SOURCE:-system}"

# ---------- argv ------------------------------------------------------------
PROJECT_DIR=""
MODE="design"
CHECK_CONFIG=0
COLLECT_ONLY=0
SELF_TEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project)      PROJECT_DIR="$2"; shift 2 ;;
    --mode)         MODE="$2"; shift 2 ;;
    --check-config) CHECK_CONFIG=1; shift ;;
    --collect-only) COLLECT_ONLY=1; shift ;;
    --self-test)    SELF_TEST=1; shift ;;
    -h|--help)      sed -n '2,40p' "$0"; exit 0 ;;
    *)              echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ===========================================================================
# --self-test: hermetic. Build a synthetic project with canned telemetry,
# stub `claude` on PATH to return 2 proposals, run design mode via a
# recursive invocation, and assert the result file + events + <=3 cap.
# Exits non-zero on any failure.
# ===========================================================================
if [ "$SELF_TEST" -eq 1 ]; then
  ST_TMP="$(mktemp -d)"
  trap 'rm -rf "$ST_TMP"' EXIT
  fail() { echo "self-test FAIL: $*" >&2; exit 1; }

  # synthetic project
  PROJ="$ST_TMP/proj/mentatself"
  mkdir -p "$PROJ/.agents" "$PROJ/tmp" "$PROJ/data"
  cat >"$PROJ/.agents/config.toml" <<'TOML'
project_name  = "mentatself"
project_owner = "self-test"
branch        = "main"
[paths]
result_dir = "tmp"
[design]
budget_tokens_daily = 1000000
max_open_proposals  = 3
[names]
design = "mentat"
TOML
  # canned telemetry the collectors will read
  ST_EVENTS="$ST_TMP/events"; mkdir -p "$ST_EVENTS"
  TODAY="$(date -u +%Y-%m-%d)"
  printf '%s\n' \
    '{"ts":"'"$TODAY"'T01:00:00Z","svc":"mentatself-guardian","event":"job.end","status":"fail","role":"release"}' \
    '{"ts":"'"$TODAY"'T02:00:00Z","svc":"mentatself-medic","event":"medic.incident.opened","role":"medic"}' \
    >"$ST_EVENTS/$TODAY.jsonl"
  printf '%s\n' '{"ts":"'"$TODAY"'T00:00:00Z","id":"fyi_1","text":"please add CSV export"}' \
    >"$PROJ/data/fyi-requests.jsonl"

  # source-5 window fixtures: one stale (40 days old, outside the 7-day
  # default window), one fresh (just written). Only the fresh one should
  # ever show up in collect_signals()'s sources.medic_incidents.
  echo '{"incident_id":"stale1","detected_at":"2026-01-01T00:00:00Z","reason":"old"}' \
    >"$PROJ/tmp/medic-incident-stale.json"
  touch -d "40 days ago" "$PROJ/tmp/medic-incident-stale.json"
  echo '{"incident_id":"fresh1","detected_at":"'"$TODAY"'T00:00:00Z","reason":"new"}' \
    >"$PROJ/tmp/medic-incident-fresh.json"

  COLLECT_JSON="$(QUARTET_DIR="$QUARTET_DIR" QUARTET_EVENTS_DIR="$ST_EVENTS" \
    bash "${BASH_SOURCE[0]}" --project "$PROJ" --collect-only)" \
    || fail "--collect-only exited non-zero"
  INC_COUNT="$(jq '.sources.medic_incidents.count' <<<"$COLLECT_JSON")"
  [ "$INC_COUNT" = "1" ] || fail "expected 1 in-window incident, got $INC_COUNT"
  jq -e '.sources.medic_incidents.examples | any(.file=="medic-incident-fresh.json")' \
    <<<"$COLLECT_JSON" >/dev/null || fail "fresh incident missing from summary"
  jq -e '.sources.medic_incidents.examples | all(.file!="medic-incident-stale.json")' \
    <<<"$COLLECT_JSON" >/dev/null || fail "stale incident leaked into summary"

  # stub claude on PATH: returns 2 proposals in the --output-format json shape
  ST_BIN="$ST_TMP/bin"; mkdir -p "$ST_BIN"
  cat >"$ST_BIN/claude" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"type":"result","result":"[{\"type\":\"feature\",\"title\":\"Add CSV export\",\"rationale\":\"users keep asking\",\"evidence\":\"fyi: please add CSV export\",\"suggested_scope\":\"export module\",\"severity\":\"med\"},{\"type\":\"bug\",\"title\":\"Fix nightly release failure\",\"rationale\":\"release keeps failing\",\"evidence\":\"job_fail=1 today\",\"suggested_scope\":\"CI\",\"severity\":\"high\"}]","usage":{"input_tokens":1000,"output_tokens":200}}
JSON
STUB
  chmod +x "$ST_BIN/claude"

  # run design mode against the fixture
  PATH="$ST_BIN:$PATH" QUARTET_DIR="$QUARTET_DIR" QUARTET_EVENTS_DIR="$ST_EVENTS" \
    bash "${BASH_SOURCE[0]}" --project "$PROJ" --mode design >/dev/null 2>&1 \
    || fail "runner exited non-zero"

  RF="$PROJ/tmp/mentatself-mentat-result.json"
  if [ ! -s "$RF" ]; then
    cat "$PROJ/tmp/"*last-run.log 2>/dev/null >&2 || true
    fail "no result file at $RF"
  fi
  jq -e . "$RF" >/dev/null 2>&1 || fail "result file is not valid JSON"
  NP="$(jq '.proposals | length' "$RF")"
  [ "$NP" = "2" ] || fail "expected 2 proposals, got $NP"
  [ "$NP" -le 3 ] || fail "cap violated: $NP > 3"
  jq -e '.proposals | all(.id and .status=="open" and .type and .severity)' "$RF" >/dev/null \
    || fail "proposal missing id/status/type/severity"
  jq -e '.proposals[0].id | startswith("mentat:mentatself:")' "$RF" >/dev/null \
    || fail "id prefix wrong"

  EF="$ST_EVENTS/$TODAY.jsonl"
  OPENED="$(jq -R 'fromjson?' <"$EF" | jq -s '[.[] | select(.event=="design.proposal.opened")] | length')"
  [ "$OPENED" = "2" ] || fail "expected 2 opened events, got $OPENED"
  ROLES_OK="$(jq -R 'fromjson?' <"$EF" | jq -s '[.[] | select(.event=="design.proposal.opened") | select(.role=="design")] | length')"
  [ "$ROLES_OK" = "2" ] || fail "opened events missing role:design"

  echo "self-test OK: 2 proposals written, 2 design.proposal.opened events, cap<=3 held, stale incident excluded"
  exit 0
fi

[ -z "$PROJECT_DIR" ] && { echo "--project required" >&2; exit 2; }
[ -d "$PROJECT_DIR" ] || { echo "project dir missing: $PROJECT_DIR" >&2; exit 2; }

CONFIG_FILE="$PROJECT_DIR/.agents/config.toml"
ROLE_FILE="$SCRIPT_DIR/role.md"
COLLECTORS="$SCRIPT_DIR/collectors.sh"
[ -f "$CONFIG_FILE" ] || { echo "config not found: $CONFIG_FILE" >&2; exit 2; }
[ -f "$COLLECTORS" ]  || { echo "collectors.sh not found: $COLLECTORS" >&2; exit 2; }

# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/load-config.sh"
CFG_JSON="$(load_config_json "$CONFIG_FILE")" || \
  { echo "failed to parse $CONFIG_FILE" >&2; exit 2; }

PROJECT_NAME="$(jq -r '.project_name' <<<"$CFG_JSON")"

# Canonical role identity + resolved display name. `design` resolves to
# "design" with no [names] block, "mentat" under a spacetime theme.
ROLE="design"
export QUARTET_ROLE="$ROLE"
# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/naming.sh"
DISPLAY="$(role_display "$ROLE" "$CFG_JSON")"
SVC="$PROJECT_NAME-$DISPLAY"

RESULT_DIR_REL="$(jq -r '.paths.result_dir // "tmp"' <<<"$CFG_JSON")"
BUDGET_TOKENS="$(jq -r '.design.budget_tokens_daily // 1000000' <<<"$CFG_JSON")"
MAX_OPEN="$(jq -r '.design.max_open_proposals // 3' <<<"$CFG_JSON")"
[[ "$BUDGET_TOKENS" =~ ^[0-9]+$ ]] || BUDGET_TOKENS=1000000
[[ "$MAX_OPEN" =~ ^[0-9]+$ ]] || MAX_OPEN=3

EVENTS_DIR="${QUARTET_EVENTS_DIR:-$QUARTET_DIR/data/events}"

# ---------- --check-config: read-only, no side effects ----------------------
if [ "$CHECK_CONFIG" -eq 1 ]; then
  # shellcheck disable=SC1091
  source "$QUARTET_DIR/agents/lib/detect-trunk.sh"
  TRUNK_BRANCH="$(detect_trunk "$CFG_JSON" "$PROJECT_DIR" 2>/dev/null)" || TRUNK_BRANCH=""
  jq -n \
    --arg agent "$ROLE" \
    --arg role "$ROLE" \
    --arg display "$DISPLAY" \
    --arg dir "$PROJECT_DIR" \
    --arg trunk "$TRUNK_BRANCH" \
    --argjson budget "$BUDGET_TOKENS" \
    --argjson maxopen "$MAX_OPEN" \
    --argjson cfg "$CFG_JSON" \
    '{agent:$agent, role:$role, display:$display,
      project:$cfg.project_name, project_dir:$dir, trunk:$trunk,
      budget_tokens_daily:$budget, max_open_proposals:$maxopen}'
  exit 0
fi

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

emit_event() {
  # emit_event <event> [key=value ...]
  [ -x "$LOG_EVENT" ] || return 0
  QUARTET_EVENTS_DIR="$EVENTS_DIR" "$LOG_EVENT" "$SVC" "$@" || true
}

# tokens_used_today — sum today's design.* event `tokens` from EVENTS_DIR.
tokens_used_today() {
  local f
  f="$EVENTS_DIR/$(date -u +%Y-%m-%d).jsonl"
  [ -f "$f" ] || { echo 0; return; }
  jq -R 'fromjson?' <"$f" 2>/dev/null | \
    jq -s '[.[] | select((.event // "") | startswith("design.")) | (.tokens // 0)] | add // 0' \
    2>/dev/null || echo 0
}

# undecided_open_count — count proposals in the result file with
# status=="open" whose id is NOT present in <project>/data/decisions.jsonl.
undecided_open_count() {
  local result="$1" decisions="$2"
  [ -f "$result" ] || { echo 0; return; }
  local decided="[]"
  if [ -f "$decisions" ]; then
    decided="$(jq -R 'fromjson?' <"$decisions" 2>/dev/null | \
      jq -s '[.[] | (.proposal_id // empty)]' 2>/dev/null || echo '[]')"
  fi
  jq --argjson decided "$decided" \
    '[.proposals[]? | select(.status=="open")
      | select((.id) as $i | ($decided | index($i)) | not)] | length' \
    "$result" 2>/dev/null || echo 0
}

# ---------- --collect-only: print summary, no claude, no events -------------
if [ "$COLLECT_ONLY" -eq 1 ]; then
  QUARTET_DIR="$QUARTET_DIR" QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    bash "$COLLECTORS" --project "$PROJECT_DIR" --json
  exit $?
fi

# ---------- design mode -----------------------------------------------------
if [ "$MODE" != "design" ]; then
  echo "bad --mode: $MODE (only 'design')" >&2; exit 2
fi
[ -f "$ROLE_FILE" ] || { echo "role.md not found: $ROLE_FILE" >&2; exit 2; }

RESULT_DIR="$PROJECT_DIR/$RESULT_DIR_REL"
mkdir -p "$RESULT_DIR"
RESULT_FILE="$RESULT_DIR/$SVC-result.json"
LOG_FILE="$RESULT_DIR/$SVC-last-run.log"
DECISIONS_FILE="$PROJECT_DIR/data/decisions.jsonl"

JOB_START="$(date +%s)"
echo "[$SVC] $(now_iso) start mode=$MODE" > "$LOG_FILE"
emit_event job.start mode="$MODE" project="$PROJECT_NAME"

# --- collectors -------------------------------------------------------------
SUMMARY="$(QUARTET_DIR="$QUARTET_DIR" QUARTET_EVENTS_DIR="$EVENTS_DIR" \
  bash "$COLLECTORS" --project "$PROJECT_DIR" --json 2>>"$LOG_FILE")" || SUMMARY='{}'
echo "[$SVC] collectors done" >> "$LOG_FILE"

finish() {
  # finish <status> [k=v ...] — emit job.end and exit 0.
  local status="$1"; shift
  local dur=$(( $(date +%s) - JOB_START ))
  emit_event job.end mode="$MODE" status="$status" duration_s="$dur" "$@"
  echo "[$SVC] done status=$status" >> "$LOG_FILE"
  exit 0
}

# --- budget gate ------------------------------------------------------------
USED="$(tokens_used_today)"; [[ "$USED" =~ ^[0-9]+$ ]] || USED=0
if [ "$USED" -ge "$BUDGET_TOKENS" ]; then
  echo "[$SVC] skip: daily token budget reached ($USED >= $BUDGET_TOKENS)" >> "$LOG_FILE"
  emit_event design.proposal.skipped reason=budget tokens_used="$USED" budget="$BUDGET_TOKENS"
  finish skipped reason=budget
fi

# --- open-proposal cap (D-O7) ----------------------------------------------
UNDECIDED="$(undecided_open_count "$RESULT_FILE" "$DECISIONS_FILE")"
[[ "$UNDECIDED" =~ ^[0-9]+$ ]] || UNDECIDED=0
if [ "$UNDECIDED" -ge "$MAX_OPEN" ]; then
  echo "[$SVC] skip: $UNDECIDED undecided proposal(s) >= cap $MAX_OPEN" >> "$LOG_FILE"
  emit_event design.proposal.skipped reason=open_cap open="$UNDECIDED" cap="$MAX_OPEN"
  finish skipped reason=open_cap
fi
AVAILABLE=$(( MAX_OPEN - UNDECIDED ))

# --- build prompt -----------------------------------------------------------
GATES=""
[ -f "$PROJECT_DIR/.agents/gates.md" ] && GATES="$(cat "$PROJECT_DIR/.agents/gates.md")"
# North star: the repo's one-line compass, handed to mentat as a directional
# prior (never a gate). [design].north_star in config wins; else the GitHub
# repo description; else empty. Soft-fail — a missing gh must not kill the run.
NORTH_STAR="$(jq -r '.design.north_star // empty' <<<"$CFG_JSON" 2>/dev/null)"
if [ -z "$NORTH_STAR" ] && command -v gh >/dev/null 2>&1; then
  NORTH_STAR="$(cd "$PROJECT_DIR" && timeout 10 gh repo view --json description -q .description 2>/dev/null || true)"
fi
RUN_CONTEXT="$(jq -n \
  --arg name "$PROJECT_NAME" \
  --arg dir "$PROJECT_DIR" \
  --arg ts "$(now_iso)" \
  --arg north "$NORTH_STAR" \
  --argjson max "$AVAILABLE" \
  --argjson summary "$SUMMARY" \
  --argjson cfg "$CFG_JSON" \
  '{project_name:$name, project_dir:$dir, timestamp:$ts, north_star:$north,
    max_new_proposals:$max, telemetry:$summary, config:$cfg}')"

PROMPT="$(cat "$ROLE_FILE")

---

PROJECT GATES (.agents/gates.md — what \"verified\" means here):

$GATES

---

RUN CONTEXT (draft <= $AVAILABLE new proposal(s); reply with ONLY a JSON array):

$RUN_CONTEXT"

# --- spawn claude -----------------------------------------------------------
MODEL="${DESIGN_MODEL:-sonnet}"
set +e
CLAUDE_OUT="$(claude -p --model "$MODEL" --output-format json "$PROMPT" 2>>"$LOG_FILE")"
CLAUDE_RC=$?
set -e
echo "[$SVC] claude exit=$CLAUDE_RC" >> "$LOG_FILE"
if [ "$CLAUDE_RC" -ne 0 ] || [ -z "$CLAUDE_OUT" ]; then
  echo "[$SVC] claude produced no output; no proposals drafted" >> "$LOG_FILE"
  finish fail reason=claude_failed
fi

RESULT_TEXT="$(jq -r '.result // ""' <<<"$CLAUDE_OUT" 2>/dev/null || true)"
TOKENS="$(jq -r '((.usage.input_tokens // 0) + (.usage.output_tokens // 0))' <<<"$CLAUDE_OUT" 2>/dev/null || echo 0)"
[[ "$TOKENS" =~ ^[0-9]+$ ]] || TOKENS=0

# --- merge proposals into the result file -----------------------------------
# Parse claude's reply (tolerant of ```json fences), assign a stable id +
# status:"open" to each, dedup by title against proposals already in the
# result file, keep at most $AVAILABLE new ones, and rewrite the result
# file preserving existing proposals. Prints the NEW proposals as JSONL.
NEW_PROPOSALS="$(
  RESULT_FILE="$RESULT_FILE" PROJECT_NAME="$PROJECT_NAME" \
  TS="$(now_iso)" AVAILABLE="$AVAILABLE" CLAUDE_TEXT="$RESULT_TEXT" \
  python3 - <<'PY' 2>>"$LOG_FILE"
import os, sys, json, re, hashlib

result_file = os.environ["RESULT_FILE"]
project     = os.environ["PROJECT_NAME"]
ts          = os.environ["TS"]
available   = int(os.environ.get("AVAILABLE", "3"))
raw         = os.environ.get("CLAUDE_TEXT", "")

# strip ```json fences if the model added them
m = re.search(r"\[.*\]", raw, re.S)
proposals = []
if m:
    try:
        proposals = json.loads(m.group(0))
    except Exception:
        proposals = []
if not isinstance(proposals, list):
    proposals = []

# existing proposals
existing = []
if os.path.exists(result_file):
    try:
        with open(result_file) as f:
            existing = (json.load(f) or {}).get("proposals", []) or []
    except Exception:
        existing = []
existing_titles = {p.get("title") for p in existing}

ALLOWED_TYPE = {"feature", "bug", "instrumentation"}
ALLOWED_SEV  = {"high", "med", "low"}

added = []
for p in proposals:
    if not isinstance(p, dict):
        continue
    title = str(p.get("title", "")).strip()
    if not title or title in existing_titles:
        continue
    ptype = p.get("type", "feature")
    if ptype not in ALLOWED_TYPE:
        ptype = "feature"
    sev = p.get("severity", "med")
    if sev not in ALLOWED_SEV:
        sev = "med"
    pid = "mentat:%s:%s" % (
        project, hashlib.sha256((ts + title).encode()).hexdigest()[:8])
    obj = {
        "id": pid, "type": ptype, "title": title,
        "rationale": str(p.get("rationale", "")),
        "evidence": str(p.get("evidence", "")),
        "suggested_scope": str(p.get("suggested_scope", "")),
        "severity": sev, "status": "open",
    }
    added.append(obj)
    existing_titles.add(title)
    if len(added) >= max(0, available):
        break

merged = existing + added
with open(result_file, "w") as f:
    json.dump({"ts": ts, "project": project, "proposals": merged}, f, indent=2)

for obj in added:
    sys.stdout.write(json.dumps(obj) + "\n")
PY
)" || NEW_PROPOSALS=""

N_NEW=0
if [ -n "$NEW_PROPOSALS" ]; then
  N_NEW="$(printf '%s\n' "$NEW_PROPOSALS" | grep -c . || true)"
fi
echo "[$SVC] drafted $N_NEW new proposal(s), tokens=$TOKENS" >> "$LOG_FILE"

# --- emit one design.proposal.opened per NEW proposal -----------------------
# The run's full token usage rides the LAST opened event only, so summing
# today's design.* tokens for the budget gate never double-counts a run.
i=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  i=$(( i + 1 ))
  PID="$(jq -r '.id' <<<"$line")"
  PTYPE="$(jq -r '.type' <<<"$line")"
  PSEV="$(jq -r '.severity' <<<"$line")"
  ev_tokens=0
  [ "$i" -eq "$N_NEW" ] && ev_tokens="$TOKENS"
  emit_event design.proposal.opened project="$PROJECT_NAME" \
    proposal_id="$PID" type="$PTYPE" severity="$PSEV" tokens="$ev_tokens"
done <<<"$NEW_PROPOSALS"

finish ok proposals="$N_NEW" tokens="$TOKENS"
