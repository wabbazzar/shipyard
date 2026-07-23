#!/bin/bash
# agents/scribe/runner.sh — generic scribe wrapper.
#
# Usage:
#   runner.sh --project DIR --mode {daily|dry-run}
#   runner.sh --project DIR --check-config   # print effective gates, read-only
#
# Reads <project>/.agents/config.toml. Prompt = agents/scribe/role.md
# + <project>/.agents/scribe.md + RUN CONTEXT block. Writes result to
# <project>/tmp/<project>-scribe-result.json.
#
# In daily mode, after claude exits, the runner counts diffed files in
# config.scribe.content_paths. If non-zero AND config.scribe.auto_commit
# is true, it commits with the configured prefix. Optionally pushes if
# config.scribe.auto_push is true.
#
# Trailer goes through agents/lib/post-run.sh with --no-escalate —
# scribe failures don't go to medic (doc-gen failures aren't fixable
# by medic→build, just notify).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUARTET_DIR="${QUARTET_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
LOG_EVENT="$QUARTET_DIR/agents/lib/log_event.sh"

export QUARTET_SOURCE="${QUARTET_SOURCE:-system}"

# ---------- argv ------------------------------------------------------------
PROJECT_DIR=""
MODE=""
CHECK_CONFIG=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project)      PROJECT_DIR="$2"; shift 2 ;;
    --mode)         MODE="$2"; shift 2 ;;
    --check-config) CHECK_CONFIG=1; shift ;;
    -h|--help)      sed -n '2,19p' "$0"; exit 0 ;;
    *)              echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -z "$PROJECT_DIR" ] && { echo "--project required" >&2; exit 2; }
[ -d "$PROJECT_DIR" ] || { echo "project dir missing: $PROJECT_DIR" >&2; exit 2; }
if [ "$CHECK_CONFIG" -eq 0 ]; then
  [ -z "$MODE" ] && { echo "--mode required (daily|dry-run)" >&2; exit 2; }
  case "$MODE" in daily|dry-run) ;; *) echo "bad --mode: $MODE" >&2; exit 2 ;; esac
fi

CONFIG_FILE="$PROJECT_DIR/.agents/config.toml"
ROLE_FILE="$SCRIPT_DIR/role.md"
PROJECT_PROMPT="$PROJECT_DIR/.agents/scribe.md"
[ -f "$CONFIG_FILE" ]    || { echo "config not found: $CONFIG_FILE" >&2; exit 2; }
if [ "$CHECK_CONFIG" -eq 0 ]; then
  [ -f "$ROLE_FILE" ]      || { echo "role.md not found: $ROLE_FILE" >&2; exit 2; }
  [ -f "$PROJECT_PROMPT" ] || { echo "project scribe.md not found: $PROJECT_PROMPT" >&2; exit 2; }
fi

# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/load-config.sh"
# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/spawn.sh"
CFG_JSON="$(load_config_json "$CONFIG_FILE")" || \
  { echo "failed to parse $CONFIG_FILE" >&2; exit 2; }

PROJECT_NAME="$(jq -r '.project_name' <<<"$CFG_JSON")"

# Canonical role identity + resolved display name (svc string). scribe is
# already a role id; legacy configs (no [names] block) resolve it to
# "scribe", so the svc/units stay exactly as they are today.
ROLE="scribe"
export QUARTET_ROLE="$ROLE"
# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/naming.sh"
DISPLAY="$(role_display "$ROLE" "$CFG_JSON")"
SVC="$PROJECT_NAME-$DISPLAY"

RESULT_DIR_REL="$(jq -r '.paths.result_dir // "tmp"' <<<"$CFG_JSON")"
BUDGET_TOKENS="$(jq -r '.scribe.budget_tokens_daily // 1000000' <<<"$CFG_JSON")"
[[ "$BUDGET_TOKENS" =~ ^[0-9]+$ ]] || BUDGET_TOKENS=1000000
WALL_CLOCK="$(jq -r '.scribe.wall_clock_sec // 3600' <<<"$CFG_JSON")"
COMMIT_PREFIX="$(jq -r '.scribe.commit_message_prefix // "scribe: nightly refresh"' <<<"$CFG_JSON")"
AUTO_COMMIT="$(jq -r '.scribe.auto_commit // true' <<<"$CFG_JSON")"
AUTO_PUSH="$(jq -r '.scribe.auto_push // false' <<<"$CFG_JSON")"
CONTENT_PATHS_JSON="$(jq -c '.scribe.content_paths // []' <<<"$CFG_JSON")"

# ---------- --check-config: print effective gates, then stop ----------------
# STRICTLY read-only: no result files, no events, no claude, no network.
if [ "$CHECK_CONFIG" -eq 1 ]; then
  # shellcheck disable=SC1091
  source "$QUARTET_DIR/agents/lib/detect-trunk.sh"
  TRUNK_BRANCH="$(detect_trunk "$CFG_JSON" "$PROJECT_DIR")" || exit 2
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
      content_paths:($cfg.scribe.content_paths // []),
      auto_commit:($cfg.scribe.auto_commit // true),
      auto_push:($cfg.scribe.auto_push // false),
      budgets:{budget_tokens_daily:($cfg.scribe.budget_tokens_daily // 1000000)}}'
  exit 0
fi

RESULT_DIR="$PROJECT_DIR/$RESULT_DIR_REL"
mkdir -p "$RESULT_DIR"
RESULT_FILE="$RESULT_DIR/$SVC-result.json"
LOG_FILE="$RESULT_DIR/$SVC-last-run.log"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
JOB_START="$(date +%s)"

cd "$PROJECT_DIR"

[ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$SVC" job.start \
  mode="$MODE" project="$PROJECT_NAME" || true
echo "[$SVC] $(now_iso) start mode=$MODE" > "$LOG_FILE"

# ---------- daily token budget gate (D-O1: caps are token-based) ------------
# Sum today's job.end token usage for THIS svc only — the events dir is
# fleet-shared, so an unscoped sum would count other projects' runs.
tokens_used_today() {
  local f="${QUARTET_EVENTS_DIR:-/nonexistent}/$(date -u +%Y-%m-%d).jsonl"
  [ -f "$f" ] || { echo 0; return; }
  jq -R 'fromjson?' <"$f" 2>/dev/null | \
    jq -s --arg svc "$SVC" \
      '[.[] | select(.svc==$svc and .event=="job.end") | (.tokens // 0)] | add // 0' \
    2>/dev/null || echo 0
}
TOKENS_USED="$(tokens_used_today)"; [[ "$TOKENS_USED" =~ ^[0-9]+$ ]] || TOKENS_USED=0
if [ "$TOKENS_USED" -ge "$BUDGET_TOKENS" ]; then
  echo "[$SVC] skip: daily token budget reached ($TOKENS_USED >= $BUDGET_TOKENS)" >> "$LOG_FILE"
  [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$SVC" scribe.skipped \
    reason=budget tokens_used="$TOKENS_USED" budget="$BUDGET_TOKENS" || true
  quartet_notify "$SVC (budget)" \
    "over daily token budget ($TOKENS_USED/$BUDGET_TOKENS); run skipped until tomorrow" || true
  JOB_DUR=$(( $(date +%s) - JOB_START ))
  [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$SVC" job.end \
    mode="$MODE" status="skipped" reason="budget" duration_s="$JOB_DUR" \
    tokens_used="$TOKENS_USED" budget="$BUDGET_TOKENS" || true
  exit 0
fi

# Optional pre-hook: a project can run a cheap, AI-free refresh step
# before scribe (e.g. regenerate a state snapshot scribe reads).
if [ -n "${QUARTET_SCRIBE_PRE_HOOK:-}" ] && [ -x "${QUARTET_SCRIBE_PRE_HOOK}" ]; then
  echo "[$SVC] running pre-hook $QUARTET_SCRIBE_PRE_HOOK" >> "$LOG_FILE"
  "$QUARTET_SCRIBE_PRE_HOOK" >> "$LOG_FILE" 2>&1 || true
fi

# Build prompt = role.md + project scribe.md + RUN CONTEXT.
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

MODEL="${SCRIBE_MODEL:-sonnet}"
HARNESS="${SCRIBE_HARNESS:-claude}"
PROVIDER="${SCRIBE_PROVIDER:-}"
: > "$RESULT_FILE"

# timeout replaces the retired per-invocation dollar ceiling as the runaway
# guard; the json envelope gives real token usage for the daily gate.
spawn_model --harness "$HARNESS" --model "$MODEL" --provider "$PROVIDER" \
  --prompt "$PROMPT" --log "$LOG_FILE" --timeout "$WALL_CLOCK" \
  --skip-perms --json
CLAUDE_OUT="$SPAWN_RAW"; EXIT="$SPAWN_RC"; TOKENS="$SPAWN_TOKENS"
echo "[$SVC] claude exit=$EXIT" >> "$LOG_FILE"
[[ "$TOKENS" =~ ^[0-9]+$ ]] || TOKENS=0
# Keep the operator debug trail the text mode used to provide.
jq -r '.result // empty' <<<"$CLAUDE_OUT" >> "$LOG_FILE" 2>/dev/null || true

# Determine pass/fail. Scribe's own result.json is the source of truth;
# a non-zero claude exit alone isn't enough (it may have written the
# result before crashing).
if [ -s "$RESULT_FILE" ]; then
  PASS="$(jq -r '.pass // false' "$RESULT_FILE" 2>/dev/null || echo false)"
else
  PASS="false"
fi
if [ "$PASS" = "true" ]; then JOB_STATUS="ok"; else JOB_STATUS="fail"; fi
# A nonzero claude exit with a usable result is a PARTIAL run — never ok.
[ "$JOB_STATUS" = "ok" ] && [ "$EXIT" -ne 0 ] && JOB_STATUS="partial"

# Count diffed files inside content_paths only — no commits to anything else.
CHANGED=0
if [ "$(jq 'length' <<<"$CONTENT_PATHS_JSON")" -gt 0 ]; then
  # Build a porcelain query restricted to content_paths.
  PATHSPECS=()
  while read -r p; do
    [ -n "$p" ] && PATHSPECS+=("$p")
  done < <(jq -r '.[]' <<<"$CONTENT_PATHS_JSON")
  if [ "${#PATHSPECS[@]}" -gt 0 ]; then
    CHANGED=$(git status --porcelain -- "${PATHSPECS[@]}" 2>/dev/null | wc -l | xargs)
  fi
fi
echo "[$SVC] changed_files=$CHANGED in content_paths" >> "$LOG_FILE"

# Auto-commit (daily mode only, if enabled, if there's drift).
# Pathspec-scoped commit: only paths inside content_paths land in the
# commit, even if the worktree has other staged changes. This protects
# against scribe accidentally vacuuming up an in-progress edit.
COMMIT_OUTCOME="skipped"
if [ "$MODE" = "daily" ] && [ "$AUTO_COMMIT" = "true" ] && [ "$CHANGED" -gt 0 ]; then
  git add -- "${PATHSPECS[@]}" >> "$LOG_FILE" 2>&1 || true
  # `-m` MUST precede the `--` pathspec separator; otherwise `-m` and the
  # message are parsed as pathnames and git rejects them with "pathspec
  # '-m' did not match any file(s) known to git", silently dropping the
  # commit while the runner returns ok.
  if git commit -m "$COMMIT_PREFIX ($CHANGED file(s))

Co-Authored-By: $SVC <noreply@anthropic.com>" -- "${PATHSPECS[@]}" >> "$LOG_FILE" 2>&1; then
    COMMIT_OUTCOME="ok"
    if [ "$AUTO_PUSH" = "true" ]; then
      if git push origin "$(git rev-parse --abbrev-ref HEAD)" >> "$LOG_FILE" 2>&1; then
        COMMIT_OUTCOME="pushed"
      else
        COMMIT_OUTCOME="committed_push_failed"
      fi
    fi
  else
    COMMIT_OUTCOME="commit_failed"
    JOB_STATUS="fail"
  fi
fi

# Notify only on failure — successful nightly refreshes are noise.
if [ "$JOB_STATUS" = "fail" ] && true; then
  quartet_notify "$SVC FAILED ($MODE)" \
    "exit=$EXIT changed=$CHANGED — see $LOG_FILE" || true
fi

JOB_DUR=$(( $(date +%s) - JOB_START ))

# Trailer — emits job.end. --no-escalate because scribe failures
# aren't medic territory.
# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/post-run.sh"
agent_finish "$SVC" "$PROJECT_DIR" "$JOB_STATUS" "$JOB_DUR" \
  --no-escalate \
  mode="$MODE" exit_code="$EXIT" tokens="$TOKENS" changed="$CHANGED" \
  commit_outcome="$COMMIT_OUTCOME" >> "$LOG_FILE" 2>&1

echo "[$SVC] done status=$JOB_STATUS changed=$CHANGED commit=$COMMIT_OUTCOME" >> "$LOG_FILE"
exit 0
