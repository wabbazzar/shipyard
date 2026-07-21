#!/bin/bash
# agents/lib/revert-merge.sh — revert a landed trunk commit, honestly.
#
# Source me, then:
#
#   if medic_revert_merge "$PROJECT_DIR" "$MERGE_SHA" "$TRUNK_BRANCH" "$LOG_FILE"; then ...
#
# The commit shape decides the revert form: a two-parent commit (a true
# merge) needs `-m 1`; a single-parent commit (GitHub "Squash and merge")
# must be reverted WITHOUT a mainline. The discriminator is the parent
# probe (`rev-parse <sha>^2`), not the exit code of `revert -m 1` — git
# 2.43 accepts `-m 1` on non-merges, so the exit code can't tell shapes
# apart (measured; see tests/harness.bats).
#
# Returns 0 only when the revert commit was created AND pushed to the
# trunk on origin — origin is what the fleet sees, so an unpushed revert
# must not be reported as "reverted". Non-zero when git refused (conflict,
# dirty tree, bad sha; any half-applied revert is aborted so the checkout
# is left clean) or when the push failed (revert commit stays local for a
# human to push or drop).

medic_revert_merge() {
  # medic_revert_merge <project-dir> <merge-sha> <trunk-branch> [log-file]
  local dir="$1" sha="$2" trunk="$3" log="${4:-/dev/null}"
  local rc
  if git -C "$dir" rev-parse --verify --quiet "$sha^2" >/dev/null 2>&1; then
    # Two parents — a true merge; the mainline must be named.
    git -C "$dir" revert --no-edit -m 1 "$sha" >>"$log" 2>&1
    rc=$?
  else
    # One parent — a squash merge; plain revert.
    git -C "$dir" revert --no-edit "$sha" >>"$log" 2>&1
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    git -C "$dir" revert --abort >>"$log" 2>&1 || true
    return 1
  fi
  if ! git -C "$dir" push origin "$trunk" >>"$log" 2>&1; then
    echo "revert-merge: revert committed locally but push to origin/$trunk failed" >>"$log"
    return 1
  fi
  return 0
}
