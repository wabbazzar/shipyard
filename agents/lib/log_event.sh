#!/bin/bash
# log_event.sh — append one JSONL event to data/events/{YYYY-MM-DD}.jsonl
#
# Usage:
#   log_event.sh <svc> <event> [key=value ...]
#   log_event.sh release job.end status=ok duration_s=42
#
# Values are written as strings unless they parse as int/float/bool,
# in which case they're emitted unquoted. Use key='"quoted"' to force a
# string that looks like a number.
#
# Source tagging — every event picks up a `source` field from one of:
#   1. `source=...` passed explicitly as a key=value arg (wins)
#   2. $QUARTET_SOURCE env var (set by the calling script)
#   3. `agent` if $CLAUDECODE=1 (Claude Code is running this indirectly)
#   4. no source field at all
# When source=agent is inferred and /tmp/claude-session-$UID.txt exists
# (written by the project's SessionStart hook), actor defaults to
# `claude-code:<first 8 chars of session id>`.
#
# Concurrent-safe: uses flock on the daily file.
# Fire-and-forget: never exits non-zero for the caller. If logging is
# broken, we don't want to break the service that called us.

set -u

QUARTET_DIR="${QUARTET_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
EVENTS_DIR="${QUARTET_EVENTS_DIR:-$QUARTET_DIR/data/events}"

if [ $# -lt 2 ]; then
    echo "Usage: log_event.sh <svc> <event> [key=value ...]" >&2
    exit 0   # fire-and-forget
fi

SVC="$1"
EVENT="$2"
shift 2

mkdir -p "$EVENTS_DIR" 2>/dev/null || exit 0

DATE=$(date -u +%Y-%m-%d)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
FILE="$EVENTS_DIR/$DATE.jsonl"

# --- source + (maybe) actor inference -------------------------------------
# Pull out an explicit source=... arg if the caller passed one.
EXPLICIT_SOURCE=""
EXPLICIT_ACTOR=""
FILTERED_ARGS=()
for kv in "$@"; do
    case "$kv" in
        source=*) EXPLICIT_SOURCE="${kv#source=}";;
        actor=*)  EXPLICIT_ACTOR="${kv#actor=}";  FILTERED_ARGS+=("$kv");;
        *)        FILTERED_ARGS+=("$kv");;
    esac
done

SOURCE="$EXPLICIT_SOURCE"
ACTOR_DEFAULT=""
if [ -z "$SOURCE" ] && [ -n "${QUARTET_SOURCE:-}" ]; then
    SOURCE="$QUARTET_SOURCE"
fi
if [ -z "$SOURCE" ] && [ "${CLAUDECODE:-0}" = "1" ]; then
    SOURCE="agent"
    SESSION_FILE="/tmp/claude-session-${UID:-$(id -u)}.txt"
    if [ -s "$SESSION_FILE" ]; then
        SID=$(head -c 8 "$SESSION_FILE" 2>/dev/null || true)
        [ -n "$SID" ] && ACTOR_DEFAULT="claude-code:$SID"
    fi
    [ -z "$ACTOR_DEFAULT" ] && ACTOR_DEFAULT="claude-code"
fi

# Build the JSON line with jq so quoting is correct.
JQ_ARGS=(--arg ts "$TS" --arg svc "$SVC" --arg event "$EVENT")
JQ_FILTER='{ts: $ts, svc: $svc, event: $event}'

if [ -n "$SOURCE" ]; then
    JQ_ARGS+=(--arg v_source "$SOURCE")
    JQ_FILTER="$JQ_FILTER + {\"source\": \$v_source}"
fi
if [ -n "$ACTOR_DEFAULT" ] && [ -z "$EXPLICIT_ACTOR" ]; then
    JQ_ARGS+=(--arg v_actor "$ACTOR_DEFAULT")
    JQ_FILTER="$JQ_FILTER + {\"actor\": \$v_actor}"
fi
# Canonical role of the emitting agent (design/build/release/medic/scribe),
# set by the runner. The display name lives in `svc`; `role` is the stable id.
if [ -n "${QUARTET_ROLE:-}" ]; then
    JQ_ARGS+=(--arg v_role "$QUARTET_ROLE")
    JQ_FILTER="$JQ_FILTER + {\"role\": \$v_role}"
fi

for kv in "${FILTERED_ARGS[@]}"; do
    key="${kv%%=*}"
    val="${kv#*=}"
    # Accept int/float/bool/null unquoted; otherwise string.
    if [[ "$val" =~ ^-?[0-9]+$ ]] || \
       [[ "$val" =~ ^-?[0-9]+\.[0-9]+$ ]] || \
       [[ "$val" == "true" || "$val" == "false" || "$val" == "null" ]]; then
        JQ_FILTER="$JQ_FILTER + {\"$key\": $val}"
    else
        JQ_ARGS+=(--arg "v_$key" "$val")
        JQ_FILTER="$JQ_FILTER + {\"$key\": \$v_$key}"
    fi
done

LINE=$(jq -cn "${JQ_ARGS[@]}" "$JQ_FILTER" 2>/dev/null) || exit 0

# flock prevents interleaved writes across concurrent callers.
(
    flock -x 9
    printf '%s\n' "$LINE" >> "$FILE"
) 9>"$FILE.lock" 2>/dev/null

exit 0
