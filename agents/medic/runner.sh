#!/bin/bash
# agents/medic/runner.sh — generic medic wrapper for any project that has
# dropped a `.agents/` install (config.toml + medic.md).
#
# Usage:
#   runner.sh --project <dir> --mode scan
#   runner.sh --project <dir> --mode post-run --incident-source <agent>
#   runner.sh --project <dir> --mode scan --dry-run
#
# Modes:
#   scan     — invoked by systemd timer; walk ops.json + (optionally) chat
#              DB, build candidate incidents, classify, act.
#   post-run — invoked by an agent's post-run hook after that agent failed;
#              build a single incident from <agent>'s result.json.
#
# Recursion guard: medic refuses to run if --incident-source is "medic".
# The runner only invokes ONE agent ever as a child (augur, in incident
# mode) and never invokes another medic.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUARTET_DIR="${QUARTET_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
LOG_EVENT="$QUARTET_DIR/agents/lib/log_event.sh"

export QUARTET_SOURCE="${QUARTET_SOURCE:-system}"

# ---------- argv parsing ----------------------------------------------------
PROJECT_DIR=""
MODE=""
INCIDENT_SOURCE=""
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project)         PROJECT_DIR="$2"; shift 2 ;;
    --mode)            MODE="$2"; shift 2 ;;
    --incident-source) INCIDENT_SOURCE="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,16p' "$0"; exit 0 ;;
    *)
      echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -z "$PROJECT_DIR" ] && { echo "--project required" >&2; exit 2; }
[ -d "$PROJECT_DIR" ] || { echo "project dir not found: $PROJECT_DIR" >&2; exit 2; }
[ -z "$MODE" ] && { echo "--mode required (scan|post-run)" >&2; exit 2; }
case "$MODE" in scan|post-run) ;; *) echo "bad --mode: $MODE" >&2; exit 2 ;; esac
[ "$MODE" = "post-run" ] && [ -z "$INCIDENT_SOURCE" ] && \
  { echo "--incident-source required for post-run" >&2; exit 2; }

# Recursion guard.
if [ "$INCIDENT_SOURCE" = "medic" ]; then
  echo "medic-recursion: refusing to triage a medic failure (would loop)" >&2
  exit 0
fi

CONFIG_FILE="$PROJECT_DIR/.agents/config.toml"
MEDIC_PROMPT_PROJECT="$PROJECT_DIR/.agents/medic.md"
MEDIC_PROMPT_ROLE="$SCRIPT_DIR/role.md"
[ -f "$CONFIG_FILE" ] || { echo "config not found: $CONFIG_FILE" >&2; exit 2; }
[ -f "$MEDIC_PROMPT_ROLE" ] || { echo "role.md not found: $MEDIC_PROMPT_ROLE" >&2; exit 2; }
[ -f "$MEDIC_PROMPT_PROJECT" ] || { echo "project medic.md not found: $MEDIC_PROMPT_PROJECT" >&2; exit 2; }

# ---------- config loader ---------------------------------------------------
source "$QUARTET_DIR/agents/lib/load-config.sh"
CFG_JSON="$(load_config_json "$CONFIG_FILE")" || \
  { echo "failed to parse $CONFIG_FILE" >&2; exit 2; }

# Cherry-pick fields we need into shell vars (jq -r is fine here).
PROJECT_NAME="$(echo "$CFG_JSON" | jq -r '.project_name // ""')"
# Trunk branch name — `master` by default; override in config.toml.
TRUNK_BRANCH="$(echo "$CFG_JSON" | jq -r '.branch // "master"')"
DEV_PORT="$(echo "$CFG_JSON" | jq -r '.dev_port // empty')"
DAILY_CAP="$(echo "$CFG_JSON" | jq -r '.medic.daily_escalation_cap // 5')"
POLL_INTERVAL="$(echo "$CFG_JSON" | jq -r '.medic.poll_interval_sec // 600')"
SYNC_TO_AUGUR="$(echo "$CFG_JSON" | jq -r '.medic.sync_to_augur // true')"
RESTART_SYSTEMD="$(echo "$CFG_JSON" | jq -r '.medic.restart_systemd // true')"
# Optional project-defined restart command for restart-class incidents that
# have no local user-unit to bounce (e.g. an HTTP probe outage on a service
# managed outside `systemctl --user`). Unset = current behavior (no-op).
RESTART_CMD="$(echo "$CFG_JSON" | jq -r '.medic.restart_cmd // empty')"
AUGUR_CAN_MERGE="$(echo "$CFG_JSON" | jq -r '.medic.augur_can_merge // true')"
AUGUR_WALL_CLOCK="$(echo "$CFG_JSON" | jq -r '.augur.wall_clock_sec // 3600')"
RESULT_DIR_REL="$(echo "$CFG_JSON" | jq -r '.paths.result_dir // "tmp"')"

[ -z "$PROJECT_NAME" ] && { echo "config missing project_name" >&2; exit 2; }

RESULT_DIR="$PROJECT_DIR/$RESULT_DIR_REL"
mkdir -p "$RESULT_DIR"

STATE_FILE="$RESULT_DIR/medic-state.json"
RESULT_FILE="$RESULT_DIR/medic-result.json"
LOG_FILE="$RESULT_DIR/medic-last-run.log"
INCIDENTS_FILE="$RESULT_DIR/medic-incidents-current.json"
AUGUR_LOCK="$RESULT_DIR/augur.lock"

# ---------- state file (init / read) ----------------------------------------
init_state() {
  if [ ! -s "$STATE_FILE" ]; then
    cat > "$STATE_FILE" <<'JSON'
{
  "watermarks": {
    "chats.last_seen_created_at": null,
    "runners.last_seen_event_id": null
  },
  "cooldowns": {},
  "daily_escalations": {}
}
JSON
  fi
}
init_state

today_utc() { date -u +%Y-%m-%d; }
now_iso()   { date -u +%Y-%m-%dT%H:%M:%SZ; }

state_get() { jq -r "$1" "$STATE_FILE"; }
state_set() {
  # state_set <jq-filter>
  local tmp
  tmp="$(mktemp)"
  jq "$1" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

DAY="$(today_utc)"
DAILY_USED="$(state_get ".daily_escalations[\"$DAY\"] // 0")"

# ---------- bookkeeping for the run -----------------------------------------
JOB_START="$(date +%s)"
echo "[medic] $(now_iso) starting mode=$MODE project=$PROJECT_NAME dry_run=$DRY_RUN" > "$LOG_FILE"
[ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$PROJECT_NAME-medic" job.start \
  mode="$MODE" project="$PROJECT_NAME" || true

# ---------- detect: build candidate incidents -------------------------------
# Each incident is a JSON object that matches the schema documented in
# agents/medic/role.md. We accumulate into $CANDIDATES (a JSON array string).
CANDIDATES='[]'

push_incident() {
  # push_incident <json-object>
  # Guard the accumulator: a caller that assembled its payload from a
  # corrupt source (e.g. a 0-byte result.json — jq exits 0 with EMPTY
  # output on empty input, so `|| echo null` guards never fire) must
  # not poison $CANDIDATES. A poisoned accumulator cascades: jq
  # 'length' returns "", and `[ "" -eq 0 ]` aborts the run (2026-06-05
  # real incident).
  if [ -z "$1" ]; then
    echo "[medic] push_incident: empty payload, skipping" >> "$LOG_FILE"
    return
  fi
  local updated
  if ! updated="$(jq --argjson obj "$1" '. + [$obj]' <<<"$CANDIDATES" 2>>"$LOG_FILE")"; then
    echo "[medic] push_incident: invalid payload, skipping" >> "$LOG_FILE"
    return
  fi
  CANDIDATES="$updated"
}

stable_id() {
  # stable_id <fields...>  →  sha256 of joined fields, hex
  printf '%s' "$*" | sha256sum | awk '{print $1}'
}

# --- Detect: post-run incident (single-shot) -------------------------------
detect_post_run() {
  local result_json="$PROJECT_DIR/$RESULT_DIR_REL/$INCIDENT_SOURCE-result.json"
  local log_file="$PROJECT_DIR/$RESULT_DIR_REL/$INCIDENT_SOURCE-last-run.log"
  local result_excerpt='null'
  local log_tail=""
  if [ -f "$result_json" ]; then
    # jq exits 0 with EMPTY output on a 0-byte file, so `|| echo null`
    # alone doesn't cover the empty-result case (exactly what a dead
    # guardian run leaves behind — the case medic post-run exists for).
    result_excerpt="$(jq -c '.' "$result_json" 2>/dev/null || echo 'null')"
    [ -z "$result_excerpt" ] && result_excerpt='null'
  fi
  if [ -f "$log_file" ]; then
    log_tail="$(tail -200 "$log_file" 2>/dev/null || true)"
  fi
  local id; id="$(stable_id "$INCIDENT_SOURCE" "$(now_iso)" "$PROJECT_NAME" post-run)"
  push_incident "$(jq -n \
    --arg id "$id" \
    --arg src "$INCIDENT_SOURCE" \
    --arg surface "runners" \
    --arg summary "$INCIDENT_SOURCE failed (post-run hook)" \
    --argjson rj "$result_excerpt" \
    --arg log "$log_tail" \
    --arg rjp "$result_json" \
    '{incident_id:$id, source:$src, surface:$surface, summary:$summary,
      evidence:{log_tail:$log, result_json_path:$rjp, result_json_excerpt:$rj}}')"
}

# --- Detect: scan runners surface ------------------------------------------
detect_scan_runners() {
  local ops="${QUARTET_OPS_JSON:-}"
  [ -f "$ops" ] || { echo "[medic] ops.json not found, skipping runners scan" >> "$LOG_FILE"; return; }

  # Filter to units whose name matches project_name (e.g. <project>-*).
  # Stale crons (ageSec > 10x interval) and failed systemd units.
  local matched
  matched="$(jq -c --arg name "$PROJECT_NAME" '
    def parse_interval(s):
      if (s|startswith("every ")) then
        ((s|capture("every (?<n>[0-9]+) min").n // "0") | tonumber * 60)
      else 86400 end;
    [
      (.cron[]?
        | select(.name | startswith($name))
        | select(.ageSec >= 10 * parse_interval(.schedule))
        | {kind:"cron-stale", name, schedule, ageSec, command, log,
           lastRun, type:"cron"}),
      (.systemd[]?
        | select(.name | startswith($name))
        | select(.state == "failed")
        | {kind:"systemd-failed", name, state, description,
           timerSchedule, type:"systemd"})
    ]
  ' "$ops")"

  local n; n="$(jq 'length' <<<"$matched")"
  echo "[medic] scan-runners found $n candidate(s) for $PROJECT_NAME" >> "$LOG_FILE"

  local i=0
  while [ "$i" -lt "$n" ]; do
    local item; item="$(jq -c ".[$i]" <<<"$matched")"
    local kind name
    kind="$(jq -r '.kind' <<<"$item")"
    name="$(jq -r '.name' <<<"$item")"
    local id; id="$(stable_id "$kind" "$name" "$DAY")"

    # Dedupe: skip if already in cooldown today.
    local cool; cool="$(state_get ".cooldowns[\"$id\"] // null")"
    if [ "$cool" != "null" ]; then
      echo "[medic] skip $name ($kind) — cooldown active" >> "$LOG_FILE"
      i=$((i+1)); continue
    fi

    # Deterministic self-failure guard: if the failed unit is *this*
    # project's own augur or medic, classify as forbidden without
    # consulting Claude. Augur cannot fix itself (its runtime lives in
    # forbidden_paths) and medic invoking augur to fix medic is a
    # recursion. Without this guard, Claude's classification is
    # non-deterministic — observed in production where the same
    # incident was classified `regression` on tick N (escalating to
    # augur, which aborted dirty-trunk) and `forbidden` on tick N+1.
    # We bake in the right answer.
    if [ "$name" = "$PROJECT_NAME-augur" ] || [ "$name" = "$PROJECT_NAME-medic" ]; then
      echo "[medic] self-failure $name → auto-classify forbidden, skip Claude" >> "$LOG_FILE"
      local until_ts
      until_ts="$(date -u -d '+24 hours' +%Y-%m-%dT%H:%M:%SZ)"
      state_set ".cooldowns[\"$id\"] = {\"frozen_until\":\"$until_ts\",\"reason\":\"self_failure\"}"
      [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$PROJECT_NAME-medic" medic.incident.frozen \
        incident_id="$id" project="$PROJECT_NAME" frozen_until="$until_ts" \
        reason="self_failure" unit="$name" || true
      quartet_notify "Medic $PROJECT_NAME (self_failure)" \
        "$name systemd unit failed. Cannot self-escalate (forbidden_paths recursion). Frozen 24h — needs human inspection." || true
      i=$((i+1)); continue
    fi

    # Pull a log tail if there's a log path.
    local log_path log_tail=""
    log_path="$(jq -r '.log // ""' <<<"$item")"
    if [ -n "$log_path" ] && [ -f "$log_path" ]; then
      log_tail="$(tail -200 "$log_path" 2>/dev/null || true)"
    fi

    # Recent commits in the project (helps augur form a hypothesis).
    local commits='[]'
    if [ -d "$PROJECT_DIR/.git" ]; then
      commits="$(cd "$PROJECT_DIR" && git log -5 --pretty=format:'{"sha":"%h","msg":"%s"}' 2>/dev/null \
        | jq -sc '.' 2>/dev/null || echo '[]')"
    fi

    local summary
    if [ "$kind" = "cron-stale" ]; then
      summary="$(jq -r '"\(.name) cron stale: ageSec=\(.ageSec) (sched=\(.schedule))"' <<<"$item")"
    else
      summary="$(jq -r '"\(.name) systemd unit state=failed"' <<<"$item")"
    fi

    push_incident "$(jq -n \
      --arg id "$id" \
      --arg src "$( [ "$kind" = "cron-stale" ] && echo cron || echo systemd )" \
      --arg surface "runners" \
      --arg summary "$summary" \
      --argjson item "$item" \
      --arg log "$log_tail" \
      --argjson commits "$commits" \
      '{incident_id:$id, source:$src, surface:$surface, summary:$summary,
        evidence:{
          log_tail:$log, result_json_path:null, result_json_excerpt:null,
          unit:$item, recent_commits:$commits
        }}')"
    i=$((i+1))
  done
}

# --- Detect: HTTP probes (project-defined liveness checks) -----------------
# Reads `[[medic.probes]]` from the project's config.toml. Each probe is a
# table with: name (str), url (str), expect_status (int, default 200),
# timeout_sec (int, default 10). Synthesizes an incident when the probe
# returns a status other than `expect_status`, including connection
# failures (curl emits 000). Catches outages that don't surface as
# `state == failed` on a local systemd unit — e.g. a clean SIGTERM that
# leaves the service `inactive (dead)`, or an upstream nginx 502 when
# the local Node process exited.
detect_scan_probes() {
  local n_probes
  n_probes="$(echo "$CFG_JSON" | jq '(.medic.probes // []) | length')"
  [ "$n_probes" = "0" ] && return

  echo "[medic] scan-probes: $n_probes configured" >> "$LOG_FILE"

  local i=0
  while [ "$i" -lt "$n_probes" ]; do
    local probe; probe="$(echo "$CFG_JSON" | jq -c ".medic.probes[$i]")"
    local p_name p_url p_expect p_timeout
    p_name="$(jq -r '.name // ""' <<<"$probe")"
    p_url="$(jq -r '.url // ""' <<<"$probe")"
    p_expect="$(jq -r '.expect_status // 200' <<<"$probe")"
    p_timeout="$(jq -r '.timeout_sec // 10' <<<"$probe")"

    if [ -z "$p_name" ] || [ -z "$p_url" ]; then
      echo "[medic] probe $i missing name/url; skipping" >> "$LOG_FILE"
      i=$((i+1)); continue
    fi

    local status_code
    status_code="$(curl -sS -o /dev/null \
      -w "%{http_code}" \
      --max-time "$p_timeout" \
      "$p_url" 2>/dev/null || echo "000")"

    if [ "$status_code" = "$p_expect" ]; then
      echo "[medic] probe $p_name OK ($status_code)" >> "$LOG_FILE"
      i=$((i+1)); continue
    fi

    echo "[medic] probe $p_name UNHEALTHY: got $status_code, expected $p_expect" >> "$LOG_FILE"

    local id; id="$(stable_id "probe" "$p_name" "$DAY")"
    local cool; cool="$(state_get ".cooldowns[\"$id\"] // null")"
    if [ "$cool" != "null" ]; then
      echo "[medic] skip $p_name probe — cooldown active" >> "$LOG_FILE"
      i=$((i+1)); continue
    fi

    local summary
    summary="$p_name probe failed: GET $p_url -> $status_code (expected $p_expect)"

    push_incident "$(jq -n \
      --arg id "$id" \
      --arg src "probe" \
      --arg surface "runners" \
      --arg summary "$summary" \
      --arg name "$p_name" \
      --arg url "$p_url" \
      --arg got "$status_code" \
      --arg expect "$p_expect" \
      '{incident_id:$id, source:$src, surface:$surface, summary:$summary,
        evidence:{
          log_tail:"", result_json_path:null, result_json_excerpt:null,
          probe:{name:$name, url:$url, status_code:$got, expect_status:$expect}
        }}')"
    i=$((i+1))
  done
}

# --- Detect: runner success freshness (project-defined heartbeats) ---------
# Reads `[[medic.freshness]]` from the project's config.toml. Each entry:
#   name          (str)  — incident label
#   log           (str)  — project-relative path to the runner's last-run log
#   success_regex (str)  — marker the run writes on clean completion
#   max_age_hours (int)  — how old the log may be before the run counts as missed
#   grace_hours   (int, default 2) — how long a marker-less log may stay
#                  fresh before it counts as died-mid-flight (covers a run
#                  that is still in progress when medic ticks)
#
# Why this exists (real incident): cron fired on schedule but the
# runner aborted 4s in (auto-updater GC'd its pinned claude binary, then the
# PATH fallback died under cron's bare PATH). detect_scan_runners tracks the
# cron *firing* via ops.json ageSec — and its staleness gate is 10x the
# interval, i.e. 10 days for a daily job — so two consecutive silent
# failures looked perfectly healthy. This surface checks the run *finished*,
# not that it started.
detect_scan_freshness() {
  local n_checks
  n_checks="$(echo "$CFG_JSON" | jq '(.medic.freshness // []) | length')"
  [ "$n_checks" = "0" ] && return

  echo "[medic] scan-freshness: $n_checks configured" >> "$LOG_FILE"

  local i=0
  while [ "$i" -lt "$n_checks" ]; do
    local chk; chk="$(echo "$CFG_JSON" | jq -c ".medic.freshness[$i]")"
    local c_name c_log c_regex c_hours c_grace
    c_name="$(jq -r '.name // ""' <<<"$chk")"
    c_log="$(jq -r '.log // ""' <<<"$chk")"
    c_regex="$(jq -r '.success_regex // ""' <<<"$chk")"
    c_hours="$(jq -r '.max_age_hours // 30' <<<"$chk")"
    c_grace="$(jq -r '.grace_hours // 2' <<<"$chk")"

    if [ -z "$c_name" ] || [ -z "$c_log" ] || [ -z "$c_regex" ]; then
      echo "[medic] freshness $i missing name/log/success_regex; skipping" >> "$LOG_FILE"
      i=$((i+1)); continue
    fi

    local log_path="$PROJECT_DIR/$c_log"
    local reason=""
    if [ ! -f "$log_path" ]; then
      reason="last-run log missing ($c_log) — runner has never completed"
    else
      local age_sec=$(( $(date +%s) - $(stat -c %Y "$log_path") ))
      if [ "$age_sec" -gt $(( c_hours * 3600 )) ]; then
        reason="last-run log is $((age_sec / 3600))h old (max ${c_hours}h) — run missed or silently dead"
      elif ! grep -qE "$c_regex" "$log_path"; then
        if [ "$age_sec" -gt $(( c_grace * 3600 )) ]; then
          reason="success marker absent $((age_sec / 3600))h after last write — run died mid-flight"
        fi
        # else: marker absent but log written < grace_hours ago — a run is
        # likely still in progress; skip this tick.
      fi
    fi

    if [ -z "$reason" ]; then
      echo "[medic] freshness $c_name OK" >> "$LOG_FILE"
      i=$((i+1)); continue
    fi

    echo "[medic] freshness $c_name UNHEALTHY: $reason" >> "$LOG_FILE"

    local id; id="$(stable_id "freshness" "$c_name" "$DAY")"
    local cool; cool="$(state_get ".cooldowns[\"$id\"] // null")"
    if [ "$cool" != "null" ]; then
      echo "[medic] skip $c_name freshness — cooldown active" >> "$LOG_FILE"
      i=$((i+1)); continue
    fi

    local log_tail=""
    [ -f "$log_path" ] && log_tail="$(tail -200 "$log_path" 2>/dev/null || true)"

    local commits='[]'
    if [ -d "$PROJECT_DIR/.git" ]; then
      commits="$(cd "$PROJECT_DIR" && git log -5 --pretty=format:'{"sha":"%h","msg":"%s"}' 2>/dev/null \
        | jq -sc '.' 2>/dev/null || echo '[]')"
    fi

    push_incident "$(jq -n \
      --arg id "$id" \
      --arg src "freshness" \
      --arg surface "runners" \
      --arg summary "$c_name: $reason" \
      --argjson chk "$chk" \
      --arg log "$log_tail" \
      --argjson commits "$commits" \
      '{incident_id:$id, source:$src, surface:$surface, summary:$summary,
        evidence:{
          log_tail:$log, result_json_path:null, result_json_excerpt:null,
          freshness_check:$chk, recent_commits:$commits
        }}')"
    i=$((i+1))
  done
}

# --- Detect: project-defined drift checks -----------------------------------
# Reads `[[medic.checks]]` from the project's config.toml. Each entry:
#   name         (str) — incident label
#   cmd          (str) — bash command run from PROJECT_DIR; nonzero exit
#                        means drift detected. stdout's first line becomes
#                        the incident summary; stdout/stderr tails land in
#                        evidence verbatim so medic + the Signal note can
#                        quote the drift message.
#   timeout_sec  (int, default 30)
#   restart_unit (str, optional) — user systemd unit medic may bounce if
#                        it classifies the incident `restart`. Lands in
#                        evidence as unit.name so the existing restart
#                        path resolves it. Omit for notify-only checks.
#
# Why this exists (real incident): the runtime can drift from repo
# HEAD without any unit going `failed` — a server-path commit lands but
# nobody restarts the app process ("PROD RESTART PENDING"), or the
# frontend auto-deployer silently skips on a dirty tree. Probes see a live
# process; freshness sees a completed run. Only a project-defined check
# can compare "what's running" against "what's at HEAD".
detect_scan_checks() {
  local n_checks
  n_checks="$(echo "$CFG_JSON" | jq '(.medic.checks // []) | length')"
  [ "$n_checks" = "0" ] && return

  echo "[medic] scan-checks: $n_checks configured" >> "$LOG_FILE"

  local i=0
  while [ "$i" -lt "$n_checks" ]; do
    local chk; chk="$(echo "$CFG_JSON" | jq -c ".medic.checks[$i]")"
    local c_name c_cmd c_timeout c_unit
    c_name="$(jq -r '.name // ""' <<<"$chk")"
    c_cmd="$(jq -r '.cmd // ""' <<<"$chk")"
    c_timeout="$(jq -r '.timeout_sec // 30' <<<"$chk")"
    c_unit="$(jq -r '.restart_unit // ""' <<<"$chk")"

    if [ -z "$c_name" ] || [ -z "$c_cmd" ]; then
      echo "[medic] check $i missing name/cmd; skipping" >> "$LOG_FILE"
      i=$((i+1)); continue
    fi

    local err_file out rc
    err_file="$(mktemp)"
    out="$( ( cd "$PROJECT_DIR" && timeout "$c_timeout" bash -c "$c_cmd" ) 2>"$err_file" )"
    rc=$?
    local err; err="$(cat "$err_file")"; rm -f "$err_file"

    if [ "$rc" = "0" ]; then
      echo "[medic] check $c_name OK" >> "$LOG_FILE"
      i=$((i+1)); continue
    fi

    echo "[medic] check $c_name FAILED (exit=$rc)" >> "$LOG_FILE"

    local id; id="$(stable_id "check" "$c_name" "$DAY")"
    local cool; cool="$(state_get ".cooldowns[\"$id\"] // null")"
    if [ "$cool" != "null" ]; then
      echo "[medic] skip $c_name check — cooldown active" >> "$LOG_FILE"
      i=$((i+1)); continue
    fi

    local first_line out_tail err_tail
    first_line="$(head -1 <<<"$out")"
    out_tail="$(tail -40 <<<"$out")"
    err_tail="$(tail -40 <<<"$err")"

    local summary="$c_name check failed: $first_line"

    push_incident "$(jq -n \
      --arg id "$id" \
      --arg src "check" \
      --arg surface "runners" \
      --arg summary "$summary" \
      --arg name "$c_name" \
      --arg rc "$rc" \
      --arg out "$out_tail" \
      --arg err "$err_tail" \
      --arg unit "$c_unit" \
      '{incident_id:$id, source:$src, surface:$surface, summary:$summary,
        evidence:({
          log_tail:"", result_json_path:null, result_json_excerpt:null,
          check:{name:$name, exit_code:($rc|tonumber), stdout_tail:$out, stderr_tail:$err}
        } + (if $unit != "" then {unit:{name:$unit}} else {} end))}')"
    i=$((i+1))
  done
}

# --- Detect: scan chats surface (Phase 1.5 — gated by config) --------------
detect_scan_chats() {
  local db; db="$(echo "$CFG_JSON" | jq -r '.paths.db // empty')"
  [ -z "$db" ] && return
  local db_path="$PROJECT_DIR/$db"
  [ -f "$db_path" ] || return

  local watermark; watermark="$(state_get '.watermarks["chats.last_seen_created_at"] // ""')"
  local where=""
  [ -n "$watermark" ] && where="AND created_at > '$watermark'"

  # Pull the last 50 assistant rows past the watermark via python+sqlite3
  # (python's stdlib sqlite3 is always present; the sqlite3 CLI is not).
  local rows
  rows="$(python3 - "$db_path" "$watermark" <<'PY' 2>/dev/null || echo '[]'
import json, sqlite3, sys
db, wm = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db); conn.row_factory = sqlite3.Row
q = ("SELECT id, conversation_id, user_id, created_at, events_json "
     "FROM chat_messages WHERE role='assistant'")
args = []
if wm:
    q += " AND created_at > ?"; args.append(wm)
q += " ORDER BY created_at DESC LIMIT 50"
rows = [dict(r) for r in conn.execute(q, args).fetchall()]
print(json.dumps(rows))
PY
)"
  [ -z "$rows" ] && rows='[]'

  # For each row, check events_json for turn-level or tool-level errors.
  local errs
  errs="$(jq -c '
    [ .[] as $r
      | ($r.events_json | fromjson? // []) as $events
      | $events as $ev
      | (
          # Turn-level error
          ($ev[]? | select(.type=="result" and .is_error==true)
            | {handle:"turn", row:$r, evt:.}),
          # Tool-level error
          ($ev[]? | select(.type=="user")
            | (.message.content // [])[]
            | select(.type=="tool_result" and .is_error==true)
            | {handle:"tool", row:$r, evt:.})
        )
    ]' <<<"$rows" 2>/dev/null || echo '[]')"

  local n; n="$(jq 'length' <<<"$errs")"
  echo "[medic] scan-chats found $n chat error(s)" >> "$LOG_FILE"

  local i=0
  while [ "$i" -lt "$n" ]; do
    local item; item="$(jq -c ".[$i]" <<<"$errs")"
    local mid handle
    mid="$(jq -r '.row.id' <<<"$item")"
    handle="$(jq -r '.handle' <<<"$item")"
    local id; id="$(stable_id "$mid" "$handle")"

    local cool; cool="$(state_get ".cooldowns[\"$id\"] // null")"
    [ "$cool" != "null" ] && { i=$((i+1)); continue; }

    local summary; summary="chat $handle-error in message $mid"
    push_incident "$(jq -n \
      --arg id "$id" \
      --arg src "chat" \
      --arg surface "chats" \
      --arg summary "$summary" \
      --argjson item "$item" \
      '{incident_id:$id, source:$src, surface:$surface, summary:$summary,
        evidence:{chat_message_id:($item.row.id), chat_evt:$item.evt}}')"
    i=$((i+1))
  done

  # Advance watermark to the newest created_at in this batch (whether or
  # not it had an error — we don't want to re-scan it).
  local newest; newest="$(jq -r 'map(.created_at) | max // empty' <<<"$rows")"
  [ -n "$newest" ] && [ "$newest" != "null" ] && \
    state_set ".watermarks[\"chats.last_seen_created_at\"] = \"$newest\""
}

# Run detection per mode.
if [ "$MODE" = "post-run" ]; then
  detect_post_run
else
  detect_scan_runners
  detect_scan_probes
  detect_scan_freshness
  detect_scan_checks
  detect_scan_chats
fi

INCIDENTS_DETECTED="$(jq 'length' <<<"$CANDIDATES" 2>>"$LOG_FILE")" || INCIDENTS_DETECTED=""
if [ -z "$INCIDENTS_DETECTED" ]; then
  # Accumulator corrupted despite the push_incident guards — treat as a
  # medic-internal error, not "no incidents" (which would hide the
  # original failure that triggered us).
  echo "[medic] FATAL: \$CANDIDATES is not valid JSON; writing error result" >> "$LOG_FILE"
  jq -n --arg ts "$(now_iso)" --arg mode "$MODE" '{
    pass: false, mode: $mode, timestamp: $ts,
    incidents_detected: 0, incidents_classified: [],
    actions_taken: [], augur_invocations: 0,
    augur_lock_contention: 0, daily_cap_hit: false,
    errors: ["medic runner: incident accumulator corrupted (invalid JSON)"]
  }' > "$RESULT_FILE"
  exit 1
fi
echo "[medic] detect: $INCIDENTS_DETECTED candidate(s)" >> "$LOG_FILE"

# Persist current incident set for debugging / dashboard.
echo "$CANDIDATES" | jq '.' > "$INCIDENTS_FILE"

# ---------- short-circuit when nothing to triage ----------------------------
if [ "$INCIDENTS_DETECTED" -eq 0 ]; then
  jq -n --arg ts "$(now_iso)" --arg mode "$MODE" '{
    pass: true, mode: $mode, timestamp: $ts,
    incidents_detected: 0, incidents_classified: [],
    actions_taken: [], augur_invocations: 0,
    augur_lock_contention: 0, daily_cap_hit: false, errors: []
  }' > "$RESULT_FILE"
  JOB_DUR=$(( $(date +%s) - JOB_START ))
  [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$PROJECT_NAME-medic" job.end \
    mode="$MODE" status="ok" duration_s="$JOB_DUR" \
    incidents=0 || true
  echo "[medic] no incidents; exiting clean" >> "$LOG_FILE"
  exit 0
fi

# ---------- classify: invoke claude with role.md + medic.md + incidents -----
RUN_CONTEXT="$(jq -n \
  --arg mode "$MODE" \
  --arg name "$PROJECT_NAME" \
  --arg dir "$PROJECT_DIR" \
  --arg today "$DAY" \
  --argjson cfg "$CFG_JSON" \
  --argjson incs "$CANDIDATES" \
  --slurpfile state "$STATE_FILE" \
  '{mode:$mode, project_name:$name, project_dir:$dir, today:$today,
    config:$cfg, state:$state[0], incidents:$incs}')"

PROMPT="$(cat "$MEDIC_PROMPT_ROLE")

---

$(cat "$MEDIC_PROMPT_PROJECT")

---

RUN CONTEXT (write your classified result to $RESULT_FILE — JSON only, no prose):

$RUN_CONTEXT"

MODEL="${MEDIC_MODEL:-sonnet}"
BUDGET="${MEDIC_BUDGET:-0.50}"

echo "[medic] invoking claude (model=$MODEL budget=\$$BUDGET incidents=$INCIDENTS_DETECTED)" >> "$LOG_FILE"

# Wipe any stale result.json so we can detect non-write.
: > "$RESULT_FILE"

set +e
claude -p \
  --model "$MODEL" \
  --dangerously-skip-permissions \
  --max-budget-usd "$BUDGET" \
  --output-format text \
  "$PROMPT" \
  >> "$LOG_FILE" 2>&1
CLAUDE_EXIT=$?
set -e

if [ ! -s "$RESULT_FILE" ]; then
  echo "[medic] claude did not write result file (exit=$CLAUDE_EXIT)" >> "$LOG_FILE"
  jq -n --arg ts "$(now_iso)" --arg mode "$MODE" --arg err "claude wrote no result" '{
    pass: false, mode: $mode, timestamp: $ts,
    incidents_detected: '"$INCIDENTS_DETECTED"',
    incidents_classified: [], actions_taken: [],
    augur_invocations: 0, augur_lock_contention: 0,
    daily_cap_hit: false, errors: [$err]
  }' > "$RESULT_FILE"
  quartet_notify "Medic ($PROJECT_NAME) FAILED" \
    "Medic detected $INCIDENTS_DETECTED incident(s) but claude did not classify. See $LOG_FILE."
  [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$PROJECT_NAME-medic" job.end \
    mode="$MODE" status="fail" exit_code="$CLAUDE_EXIT" || true
  exit 1
fi

# ---------- act: dispatch each classified incident --------------------------
N_CLASS="$(jq '.incidents_classified | length' "$RESULT_FILE")"
echo "[medic] claude classified $N_CLASS incident(s)" >> "$LOG_FILE"

ACTIONS_TAKEN='[]'
AUGUR_INVOCATIONS=0
AUGUR_LOCK_CONTENTION=0
CAP_HIT=false

# Helper: append an action record into ACTIONS_TAKEN.
push_action() {
  ACTIONS_TAKEN="$(jq --argjson obj "$1" '. + [$obj]' <<<"$ACTIONS_TAKEN")"
}

# Helper: emit medic.* event with the shared incident_id key.
emit() {
  # emit <event> <incident_id> [extra_kv...]
  local ev="$1"; shift
  local iid="$1"; shift
  [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$PROJECT_NAME-medic" "$ev" \
    incident_id="$iid" project="$PROJECT_NAME" "$@" || true
}

# Iterate classified incidents.
i=0
while [ "$i" -lt "$N_CLASS" ]; do
  inc="$(jq -c ".incidents_classified[$i]" "$RESULT_FILE")"
  iid="$(jq -r '.incident_id' <<<"$inc")"
  cls="$(jq -r '.class' <<<"$inc")"
  act="$(jq -r '.action' <<<"$inc")"
  surface="$(jq -r '.surface' <<<"$inc")"
  source="$(jq -r '.source' <<<"$inc")"
  summary="$(jq -r '.incident_summary // .hypothesis // ""' <<<"$inc")"

  emit medic.incident.detected "$iid" source="$source" surface="$surface" \
    summary="$summary"
  emit medic.incident.classified "$iid" class="$cls" action="$act"

  # Honor dry-run: classify-only, no side effects.
  if [ "$DRY_RUN" -eq 1 ]; then
    push_action "$(jq -n --arg iid "$iid" --arg act "$act" \
      '{incident_id:$iid, action:$act, outcome:"dry-run"}')"
    i=$((i+1)); continue
  fi

  case "$cls" in
    duplicate)
      push_action "$(jq -n --arg iid "$iid" '{incident_id:$iid, action:"skip", outcome:"duplicate"}')"
      ;;

    forbidden|infra|cap_hit)
      [ "$cls" = "cap_hit" ] && CAP_HIT=true
      quartet_notify "Medic $PROJECT_NAME ($cls)" \
        "Incident: $summary"$'\n'"Action: notify-only ($cls)."
      # Freeze for 24h (cooldown).
      until_ts="$(date -u -d '+24 hours' +%Y-%m-%dT%H:%M:%SZ)"
      state_set ".cooldowns[\"$iid\"] = {\"frozen_until\":\"$until_ts\",\"reason\":\"$cls\"}"
      emit medic.incident.frozen "$iid" frozen_until="$until_ts" reason="$cls"
      push_action "$(jq -n --arg iid "$iid" --arg cls "$cls" \
        '{incident_id:$iid, action:"freeze", outcome:$cls}')"
      ;;

    transient)
      echo "[medic] $iid transient — sleep 30, recheck" >> "$LOG_FILE"
      sleep 30
      # Recheck is best-effort: re-detect runners and see if this id reappears.
      RECHECK='[]'
      detect_scan_runners >/dev/null 2>&1 || true
      RECHECK="$CANDIDATES"
      still="$(jq --arg iid "$iid" '[.[] | select(.incident_id==$iid)] | length' <<<"$RECHECK")"
      if [ "$still" = "0" ]; then
        emit medic.incident.resolved "$iid" via="retry"
        push_action "$(jq -n --arg iid "$iid" '{incident_id:$iid, action:"retry", outcome:"resolved"}')"
      else
        # Promote to notify; don't loop again.
        quartet_notify "Medic $PROJECT_NAME (transient→stuck)" \
          "Retry didn't clear: $summary"
        push_action "$(jq -n --arg iid "$iid" '{incident_id:$iid, action:"retry", outcome:"still_failing"}')"
      fi
      ;;

    restart)
      if [ "$RESTART_SYSTEMD" = "true" ]; then
        unit="$(jq -r '.evidence.unit.name // empty' <<<"$inc")"
        if [ -z "$unit" ]; then
          # Fallback: try matching incidents file.
          unit="$(jq -r --arg iid "$iid" '.[] | select(.incident_id==$iid) | .evidence.unit.name // empty' "$INCIDENTS_FILE")"
        fi
        if [ -n "$unit" ]; then
          echo "[medic] systemctl --user restart $unit" >> "$LOG_FILE"
          systemctl --user restart "$unit" >> "$LOG_FILE" 2>&1
          rc=$?
          outcome=$([ "$rc" = "0" ] && echo "ok" || echo "fail")
          emit medic.action.restart "$iid" unit="$unit" outcome="$outcome"
          push_action "$(jq -n --arg iid "$iid" --arg u "$unit" --arg o "$outcome" \
            '{incident_id:$iid, action:"restart", unit:$u, outcome:$o}')"
        elif [ -n "$RESTART_CMD" ]; then
          # No local user-unit to bounce (e.g. a probe-surface outage):
          # run the project-defined restart command. cwd = PROJECT_DIR so
          # relative paths resolve. Policy: auto-restart THEN alert, then a
          # one-per-UTC-day cooldown so a hard-down service doesn't
          # restart-storm every tick (the probe incident_id rolls over
          # daily, so detection resumes tomorrow).
          echo "[medic] restart_cmd: $RESTART_CMD (cwd=$PROJECT_DIR)" >> "$LOG_FILE"
          ( cd "$PROJECT_DIR" && eval "$RESTART_CMD" ) >> "$LOG_FILE" 2>&1
          rc=$?
          outcome=$([ "$rc" = "0" ] && echo "ok" || echo "fail")
          emit medic.action.restart "$iid" via="restart_cmd" outcome="$outcome"
          quartet_notify "Medic $PROJECT_NAME (restart)" \
            "Incident: $summary"$'\n'"Ran restart_cmd → $outcome. Re-fire suppressed until tomorrow (UTC)."
          until_ts="$(date -u -d '+24 hours' +%Y-%m-%dT%H:%M:%SZ)"
          state_set ".cooldowns[\"$iid\"] = {\"frozen_until\":\"$until_ts\",\"reason\":\"restart_cmd\"}"
          emit medic.incident.frozen "$iid" frozen_until="$until_ts" reason="restart_cmd"
          push_action "$(jq -n --arg iid "$iid" --arg o "$outcome" \
            '{incident_id:$iid, action:"restart", via:"restart_cmd", outcome:$o}')"
        else
          push_action "$(jq -n --arg iid "$iid" '{incident_id:$iid, action:"restart", outcome:"no_unit_name"}')"
        fi
      else
        push_action "$(jq -n --arg iid "$iid" '{incident_id:$iid, action:"restart", outcome:"disabled_by_config"}')"
      fi
      ;;

    regression)
      if [ "$DAILY_USED" -ge "$DAILY_CAP" ]; then
        CAP_HIT=true
        quartet_notify "Medic $PROJECT_NAME (cap_hit)" \
          "Daily augur escalation cap ($DAILY_CAP) reached. Notify-only: $summary"
        push_action "$(jq -n --arg iid "$iid" '{incident_id:$iid, action:"escalate_augur", outcome:"cap_hit"}')"
        i=$((i+1)); continue
      fi
      if [ "$SYNC_TO_AUGUR" != "true" ]; then
        push_action "$(jq -n --arg iid "$iid" '{incident_id:$iid, action:"escalate_augur", outcome:"disabled_by_config"}')"
        i=$((i+1)); continue
      fi

      # Write incident file for augur.
      INC_FILE="$RESULT_DIR/medic-incident-$iid.json"
      jq --argjson inc "$inc" --arg ts "$(now_iso)" \
         --arg src "$INCIDENT_SOURCE" \
         --argjson all "$CANDIDATES" \
         '.[0] as $cfg | {
            incident_id: $inc.incident_id,
            detected_at: $ts,
            source: $inc.source,
            surface: $inc.surface,
            summary: $inc.incident_summary,
            hypothesis: $inc.hypothesis,
            evidence: ($all[] | select(.incident_id==$inc.incident_id) | .evidence)
          }' <<< "[$CFG_JSON]" > "$INC_FILE"

      # Acquire augur.lock with non-blocking flock; on contention, notify.
      AUGUR_RUNNER="$QUARTET_DIR/agents/augur/runner.sh"
      if [ ! -x "$AUGUR_RUNNER" ]; then
        echo "[medic] augur runner not present yet at $AUGUR_RUNNER" >> "$LOG_FILE"
        quartet_notify "Medic $PROJECT_NAME (regression)" \
          "Detected: $summary"$'\n'"Augur runner missing; notify-only."
        push_action "$(jq -n --arg iid "$iid" '{incident_id:$iid, action:"escalate_augur", outcome:"runner_missing"}')"
        i=$((i+1)); continue
      fi

      # Acquire the lock first; only count an invocation once we own it.
      # Variable assignments inside the ( ... ) subshell don't propagate
      # back to the parent — keep counters and event emissions outside.
      exec 9>"$AUGUR_LOCK"
      if flock -n 9; then
        AUGUR_INVOCATIONS=$((AUGUR_INVOCATIONS + 1))
        emit augur.incident.attempted "$iid" mode="incident"
        timeout "$AUGUR_WALL_CLOCK" "$AUGUR_RUNNER" \
          --project "$PROJECT_DIR" \
          --mode incident \
          --incident-file "$INC_FILE" >> "$LOG_FILE" 2>&1
        AUGUR_RC=$?
        echo "[medic] augur exit=$AUGUR_RC" >> "$LOG_FILE"
        flock -u 9
      else
        AUGUR_RC=99
      fi
      exec 9>&-

      if [ "$AUGUR_RC" = "99" ]; then
        AUGUR_LOCK_CONTENTION=$((AUGUR_LOCK_CONTENTION + 1))
        quartet_notify "Medic $PROJECT_NAME (regression)" \
          "Detected: $summary"$'\n'"Augur busy (lock held). Will retry next tick."
        push_action "$(jq -n --arg iid "$iid" '{incident_id:$iid, action:"escalate_augur", outcome:"lock_contention"}')"
        i=$((i+1)); continue
      fi

      # Parse augur result + run retrigger phase.
      AUGUR_RESULT="$RESULT_DIR/$PROJECT_NAME-augur-result.json"
      [ ! -f "$AUGUR_RESULT" ] && AUGUR_RESULT="$RESULT_DIR/augur-result.json"
      if [ -f "$AUGUR_RESULT" ]; then
        AUGUR_PASS="$(jq -r '.pass // false' "$AUGUR_RESULT")"
        PR_URL="$(jq -r '.pr_url // empty' "$AUGUR_RESULT")"
        MERGE_SHA="$(jq -r '.merge_sha // empty' "$AUGUR_RESULT")"
      else
        AUGUR_PASS="false"; PR_URL=""; MERGE_SHA=""
      fi

      # Bump daily counter on any successful escalation attempt
      DAILY_USED=$((DAILY_USED + 1))
      state_set ".daily_escalations[\"$DAY\"] = $DAILY_USED"

      if [ "$AUGUR_PASS" = "true" ] && [ -n "$MERGE_SHA" ]; then
        emit augur.incident.merged "$iid" pr_url="$PR_URL" merge_sha="$MERGE_SHA"

        # Run guardian post-merge against the merge sha.
        GUARDIAN_RUNNER="$QUARTET_DIR/agents/guardian/runner.sh"
        # Legacy fallback: invoke the project's own <project>-guardian.sh launcher.
        if [ ! -x "$GUARDIAN_RUNNER" ]; then
          GUARDIAN_RUNNER="$PROJECT_DIR/scripts/$PROJECT_NAME-guardian.sh"
        fi
        GUARDIAN_OUTCOME="skipped"
        if [ -x "$GUARDIAN_RUNNER" ]; then
          "$GUARDIAN_RUNNER" --mode post-merge --merge-sha "$MERGE_SHA" \
            >> "$LOG_FILE" 2>&1
          GRC=$?
          GUARDIAN_OUTCOME=$([ "$GRC" = "0" ] && echo "ok" || echo "fail")
          emit guardian.post_merge.run "$iid" merge_sha="$MERGE_SHA" outcome="$GUARDIAN_OUTCOME"
        fi

        if [ "$GUARDIAN_OUTCOME" = "fail" ]; then
          # Revert the merge to keep the trunk branch green.
          (cd "$PROJECT_DIR" && git revert --no-edit -m 1 "$MERGE_SHA" \
            >> "$LOG_FILE" 2>&1 && git push origin "$TRUNK_BRANCH" >> "$LOG_FILE" 2>&1) || true
          quartet_notify "Medic $PROJECT_NAME (regression)" \
            "Augur merged $PR_URL but post-merge guardian failed; reverted. Frozen 24h."
          until_ts="$(date -u -d '+24 hours' +%Y-%m-%dT%H:%M:%SZ)"
          state_set ".cooldowns[\"$iid\"] = {\"frozen_until\":\"$until_ts\",\"reason\":\"post_merge_guardian_fail\"}"
          emit medic.incident.frozen "$iid" frozen_until="$until_ts" reason="post_merge_guardian_fail"
          push_action "$(jq -n --arg iid "$iid" --arg pr "$PR_URL" \
            '{incident_id:$iid, action:"escalate_augur", outcome:"post_merge_guardian_fail", pr_url:$pr}')"
        else
          # Retrigger the failed unit (runners surface only in v1).
          RETRIGGER_OUTCOME="skipped"
          if [ "$surface" = "runners" ]; then
            unit="$(jq -r --arg iid "$iid" '.[] | select(.incident_id==$iid) | .evidence.unit.name // empty' "$INCIDENTS_FILE")"
            if [ -n "$unit" ]; then
              if systemctl --user list-units --all | grep -q "$unit"; then
                systemctl --user restart "$unit" >> "$LOG_FILE" 2>&1 \
                  && RETRIGGER_OUTCOME="ok" || RETRIGGER_OUTCOME="fail"
              fi
            fi
          else
            RETRIGGER_OUTCOME="skipped_chat"
          fi
          emit medic.retrigger.attempted "$iid" surface="$surface" outcome="$RETRIGGER_OUTCOME"

          # Final Signal.
          quartet_notify "Medic $PROJECT_NAME (resolved)" \
            "Incident: $summary"$'\n'"PR merged: $PR_URL"$'\n'"Guardian post-merge: $GUARDIAN_OUTCOME"$'\n'"Retrigger: $RETRIGGER_OUTCOME"
          emit medic.incident.resolved "$iid" via="augur-pr"
          push_action "$(jq -n --arg iid "$iid" --arg pr "$PR_URL" --arg rt "$RETRIGGER_OUTCOME" \
            '{incident_id:$iid, action:"escalate_augur", outcome:"resolved", pr_url:$pr, retrigger:$rt}')"
        fi
      else
        # Augur ran but didn't produce a merge. Two cases:
        #   * augur succeeded (pass=true) but the self-merge gate blocked
        #     → outcome=merge_blocked, PR is open for human review
        #   * augur reported failure (pass=false) → outcome=augur_failed
        REASON="$(jq -r '.errors[0] // "no_merge"' "$AUGUR_RESULT" 2>/dev/null || echo "no_result")"
        if [ "$AUGUR_PASS" = "true" ] && [ -n "$PR_URL" ]; then
          OUTCOME="merge_blocked"; FROZEN_REASON="merge_blocked"
        else
          OUTCOME="augur_failed"; FROZEN_REASON="augur_failed"
        fi
        PR_LINE=""
        [ -n "$PR_URL" ] && PR_LINE="PR open: $PR_URL"$'\n'
        quartet_notify "Medic $PROJECT_NAME (regression)" \
          "Augur attempted $summary"$'\n'"Outcome: $OUTCOME ($REASON)"$'\n'"${PR_LINE}Frozen 24h."
        until_ts="$(date -u -d '+24 hours' +%Y-%m-%dT%H:%M:%SZ)"
        state_set ".cooldowns[\"$iid\"] = {\"frozen_until\":\"$until_ts\",\"reason\":\"$FROZEN_REASON\"}"
        emit medic.incident.frozen "$iid" frozen_until="$until_ts" reason="$FROZEN_REASON"
        push_action "$(jq -n --arg iid "$iid" --arg r "$REASON" --arg o "$OUTCOME" --arg pr "$PR_URL" \
          '{incident_id:$iid, action:"escalate_augur", outcome:$o, reason:$r, pr_url:$pr}')"
      fi
      ;;

    *)
      echo "[medic] unknown class '$cls' for $iid; skipping" >> "$LOG_FILE"
      push_action "$(jq -n --arg iid "$iid" --arg cls "$cls" \
        '{incident_id:$iid, action:"unknown", outcome:$cls}')"
      ;;
  esac
  i=$((i+1))
done

# ---------- write final result.json + emit job.end --------------------------
FINAL="$(jq -n \
  --arg ts "$(now_iso)" \
  --arg mode "$MODE" \
  --argjson detected "$INCIDENTS_DETECTED" \
  --slurpfile classified "$RESULT_FILE" \
  --argjson actions "$ACTIONS_TAKEN" \
  --argjson aug_inv "$AUGUR_INVOCATIONS" \
  --argjson aug_lock "$AUGUR_LOCK_CONTENTION" \
  --argjson cap "$CAP_HIT" \
  '{pass:true, mode:$mode, timestamp:$ts,
    incidents_detected:$detected,
    incidents_classified:$classified[0].incidents_classified,
    actions_taken:$actions,
    augur_invocations:$aug_inv,
    augur_lock_contention:$aug_lock,
    daily_cap_hit:$cap,
    errors: ($classified[0].errors // [])}')"
echo "$FINAL" > "$RESULT_FILE"

JOB_DUR=$(( $(date +%s) - JOB_START ))
[ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$PROJECT_NAME-medic" job.end \
  mode="$MODE" status="ok" duration_s="$JOB_DUR" \
  incidents="$INCIDENTS_DETECTED" \
  augur_invocations="$AUGUR_INVOCATIONS" \
  cap_hit="$CAP_HIT" || true

echo "[medic] done — incidents=$INCIDENTS_DETECTED augur=$AUGUR_INVOCATIONS" >> "$LOG_FILE"
exit 0
