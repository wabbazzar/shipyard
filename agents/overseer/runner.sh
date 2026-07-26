#!/bin/bash
# agents/overseer/runner.sh — the fleet dogfood OVERSEER.
#
# Autonomous dogfood repos (config `autonomous = true`) run the crew hands-off
# and never surface in the human approval wire. The overseer is the meta-QA that
# periodically LOOKS IN on them: for each autonomous repo it hands the crew's
# recent outputs to an LLM judge and asks "is this crew producing correct,
# coherent work?" — and notifies the owner ONLY when something is wrong (a
# hallucinated proposal, a false-green proctor verdict, an inappropriate medic
# action, a role that stopped running). Healthy runs are SILENT: an
# `overseer.assessed status=ok` health event only, no notification.
#
# It never writes code and never touches a repo — it reads its outputs and
# judges. It is NOT a crew role (the canonical five are design/build/release/
# medic/scribe); it is a standalone fleet timer that watches them.
#
# Usage:
#   runner.sh                  # fleet: assess every autonomous repo under CODE_ROOT
#   runner.sh --project DIR    # assess one repo (exit 3 if it is not autonomous)
#   runner.sh --check-config   # read-only: print the repos it WOULD assess
#
# Env (baked into the unit): QUARTET_DIR, QUARTET_NOTIFY_CMD, QUARTET_EVENTS_DIR,
#   CODE_ROOT (default ~/code), OVERSEER_MODEL (default sonnet),
#   OVERSEER_HARNESS (default claude), OVERSEER_WALL_CLOCK (default 600).
#
# Verdict (the judge's final message, strict JSON):
#   {healthy:bool, summary:"one line", findings:[{role,severity,issue}]}
# Result file: <repo>/tmp/overseer-result.json.
# Event: overseer.assessed status=ok|problem|error project=<name> findings=<n>.
# Exit: 0 all healthy · 1 a problem was found · 2 bad invocation · 3 not autonomous.

set -uo pipefail
QUARTET_DIR="${QUARTET_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
LOG_EVENT="$QUARTET_DIR/agents/lib/log_event.sh"
export QUARTET_SOURCE="${QUARTET_SOURCE:-system}"
# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/load-config.sh"   # load_config_json + quartet_notify
# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/spawn.sh"         # spawn_model

CODE_ROOT="${CODE_ROOT:-$HOME/code}"
OVERSEER_MODEL="${OVERSEER_MODEL:-sonnet}"
OVERSEER_HARNESS="${OVERSEER_HARNESS:-claude}"
WALL_CLOCK="${OVERSEER_WALL_CLOCK:-600}"
ROLE_FILE="$QUARTET_DIR/agents/overseer/role.md"

PROJECT_DIR=""
CHECK_CONFIG=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project)      PROJECT_DIR="$2"; shift 2 ;;
    --check-config) CHECK_CONFIG=1; shift ;;
    -h|--help)      sed -n '2,32p' "$0"; exit 0 ;;
    *)              echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# extract_json — pull the first balanced, parseable JSON object out of a model
# message (LLMs wrap the verdict in ```json fences or add prose despite the
# "return ONLY JSON" instruction). Prints the object or nothing. stdin → stdout.
extract_json() {
  # -c (not a heredoc) so the piped model text stays on stdin; script uses only
  # double quotes so the single-quoted -c body is safe.
  python3 -c '
import sys, json
s = sys.stdin.read()
depth = 0; start = -1
for i, ch in enumerate(s):
    if ch == "{":
        if depth == 0: start = i
        depth += 1
    elif ch == "}" and depth > 0:
        depth -= 1
        if depth == 0 and start >= 0:
            frag = s[start:i+1]
            try:
                json.loads(frag); sys.stdout.write(frag); sys.exit(0)
            except Exception:
                start = -1
' 2>/dev/null || true
}

# is_autonomous <dir> — the project opted into hands-off mode. Top-level-key
# match (a [section] `autonomous` is scoped differently and NOT matched), the
# same rule the hub dispatch uses to drop the repo from the approval wire.
is_autonomous() {
  local cfg="$1/.agents/config.toml"
  [ -f "$cfg" ] && grep -qE '^[[:space:]]*autonomous[[:space:]]*=[[:space:]]*true\b' "$cfg"
}

# autonomous_repos — absolute dirs under CODE_ROOT with autonomous=true.
autonomous_repos() {
  local d
  for d in "$CODE_ROOT"/*/; do
    d="${d%/}"
    [ -d "$d" ] || continue
    is_autonomous "$d" && printf '%s\n' "$d"
  done
}

if [ "$CHECK_CONFIG" -eq 1 ]; then
  if [ -n "$PROJECT_DIR" ]; then is_autonomous "$PROJECT_DIR" && printf '%s\n' "$PROJECT_DIR"
  else autonomous_repos; fi
  exit 0
fi

# assess <dir> — judge one repo's crew. Returns 0 healthy, 1 problem/error.
assess() {
  local dir="$1" cfg_json name svc result_file
  cfg_json="$(load_config_json "$dir/.agents/config.toml" 2>/dev/null)" || cfg_json='{}'
  name="$(jq -r '.project_name // empty' <<<"$cfg_json" 2>/dev/null)"
  [ -z "$name" ] && name="$(basename "$dir")"
  svc="$name-overseer"
  result_file="$dir/tmp/overseer-result.json"
  mkdir -p "$dir/tmp" 2>/dev/null || true

  # ---- gather the crew's recent output (bounded) --------------------------
  local ctx f
  ctx="## PROJECT: $name  (dir: $dir)
## north_star: $(jq -r '.design.north_star // "—"' <<<"$cfg_json" 2>/dev/null)

## CREW RESULT FILES (tmp/*-result.json):"
  for f in "$dir"/tmp/*-result.json; do
    [ -e "$f" ] || continue
    case "$f" in *overseer-result.json) continue ;; esac   # don't grade our own prior verdict
    ctx="$ctx
### $(basename "$f")
$(head -c 4000 "$f")"
  done
  ctx="$ctx

## USER-FEEDBACK SIGNALS (data/fyi-requests.jsonl):
$( [ -f "$dir/data/fyi-requests.jsonl" ] && head -c 2000 "$dir/data/fyi-requests.jsonl" || echo '(none)' )

## RECENT COMMITS (hash · committer-date-UTC · subject · co-authors):
## Correlate a result file's timestamp against these dates before calling it
## out of sync; a Co-authored-by trailer names the role svc that made a commit.
$(TZ=UTC git -C "$dir" log -15 --date=iso-strict-local \
    --pretty=format:'%h %cd %s | co: %(trailers:key=Co-authored-by,valueonly,separator=%x2C%x20)' \
    2>/dev/null || echo '(no git)')
## WORKING TREE:
$(git -C "$dir" status --short 2>/dev/null | head -20)"

  local prompt
  prompt="$(cat "$ROLE_FILE" 2>/dev/null)

---

CREW OUTPUT TO ASSESS:

$ctx

---

Return ONLY the JSON verdict, no prose."

  spawn_model --harness "$OVERSEER_HARNESS" --model "$OVERSEER_MODEL" \
    --prompt "$prompt" --log "$dir/tmp/$svc-last-run.log" --timeout "$WALL_CLOCK" \
    --skip-perms --json
  local rc="$SPAWN_RC" tokens="$SPAWN_TOKENS" out
  out="$(printf '%s' "$SPAWN_TEXT" | extract_json)"   # tolerate fences / prose

  # ---- parse the verdict --------------------------------------------------
  local healthy summary nfind status
  if [ -n "$out" ] && jq -e 'has("healthy")' <<<"$out" >/dev/null 2>&1; then
    healthy="$(jq -r '.healthy // false' <<<"$out")"
    summary="$(jq -r '.summary // ""' <<<"$out")"
    nfind="$(jq -r '(.findings // []) | length' <<<"$out")"
    status="ok"; [ "$healthy" = "true" ] || status="problem"
    jq --arg ts "$(now_iso)" --arg st "$status" \
      '{healthy:(.healthy // false), status:$st, summary:(.summary // ""),
        findings:(.findings // []), ts:$ts}' <<<"$out" > "$result_file"
  else
    # the judge itself failed to return a usable verdict — can't certify health
    status="error"
    summary="overseer could not assess $name — judge returned no verdict (exit $rc)"
    nfind=0
    jq -n --arg s "$summary" --arg ts "$(now_iso)" \
      '{healthy:false, status:"error", summary:$s, findings:[], ts:$ts}' > "$result_file"
  fi

  [ -x "$LOG_EVENT" ] && "$LOG_EVENT" "$svc" overseer.assessed \
    status="$status" project="$name" role=overseer findings="$nfind" tokens="$tokens" || true

  # ---- notify ONLY when something is wrong (silent + logged when healthy) --
  if [ "$status" != "ok" ]; then
    local body
    body="$(jq -r '(.findings // []) | map("• [\(.severity // "?")/\(.role // "?")] \(.issue // "")") | join("\n")' "$result_file" 2>/dev/null)"
    quartet_notify "overseer: $name crew needs a look" "$summary${body:+
$body}"
    return 1
  fi
  return 0
}

# ---- drive: one repo, or the whole fleet ----------------------------------
rc=0
if [ -n "$PROJECT_DIR" ]; then
  if is_autonomous "$PROJECT_DIR"; then assess "$PROJECT_DIR" || rc=1
  else echo "not an autonomous repo (no overseer): $PROJECT_DIR" >&2; exit 3; fi
else
  found=0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    found=1
    assess "$d" || rc=1   # a problem in one repo must not abort the fleet sweep
  done <<<"$(autonomous_repos)"
  [ "$found" -eq 0 ] && echo "overseer: no autonomous repos under $CODE_ROOT" >&2
fi
exit "$rc"
