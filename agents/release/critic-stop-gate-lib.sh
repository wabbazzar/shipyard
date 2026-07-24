# agents/release/critic-stop-gate-lib.sh — shared teeth for the shoulder-mode
# stop gate. Sourced by the per-harness front-ends:
#   critic-stop-gate.sh        (claude Stop hook)
#   critic-stop-gate-codex.sh  (codex  SessionEnd/Stop hook)
#   critic-stop-gate-hermes.sh (hermes on_session_end hook)
#
# DISARMED unless the session exports CRITIC_BLOCK=1 — the crew's own headless
# runs never set it, so they are never blocked. Armed, it reads the latest
# critique findings critic-watch.sh wrote beside the queue and, if any
# block-severity finding is unaddressed, returns 2 with them on stderr — the
# "don't stop yet" signal. Whether a given harness HONORS a stop-hook's exit 2
# is a harness capability verified live (see the ticket's P5); the gate's shape
# is identical across all three.

# csg_gate <session_id> <project_dir>
csg_gate() {
  [ "${CRITIC_BLOCK:-0}" = "1" ] || return 0
  local SESSION_ID="${1:-}" PROJECT_DIR="${2:-$PWD}" QUEUE_DIR FF BLOCKS
  [ -n "$SESSION_ID" ] || SESSION_ID="default"
  if [ -d "$PROJECT_DIR/tmp" ]; then
    QUEUE_DIR="$PROJECT_DIR/tmp"
  else
    QUEUE_DIR="/tmp/shipyard-critic-$(id -u)/$(basename "$PROJECT_DIR")"
  fi
  FF="$QUEUE_DIR/critic-findings-$SESSION_ID"
  [ -f "$FF" ] || return 0
  BLOCKS="$(grep '^block|' "$FF" 2>/dev/null || true)"
  [ -n "$BLOCKS" ] || return 0
  {
    echo "release critic: unaddressed block-severity findings:"
    printf '%s\n' "$BLOCKS"
  } >&2
  return 2
}
