#!/bin/bash
# agents/augur/runner.sh — generic augur wrapper.
#
# Live and dry-run modes run natively here (nightly feedback triage →
# autonomous PRs). Incident mode is the medic handoff path — single
# incident, sync invocation, with self-merge gate.
#
# Usage:
#   runner.sh --project DIR --mode live
#   runner.sh --project DIR --mode dry-run
#   runner.sh --project DIR --mode incident --incident-file PATH
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
CHECK_CONFIG=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project)        PROJECT_DIR="$2"; shift 2 ;;
    --mode)           MODE="$2"; shift 2 ;;
    --incident-file)  INCIDENT_FILE="$2"; shift 2 ;;
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
# Trunk branch — config wins, else origin/HEAD; unresolvable fails loudly.
TRUNK_BRANCH="$(detect_trunk "$CFG_JSON" "$PROJECT_DIR")" || exit 2
RESULT_DIR_REL="$(jq -r '.paths.result_dir // "tmp"' <<<"$CFG_JSON")"
WORKTREE_DIR_REL="$(jq -r '.paths.worktree_dir // ".worktrees"' <<<"$CFG_JSON")"

# ---------- --check-config: print effective gates, then stop ----------------
# STRICTLY read-only: no result files, no events, no claude, no gh.
if [ "$CHECK_CONFIG" -eq 1 ]; then
  jq -n \
    --arg agent "augur" \
    --arg dir "$PROJECT_DIR" \
    --arg trunk "$TRUNK_BRANCH" \
    --argjson cfg "$CFG_JSON" \
    '{agent:$agent, project:$cfg.project_name, project_dir:$dir, trunk:$trunk,
      can_merge:($cfg.medic.augur_can_merge // false),
      allow_no_ci:($cfg.augur.allow_no_ci // false),
      in_scope_paths:($cfg.augur.in_scope_paths // []),
      forbidden_paths:($cfg.augur.forbidden_paths // []),
      budgets:{live_usd:($cfg.augur.budget // 2.00),
               incident_usd:($cfg.augur.budget_incident // 1.50),
               wall_clock_sec:($cfg.augur.wall_clock_sec // 3600)}}'
  exit 0
fi

RESULT_DIR="$PROJECT_DIR/$RESULT_DIR_REL"
WORKTREE_DIR="$PROJECT_DIR/$WORKTREE_DIR_REL"
mkdir -p "$RESULT_DIR" "$WORKTREE_DIR"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---------- live / dry-run: native handling ---------------------------------
if [ "$MODE" = "live" ] || [ "$MODE" = "dry-run" ]; then
  ROLE_FILE="$SCRIPT_DIR/role.md"
  PROJECT_PROMPT="$PROJECT_DIR/.agents/augur.md"
  [ -f "$ROLE_FILE" ]      || { echo "role.md missing: $ROLE_FILE" >&2; exit 2; }
  [ -f "$PROJECT_PROMPT" ] || { echo "project augur.md missing: $PROJECT_PROMPT" >&2; exit 2; }

  WALL_CLOCK="$(jq -r '.augur.wall_clock_sec // 3600' <<<"$CFG_JSON")"
  BUDGET="$(jq -r '.augur.budget // 2.00' <<<"$CFG_JSON")"
  PROJECT_OWNER="$(jq -r '.project_owner // ""' <<<"$CFG_JSON")"

  RESULT_FILE="$RESULT_DIR/$PROJECT_NAME-augur-result.json"
  LOG_FILE="$RESULT_DIR/$PROJECT_NAME-augur-last-run.log"
  FYI_LOG="$PROJECT_DIR/$(jq -r '.augur.fyi_log // "data/fyi-requests.jsonl"' <<<"$CFG_JSON")"

  JOB_START="$(date +%s)"
  echo "[$PROJECT_NAME-augur] $(now_iso) start mode=$MODE" > "$LOG_FILE"
  [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$PROJECT_NAME-augur" job.start \
    mode="$MODE" project="$PROJECT_NAME" || true

  cd "$PROJECT_DIR"

  # Pre-flight: live only. dry-run does no git ops, so skip.
  if [ "$MODE" = "live" ]; then
    if [ -n "$(git status --porcelain)" ]; then
      echo "[$PROJECT_NAME-augur] ABORT: main checkout dirty" >> "$LOG_FILE"
      git status --short >> "$LOG_FILE"
      quartet_notify "$PROJECT_NAME Augur aborted ($MODE)" \
        "Main checkout has uncommitted changes." || true
      [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$PROJECT_NAME-augur" job.end \
        mode="$MODE" status="abort" reason="dirty" || true
      exit 1
    fi
    CB="$(git rev-parse --abbrev-ref HEAD)"
    if [ "$CB" != "$TRUNK_BRANCH" ]; then
      echo "[$PROJECT_NAME-augur] ABORT: not on $TRUNK_BRANCH ($CB)" >> "$LOG_FILE"
      quartet_notify "$PROJECT_NAME Augur aborted ($MODE)" \
        "Current branch is $CB, not $TRUNK_BRANCH." || true
      [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$PROJECT_NAME-augur" job.end \
        mode="$MODE" status="abort" reason="not_trunk" || true
      exit 1
    fi
    git fetch origin "$TRUNK_BRANCH" --quiet 2>>"$LOG_FILE" || true
    if [ -n "$(git rev-list "origin/$TRUNK_BRANCH..$TRUNK_BRANCH" 2>/dev/null)" ]; then
      echo "[$PROJECT_NAME-augur] pushing local $TRUNK_BRANCH ahead-of-origin commits" >> "$LOG_FILE"
      git push origin "$TRUNK_BRANCH" >> "$LOG_FILE" 2>&1 || {
        [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$PROJECT_NAME-augur" job.end \
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
  echo "[$PROJECT_NAME-augur] claude exit=$EXIT" >> "$LOG_FILE"

  # Live mode only — clean up any worktrees augur left behind. Belt-and-
  # suspenders for the case where claude crashed mid-run.
  if [ "$MODE" = "live" ]; then
    while read -r wt; do
      [ -z "$wt" ] && continue
      path="$(awk '{print $1}' <<<"$wt")"
      case "$path" in
        *"/.worktrees/augur-"*|*"/.worktrees/medic-incident-"*)
          echo "[$PROJECT_NAME-augur] cleanup leftover worktree $path" >> "$LOG_FILE"
          git worktree remove --force "$path" 2>>"$LOG_FILE" || true ;;
      esac
    done < <(git worktree list --porcelain 2>/dev/null | grep '^worktree ' | sed 's/^worktree //')
  fi

  # Build human-facing summary. Project may ship its own formatter at
  # scripts/augur-format-signal.mjs (optional per-project); fall back to a
  # generic line if not.
  FMT="$PROJECT_DIR/scripts/augur-format-signal.mjs"
  SUMMARY_FILE="$RESULT_DIR/$PROJECT_NAME-augur-signal.txt"
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
  agent_finish "$PROJECT_NAME-augur" "$PROJECT_DIR" "$JOB_STATUS" "$JOB_DUR" \
    mode="$MODE" exit_code="$EXIT" >> "$LOG_FILE" 2>&1

  echo "[$PROJECT_NAME-augur] done pass=$PASS exit=$EXIT" >> "$LOG_FILE"
  exit "$EXIT"
fi

if [ "$MODE" != "incident" ]; then
  echo "unknown mode: $MODE" >&2; exit 2
fi

[ -z "$INCIDENT_FILE" ] && { echo "--incident-file required for incident mode" >&2; exit 2; }
[ -f "$INCIDENT_FILE" ] || { echo "incident file not found: $INCIDENT_FILE" >&2; exit 2; }

# ---------- incident-mode setup ---------------------------------------------
INCIDENT_ID="$(jq -r '.incident_id' "$INCIDENT_FILE")"
INCIDENT_SUMMARY="$(jq -r '.summary // "(no summary)"' "$INCIDENT_FILE")"
ID_PREFIX="${INCIDENT_ID:0:12}"
BRANCH="medic-incident-$ID_PREFIX"
WORKTREE_PATH="$WORKTREE_DIR/medic-incident-$ID_PREFIX"
RESULT_FILE="$RESULT_DIR/$PROJECT_NAME-augur-result.json"
LOG_FILE="$RESULT_DIR/$PROJECT_NAME-augur-incident-$ID_PREFIX.log"

INCIDENT_BUDGET="$(jq -r '.augur.budget_incident // 1.50' <<<"$CFG_JSON")"
WALL_CLOCK="$(jq -r '.augur.wall_clock_sec // 3600' <<<"$CFG_JSON")"
AUGUR_CAN_MERGE="$(jq -r '.medic.augur_can_merge // false' <<<"$CFG_JSON")"
ALLOW_NO_CI="$(jq -r '.augur.allow_no_ci // false' <<<"$CFG_JSON")"
IN_SCOPE_PATHS="$(jq -c '.augur.in_scope_paths // []' <<<"$CFG_JSON")"
FORBIDDEN_PATHS="$(jq -c '.augur.forbidden_paths // []' <<<"$CFG_JSON")"

JOB_START="$(date +%s)"
echo "[augur-incident] $(now_iso) start id=$INCIDENT_ID branch=$BRANCH" > "$LOG_FILE"
[ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$PROJECT_NAME-augur" job.start \
  mode="incident" incident_id="$INCIDENT_ID" project="$PROJECT_NAME" || true

write_failure() {
  # write_failure <reason>
  jq -n \
    --arg ts "$(now_iso)" \
    --arg iid "$INCIDENT_ID" \
    --arg br "$BRANCH" \
    --arg reason "$1" \
    '{pass:false, incident_id:$iid, branch:$br, pr_url:"", merge_sha:"",
      files_changed:[], errors:[$reason], timestamp:$ts}' > "$RESULT_FILE"
  JOB_DUR=$(( $(date +%s) - JOB_START ))
  [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$PROJECT_NAME-augur" job.end \
    mode="incident" status="fail" reason="$1" duration_s="$JOB_DUR" \
    incident_id="$INCIDENT_ID" || true
}

# Pre-flight: clean trunk checkout, on the trunk branch, push if ahead.
cd "$PROJECT_DIR"
if [ -n "$(git status --porcelain)" ]; then
  echo "[augur-incident] ABORT: trunk checkout dirty" >> "$LOG_FILE"
  git status --short >> "$LOG_FILE"
  write_failure "trunk_checkout_dirty"
  exit 1
fi
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT_BRANCH" != "$TRUNK_BRANCH" ]; then
  echo "[augur-incident] ABORT: not on $TRUNK_BRANCH ($CURRENT_BRANCH)" >> "$LOG_FILE"
  write_failure "not_on_trunk"
  exit 1
fi
git fetch origin "$TRUNK_BRANCH" --quiet 2>>"$LOG_FILE" || true
if [ -n "$(git rev-list "origin/$TRUNK_BRANCH..$TRUNK_BRANCH" 2>/dev/null)" ]; then
  git push origin "$TRUNK_BRANCH" >> "$LOG_FILE" 2>&1 || {
    write_failure "push_trunk_failed"; exit 1
  }
fi

# Create the worktree on a fresh branch from origin/$TRUNK_BRANCH.
if [ -e "$WORKTREE_PATH" ]; then
  git worktree remove --force "$WORKTREE_PATH" >> "$LOG_FILE" 2>&1 || true
fi
git worktree add -B "$BRANCH" "$WORKTREE_PATH" "origin/$TRUNK_BRANCH" >> "$LOG_FILE" 2>&1 || {
  write_failure "worktree_add_failed"; exit 1
}

# ---------- assemble prompt -------------------------------------------------
ROLE_FILE="$SCRIPT_DIR/incident-role.md"

INCIDENT_JSON="$(cat "$INCIDENT_FILE")"
RUN_CONTEXT="$(jq -n \
  --argjson cfg "$CFG_JSON" \
  --argjson inc "$INCIDENT_JSON" \
  --arg wt "$WORKTREE_PATH" \
  --arg br "$BRANCH" \
  --arg rf "$RESULT_FILE" \
  '{config:$cfg, incident:$inc, worktree:$wt, branch:$br, result_file:$rf}')"

# Project-specific augur prompt extension (optional).
PROJECT_AUGUR_MD="$PROJECT_DIR/.agents/augur.md"
PROJECT_BLOCK=""
[ -f "$PROJECT_AUGUR_MD" ] && PROJECT_BLOCK="$(cat "$PROJECT_AUGUR_MD")

---
"

PROMPT="$(cat "$ROLE_FILE")

---

$PROJECT_BLOCK
RUN CONTEXT (work entirely inside $WORKTREE_PATH; write your result to $RESULT_FILE — JSON only, no prose):

$RUN_CONTEXT"

MODEL="${AUGUR_MODEL:-sonnet}"

# ---------- invoke claude ---------------------------------------------------
: > "$RESULT_FILE"

set +e
cd "$WORKTREE_PATH"
timeout "$WALL_CLOCK" claude -p \
  --model "$MODEL" \
  --dangerously-skip-permissions \
  --max-budget-usd "$INCIDENT_BUDGET" \
  --output-format text \
  "$PROMPT" \
  >> "$LOG_FILE" 2>&1
CLAUDE_EXIT=$?
set -e
cd "$PROJECT_DIR"
echo "[augur-incident] claude exit=$CLAUDE_EXIT" >> "$LOG_FILE"

# ---------- evaluate result + self-merge gate -------------------------------
cleanup_worktree() {
  git worktree remove --force "$WORKTREE_PATH" >> "$LOG_FILE" 2>&1 || true
}

if [ ! -s "$RESULT_FILE" ]; then
  cleanup_worktree
  write_failure "claude_wrote_no_result"
  exit 1
fi

PASS="$(jq -r '.pass // false' "$RESULT_FILE")"
PR_URL="$(jq -r '.pr_url // ""' "$RESULT_FILE")"

if [ "$PASS" != "true" ] || [ -z "$PR_URL" ]; then
  cleanup_worktree
  # Augur reported failure inline — preserve its result, just confirm
  # status=fail in the event stream.
  JOB_DUR=$(( $(date +%s) - JOB_START ))
  [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$PROJECT_NAME-augur" job.end \
    mode="incident" status="fail" duration_s="$JOB_DUR" \
    incident_id="$INCIDENT_ID" || true
  exit 1
fi

# Pull the PR number from the URL (last URL segment).
PR_NUM="$(echo "$PR_URL" | awk -F/ '{print $NF}')"
echo "[augur-incident] PR opened: $PR_URL (#$PR_NUM)" >> "$LOG_FILE"

# ---------- self-merge gate -------------------------------------------------
gate_fail() {
  echo "[augur-incident] gate FAIL: $1" >> "$LOG_FILE"
  cleanup_worktree
  jq --arg reason "$1" '. + {merge_sha:"", errors: ((.errors // []) + [$reason])}' \
    "$RESULT_FILE" > "$RESULT_FILE.tmp" && mv "$RESULT_FILE.tmp" "$RESULT_FILE"
  # Dedicated lifecycle event so the dashboard can join a "merge_blocked"
  # state without falling back to job.end. Carries the PR URL so
  # /incidents can link to the PR even when no merge happened.
  [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$PROJECT_NAME-augur" augur.incident.merge_blocked \
    incident_id="$INCIDENT_ID" project="$PROJECT_NAME" \
    pr_url="$PR_URL" reason="$1" || true
  quartet_notify "Augur incident PR opened ($PROJECT_NAME)" \
    "PR: $PR_URL"$'\n'"Merge gate failed: $1. Human review needed."
  JOB_DUR=$(( $(date +%s) - JOB_START ))
  [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$PROJECT_NAME-augur" job.end \
    mode="incident" status="merge_blocked" reason="$1" duration_s="$JOB_DUR" \
    incident_id="$INCIDENT_ID" pr_url="$PR_URL" || true
  exit 0  # not an augur failure — PR is open, just wasn't merged
}

# Gate 1 — kill switch.
if [ "$AUGUR_CAN_MERGE" != "true" ]; then
  gate_fail "merge_disabled_by_config"
fi

# Gate 2 — branch name matches medic-incident-*.
if ! [[ "$BRANCH" == medic-incident-* ]]; then
  gate_fail "branch_name_mismatch"
fi

# Gate 3 — diff against trunk touches only in_scope_paths, no forbidden_paths.
# Use python with fnmatch for glob-style path matching against the config arrays.
DIFF_FILES="$(git diff --name-only "origin/$TRUNK_BRANCH...origin/$BRANCH" 2>/dev/null)"
if [ -z "$DIFF_FILES" ]; then
  gate_fail "no_diff_against_trunk"
fi
echo "[augur-incident] diff files:" >> "$LOG_FILE"
echo "$DIFF_FILES" >> "$LOG_FILE"

GATE_CHECK="$(python3 - <<PY
import fnmatch, json, sys
in_scope  = json.loads('''$IN_SCOPE_PATHS''')
forbidden = json.loads('''$FORBIDDEN_PATHS''')
files = """$DIFF_FILES""".strip().splitlines()
def match_any(path, patterns):
    return any(fnmatch.fnmatch(path, p) for p in patterns)
out_of_scope, hits_forbidden = [], []
for f in files:
    if match_any(f, forbidden):
        hits_forbidden.append(f)
    if not match_any(f, in_scope):
        out_of_scope.append(f)
if hits_forbidden:
    print("forbidden_path:" + hits_forbidden[0]); sys.exit(0)
if out_of_scope:
    print("out_of_scope:" + out_of_scope[0]); sys.exit(0)
print("ok")
PY
)"
if [ "$GATE_CHECK" != "ok" ]; then
  gate_fail "$GATE_CHECK"
fi

# Gate 4 — CI green. Wait up to 15 min.
echo "[augur-incident] waiting for CI on PR #$PR_NUM" >> "$LOG_FILE"
CI_WAIT_DEADLINE=$(( $(date +%s) + 900 ))
CI_STATE="pending"
while [ "$(date +%s)" -lt "$CI_WAIT_DEADLINE" ]; do
  CI_RAW="$(gh pr checks "$PR_NUM" --json state 2>/dev/null || echo '[]')"
  if [ -z "$CI_RAW" ] || [ "$CI_RAW" = "[]" ]; then
    CI_STATE="no_checks"; break
  fi
  if jq -e 'all(.state == "SUCCESS" or .state == "NEUTRAL" or .state == "SKIPPED")' \
       <<<"$CI_RAW" >/dev/null; then
    CI_STATE="green"; break
  fi
  if jq -e 'any(.state == "FAILURE" or .state == "CANCELLED" or .state == "TIMED_OUT")' \
       <<<"$CI_RAW" >/dev/null; then
    CI_STATE="failed"; break
  fi
  sleep 30
done

case "$CI_STATE" in
  green)  echo "[augur-incident] CI ok (green)" >> "$LOG_FILE" ;;
  no_checks)
    # Zero CI checks is NOT green — it only passes when the project has
    # explicitly opted in, and even then the waiver is emitted loudly so
    # the dashboard/owner can see merges that skipped CI.
    if [ "$ALLOW_NO_CI" = "true" ]; then
      echo "[augur-incident] CI has no checks — waived (augur.allow_no_ci=true)" >> "$LOG_FILE"
      [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$PROJECT_NAME-augur" augur.incident.ci_waived \
        incident_id="$INCIDENT_ID" project="$PROJECT_NAME" pr_url="$PR_URL" || true
    else
      gate_fail "ci_no_checks"
    fi ;;
  failed)           gate_fail "ci_failed" ;;
  pending)          gate_fail "ci_timeout" ;;
  *)                gate_fail "ci_unknown_state:$CI_STATE" ;;
esac

# All gates green — merge.
# Clean up the worktree FIRST so the local branch ref is freed before
# `gh pr merge --delete-branch` tries to delete it. Otherwise the
# remote merge succeeds but gh exits non-zero ("cannot delete branch
# used by worktree at ..."), and we'd misclassify a real merge as
# merge_command_failed. Empirically observed on PR #14 — merge
# happened, but augur aborted before running post-merge guardian.
echo "[augur-incident] cleanup worktree pre-merge" >> "$LOG_FILE"
cleanup_worktree

echo "[augur-incident] merging PR #$PR_NUM" >> "$LOG_FILE"
gh pr merge "$PR_NUM" --squash --delete-branch >> "$LOG_FILE" 2>&1
GH_MERGE_RC=$?

# Defense in depth: even with the cleanup-first fix, network blips or
# gh-side glitches can produce non-zero exits when the merge actually
# happened on GitHub. Confirm with the API before declaring failure.
if [ "$GH_MERGE_RC" != "0" ]; then
  PR_STATE="$(gh pr view "$PR_NUM" --json state -q .state 2>/dev/null || echo UNKNOWN)"
  if [ "$PR_STATE" = "MERGED" ]; then
    echo "[augur-incident] gh exited $GH_MERGE_RC but PR is MERGED — proceeding" >> "$LOG_FILE"
  else
    gate_fail "merge_command_failed"
  fi
fi

# Pull trunk to capture the new HEAD.
git fetch origin "$TRUNK_BRANCH" --quiet 2>>"$LOG_FILE"
git checkout "$TRUNK_BRANCH" >> "$LOG_FILE" 2>&1
git reset --hard "origin/$TRUNK_BRANCH" >> "$LOG_FILE" 2>&1
MERGE_SHA="$(git rev-parse HEAD)"
echo "[augur-incident] merged at $MERGE_SHA" >> "$LOG_FILE"

# Update result.json with merge_sha.
jq --arg sha "$MERGE_SHA" '. + {merge_sha:$sha}' "$RESULT_FILE" > "$RESULT_FILE.tmp" \
  && mv "$RESULT_FILE.tmp" "$RESULT_FILE"

JOB_DUR=$(( $(date +%s) - JOB_START ))
[ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$PROJECT_NAME-augur" job.end \
  mode="incident" status="ok" duration_s="$JOB_DUR" \
  incident_id="$INCIDENT_ID" pr_url="$PR_URL" merge_sha="$MERGE_SHA" || true

echo "[augur-incident] done — incident=$INCIDENT_ID merged at $MERGE_SHA" >> "$LOG_FILE"
exit 0
