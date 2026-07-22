#!/bin/bash
# agents/build/runner.sh — generic build (augur) wrapper.
#
# Live and dry-run modes run natively here (nightly feedback triage →
# autonomous PRs). Incident mode is RETIRED (D-L15): incident repair now
# routes through the design loop (medic writes a proposal → mentat →
# helldiver). `--mode ticket` drives execute-ticket on a ratified ticket,
# gated behind [build] ticket_mode (default false → no-op).
#
# Usage:
#   runner.sh --project DIR --mode live
#   runner.sh --project DIR --mode dry-run
#   runner.sh --project DIR --mode ticket --ticket-file PATH   # gated: [build].ticket_mode
#   runner.sh --project DIR --check-config   # print effective gates, read-only
#
# Result file (written to $PROJECT_DIR/$paths.result_dir/$project-augur-result.json):
#   {pass, incident_id, branch, pr_url, merge_sha, files_changed, errors}

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUARTET_DIR="${QUARTET_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
LOG_EVENT="$QUARTET_DIR/agents/lib/log_event.sh"

export QUARTET_SOURCE="${QUARTET_SOURCE:-system}"

# ---------- argv ------------------------------------------------------------
PROJECT_DIR=""
MODE=""
INCIDENT_FILE=""
TICKET_FILE=""
CHECK_CONFIG=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project)        PROJECT_DIR="$2"; shift 2 ;;
    --mode)           MODE="$2"; shift 2 ;;
    --incident-file)  INCIDENT_FILE="$2"; shift 2 ;;
    --ticket-file|--ticket) TICKET_FILE="$2"; shift 2 ;;
    --check-config)   CHECK_CONFIG=1; shift ;;
    -h|--help)        sed -n '2,16p' "$0"; exit 0 ;;
    *)                echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -z "$PROJECT_DIR" ] && { echo "--project required" >&2; exit 2; }
[ -d "$PROJECT_DIR" ] || { echo "project dir missing: $PROJECT_DIR" >&2; exit 2; }
[ "$CHECK_CONFIG" -eq 0 ] && [ -z "$MODE" ] && { echo "--mode required" >&2; exit 2; }

CONFIG_FILE="$PROJECT_DIR/.agents/config.toml"
[ -f "$CONFIG_FILE" ] || { echo "config not found: $CONFIG_FILE" >&2; exit 2; }

source "$QUARTET_DIR/agents/lib/load-config.sh"
# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/detect-trunk.sh"
CFG_JSON="$(load_config_json "$CONFIG_FILE")" || \
  { echo "failed to parse $CONFIG_FILE" >&2; exit 2; }

PROJECT_NAME="$(jq -r '.project_name' <<<"$CFG_JSON")"

# Canonical role identity + resolved display name (svc string). Legacy
# configs (no [names] block) resolve build→"augur", so the svc/units stay
# exactly as they are today.
ROLE="build"
export QUARTET_ROLE="$ROLE"
# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/naming.sh"
DISPLAY="$(role_display "$ROLE" "$CFG_JSON")"
SVC="$PROJECT_NAME-$DISPLAY"

# Trunk branch — config wins, else origin/HEAD; unresolvable fails loudly.
TRUNK_BRANCH="$(detect_trunk "$CFG_JSON" "$PROJECT_DIR")" || exit 2
RESULT_DIR_REL="$(jq -r '.paths.result_dir // "tmp"' <<<"$CFG_JSON")"
WORKTREE_DIR_REL="$(jq -r '.paths.worktree_dir // ".worktrees"' <<<"$CFG_JSON")"

# ---------- --check-config: print effective gates, then stop ----------------
# STRICTLY read-only: no result files, no events, no claude, no gh.
if [ "$CHECK_CONFIG" -eq 1 ]; then
  jq -n \
    --arg agent "$ROLE" \
    --arg role "$ROLE" \
    --arg display "$DISPLAY" \
    --arg dir "$PROJECT_DIR" \
    --arg trunk "$TRUNK_BRANCH" \
    --argjson cfg "$CFG_JSON" \
    '{agent:$agent, role:$role, display:$display,
      project:$cfg.project_name, project_dir:$dir, trunk:$trunk,
      can_merge:($cfg.medic.can_merge // false),
      allow_no_ci:($cfg.build.allow_no_ci // false),
      in_scope_paths:($cfg.build.in_scope_paths // []),
      forbidden_paths:($cfg.build.forbidden_paths // []),
      budgets:{live_usd:($cfg.build.budget // 2.00),
               incident_usd:($cfg.build.budget_incident // 1.50),
               wall_clock_sec:($cfg.build.wall_clock_sec // 3600)}}'
  exit 0
fi

RESULT_DIR="$PROJECT_DIR/$RESULT_DIR_REL"
WORKTREE_DIR="$PROJECT_DIR/$WORKTREE_DIR_REL"
mkdir -p "$RESULT_DIR" "$WORKTREE_DIR"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---------- live / dry-run: native handling ---------------------------------
if [ "$MODE" = "live" ] || [ "$MODE" = "dry-run" ]; then
  ROLE_FILE="$SCRIPT_DIR/role.md"
  # Role-id filename first; .agents/augur.md is the legacy name (pre-rename).
  PROJECT_PROMPT="$PROJECT_DIR/.agents/build.md"
  [ -f "$PROJECT_PROMPT" ] || PROJECT_PROMPT="$PROJECT_DIR/.agents/augur.md"
  [ -f "$ROLE_FILE" ]      || { echo "role.md missing: $ROLE_FILE" >&2; exit 2; }
  [ -f "$PROJECT_PROMPT" ] || { echo "project build.md (or legacy augur.md) missing: $PROJECT_DIR/.agents/" >&2; exit 2; }

  WALL_CLOCK="$(jq -r '.build.wall_clock_sec // 3600' <<<"$CFG_JSON")"
  BUDGET="$(jq -r '.build.budget // 2.00' <<<"$CFG_JSON")"
  PROJECT_OWNER="$(jq -r '.project_owner // ""' <<<"$CFG_JSON")"

  RESULT_FILE="$RESULT_DIR/$SVC-result.json"
  LOG_FILE="$RESULT_DIR/$SVC-last-run.log"
  FYI_LOG="$PROJECT_DIR/$(jq -r '.build.fyi_log // "data/fyi-requests.jsonl"' <<<"$CFG_JSON")"

  JOB_START="$(date +%s)"
  echo "[$SVC] $(now_iso) start mode=$MODE" > "$LOG_FILE"
  [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$SVC" job.start \
    mode="$MODE" project="$PROJECT_NAME" || true

  cd "$PROJECT_DIR"

  # Pre-flight: live only. dry-run does no git ops, so skip.
  if [ "$MODE" = "live" ]; then
    if [ -n "$(git status --porcelain)" ]; then
      echo "[$SVC] ABORT: main checkout dirty" >> "$LOG_FILE"
      git status --short >> "$LOG_FILE"
      quartet_notify "$PROJECT_NAME Augur aborted ($MODE)" \
        "Main checkout has uncommitted changes." || true
      [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$SVC" job.end \
        mode="$MODE" status="abort" reason="dirty" || true
      exit 1
    fi
    CB="$(git rev-parse --abbrev-ref HEAD)"
    if [ "$CB" != "$TRUNK_BRANCH" ]; then
      echo "[$SVC] ABORT: not on $TRUNK_BRANCH ($CB)" >> "$LOG_FILE"
      quartet_notify "$PROJECT_NAME Augur aborted ($MODE)" \
        "Current branch is $CB, not $TRUNK_BRANCH." || true
      [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$SVC" job.end \
        mode="$MODE" status="abort" reason="not_trunk" || true
      exit 1
    fi
    git fetch origin "$TRUNK_BRANCH" --quiet 2>>"$LOG_FILE" || true
    if [ -n "$(git rev-list "origin/$TRUNK_BRANCH..$TRUNK_BRANCH" 2>/dev/null)" ]; then
      echo "[$SVC] pushing local $TRUNK_BRANCH ahead-of-origin commits" >> "$LOG_FILE"
      git push origin "$TRUNK_BRANCH" >> "$LOG_FILE" 2>&1 || {
        [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$SVC" job.end \
          mode="$MODE" status="abort" reason="push_failed" || true
        exit 1
      }
    fi
  fi

  RUN_CONTEXT="$(jq -n \
    --arg mode "$MODE" \
    --arg name "$PROJECT_NAME" \
    --arg dir "$PROJECT_DIR" \
    --arg owner "$PROJECT_OWNER" \
    --arg ts "$(now_iso)" \
    --arg result_file "$RESULT_FILE" \
    --arg fyi_log "$FYI_LOG" \
    --arg worktree_dir "$WORKTREE_DIR" \
    --argjson cfg "$CFG_JSON" \
    '{mode:$mode, project_name:$name, project_dir:$dir, project_owner:$owner,
      timestamp:$ts, result_file:$result_file, fyi_log:$fyi_log,
      worktree_dir:$worktree_dir, config:$cfg}')"

  PROMPT="$(cat "$ROLE_FILE")

---

$(cat "$PROJECT_PROMPT")

---

RUN CONTEXT (write your result to $RESULT_FILE — JSON only, no prose):

$RUN_CONTEXT"

  MODEL="${AUGUR_MODEL:-sonnet}"
  : > "$RESULT_FILE"

  set +e
  timeout "$WALL_CLOCK" claude -p \
    --model "$MODEL" \
    --dangerously-skip-permissions \
    --max-budget-usd "$BUDGET" \
    --output-format text \
    "$PROMPT" \
    >> "$LOG_FILE" 2>&1
  EXIT=$?
  set -e
  echo "[$SVC] claude exit=$EXIT" >> "$LOG_FILE"

  # Live mode only — clean up any worktrees augur left behind. Belt-and-
  # suspenders for the case where claude crashed mid-run.
  if [ "$MODE" = "live" ]; then
    while read -r wt; do
      [ -z "$wt" ] && continue
      path="$(awk '{print $1}' <<<"$wt")"
      case "$path" in
        *"/.worktrees/augur-"*|*"/.worktrees/medic-incident-"*)
          echo "[$SVC] cleanup leftover worktree $path" >> "$LOG_FILE"
          git worktree remove --force "$path" 2>>"$LOG_FILE" || true ;;
      esac
    done < <(git worktree list --porcelain 2>/dev/null | grep '^worktree ' | sed 's/^worktree //')
  fi

  # Build human-facing summary. Project may ship its own formatter at
  # scripts/augur-format-signal.mjs (optional per-project); fall back to a
  # generic line if not.
  FMT="$PROJECT_DIR/scripts/augur-format-signal.mjs"
  SUMMARY_FILE="$RESULT_DIR/$SVC-signal.txt"
  if [ -f "$RESULT_FILE" ] && [ -s "$RESULT_FILE" ]; then
    if [ -x "$FMT" ] || [ -f "$FMT" ]; then
      node "$FMT" "$RESULT_FILE" > "$SUMMARY_FILE" 2>>"$LOG_FILE" || \
        echo "$PROJECT_NAME augur ($MODE) — formatter failed; see $LOG_FILE" > "$SUMMARY_FILE"
    else
      jq -r --arg name "$PROJECT_NAME" --arg mode "$MODE" \
        '"\($name) augur (\($mode)) — pass=\(.pass) items=\(.items|length)"' \
        "$RESULT_FILE" > "$SUMMARY_FILE" 2>/dev/null || \
        echo "$PROJECT_NAME augur ($MODE) — no result." > "$SUMMARY_FILE"
    fi
    PASS="$(jq -r '.pass // false' "$RESULT_FILE")"
  else
    echo "$PROJECT_NAME augur ($MODE) — no result file produced (exit=$EXIT)." > "$SUMMARY_FILE"
    PASS="false"
  fi

  SUMMARY="$(cat "$SUMMARY_FILE")"
  if [ "$PASS" = "true" ]; then
    quartet_notify "$PROJECT_NAME Augur ($MODE)" "$SUMMARY" || true
    JOB_STATUS="ok"
  else
    quartet_notify "$PROJECT_NAME Augur FAILED ($MODE)" "$SUMMARY" || true
    JOB_STATUS="fail"
  fi

  JOB_DUR=$(( $(date +%s) - JOB_START ))
  # shellcheck disable=SC1091
  source "$QUARTET_DIR/agents/lib/post-run.sh"
  agent_finish "$SVC" "$PROJECT_DIR" "$JOB_STATUS" "$JOB_DUR" \
    mode="$MODE" exit_code="$EXIT" >> "$LOG_FILE" 2>&1

  echo "[$SVC] done pass=$PASS exit=$EXIT" >> "$LOG_FILE"
  exit "$EXIT"
fi

# ---------- ticket mode (Phase 11 wiring; DEFAULT OFF) ----------------------
# Opt-in hook: drive the execute-ticket skill on a ratified ticket. Gated
# behind [build] ticket_mode — an unset/false flag is EXACTLY today's
# behavior (no timer uses this mode), so the live fleet is unaffected.
if [ "$MODE" = "ticket" ]; then
  TICKET_MODE="$(jq -r '.build.ticket_mode // false' <<<"$CFG_JSON")"
  if [ "$TICKET_MODE" != "true" ]; then
    echo "ticket_mode disabled ([build].ticket_mode is not true) — --mode ticket is a no-op" >&2
    exit 2
  fi
  [ -z "$TICKET_FILE" ] && { echo "--ticket-file required for ticket mode" >&2; exit 2; }
  [ -f "$TICKET_FILE" ] || { echo "ticket file not found: $TICKET_FILE" >&2; exit 2; }

  WALL_CLOCK="$(jq -r '.build.wall_clock_sec // 3600' <<<"$CFG_JSON")"
  BUDGET="$(jq -r '.build.budget // 2.00' <<<"$CFG_JSON")"
  LOG_FILE="$RESULT_DIR/$SVC-ticket-last-run.log"
  JOB_START="$(date +%s)"
  echo "[$SVC] $(now_iso) start mode=ticket ticket=$TICKET_FILE" > "$LOG_FILE"
  [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$SVC" job.start \
    mode="ticket" project="$PROJECT_NAME" || true

  # Headless: the execute-ticket skill is symlinked into
  # <project>/.claude/skills at install, so a cwd-at-project `claude -p`
  # auto-discovers it. Same wall-clock/budget contract as live mode.
  MODEL="${BUILD_MODEL:-sonnet}"
  PROMPT="Use the execute-ticket skill to build the ticket at $TICKET_FILE to completion. It is a ratified ticket; build it phase-by-phase and verify each phase on the real system per the project's gate file (.agents/gates.md)."

  cd "$PROJECT_DIR"
  set +e
  timeout "$WALL_CLOCK" claude -p \
    --model "$MODEL" \
    --dangerously-skip-permissions \
    --max-budget-usd "$BUDGET" \
    --output-format text \
    "$PROMPT" \
    >> "$LOG_FILE" 2>&1
  EXIT=$?
  set -e
  echo "[$SVC] execute-ticket exit=$EXIT" >> "$LOG_FILE"

  JOB_DUR=$(( $(date +%s) - JOB_START ))
  JOB_STATUS=$([ "$EXIT" = "0" ] && echo "ok" || echo "fail")
  [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$SVC" job.end \
    mode="ticket" status="$JOB_STATUS" duration_s="$JOB_DUR" exit_code="$EXIT" \
    project="$PROJECT_NAME" || true
  exit "$EXIT"
fi

# ---------- incident mode: RETIRED (D-L15) ----------------------------------
# The medic→build incident side-door is gone. Incident repair now routes
# through the design loop: medic writes an incident-repair proposal that the
# owner stamps in the dispatch, then mentat→helldiver build it. This path
# emits NOTHING and exits non-zero so any stale caller fails loudly.
if [ "$MODE" = "incident" ]; then
  echo "build --mode incident is retired (D-L15); incident repair now routes through the design loop (mentat→helldiver)" >&2
  exit 3
fi

echo "unknown mode: $MODE" >&2; exit 2
