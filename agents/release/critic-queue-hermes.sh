#!/bin/bash
# agents/release/critic-queue-hermes.sh — hermes post_tool_call hook: queue the
# file(s) an edit touched for the shoulder-mode critic (critic-watch.sh).
#
# hermes file-editing tools are write_file / patch / edit_file. Payload shape
# (captured via `hermes hooks test post_tool_call`):
#   { "hook_event_name": "post_tool_call", "tool_name": "write_file",
#     "tool_input": { "path": "<file>" }, "session_id": "...", "cwd": "<project>" }
# The `patch` tool in mode=patch instead carries a V4A multi-file patch in
# .tool_input.patch (same header format as codex apply_patch) — handled too.
#
# Registered under `hooks: post_tool_call:` in ~/.hermes/config.yaml (see
# install.sh --wire-shoulder). Writes the SAME queue format as the claude hook
# so critic-watch.sh drains it unchanged. ALWAYS exits 0.

set -u

# shellcheck source=agents/release/critic-queue-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/critic-queue-lib.sh"

INPUT="$(cat 2>/dev/null || true)"

SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null || true)"
PROJECT_DIR="$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null || true)"
[ -n "$PROJECT_DIR" ] || PROJECT_DIR="$PWD"

_queue_one() {
  local rel
  rel="$(cq_under_project "$1" "$PROJECT_DIR")" || return 0
  [ "$rel" = "." ] && return 0
  cq_enqueue "$rel" "$SESSION_ID" "$PROJECT_DIR"
}

# write_file / patch(replace) / edit_file → a single .tool_input.path.
FP="$(jq -r '.tool_input.path // empty' <<<"$INPUT" 2>/dev/null || true)"
[ -n "$FP" ] && _queue_one "$FP"

# patch(mode=patch) → a V4A multi-file patch in .tool_input.patch.
PATCH="$(jq -r '.tool_input.patch // empty' <<<"$INPUT" 2>/dev/null || true)"
if [ -n "$PATCH" ]; then
  while IFS= read -r path; do
    [ -n "$path" ] && _queue_one "$path"
  done < <(printf '%s' "$PATCH" | cq_v4a_paths)
fi

exit 0
