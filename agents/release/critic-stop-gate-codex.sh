#!/bin/bash
# agents/release/critic-stop-gate-codex.sh — opt-in codex SessionEnd/Stop hook.
# Same teeth as the claude gate; project dir from the payload .cwd (codex sets
# no CLAUDE_PROJECT_DIR). DISARMED unless CRITIC_BLOCK=1. Returns 2 with
# unaddressed block findings on stderr — whether codex honors it is verified
# live (ticket P5).
set -u
# shellcheck source=agents/release/critic-stop-gate-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/critic-stop-gate-lib.sh"
INPUT="$(cat 2>/dev/null || true)"
SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null || true)"
PROJECT_DIR="$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null || true)"
[ -n "$PROJECT_DIR" ] || PROJECT_DIR="$PWD"
csg_gate "$SESSION_ID" "$PROJECT_DIR"
exit $?
