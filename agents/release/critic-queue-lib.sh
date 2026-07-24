# agents/release/critic-queue-lib.sh — shared enqueue for the shoulder-mode
# capture hooks. Sourced by the per-harness front-ends:
#   critic-queue.sh        (claude PostToolUse)
#   critic-queue-codex.sh  (codex  PostToolUse — apply_patch V4A patches)
#   critic-queue-hermes.sh (hermes post_tool_call — write_file/patch/edit_file)
#
# Each front-end parses ITS harness's payload down to (file_path, session_id,
# project_dir) and calls cq_enqueue. This file owns the filters + the queue
# file format that agents/release/critic-watch.sh drains — keep that format
# byte-stable (`<file_path> <epoch>` per line, one file per line).
#
# cq_enqueue stores file_path EXACTLY as handed to it (no relative→absolute
# rewrite) so the claude path stays byte-identical to its pre-refactor
# behavior; a front-end that wants a path normalized must do so before calling.
# ALWAYS returns 0 — a capture hook must never fail the dev agent's tool loop.

# cq_enqueue <file_path> <session_id> <project_dir>
cq_enqueue() {
  local FILE_PATH="${1:-}" SESSION_ID="${2:-}" PROJECT_DIR="${3:-$PWD}"
  [ -n "$FILE_PATH" ] || return 0
  [ -n "$SESSION_ID" ] || SESSION_ID="default"

  # Absolute paths outside this project belong to some other repo's critic
  # (a session working across two checkouts edits both); queueing them here
  # gets them critiqued against the WRONG project's conventions and trunk.
  case "$FILE_PATH" in
    /*)
      case "$FILE_PATH" in
        "$PROJECT_DIR"/*) ;;
        *) return 0 ;;
      esac ;;
  esac

  # Gitignored paths (result JSONs, scratch under tmp/) are runtime artifacts,
  # never release candidates. check-ignore failing open (not a repo, git
  # missing) keeps the old behavior.
  if git -C "$PROJECT_DIR" check-ignore -q "$FILE_PATH" 2>/dev/null; then
    return 0
  fi

  local QUEUE_DIR
  if [ -d "$PROJECT_DIR/tmp" ]; then
    QUEUE_DIR="$PROJECT_DIR/tmp"
  else
    QUEUE_DIR="/tmp/shipyard-critic-$(id -u)/$(basename "$PROJECT_DIR")"
    mkdir -p "$QUEUE_DIR" 2>/dev/null || return 0
  fi

  printf '%s %s\n' "$FILE_PATH" "$(date +%s)" \
    >> "$QUEUE_DIR/critic-queue-$SESSION_ID" 2>/dev/null || true
  return 0
}

# cq_under_project <candidate> <project_dir>
# Resolve <candidate> (relative to project_dir if not absolute) and echo a
# PROJECT-RELATIVE path iff it lands inside project_dir; else echo nothing and
# return 1. Used by the codex/hermes front-ends to normalize + fence paths
# before enqueue (claude passes its own absolute paths and skips this).
# Canonicalizes `..` LEXICALLY so a traversal like `<proj>/../evil` is rejected
# — a plain string prefix check would wrongly accept it.
cq_under_project() {
  local cand="${1:-}" proj="${2:-$PWD}" abs
  [ -n "$cand" ] || return 1
  case "$cand" in
    /*) abs="$cand" ;;
    *)  abs="$proj/$cand" ;;
  esac
  # Lexical canonicalization (-m: missing ok, -s: don't follow symlinks).
  if command -v realpath >/dev/null 2>&1; then
    abs="$(realpath -ms -- "$abs" 2>/dev/null)" || return 1
    proj="$(realpath -ms -- "$proj" 2>/dev/null)" || return 1
  else
    # No realpath: reject any `..` segment rather than risk an escape.
    case "/$cand/" in */../*) return 1 ;; esac
  fi
  case "$abs" in
    "$proj")     printf '.\n'; return 0 ;;
    "$proj"/*)   printf '%s\n' "${abs#"$proj"/}"; return 0 ;;
    *)           return 1 ;;
  esac
}
