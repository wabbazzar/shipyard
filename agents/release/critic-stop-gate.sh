#!/bin/bash
# agents/release/critic-stop-gate.sh — opt-in Stop hook for shoulder mode.
#
# Default: exit 0 immediately — the gate is DISARMED unless the session
# explicitly sets GUARDIAN_CRITIC_BLOCK=1. Quartet agents' own headless
# runs never set it, so they are unaffected.
#
# Armed: reads the latest critique findings for the session (the file
# critic-watch.sh writes beside the queue) and exits 2 with the
# block-severity findings on stderr if any are unaddressed — Claude Code
# treats a Stop-hook exit 2 as "don't stop yet". No block findings (or
# no findings file at all) → exit 0.
#
# Session id comes from the hook JSON on stdin (.session_id), fallback
# "default"; project dir from $CLAUDE_PROJECT_DIR or cwd — same
# resolution as critic-queue.sh.

set -u

[ "${GUARDIAN_CRITIC_BLOCK:-0}" = "1" ] || exit 0

INPUT="$(cat 2>/dev/null || true)"
SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null || true)"
[ -n "$SESSION_ID" ] || SESSION_ID="default"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
if [ -d "$PROJECT_DIR/tmp" ]; then
  QUEUE_DIR="$PROJECT_DIR/tmp"
else
  QUEUE_DIR="/tmp/guardian-critic-$(id -u)/$(basename "$PROJECT_DIR")"
fi

FINDINGS_FILE="$QUEUE_DIR/guardian-critic-findings-$SESSION_ID"
[ -f "$FINDINGS_FILE" ] || exit 0

BLOCKS="$(grep '^block|' "$FINDINGS_FILE" 2>/dev/null || true)"
[ -n "$BLOCKS" ] || exit 0

{
  echo "guardian critic: unaddressed block-severity findings:"
  printf '%s\n' "$BLOCKS"
} >&2
exit 2
