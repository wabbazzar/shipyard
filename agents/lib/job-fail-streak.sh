#!/usr/bin/env bash
# job-fail-streak.sh — read-only: exit 1 when a service's trailing run of
# job.end status=fail events is >= threshold.
#
#   job-fail-streak.sh --svc <svc> [--threshold N=2] [--events-dir D=$QUARTET_EVENTS_DIR]
#
# Reads D/*.jsonl in ts order, keeps svc's job.end events. status=fail extends
# the streak, status=skipped is neutral (ignored), anything else (ok, ...)
# breaks it. Missing/empty dir, no events, malformed lines -> tolerated.
# Exit: 0 below threshold, 1 at/above (one-line reason on stdout), 2 bad args.
# No writes, no network. Intended as a notify-only [[medic.checks]] cmd.

set -uo pipefail

SVC=""
THRESHOLD=2
EVENTS_DIR="${QUARTET_EVENTS_DIR:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --svc)        [ $# -ge 2 ] || { echo "job-fail-streak: --svc needs a value" >&2; exit 2; }
                  SVC="$2"; shift 2 ;;
    --threshold)  [ $# -ge 2 ] || { echo "job-fail-streak: --threshold needs a value" >&2; exit 2; }
                  THRESHOLD="$2"; shift 2 ;;
    --events-dir) [ $# -ge 2 ] || { echo "job-fail-streak: --events-dir needs a value" >&2; exit 2; }
                  EVENTS_DIR="$2"; shift 2 ;;
    *) echo "job-fail-streak: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$SVC" ] || { echo "job-fail-streak: --svc is required" >&2; exit 2; }
case "$THRESHOLD" in ''|*[!0-9]*) echo "job-fail-streak: --threshold must be an integer" >&2; exit 2 ;; esac

[ -n "$EVENTS_DIR" ] && [ -d "$EVENTS_DIR" ] || exit 0

shopt -s nullglob
files=("$EVENTS_DIR"/*.jsonl)
[ "${#files[@]}" -gt 0 ] || exit 0

# fromjson? drops malformed lines; non-object lines are filtered by type check.
# Output: "<streak> <last_fail_ts>" for the trailing fail run.
read -r streak last_ts < <(
  cat "${files[@]}" 2>/dev/null \
  | jq -R -r --arg svc "$SVC" '
      fromjson? | select(type=="object" and .event=="job.end" and .svc==$svc)
      | [(.ts // ""), (.status // "")] | @tsv' 2>/dev/null \
  | sort -s -t$'\t' -k1,1 \
  | awk -F'\t' '
      $2=="skipped" { next }
      $2=="fail"    { n++; ts=$1; next }
      { n=0; ts="" }
      END { printf "%d %s\n", n+0, ts }'
)
streak="${streak:-0}"

if [ "$streak" -ge "$THRESHOLD" ]; then
  echo "$SVC: $streak consecutive job.end status=fail (threshold $THRESHOLD, latest ${last_ts:-unknown})"
  exit 1
fi
exit 0
