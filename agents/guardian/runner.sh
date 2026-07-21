#!/bin/bash
# agents/guardian/runner.sh — generic guardian wrapper.
#
# Usage:
#   runner.sh --project DIR --mode {hook|daily}
#   runner.sh --project DIR --mode post-merge --merge-sha SHA
#   runner.sh --project DIR --check-config   # print effective gates, read-only
#
# Reads <project>/.agents/config.toml. Prompt = agents/guardian/role.md
# + <project>/.agents/guardian.md + RUN CONTEXT block. Writes result to
# <project>/tmp/<project>-guardian-result.json. Trailer via
# agents/lib/post-run.sh emits job.end and (on fail) escalates to medic.
#
# post-merge mode is deterministic — runs the project's test_cmd +
# typecheck against the current checkout, no Claude invocation. Used
# by medic post-augur-merge to validate before retrigger.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUARTET_DIR="${QUARTET_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
LOG_EVENT="$QUARTET_DIR/agents/lib/log_event.sh"

export QUARTET_SOURCE="${QUARTET_SOURCE:-system}"

# ---------- argv ------------------------------------------------------------
PROJECT_DIR=""
MODE=""
MERGE_SHA=""
CHECK_CONFIG=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project)      PROJECT_DIR="$2"; shift 2 ;;
    --mode)         MODE="$2"; shift 2 ;;
    --merge-sha)    MERGE_SHA="$2"; shift 2 ;;
    --check-config) CHECK_CONFIG=1; shift ;;
    -h|--help)      sed -n '2,16p' "$0"; exit 0 ;;
    *)              echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -z "$PROJECT_DIR" ] && { echo "--project required" >&2; exit 2; }
[ -d "$PROJECT_DIR" ] || { echo "project dir missing: $PROJECT_DIR" >&2; exit 2; }
if [ "$CHECK_CONFIG" -eq 0 ]; then
  [ -z "$MODE" ] && { echo "--mode required" >&2; exit 2; }
  case "$MODE" in hook|daily|post-merge) ;; *) echo "bad --mode: $MODE" >&2; exit 2 ;; esac
fi

CONFIG_FILE="$PROJECT_DIR/.agents/config.toml"
ROLE_FILE="$SCRIPT_DIR/role.md"
PROJECT_PROMPT="$PROJECT_DIR/.agents/guardian.md"
[ -f "$CONFIG_FILE" ]    || { echo "config not found: $CONFIG_FILE" >&2; exit 2; }
if [ "$CHECK_CONFIG" -eq 0 ]; then
  [ -f "$ROLE_FILE" ]      || { echo "role.md not found: $ROLE_FILE" >&2; exit 2; }
  [ -f "$PROJECT_PROMPT" ] || { echo "project guardian.md not found: $PROJECT_PROMPT" >&2; exit 2; }
fi

# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/load-config.sh"
CFG_JSON="$(load_config_json "$CONFIG_FILE")" || \
  { echo "failed to parse $CONFIG_FILE" >&2; exit 2; }

PROJECT_NAME="$(jq -r '.project_name' <<<"$CFG_JSON")"
RESULT_DIR_REL="$(jq -r '.paths.result_dir // "tmp"' <<<"$CFG_JSON")"
TEST_CMD="$(jq -r '.guardian.test_cmd // "npx vitest run"' <<<"$CFG_JSON")"
TYPECHECK_CMD="$(jq -r '.guardian.typecheck // "npx tsc --noEmit"' <<<"$CFG_JSON")"
BUDGET_HOOK="$(jq -r '.guardian.budget_hook // 0.50' <<<"$CFG_JSON")"
BUDGET_DAILY="$(jq -r '.guardian.budget_daily // 2.00' <<<"$CFG_JSON")"

# ---------- --check-config: print effective gates, then stop ----------------
# STRICTLY read-only: no result files, no events, no claude, no network.
if [ "$CHECK_CONFIG" -eq 1 ]; then
  # shellcheck disable=SC1091
  source "$QUARTET_DIR/agents/lib/detect-trunk.sh"
  TRUNK_BRANCH="$(detect_trunk "$CFG_JSON" "$PROJECT_DIR")" || exit 2
  jq -n \
    --arg agent "guardian" \
    --arg dir "$PROJECT_DIR" \
    --arg trunk "$TRUNK_BRANCH" \
    --arg test_cmd "$TEST_CMD" \
    --arg typecheck "$TYPECHECK_CMD" \
    --argjson cfg "$CFG_JSON" \
    '{agent:$agent, project:$cfg.project_name, project_dir:$dir, trunk:$trunk,
      can_merge:($cfg.medic.augur_can_merge // false),
      allow_no_ci:($cfg.augur.allow_no_ci // false),
      test_cmd:$test_cmd, typecheck:$typecheck,
      budgets:{hook_usd:($cfg.guardian.budget_hook // 0.50),
               daily_usd:($cfg.guardian.budget_daily // 2.00)}}'
  exit 0
fi

RESULT_DIR="$PROJECT_DIR/$RESULT_DIR_REL"
mkdir -p "$RESULT_DIR"
RESULT_FILE="$RESULT_DIR/$PROJECT_NAME-guardian-result.json"
LOG_FILE="$RESULT_DIR/$PROJECT_NAME-guardian-last-run.log"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
JOB_START="$(date +%s)"
cd "$PROJECT_DIR"

[ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$PROJECT_NAME-guardian" job.start \
  mode="$MODE" project="$PROJECT_NAME" || true

# ---------- post-merge: deterministic, no Claude ----------------------------
if [ "$MODE" = "post-merge" ]; then
  PM_LOG="$RESULT_DIR/$PROJECT_NAME-guardian-post-merge.log"
  echo "[$PROJECT_NAME-guardian] post-merge $(now_iso) merge_sha=$MERGE_SHA" > "$PM_LOG"
  HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  if [ -n "$MERGE_SHA" ] && [ "$HEAD_SHA" != "$MERGE_SHA" ] \
     && [ "${HEAD_SHA:0:${#MERGE_SHA}}" != "$MERGE_SHA" ]; then
    echo "[$PROJECT_NAME-guardian] WARN: HEAD ($HEAD_SHA) != merge_sha ($MERGE_SHA)" >> "$PM_LOG"
  fi

  PM_STATUS="ok"; PM_REASON=""
  set +e
  echo "[$PROJECT_NAME-guardian] $TYPECHECK_CMD" >> "$PM_LOG"
  eval "$TYPECHECK_CMD" >> "$PM_LOG" 2>&1
  TC_RC=$?
  echo "[$PROJECT_NAME-guardian] $TEST_CMD" >> "$PM_LOG"
  eval "$TEST_CMD" >> "$PM_LOG" 2>&1
  TS_RC=$?
  set -e
  [ "$TC_RC" != "0" ] && { PM_STATUS="fail"; PM_REASON="tsc_failed"; }
  [ "$TS_RC" != "0" ] && { PM_STATUS="fail"; PM_REASON="${PM_REASON:+$PM_REASON,}vitest_failed"; }

  PM_DUR=$(( $(date +%s) - JOB_START ))
  # Direct log_event — do NOT use agent_finish here (medic invoked us;
  # escalating back to medic would loop on a different surface).
  [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$PROJECT_NAME-guardian" job.end \
    mode="post-merge" status="$PM_STATUS" duration_s="$PM_DUR" \
    merge_sha="$MERGE_SHA" reason="${PM_REASON:-none}" || true

  [ "$PM_STATUS" = "ok" ] && exit 0 || exit 1
fi

# ---------- hook | daily: invoke Claude -------------------------------------
echo "[$PROJECT_NAME-guardian] $(now_iso) start mode=$MODE" > "$LOG_FILE"

# Pick budget by mode.
if [ "$MODE" = "daily" ]; then
  BUDGET="$BUDGET_DAILY"
else
  BUDGET="$BUDGET_HOOK"
fi
MODEL="${GUARDIAN_MODEL:-sonnet}"

RUN_CONTEXT="$(jq -n \
  --arg mode "$MODE" \
  --arg name "$PROJECT_NAME" \
  --arg dir "$PROJECT_DIR" \
  --arg ts "$(now_iso)" \
  --arg result_file "$RESULT_FILE" \
  --argjson cfg "$CFG_JSON" \
  '{mode:$mode, project_name:$name, project_dir:$dir, timestamp:$ts,
    result_file:$result_file, config:$cfg}')"

PROMPT="$(cat "$ROLE_FILE")

---

$(cat "$PROJECT_PROMPT")

---

RUN CONTEXT (write your result to $RESULT_FILE — JSON only, no prose):

$RUN_CONTEXT"

: > "$RESULT_FILE"

set +e
claude -p \
  --model "$MODEL" \
  --dangerously-skip-permissions \
  --max-budget-usd "$BUDGET" \
  --output-format text \
  "$PROMPT" \
  >> "$LOG_FILE" 2>&1
EXIT=$?
set -e

# If the Claude run died without writing results (budget cut, timeout,
# or the session backgrounded a step and exited — real incident),
# synthesize a valid failure result. Downstream consumers (medic
# post-run, telemetry) feed this file to `jq --argjson`; a 0-byte file
# poisons them because jq exits 0 with empty output on empty input.
if [ ! -s "$RESULT_FILE" ]; then
  jq -n --arg ts "$(now_iso)" --arg mode "$MODE" --argjson exit "$EXIT" '{
    pass: false, mode: $mode, timestamp: $ts,
    errors: ["guardian claude run exited (\($exit)) without writing result.json"]
  }' > "$RESULT_FILE"
  echo "[$PROJECT_NAME-guardian] claude run wrote no result.json; synthesized failure result" >> "$LOG_FILE"
fi

# Determine pass/fail from result.json (caller-written).
if [ -s "$RESULT_FILE" ]; then
  PASS="$(jq -r '.pass // false' "$RESULT_FILE" 2>/dev/null || echo false)"
else
  PASS="false"
fi

if [ "$PASS" = "true" ]; then JOB_STATUS="ok"; else JOB_STATUS="fail"; fi

# Build category tag from the result fields (project-specific structure
# but the field names are stable across guardian-style runs).
CATEGORY="$(python3 - "$RESULT_FILE" <<'PY' 2>/dev/null || echo unknown
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("unknown"); sys.exit(0)
cats = []
if (d.get("vitest") or {}).get("failed", 0) > 0: cats.append("vitest")
if (d.get("typecheck") or {}).get("errors", 0) > 0: cats.append("tsc")
if d.get("dbIssues"): cats.append("db")
if d.get("tombstoneAnomalies"): cats.append("tombstones")
sec = d.get("security") or {}
if sec.get("auditCritical", 0) > 0 or sec.get("headerIssues") or sec.get("secretsHits"): cats.append("security")
if d.get("errors"): cats.append("error")
print(",".join(cats) or ("ok" if d.get("pass") else "unknown"))
PY
)"

# Notify the human (Signal) — kept human-readable; the dashboard reads
# from the events stream, not from the notification body.
SUMMARY="$(tail -30 "$LOG_FILE" | grep -A20 -i "GUARDIAN RESULT" | head -10 || true)"
[ -z "$SUMMARY" ] && SUMMARY="$PROJECT_NAME-guardian completed (mode=$MODE, exit=$EXIT). See $LOG_FILE."
if [ "$PASS" = "true" ]; then
  quartet_notify "$PROJECT_NAME Guardian ($MODE)" "$SUMMARY" || true
else
  quartet_notify "$PROJECT_NAME Guardian FAILED ($MODE)" "$SUMMARY" || true
fi

JOB_DUR=$(( $(date +%s) - JOB_START ))

# Emit job.end + (on fail) escalate to medic, via shared trailer.
# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/post-run.sh"
agent_finish "$PROJECT_NAME-guardian" "$PROJECT_DIR" "$JOB_STATUS" "$JOB_DUR" \
  mode="$MODE" exit_code="$EXIT" category="$CATEGORY" >> "$LOG_FILE" 2>&1

echo "[$PROJECT_NAME-guardian] done pass=$PASS exit=$EXIT" >> "$LOG_FILE"
exit "$EXIT"
