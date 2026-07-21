#!/bin/bash
# agents/lib/detect-trunk.sh — resolve a project's trunk branch, loudly.
#
# Source me from a runner, then:
#
#   TRUNK_BRANCH="$(detect_trunk "$CFG_JSON" "$PROJECT_DIR")" || exit 2
#
# Resolution order:
#   1. the config's `branch` key, if set;
#   2. origin/HEAD — refresh it from the remote (`git remote set-head
#      origin -a`), then read `refs/remotes/origin/HEAD`;
#   3. FAIL: return 2 with a message on stderr. NEVER silently default —
#      a guessed trunk is exactly what you don't want a revert pushed to.

detect_trunk() {
  # detect_trunk <cfg-json> <project-dir>
  local cfg_json="$1" project_dir="$2"
  local branch
  branch="$(jq -r '.branch // empty' <<<"$cfg_json")"
  if [ -n "$branch" ]; then
    printf '%s\n' "$branch"
    return 0
  fi
  git -C "$project_dir" remote set-head origin -a >/dev/null 2>&1 || true
  local ref
  if ref="$(git -C "$project_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)"; then
    printf '%s\n' "${ref#refs/remotes/origin/}"
    return 0
  fi
  echo "detect-trunk: cannot resolve trunk branch for $project_dir —" \
    "set 'branch' in .agents/config.toml or give origin a HEAD" \
    "(git remote set-head origin -a)" >&2
  return 2
}
