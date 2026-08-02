#!/bin/bash
# agents/release/runner.sh — generic release wrapper.
#
# Usage:
#   runner.sh --project DIR --mode {hook|daily}
#   runner.sh --project DIR --mode post-merge --merge-sha SHA
#   runner.sh --project DIR --check-config   # print effective gates, read-only
#
# Reads <project>/.agents/config.toml. Prompt = agents/release/role.md
# + <project>/.agents/release.md + RUN CONTEXT block. Writes result to
# <project>/tmp/<svc>-result.json. Trailer via
# agents/lib/post-run.sh emits job.end and (on fail) escalates to medic.
#
# post-merge mode is deterministic — runs the project's test_cmd +
# typecheck against the current checkout, no Claude invocation. Used
# by medic post-build-merge to validate before retrigger.

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
PROJECT_PROMPT="$PROJECT_DIR/.agents/release.md"
[ -f "$CONFIG_FILE" ]    || { echo "config not found: $CONFIG_FILE" >&2; exit 2; }
if [ "$CHECK_CONFIG" -eq 0 ]; then
  [ -f "$ROLE_FILE" ]      || { echo "role.md not found: $ROLE_FILE" >&2; exit 2; }
  [ -f "$PROJECT_PROMPT" ] || { echo "project release.md not found: $PROJECT_DIR/.agents/" >&2; exit 2; }
fi

# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/load-config.sh"
# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/post-run.sh"
# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/spawn.sh"
# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/release-verdict.sh"
CFG_JSON="$(load_config_json "$CONFIG_FILE")" || \
  { echo "failed to parse $CONFIG_FILE" >&2; exit 2; }

PROJECT_NAME="$(jq -r '.project_name' <<<"$CFG_JSON")"

# Canonical role identity + resolved display name (svc string). Legacy
# configs (no [names] block) resolve the display to the role id "release";
# stay exactly as they are today.
ROLE="release"
export QUARTET_ROLE="$ROLE"
# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/naming.sh"
DISPLAY="$(role_display "$ROLE" "$CFG_JSON")"
DISPLAY_TITLE="$(display_title "$DISPLAY")"
SVC="$PROJECT_NAME-$DISPLAY"

RESULT_DIR_REL="$(jq -r '.paths.result_dir // "tmp"' <<<"$CFG_JSON")"
TEST_CMD="$(jq -r '.release.test_cmd // "npx vitest run"' <<<"$CFG_JSON")"
TYPECHECK_CMD="$(jq -r '.release.typecheck // "npx tsc --noEmit"' <<<"$CFG_JSON")"
BUDGET_TOKENS="$(jq -r '.release.budget_tokens_daily // 1000000' <<<"$CFG_JSON")"
[[ "$BUDGET_TOKENS" =~ ^[0-9]+$ ]] || BUDGET_TOKENS=1000000
WALL_CLOCK="$(jq -r '.release.wall_clock_sec // 3600' <<<"$CFG_JSON")"

# ---------- optional runner-owned blocking gate -----------------------------
# Validate the complete opt-in table before job.start, model invocation, or
# result-file creation. Unset remains byte-for-byte the legacy path.
BLOCKING_GATE_CONFIGURED=0
BLOCKING_GATE_JSON="null"
if jq -e '.release | type == "object" and has("blocking_gate")' \
     <<<"$CFG_JSON" >/dev/null 2>&1; then
  BLOCKING_GATE_CONFIGURED=1
  BLOCKING_GATE_JSON="$(jq -c '.release.blocking_gate' <<<"$CFG_JSON")"
  if ! jq -e '
    type == "object"
    and keys == ["command", "modes", "result_key", "timeout_sec"]
    and (.command | type == "string")
    and (.command | test("[^[:space:]]"))
    and (.result_key | type == "string")
    and (.result_key | test("[^[:space:]]"))
    and (.timeout_sec | type == "number")
    and (.timeout_sec | . > 0 and floor == .)
    and (.modes | type == "array")
    and (.modes | length > 0)
    and all(.modes[]; type == "string" and (. == "hook" or . == "daily"))
  ' <<<"$BLOCKING_GATE_JSON" >/dev/null 2>&1; then
    echo "invalid [release.blocking_gate]: require exactly command, timeout_sec, modes, result_key" >&2
    exit 2
  fi
fi

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
    --arg test_cmd "$TEST_CMD" \
    --arg typecheck "$TYPECHECK_CMD" \
    --argjson cfg "$CFG_JSON" \
    '{agent:$agent, role:$role, display:$display,
      project:$cfg.project_name, project_dir:$dir, trunk:$trunk,
      can_merge:($cfg.medic.can_merge // false),
      allow_no_ci:($cfg.build.allow_no_ci // false),
      test_cmd:$test_cmd, typecheck:$typecheck,
      blocking_gate:($cfg.release.blocking_gate // null),
      budgets:{budget_tokens_daily:($cfg.release.budget_tokens_daily // 1000000)}}'
  exit 0
fi

outcome_lineage_start_run "$CFG_JSON" || {
  echo "failed to initialize outcome lineage" >&2
  exit 2
}

RESULT_DIR="$PROJECT_DIR/$RESULT_DIR_REL"
mkdir -p "$RESULT_DIR"
RESULT_FILE="$RESULT_DIR/$SVC-result.json"
LOG_FILE="$RESULT_DIR/$SVC-last-run.log"
WORK_RESULT_FILE="$RESULT_FILE"
BLOCKING_GATE_ACTIVE=0
if [ "$BLOCKING_GATE_CONFIGURED" -eq 1 ] && \
   jq -e --arg mode "$MODE" '.modes | index($mode) != null' \
     <<<"$BLOCKING_GATE_JSON" >/dev/null 2>&1; then
  BLOCKING_GATE_ACTIVE=1
  # Same directory/filesystem as RESULT_FILE. The suffix remains recognizable
  # to existing harness stubs that locate "*-release-result.json" in prompts.
  WORK_RESULT_FILE="$RESULT_DIR/.$SVC-stage-$$-release-result.json"
  trap 'rm -f -- "$WORK_RESULT_FILE"' EXIT
fi

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
JOB_START="$(date +%s)"
cd "$PROJECT_DIR"

# Capture the caller-visible checkout state before the model can touch it.
# Only byte-for-byte unchanged, pre-existing dirt can later be classified as
# hygiene rather than a release failure.
INITIAL_WORKTREE_STATUS="$(git status --porcelain 2>/dev/null || true)"
if [ -n "$INITIAL_WORKTREE_STATUS" ]; then
  INITIAL_WORKTREE_DIRTY=true
else
  INITIAL_WORKTREE_DIRTY=false
fi

[ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$SVC" job.start \
  mode="$MODE" project="$PROJECT_NAME" || true

# ---------- post-merge: deterministic, no Claude ----------------------------
if [ "$MODE" = "post-merge" ]; then
  PM_LOG="$RESULT_DIR/$SVC-post-merge.log"
  echo "[$SVC] post-merge $(now_iso) merge_sha=$MERGE_SHA" > "$PM_LOG"
  HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  if [ -n "$MERGE_SHA" ] && [ "$HEAD_SHA" != "$MERGE_SHA" ] \
     && [ "${HEAD_SHA:0:${#MERGE_SHA}}" != "$MERGE_SHA" ]; then
    echo "[$SVC] WARN: HEAD ($HEAD_SHA) != merge_sha ($MERGE_SHA)" >> "$PM_LOG"
  fi

  PM_STATUS="ok"; PM_REASON=""
  set +e
  echo "[$SVC] $TYPECHECK_CMD" >> "$PM_LOG"
  eval "$TYPECHECK_CMD" >> "$PM_LOG" 2>&1
  TC_RC=$?
  echo "[$SVC] $TEST_CMD" >> "$PM_LOG"
  eval "$TEST_CMD" >> "$PM_LOG" 2>&1
  TS_RC=$?
  set -e
  [ "$TC_RC" != "0" ] && { PM_STATUS="fail"; PM_REASON="tsc_failed"; }
  [ "$TS_RC" != "0" ] && { PM_STATUS="fail"; PM_REASON="${PM_REASON:+$PM_REASON,}vitest_failed"; }

  PM_DUR=$(( $(date +%s) - JOB_START ))
  # Direct log_event — do NOT use agent_finish here (medic invoked us;
  # escalating back to medic would loop on a different surface).
  [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$SVC" job.end \
    mode="post-merge" status="$PM_STATUS" duration_s="$PM_DUR" \
    merge_sha="$MERGE_SHA" reason="${PM_REASON:-none}" || true

  [ "$PM_STATUS" = "ok" ] && exit 0 || exit 1
fi

# ---------- hook | daily: invoke Claude -------------------------------------
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
  [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$SVC" release.skipped \
    reason=budget tokens_used="$TOKENS_USED" budget="$BUDGET_TOKENS" || true
  BUDGET_EPISODE="$(agent_episode "$PROJECT_NAME" "$ROLE" "$MODE" budget "")"
  quartet_notify --class routine --episode "$BUDGET_EPISODE" "$SVC (budget)" \
    "over daily token budget ($TOKENS_USED/$BUDGET_TOKENS); run skipped until tomorrow" || true
  JOB_DUR=$(( $(date +%s) - JOB_START ))
  [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$SVC" job.end \
    mode="$MODE" status="skipped" reason="budget" duration_s="$JOB_DUR" \
    tokens_used="$TOKENS_USED" budget="$BUDGET_TOKENS" || true
  exit 0
fi

MODEL="${RELEASE_MODEL:-sonnet}"
HARNESS="${RELEASE_HARNESS:-claude}"
PROVIDER="${RELEASE_PROVIDER:-}"

RUNNER_OWNED_GATE="null"
if [ "$BLOCKING_GATE_ACTIVE" -eq 1 ]; then
  RUNNER_OWNED_GATE="$(jq -c '. + {
    runner_owned: true,
    instruction: "Do not run this command; the release runner executes it synchronously after your result."
  }' <<<"$BLOCKING_GATE_JSON")"
fi

if [ "$BLOCKING_GATE_ACTIVE" -eq 1 ]; then
  RUN_CONTEXT="$(jq -n \
    --arg mode "$MODE" \
    --arg name "$PROJECT_NAME" \
    --arg dir "$PROJECT_DIR" \
    --arg ts "$(now_iso)" \
    --arg result_file "$WORK_RESULT_FILE" \
    --argjson initial_worktree_dirty "$INITIAL_WORKTREE_DIRTY" \
    --arg initial_worktree_status "$INITIAL_WORKTREE_STATUS" \
    --argjson runner_owned_gate "$RUNNER_OWNED_GATE" \
    --argjson cfg "$CFG_JSON" \
    '{mode:$mode, project_name:$name, project_dir:$dir, timestamp:$ts,
      result_file:$result_file,
      initial_worktree:{dirty:$initial_worktree_dirty,status:$initial_worktree_status},
      runner_owned_gate:$runner_owned_gate, config:$cfg}')"
else
  # Keep the same initial-worktree evidence available when the blocking-gate
  # capability is absent or does not match this mode.
  RUN_CONTEXT="$(jq -n \
    --arg mode "$MODE" \
    --arg name "$PROJECT_NAME" \
    --arg dir "$PROJECT_DIR" \
    --arg ts "$(now_iso)" \
    --arg result_file "$RESULT_FILE" \
    --argjson initial_worktree_dirty "$INITIAL_WORKTREE_DIRTY" \
    --arg initial_worktree_status "$INITIAL_WORKTREE_STATUS" \
    --argjson cfg "$CFG_JSON" \
    '{mode:$mode, project_name:$name, project_dir:$dir, timestamp:$ts,
      result_file:$result_file,
      initial_worktree:{dirty:$initial_worktree_dirty,status:$initial_worktree_status},
      config:$cfg}')"
fi

PROMPT="$(cat "$ROLE_FILE")

---

$(cat "$PROJECT_PROMPT")

---

RUN CONTEXT (write your result to $WORK_RESULT_FILE — JSON only, no prose):

$RUN_CONTEXT"

# [release] stall_retries (default 0 = today's behavior exactly): a transient
# mid-stream stall shows up as the model producing NO result.json. When set,
# retry the spawn — bounded, short backoff — before letting the job fail, so a
# one-off network stall self-heals in-process instead of triggering a medic
# retry storm (proposal shipyard:3b5a75e8). A run that WROTE a verdict (pass
# OR fail) is a real result and is NEVER retried; only a no-result stall is.
STALL_RETRIES="$(jq -r '.release.stall_retries // 0' <<<"$CFG_JSON")"
[[ "$STALL_RETRIES" =~ ^[0-9]+$ ]] || STALL_RETRIES=0
[ "$STALL_RETRIES" -gt 3 ] && STALL_RETRIES=3   # runaway guard

_stall_attempt=0
while : ; do
  : > "$WORK_RESULT_FILE"

  # timeout replaces the retired per-invocation dollar ceiling as the runaway
  # guard; the json envelope gives real token usage for the daily gate.
  spawn_model --harness "$HARNESS" --model "$MODEL" --provider "$PROVIDER" \
    --prompt "$PROMPT" --log "$LOG_FILE" --timeout "$WALL_CLOCK" \
    --skip-perms --json
  CLAUDE_OUT="$SPAWN_RAW"; EXIT="$SPAWN_RC"; TOKENS="$SPAWN_TOKENS"
  # Keep the operator debug trail the text mode used to provide.
  jq -r '.result // empty' <<<"$CLAUDE_OUT" >> "$LOG_FILE" 2>/dev/null || true

  # Break on a written verdict (real result) or once retries are exhausted.
  if [ -s "$WORK_RESULT_FILE" ] || [ "$_stall_attempt" -ge "$STALL_RETRIES" ]; then
    break
  fi
  _stall_attempt=$(( _stall_attempt + 1 ))
  echo "[$SVC] model stalled (no result.json); retry $_stall_attempt/$STALL_RETRIES" >> "$LOG_FILE"
  [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$SVC" release.stall.retry \
    mode="$MODE" attempt="$_stall_attempt" max="$STALL_RETRIES" || true
  sleep "${RELEASE_STALL_BACKOFF_SEC:-3}"
done

# If the Claude run died without writing results (budget cut, timeout,
# or the session backgrounded a step and exited — real incident),
# synthesize a valid failure result. Downstream consumers (medic
# post-run, telemetry) feed this file to `jq --argjson`; a 0-byte file
# poisons them because jq exits 0 with empty output on empty input.
if [ ! -s "$WORK_RESULT_FILE" ]; then
  jq -n --arg ts "$(now_iso)" --arg mode "$MODE" --argjson exit "$EXIT" --arg d "$DISPLAY" '{
    pass: false, mode: $mode, timestamp: $ts,
    errors: ["\($d) claude run exited (\($exit)) without writing result.json"]
  }' > "$WORK_RESULT_FILE"
  echo "[$SVC] claude run wrote no result.json; synthesized failure result" >> "$LOG_FILE"
fi

# The model result stays private until this foreground command has exited and
# its status has been reconciled. A model-written claim for this key is ignored.
FINAL_EXIT="$EXIT"
if [ "$BLOCKING_GATE_ACTIVE" -eq 1 ]; then
  BLOCKING_GATE_COMMAND="$(jq -r '.command' <<<"$BLOCKING_GATE_JSON")"
  BLOCKING_GATE_TIMEOUT="$(jq -r '.timeout_sec' <<<"$BLOCKING_GATE_JSON")"
  BLOCKING_GATE_RESULT_KEY="$(jq -r '.result_key' <<<"$BLOCKING_GATE_JSON")"

  if ! jq empty "$WORK_RESULT_FILE" >/dev/null 2>&1; then
    jq -n --arg ts "$(now_iso)" --arg mode "$MODE" '{
      pass:false, mode:$mode, timestamp:$ts,
      errors:["release model wrote invalid result JSON"]
    }' >"$WORK_RESULT_FILE"
  fi

  echo "[$SVC] blocking_gate start key=$BLOCKING_GATE_RESULT_KEY timeout_s=$BLOCKING_GATE_TIMEOUT" >>"$LOG_FILE"
  timeout "$BLOCKING_GATE_TIMEOUT" bash -o pipefail -c "$BLOCKING_GATE_COMMAND" >>"$LOG_FILE" 2>&1
  BLOCKING_GATE_EXIT=$?
  echo "[$SVC] blocking_gate end key=$BLOCKING_GATE_RESULT_KEY exit=$BLOCKING_GATE_EXIT" >>"$LOG_FILE"

  _bg_tmp="$(mktemp "$RESULT_DIR/.$SVC-blocking-gate.XXXXXX")"
  if [ "$BLOCKING_GATE_EXIT" -eq 0 ]; then
    FINAL_WORKTREE_STATUS="$(git status --porcelain 2>/dev/null || true)"
    jq --arg key "$BLOCKING_GATE_RESULT_KEY" \
       --arg initial_worktree "$INITIAL_WORKTREE_STATUS" \
       --arg final_worktree "$FINAL_WORKTREE_STATUS" '
      def runner_pending_error:
        type == "string" and startswith("run-in-progress");
      def hygiene_error:
        type == "string"
        and (ascii_downcase | contains("worktree"))
        and (ascii_downcase | contains("pre-existing"))
        and (ascii_downcase | contains("notify-only"));
      . as $model
      | [($model.errors // [])[] | select(hygiene_error)] as $hygiene
      | (
          $model.pass == false
          and $model.incomplete == true
          and (($model[$key].status // "") == "run-in-progress")
          and (($model.errors // []) | type == "array")
          and (($model.errors // []) | length > 0)
          and all(($model.errors // [])[];
            type == "string" and startswith("run-in-progress"))
        ) as $only_runner_gate_pending
      | (
          $model.pass == false
          and $model.incomplete == true
          and (($model[$key].status // "") == "run-in-progress")
          and ($initial_worktree | length) > 0
          and $final_worktree == $initial_worktree
          and (($model.errors // []) | type == "array")
          and (($model.hygieneNotifications // []) | type == "array")
          and ($hygiene | length) > 0
          and all(($model.errors // [])[];
            runner_pending_error or hygiene_error)
          and (($model.vitest.failed // null) == 0)
          and (($model.pytest.failed // null) == 0)
          and (($model.typecheck.errors // null) == 0)
          and (($model.build.ok // false) == true)
          and (($model.scriptChecks // null) | type == "object")
          and ($model.scriptChecks.worktreeClean == false)
          and all($model.scriptChecks | to_entries[];
            .key == "worktreeClean" or .value == true)
          and (($model.dbIssues // null) | type == "array")
          and (($model.dbIssues | length) == 0)
          and (($model.fixAttempts // null) | type == "array")
          and all($model.fixAttempts[];
            ((.outcome // "") != "failed"))
          and (
            ($model.security // null) == null
            or (
              (($model.security.auditCritical // 0) == 0)
              and (($model.security.headerIssues // []) | length) == 0
              and (($model.security.secretsHits // []) | length) == 0
              and (($model.security.headersOk // true) == true)
            )
          )
        ) as $preexisting_hygiene_only
      | .[$key] = {status:"completed", pass:true, exitCode:0}
      | del(.incomplete)
      | .errors = [(.errors // [])[] |
          select(
            (runner_pending_error | not)
            and (($preexisting_hygiene_only and hygiene_error) | not)
          )]
      | if $preexisting_hygiene_only then
          .hygieneNotifications =
            (((.hygieneNotifications // []) + $hygiene) | unique)
          | .pass = true
        elif $only_runner_gate_pending then
          .pass = true
        else
          .
        end
    ' "$WORK_RESULT_FILE" >"$_bg_tmp"
  else
    _bg_error="runner-owned blocking gate $BLOCKING_GATE_RESULT_KEY failed (exit $BLOCKING_GATE_EXIT)"
    jq --arg key "$BLOCKING_GATE_RESULT_KEY" \
       --argjson rc "$BLOCKING_GATE_EXIT" --arg error "$_bg_error" '
      .[$key] = {status:"completed", pass:false, exitCode:$rc}
      | .pass = false
      | del(.incomplete)
      | .errors = ([((.errors // [])[]) |
          select((type != "string") or (startswith("run-in-progress") | not))] + [$error])
    ' "$WORK_RESULT_FILE" >"$_bg_tmp"
    FINAL_EXIT="$BLOCKING_GATE_EXIT"
  fi
  mv -f -- "$_bg_tmp" "$WORK_RESULT_FILE"
fi

# Determine pass/fail from result.json (caller-written).
if [ -s "$WORK_RESULT_FILE" ]; then
  PASS="$(jq -r '.pass // false' "$WORK_RESULT_FILE" 2>/dev/null || echo false)"
else
  PASS="false"
fi

if [ "$PASS" = "true" ]; then JOB_STATUS="ok"; else JOB_STATUS="fail"; fi
# A nonzero claude exit with a usable result is a PARTIAL run — never ok.
[ "$JOB_STATUS" = "ok" ] && [ "$EXIT" -ne 0 ] && JOB_STATUS="partial"

# An unfinished run (wall-clock timeout / SIGKILL, or the caller's
# "run-in-progress" sentinel left as the verdict) is NOT a failed check.
# JOB_STATUS/escalation are deliberately unchanged — only the human alarm and
# the dashboard's dispatch-item minting key off this flag (see release-verdict.sh).
INCOMPLETE=0
if [ "$PASS" != "true" ] && release_incomplete "$EXIT" "$WORK_RESULT_FILE"; then
  INCOMPLETE=1
  # Stamp the result so the hub's guardianItems skips minting a false
  # "proctor failed" dispatch item from an unfinished run.
  if [ -s "$WORK_RESULT_FILE" ]; then
    _iv_tmp="$(mktemp "$RESULT_DIR/.$SVC-incomplete.XXXXXX")"
    if jq '. + {incomplete: true}' "$WORK_RESULT_FILE" > "$_iv_tmp" 2>/dev/null; then
      mv "$_iv_tmp" "$WORK_RESULT_FILE"
    else
      rm -f "$_iv_tmp"
    fi
  fi
fi

# ---- false-green guard ([release] verify_gate; unset = today's behavior) ----
# In hook/daily mode the MODEL self-reports its verdict; a careless or
# hallucinating run can write pass:true with check numbers that never ran
# (overseer 2026-07-25: caladan's proctor reported vitest/typecheck JS numbers
# in a pure-Python repo). When verify_gate is set, actually run the project's
# typecheck + test_cmd and OVERRIDE a claimed pass to fail if either really
# fails — so a false green can't reach medic or the dispatch. post-merge already
# runs the gate deterministically, so it is exempt.
VERIFY_GATE="$(jq -r '.release.verify_gate // false' <<<"$CFG_JSON")"
if [ "$VERIFY_GATE" = "true" ] && [ "$PASS" = "true" ] && [ "$INCOMPLETE" -eq 0 ] && [ "$MODE" != "post-merge" ]; then
  echo "[$SVC] verify_gate: reconciling model pass against the real gate" >> "$LOG_FILE"
  eval "$TYPECHECK_CMD" >> "$LOG_FILE" 2>&1; VG_TC=$?
  eval "$TEST_CMD"      >> "$LOG_FILE" 2>&1; VG_TS=$?
  if [ "$VG_TC" -ne 0 ] || [ "$VG_TS" -ne 0 ]; then
    echo "[$SVC] FALSE GREEN caught: model reported pass but real gate failed (tsc=$VG_TC test=$VG_TS)" >> "$LOG_FILE"
    PASS="false"; JOB_STATUS="fail"
    _fg_tmp="$(mktemp "$RESULT_DIR/.$SVC-false-green.XXXXXX")"
    if jq --arg e "false-green caught: model reported pass:true but the real gate failed (typecheck rc=$VG_TC, test rc=$VG_TS)" \
         '. + {pass:false, false_green_caught:true, errors:((.errors // []) + [$e])}' \
         "$WORK_RESULT_FILE" > "$_fg_tmp" 2>/dev/null; then mv "$_fg_tmp" "$WORK_RESULT_FILE"; else rm -f "$_fg_tmp"; fi
  fi
fi

# The process status is part of the release verdict consumed by hooks and
# pipeline callers. A harness can finish its one-shot turn successfully while
# writing pass:false (including a run-in-progress sentinel); never let that
# transport success escape as a green runner exit. Preserve every genuine
# nonzero harness or runner-owned-gate code for exact diagnosis.
if [ "$PASS" != "true" ] && [ "$FINAL_EXIT" -eq 0 ]; then
  FINAL_EXIT=1
fi

# Build category tag from the result fields (project-specific structure
# but the field names are stable across release-style runs).
CATEGORY="$(python3 - "$WORK_RESULT_FILE" <<'PY' 2>/dev/null || echo unknown
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
SUMMARY="$(tail -30 "$LOG_FILE" | grep -A20 -i "RELEASE RESULT" | head -10 || true)"
[ -z "$SUMMARY" ] && SUMMARY="$SVC completed (mode=$MODE, exit=$FINAL_EXIT). See $LOG_FILE."
HYGIENE_COUNT="$(jq -r '
  if ((.hygieneNotifications // null) | type) == "array"
  then (.hygieneNotifications | length)
  else 0
  end' "$WORK_RESULT_FILE" 2>/dev/null || echo 0)"
[[ "$HYGIENE_COUNT" =~ ^[0-9]+$ ]] || HYGIENE_COUNT=0
if [ "$PASS" = "true" ] && [ "$HYGIENE_COUNT" -gt 0 ]; then
  SUMMARY="$(jq -r '"Release gates passed with pre-existing worktree hygiene advisory:\n"
    + ((.hygieneNotifications // []) | join("\n"))' "$WORK_RESULT_FILE")"
  RUN_CLASS="actionable"; RUN_CAUSE="hygiene"
elif [ "$PASS" = "true" ]; then
  RUN_CLASS="routine"; RUN_CAUSE="pass"
elif [ "$INCOMPLETE" -eq 1 ]; then
  RUN_CLASS="routine"; RUN_CAUSE="incomplete"
else
  RUN_CLASS="actionable"; RUN_CAUSE="gate_failure"
fi
RUN_EPISODE="$(agent_episode "$PROJECT_NAME" "$ROLE" "$MODE" "$RUN_CAUSE" "$WORK_RESULT_FILE")"

# Matching-mode runs publish exactly once, after reconciliation, with a
# same-directory rename. Until this point RESULT_FILE is absent or the previous
# complete verdict byte-for-byte.
if [ "$BLOCKING_GATE_ACTIVE" -eq 1 ]; then
  mv -f -- "$WORK_RESULT_FILE" "$RESULT_FILE"
fi

quartet_notify --class "$RUN_CLASS" --episode "$RUN_EPISODE" \
  "$(release_notify_title "$PROJECT_NAME" "$DISPLAY_TITLE" "$MODE" "$PASS" "$INCOMPLETE")" \
  "$SUMMARY" || true

JOB_DUR=$(( $(date +%s) - JOB_START ))

# Emit job.end + (on fail) escalate to medic, via shared trailer.
agent_finish "$SVC" "$PROJECT_DIR" "$JOB_STATUS" "$JOB_DUR" \
  --episode "$RUN_EPISODE" mode="$MODE" exit_code="$FINAL_EXIT" tokens="$TOKENS" \
  category="$CATEGORY" >> "$LOG_FILE" 2>&1

echo "[$SVC] done pass=$PASS exit=$FINAL_EXIT" >> "$LOG_FILE"
exit "$FINAL_EXIT"
