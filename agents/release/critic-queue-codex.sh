#!/bin/bash
# agents/release/critic-queue-codex.sh — codex PostToolUse hook: queue the
# file(s) an edit touched for the shoulder-mode critic (critic-watch.sh).
#
# codex's edit tool is `apply_patch`: the hook payload carries a V4A patch
# STRING in .tool_input.command, not a file_path. We extract every touched
# path from the patch header lines and queue each. Payload shape (captured):
#   { "session_id": "...", "cwd": "<project>", "hook_event_name": "PostToolUse",
#     "tool_name": "apply_patch",
#     "tool_input": { "command": "*** Begin Patch\n*** Add File: a.txt\n..." } }
# Some tools may instead expose .tool_input.file_path directly — honored too.
#
# Registered via an inline [[hooks.PostToolUse]] block in the codex config.toml
# (see install.sh --wire-shoulder). Writes the SAME queue format as the claude
# hook so critic-watch.sh drains it unchanged. ALWAYS exits 0.

set -u

# shellcheck source=agents/release/critic-queue-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/critic-queue-lib.sh"

INPUT="$(cat 2>/dev/null || true)"

SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null || true)"
PROJECT_DIR="$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null || true)"
[ -n "$PROJECT_DIR" ] || PROJECT_DIR="$PWD"

# enqueue a single candidate, fenced to the project (relative form).
_queue_one() {
  local rel
  rel="$(cq_under_project "$1" "$PROJECT_DIR")" || return 0
  [ "$rel" = "." ] && return 0    # a bare project-dir path is not a file
  cq_enqueue "$rel" "$SESSION_ID" "$PROJECT_DIR"
}

# Direct file_path (non-apply_patch tools), if present.
FP="$(jq -r '.tool_input.file_path // empty' <<<"$INPUT" 2>/dev/null || true)"
[ -n "$FP" ] && _queue_one "$FP"

# apply_patch: pull every path from the V4A header lines.
CMD="$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null || true)"
if [ -n "$CMD" ]; then
  # Lines look like: "*** Add File: path", "*** Update File: path",
  # "*** Delete File: path". Strip the marker, trim, queue each.
  while IFS= read -r path; do
    [ -n "$path" ] && _queue_one "$path"
  done < <(grep -oE '^\*\*\* (Add|Update|Delete) File: .+$' <<<"$CMD" \
             | sed -E 's/^\*\*\* (Add|Update|Delete) File: //')
fi

exit 0
