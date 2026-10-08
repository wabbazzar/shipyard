#!/usr/bin/env bats
#
# scribe-publish-pr.bats — `[scribe] publish = "pr"`: a nightly scribe commit
# leaves the trunk checkout and lands as a pull request.
#
# Real git (bare origin + clone), stubbed `gh`. Each test fails on the real
# defect: a publish that left the commit on local trunk, pushed to trunk
# instead of a branch, lost an unrelated local edit, or opened a PR without
# the evidence the fleet PR watcher reads.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  quartet_setup
  P="$(make_git_topology "$BATS_TEST_TMPDIR/topo" main)"
  LOG="$BATS_TEST_TMPDIR/publish.log"
  : >"$LOG"
  # gh: `pr create` prints a URL (and records its body to a file);
  # `pr list` answers from $SHIM_LOG/gh.prlist (default: no open PRs);
  # everything else is a no-op.
  make_stub_script gh '
case "$1 $2" in
  "pr create")
    while [ $# -gt 0 ]; do
      case "$1" in --body) shift; printf "%s" "$1" > "'"$SHIM_LOG"'/gh.body" ;; esac
      shift
    done
    echo "https://example.invalid/pull/42" ;;
  "pr list")
    if [ -f "'"$SHIM_LOG"'/gh.prlist" ]; then cat "'"$SHIM_LOG"'/gh.prlist"; else echo "[]"; fi ;;
  *) : ;;
esac
exit 0'
}

# scribe_commit <file> <content> — one pathspec-scoped commit on trunk, the
# shape the runner produces. Echoes the commit sha.
scribe_commit() {
  printf '%s\n' "$2" >"$P/$1"
  git -C "$P" add -- "$1"
  git -C "$P" commit -q -m "scribe: nightly refresh (1 file(s))" -- "$1"
  git -C "$P" rev-parse HEAD
}

publish() {
  # shellcheck disable=SC1091
  source "$QUARTET_ROOT/agents/lib/scribe-publish.sh"
  scribe_publish_pr "$P" main fixture-scribe "scribe: nightly refresh (1 file(s))" 1 "$LOG"
}

@test "publish=pr moves the commit to a scribe/ branch, pushes it, resets trunk, opens a PR" {
  base="$(git -C "$P" rev-parse HEAD)"
  sha="$(scribe_commit docs.md "refreshed")"

  run publish
  [ "$status" -eq 0 ]

  # trunk checkout is back on the base commit and clean
  [ "$(git -C "$P" rev-parse HEAD)" = "$base" ]
  [ "$(git -C "$P" rev-parse --abbrev-ref HEAD)" = "main" ]
  [ -z "$(git -C "$P" status --porcelain)" ]
  [ ! -f "$P/docs.md" ]

  # the commit exists on origin under scribe/<stamp>, and origin/main did NOT move
  br="$(git -C "$BATS_TEST_TMPDIR/topo/origin.git" for-each-ref --format='%(refname:short)' 'refs/heads/scribe/*')"
  [ -n "$br" ]
  [ "$(git -C "$BATS_TEST_TMPDIR/topo/origin.git" rev-parse "$br")" = "$sha" ]
  [ "$(git -C "$BATS_TEST_TMPDIR/topo/origin.git" rev-parse main)" = "$base" ]

  # gh pr create targeted trunk from that branch, with watcher evidence in the body
  grep -q "pr create --base main --head $br " "$SHIM_LOG/gh.argv"
  grep -q '^## Acceptance' "$SHIM_LOG/gh.body"
  grep -q '^## Verification' "$SHIM_LOG/gh.body"
  ! grep -q '^- \[ \]' "$SHIM_LOG/gh.body"
  grep -q 'opened https://example.invalid/pull/42' "$LOG"
}

@test "an unrelated local edit survives the trunk reset" {
  printf 'wip\n' >"$P/scratch.txt"          # untracked, not part of the commit
  printf 'base edited\n' >"$P/README.md"     # tracked, modified, not committed
  scribe_commit docs.md "refreshed" >/dev/null

  run publish
  [ "$status" -eq 0 ]
  [ "$(cat "$P/scratch.txt")" = "wip" ]
  [ "$(cat "$P/README.md")" = "base edited" ]
  [ ! -f "$P/docs.md" ]
}

@test "older open scribe PRs are closed as superseded, other PRs untouched" {
  printf '[{"number":7,"headRefName":"scribe/20260101-000000"},{"number":8,"headRefName":"build/ticket-9"}]\n' \
    >"$SHIM_LOG/gh.prlist"
  scribe_commit docs.md "refreshed" >/dev/null

  run publish
  [ "$status" -eq 0 ]
  grep -q '^pr close 7 --delete-branch' "$SHIM_LOG/gh.argv"
  ! grep -q '^pr close 8' "$SHIM_LOG/gh.argv"
}

@test "refuses when the checkout is not on trunk; commit stays put" {
  git -C "$P" checkout -q -b feature
  sha="$(scribe_commit docs.md "refreshed")"

  run publish
  [ "$status" -eq 10 ]
  [ "$(git -C "$P" rev-parse HEAD)" = "$sha" ]
  [ "$(stub_calls gh)" = "0" ]
  grep -q "expected trunk 'main'" "$LOG"
}

@test "a failed push leaves the commit on local trunk and no PR" {
  rm -rf "$BATS_TEST_TMPDIR/topo/origin.git"   # origin gone: push must fail
  sha="$(scribe_commit docs.md "refreshed")"

  run publish
  [ "$status" -eq 10 ]
  [ "$(git -C "$P" rev-parse HEAD)" = "$sha" ]
  [ -z "$(git -C "$P" for-each-ref 'refs/heads/scribe/*')" ]
  [ "$(stub_calls gh)" = "0" ]
}

@test "refuses when local trunk has unpushed commits; nothing pushed, commit stays" {
  printf 'local\n' >"$P/local.txt"
  git -C "$P" add -- local.txt
  git -C "$P" commit -q -m "owner: unpushed work" -- local.txt   # trunk ahead of origin
  sha="$(scribe_commit docs.md "refreshed")"

  run publish
  [ "$status" -eq 13 ]
  [ "$(git -C "$P" rev-parse HEAD)" = "$sha" ]
  [ -z "$(git -C "$BATS_TEST_TMPDIR/topo/origin.git" for-each-ref 'refs/heads/scribe/*')" ]
  [ "$(stub_calls gh)" = "0" ]
  grep -q "ahead of origin/main; push trunk first" "$LOG"
}

@test "runner --check-config reports publish, defaulting from auto_push" {
  proj="$(make_fixture_project pubcfg clean-install.toml)"
  run bash "$QUARTET_ROOT/agents/scribe/runner.sh" --project "$proj" --check-config
  [ "$status" -eq 0 ]
  [ "$(jq -r .publish <<<"$output")" = "local" ]

  printf '\n[scribe]\nauto_push = true\n' >>"$proj/.agents/config.toml"
  run bash "$QUARTET_ROOT/agents/scribe/runner.sh" --project "$proj" --check-config
  [ "$(jq -r .publish <<<"$output")" = "push" ]

  printf 'publish = "pr"\n' >>"$proj/.agents/config.toml"
  run bash "$QUARTET_ROOT/agents/scribe/runner.sh" --project "$proj" --check-config
  [ "$(jq -r .publish <<<"$output")" = "pr" ]

  printf 'publish = "email"\n' >>"$proj/.agents/config.toml"
  run bash "$QUARTET_ROOT/agents/scribe/runner.sh" --project "$proj" --check-config
  [ "$status" -eq 2 ]
}
