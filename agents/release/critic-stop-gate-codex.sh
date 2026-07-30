#!/bin/bash
# agents/release/critic-stop-gate-codex.sh — Codex Stop delivery/backstop hook.
# Completed durable feedback is returned as a Stop continuation. The bounded
# urgent-flush state machine is opt-in through [shoulder].require_feedback;
# legacy CRITIC_BLOCK=1 findings retain their historical exit-2 behavior.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=agents/release/critic-stop-gate-lib.sh
. "$SCRIPT_DIR/critic-stop-gate-lib.sh"
CSG_CLAIM_TOKENS=""
CSG_CLAIM_PROJECT=""
CSG_CLAIM_SESSION=""
trap csg_rollback_claims EXIT
trap 'exit 130' HUP INT TERM
INPUT="$(
  python3 -c '
import sys
payload = sys.stdin.buffer.read(131073)
if len(payload) > 131072:
    raise SystemExit(2)
sys.stdout.buffer.write(payload)
'
)"
INPUT_RC=$?
[ "$INPUT_RC" -eq 0 ] || {
  echo "critic-stop-gate-codex: Stop payload exceeds 128 KiB" >&2
  exit 2
}
csg_codex_stop "$INPUT"
exit $?
