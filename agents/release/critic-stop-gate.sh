#!/bin/bash
# agents/release/critic-stop-gate.sh — opt-in Stop hook for shoulder mode (claude).
#
# Default: exit 0 immediately — DISARMED unless the session sets CRITIC_BLOCK=1.
# Quartet agents' own headless runs never set it, so they are unaffected.
# Armed: exits 2 (Claude Code: "don't stop yet") with unaddressed block-severity
# findings on stderr. Session id from the hook JSON (.session_id, fallback
# "default"); project dir from $CLAUDE_PROJECT_DIR or cwd. Teeth live in
# critic-stop-gate-lib.sh (shared with the codex/hermes gates).

set -u

# shellcheck source=agents/release/critic-stop-gate-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/critic-stop-gate-lib.sh"

INPUT="$(cat 2>/dev/null || true)"
SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null || true)"

csg_gate "$SESSION_ID" "${CLAUDE_PROJECT_DIR:-$PWD}"
exit $?
