#!/bin/bash
# agents/lib/scribe-publish.sh — publish a scribe commit as a pull request.
#
# Source me from the scribe runner, then:
#
#   scribe_publish_pr "$PROJECT_DIR" "$TRUNK_BRANCH" "$SVC" "$TITLE" "$CHANGED" "$LOG_FILE"
#
# Precondition: HEAD of the shared checkout is ONE fresh scribe commit on top
# of the trunk branch (the runner's pathspec-scoped commit). This function:
#
#   1. points a new branch `scribe/<utc-stamp>` at that commit and pushes it;
#   2. resets the shared checkout back to the commit it was on before the
#      scribe commit (`git reset --keep`, so unrelated local edits survive —
#      only the committed content paths move back, and they live on the
#      branch now);
#   3. opens a PR against trunk whose body carries the Acceptance /
#      Verification evidence the fleet PR watcher looks for;
#   4. closes any OLDER open `scribe/*` PR, since each nightly run re-derives
#      the full drift from the current trunk and supersedes the previous one.
#
# Return codes name the furthest step reached so the runner can report an
# honest outcome: 0 = PR open; 10 = branch/push failed (commit still on
# trunk locally); 11 = reset failed (commit on branch AND local trunk); 12 =
# PR creation failed (branch pushed, no PR); 13 = local trunk has unpushed
# commits (nothing done). Step 4 failures are logged only.
scribe_publish_pr() {
  local dir="$1" base="$2" svc="$3" title="$4" changed="$5" log="$6"
  local head prev current stamp branch url body

  current="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>>"$log")" || return 10
  if [ "$current" != "$base" ]; then
    echo "[$svc] publish=pr: checkout is on '$current', expected trunk '$base'" >>"$log"
    return 10
  fi
  head="$(git -C "$dir" rev-parse HEAD)" || return 10
  prev="$(git -C "$dir" rev-parse HEAD~1 2>>"$log")" || return 10

  # The PR must contain exactly the scribe commit. If the local trunk is
  # ahead of origin, pushing the branch would publish every unpushed commit
  # under the scribe's name — refuse and let a human push trunk first.
  git -C "$dir" fetch -q origin "$base" >>"$log" 2>&1 || true
  local ahead
  ahead="$(git -C "$dir" rev-list --count "origin/$base..$prev" 2>>"$log")" || ahead="?"
  if [ "$ahead" != "0" ]; then
    echo "[$svc] publish=pr: local $base is $ahead commit(s) ahead of origin/$base; push trunk first" >>"$log"
    return 13
  fi

  stamp="$(date -u +%Y%m%d-%H%M%S)"
  branch="scribe/$stamp"
  git -C "$dir" branch "$branch" "$head" >>"$log" 2>&1 || return 10
  if ! git -C "$dir" push -u origin "$branch" >>"$log" 2>&1; then
    git -C "$dir" branch -D "$branch" >>"$log" 2>&1 || true
    return 10
  fi
  echo "[$svc] publish=pr: pushed $branch at ${head:0:7}" >>"$log"

  # Trunk checkout goes back to where it was; the content now lives on the
  # branch and returns through the merge. --keep refuses (and leaves things
  # untouched) if a local edit would be clobbered.
  if ! git -C "$dir" reset --keep "$prev" >>"$log" 2>&1; then
    echo "[$svc] publish=pr: reset --keep to ${prev:0:7} failed; trunk still carries ${head:0:7}" >>"$log"
    return 11
  fi

  body="$(printf '%s\n' \
    "Automated documentation refresh by \`$svc\` (shipyard scribe)." \
    "" \
    "## Acceptance" \
    "- Only paths inside \`[scribe] content_paths\` changed ($changed file(s))." \
    "- One pathspec-scoped commit; no other worktree state included." \
    "" \
    "## Verification" \
    "- Runner lifecycle gate passed before the commit." \
    "- Branch \`$branch\` is one commit ahead of \`$base\` at the time of opening." \
    "- CI on this PR is the merge gate; the fleet PR watcher merges when green.")"

  if ! url="$(cd "$dir" && gh pr create --base "$base" --head "$branch" \
        --title "$title" --body "$body" 2>>"$log")"; then
    echo "[$svc] publish=pr: gh pr create failed for $branch" >>"$log"
    return 12
  fi
  echo "[$svc] publish=pr: opened $url" >>"$log"

  # Supersede older open scribe PRs — their drift is re-derived in this one.
  local older
  older="$(cd "$dir" && gh pr list --state open --base "$base" \
            --json number,headRefName 2>>"$log" \
          | jq -r --arg b "$branch" \
              '.[] | select(.headRefName != $b and (.headRefName | startswith("scribe/"))) | .number' \
            2>>"$log")" || older=""
  local n
  for n in $older; do
    if (cd "$dir" && gh pr close "$n" --delete-branch \
          --comment "Superseded by $url (nightly scribe refresh re-derives this drift)." \
          >>"$log" 2>&1); then
      echo "[$svc] publish=pr: closed superseded scribe PR #$n" >>"$log"
    else
      echo "[$svc] publish=pr: could not close superseded scribe PR #$n" >>"$log"
    fi
  done
  return 0
}
