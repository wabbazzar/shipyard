#!/usr/bin/env bats
# Real local Git histories; no network or model calls.
setup() {
  load helpers
  quartet_setup
  P="$(make_fixture_project trunk can-merge-false.toml)"
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  git init -q --bare -b main "$ORIGIN"
  git -C "$P" remote add origin "$ORIGIN"
  git -C "$P" push -q -u origin main
  B="$BATS_TEST_TMPDIR/other"
  git clone -q "$ORIGIN" "$B"
  # Halt after Git preflight, never enter a model/harness path.
  printf '%s\n' '{"svc":"trunk-build","event":"job.end","tokens":1000000}' > "$(events_file)"
  make_stub claude 99
  make_stub codex 99
  make_stub gh 99
}

flag() {
  fixture_replace_in_place "$P/.agents/config.toml" '^wall_clock_sec = 60$' "wall_clock_sec = 60\nreconcile_trunk = $1"
  git -C "$P" add .agents/config.toml
  git -C "$P" commit -qm config
  git -C "$P" push -q origin main
  git -C "$B" pull -q --ff-only
}

commit_file() {
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -qm "fixture $2"
}

diverge() {
  local kind="${1:-clean}"
  if [ "$kind" = conflict ]; then
    commit_file "$P" README.md local
    commit_file "$B" README.md remote
  else
    commit_file "$P" LOCAL local
    commit_file "$B" REMOTE remote
  fi
  LOCAL_SHA="$(git -C "$P" rev-parse HEAD)"
  REMOTE_SHA="$(git -C "$B" rev-parse HEAD)"
  git -C "$B" push -q origin main
}

no_model() {
  [ "$(stub_calls claude)" -eq 0 ]
  [ "$(stub_calls codex)" -eq 0 ]
  [ "$(stub_calls gh)" -eq 0 ]
}

event_reason() {
  events_json | jq -e --arg reason "$1" 'select(.event=="job.end" and .reason==$reason)'
}

@test "trunk reconcile: clean divergence preserves both histories and pushes" {
  flag true
  diverge
  run run_runner build "$P" --mode live
  [ "$status" -eq 0 ]
  git -C "$P" merge-base --is-ancestor "$LOCAL_SHA" HEAD
  git -C "$P" merge-base --is-ancestor "$REMOTE_SHA" HEAD
  [ "$(git -C "$P" rev-parse HEAD)" = "$(git --git-dir="$ORIGIN" rev-parse main)" ]
  [ -f "$P/LOCAL" ] && [ -f "$P/REMOTE" ]
  [ -z "$(git -C "$P" status --porcelain)" ]
  no_model
}

@test "trunk reconcile: behind-only fast forwards and ahead-only pushes" {
  flag true
  commit_file "$B" REMOTE remote
  git -C "$B" push -q origin main
  run run_runner build "$P" --mode live
  [ "$status" -eq 0 ]
  [ "$(git -C "$P" rev-parse HEAD)" = "$(git -C "$B" rev-parse HEAD)" ]
  commit_file "$P" LOCAL local
  run run_runner build "$P" --mode live
  [ "$status" -eq 0 ]
  [ "$(git -C "$P" rev-parse HEAD)" = "$(git --git-dir="$ORIGIN" rev-parse main)" ]
  no_model
}

@test "trunk reconcile: conflict aborts cleanly and notifies once per UTC day" {
  flag true
  diverge conflict
  for attempt in 1 2; do
    run run_runner build "$P" --mode live
    [ "$status" -eq 0 ]
    [ "$(git -C "$P" rev-parse HEAD)" = "$LOCAL_SHA" ]
    [ -z "$(git -C "$P" status --porcelain)" ]
    [ ! -f "$P/.git/MERGE_HEAD" ]
  done
  event_reason push_diverged | jq -e '.status=="abort" and (.detail|length)>0 and (.detail|length)<=300' >/dev/null
  [ "$(grep -c 'trunk-build (trunk conflict)' "$NOTIFY_LOG")" -eq 1 ]
  no_model
}

@test "trunk reconcile: fetch failure is nonzero with actionable detail" {
  flag true
  git -C "$P" remote set-url origin "$BATS_TEST_TMPDIR/missing.git"
  run run_runner build "$P" --mode live
  [ "$status" -eq 1 ]
  event_reason fetch_failed | jq -e '.status=="abort" and (.detail|contains("repository")) and (.detail|length)<=300' >/dev/null
  no_model
}

@test "trunk reconcile: push rejection retains bounded quotes without hints or ANSI" {
  flag true
  commit_file "$P" LOCAL local
  cat > "$ORIGIN/hooks/pre-receive" <<'HOOK'
#!/bin/sh
printf '\033[31merror: policy "quoted" rejected\033[0m\n' >&2
printf 'hint: do not forward this\n' >&2
printf 'error: %0500d\n' 0 >&2
exit 1
HOOK
  chmod +x "$ORIGIN/hooks/pre-receive"
  run run_runner build "$P" --mode live
  [ "$status" -eq 1 ]
  event_reason push_failed | jq -e '(.detail|length)<=300 and (.detail|contains("\"quoted\"")) and (.detail|contains("hint:")|not) and (.detail|contains("\u001b")|not)' >/dev/null
  no_model
}

@test "trunk reconcile: unset and false preserve legacy divergent rejection" {
  for setting in unset false; do
    if [ "$setting" = false ]; then
      flag false
    fi
    diverge conflict
    run run_runner build "$P" --mode live
    [ "$status" -eq 1 ]
    event_reason push_failed >/dev/null
    [ "$(git -C "$P" rev-parse HEAD)" = "$LOCAL_SHA" ]
    [ ! -f "$P/.git/MERGE_HEAD" ]
    if [ "$setting" = unset ]; then
      # Build a fresh topology for explicit false without touching history.
      P="$(make_fixture_project trunkfalse can-merge-false.toml)"
      # Keep svc stable for the event/budget fixture.
      fixture_replace_in_place "$P/.agents/config.toml" 'trunkfalse' 'trunk'
      git -C "$P" add .agents/config.toml && git -C "$P" commit -qm name
      ORIGIN="$BATS_TEST_TMPDIR/false-origin.git"
      git init -q --bare -b main "$ORIGIN"
      git -C "$P" remote add origin "$ORIGIN"
      git -C "$P" push -q -u origin main
      B="$BATS_TEST_TMPDIR/false-other"
      git clone -q "$ORIGIN" "$B"
    fi
  done
  no_model
}

@test "trunk reconcile: check-config is read-only and rejects string boolean" {
  run run_runner build "$P" --check-config
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.reconcile_trunk==false' >/dev/null
  flag true
  before="$(git -C "$P" status --porcelain)"
  event_before="$(wc -c < "$(events_file)")"
  run run_runner build "$P" --check-config
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.reconcile_trunk==true' >/dev/null
  [ "$before" = "$(git -C "$P" status --porcelain)" ]
  [ "$event_before" = "$(wc -c < "$(events_file)")" ]
  fixture_replace_in_place "$P/.agents/config.toml" '^reconcile_trunk = true$' 'reconcile_trunk = "true"'
  run run_runner build "$P" --check-config
  [ "$status" -eq 2 ]
  [[ "$output" == *'must be a boolean'* ]]
  no_model
}

@test "trunk reconcile: caller edits during fetch are preserved and skip mutation" {
  flag true
  diverge
  export REAL_GIT="$(command -v git)" FIXTURE_PROJECT="$P"
  make_stub_script git '
if [ "${1:-}" = fetch ]; then
  "$REAL_GIT" "$@" || exit $?
  printf "caller edit\n" > "$FIXTURE_PROJECT/README.md"
  exit 0
fi
exec "$REAL_GIT" "$@"'
  run run_runner build "$P" --mode live
  [ "$status" -eq 0 ]
  [ "$("$REAL_GIT" -C "$P" rev-parse HEAD)" = "$LOCAL_SHA" ]
  [ "$(cat "$P/README.md")" = 'caller edit' ]
  event_reason preflight_changed >/dev/null
  no_model
}

@test "trunk reconcile: approved managed skill links remain eligible" {
  flag true
  mkdir -p "$P/.agents/skills" "$P/.claude/skills"
  ln -s "$QUARTET_ROOT/skills/bugfix" "$P/.agents/skills/bugfix"
  ln -s "$QUARTET_ROOT/skills/bugfix" "$P/.claude/skills/bugfix"
  printf '# runtime\n' > "$P/.agents/shoulder.env"
  commit_file "$B" REMOTE remote
  git -C "$B" push -q origin main
  run run_runner build "$P" --mode live
  [ "$status" -eq 0 ]
  [ -f "$P/REMOTE" ]
  ! event_reason preflight_changed >/dev/null
  no_model
}

@test "trunk reconcile: remote push race is rejected without losing either history" {
  flag true
  commit_file "$P" LOCAL local
  LOCAL_SHA="$(git -C "$P" rev-parse HEAD)"
  commit_file "$B" REMOTE remote
  REMOTE_SHA="$(git -C "$B" rev-parse HEAD)"
  export REAL_GIT="$(command -v git)" FIXTURE_OTHER="$B"
  make_stub_script git '
if [ "${1:-}" = push ]; then
  "$REAL_GIT" -C "$FIXTURE_OTHER" push -q origin main || exit $?
fi
exec "$REAL_GIT" "$@"'
  run run_runner build "$P" --mode live
  [ "$status" -eq 1 ]
  event_reason push_failed | jq -e '(.detail|contains("rejected"))' >/dev/null
  [ "$("$REAL_GIT" -C "$P" rev-parse HEAD)" = "$LOCAL_SHA" ]
  [ "$("$REAL_GIT" --git-dir="$ORIGIN" rev-parse main)" = "$REMOTE_SHA" ]
  no_model
}

@test "trunk reconcile: changed HEAD during fetch skips further integration" {
  flag true
  diverge
  export REAL_GIT="$(command -v git)" FIXTURE_PROJECT="$P"
  make_stub_script git '
if [ "${1:-}" = fetch ]; then
  "$REAL_GIT" "$@" || exit $?
  "$REAL_GIT" -C "$FIXTURE_PROJECT" commit -q --allow-empty -m caller-work
  exit 0
fi
exec "$REAL_GIT" "$@"'
  run run_runner build "$P" --mode live
  [ "$status" -eq 0 ]
  [ "$("$REAL_GIT" -C "$P" log -1 --format=%s)" = caller-work ]
  ! "$REAL_GIT" -C "$P" merge-base --is-ancestor "$REMOTE_SHA" HEAD
  event_reason preflight_changed >/dev/null
  no_model
}

@test "trunk reconcile: abort failure remains nonzero and preserves evidence" {
  flag true
  diverge conflict
  export REAL_GIT="$(command -v git)"
  make_stub_script git '
if [ "${1:-}" = merge ] && [ "${2:-}" = --abort ]; then
  printf "error: fixture abort failed\n" >&2
  exit 1
fi
exec "$REAL_GIT" "$@"'
  run run_runner build "$P" --mode live
  [ "$status" -eq 1 ]
  [ -f "$P/.git/MERGE_HEAD" ]
  event_reason merge_abort_failed >/dev/null
  ! event_reason push_diverged >/dev/null
  [ "$(stub_calls claude)" -eq 0 ]
  # Fixture cleanup only: remove the intentional abort-failure override.
  "$REAL_GIT" -C "$P" merge --abort
}

@test "trunk reconcile: missing tracking ref after successful fetch fails before model" {
  flag true
  export REAL_GIT="$(command -v git)" FIXTURE_PROJECT="$P"
  make_stub_script git '
if [ "${1:-}" = fetch ]; then
  "$REAL_GIT" "$@" || exit $?
  "$REAL_GIT" -C "$FIXTURE_PROJECT" update-ref -d refs/remotes/origin/main
  exit 0
fi
exec "$REAL_GIT" "$@"'
  run run_runner build "$P" --mode live
  [ "$status" -eq 1 ]
  event_reason git_state_failed | jq -e '(.detail|length)>0 and (.detail|length)<=300' >/dev/null
  ! events_json | jq -e 'select(.event=="build.skipped")' >/dev/null
  no_model
}

@test "trunk reconcile: graph command errors fail with diagnostics before model" {
  flag true
  diverge
  export REAL_GIT="$(command -v git)"
  make_stub_script git '
if [ "${1:-}" = "$FIXTURE_GRAPH_COMMAND" ]; then
  printf "fatal: fixture commit graph unreadable\n" >&2
  exit 128
fi
exec "$REAL_GIT" "$@"'
  for graph_command in rev-list merge-base; do
    export FIXTURE_GRAPH_COMMAND="$graph_command"
    run run_runner build "$P" --mode live
    [ "$status" -eq 1 ]
    event_reason git_state_failed | jq -e '.detail|contains("graph unreadable")' >/dev/null
  done
  no_model
}

@test "trunk reconcile: integrated policy change stops before push or stale model work" {
  flag true
  printf '%s\n' '{"svc":"trunk-build","event":"job.end","tokens":1}' > "$(events_file)"
  commit_file "$P" LOCAL local
  fixture_replace_in_place "$B/.agents/config.toml" '^wall_clock_sec = 60$' 'wall_clock_sec = 60\nbudget_tokens_daily = 1\nforbidden_paths = ["protected/"]'
  git -C "$B" add .agents/config.toml
  git -C "$B" commit -qm remote-policy
  REMOTE_SHA="$(git -C "$B" rev-parse HEAD)"
  git -C "$B" push -q origin main
  run run_runner build "$P" --mode live
  [ "$status" -eq 0 ]
  event_reason config_changed >/dev/null
  no_model
  [ "$(git --git-dir="$ORIGIN" rev-parse main)" = "$REMOTE_SHA" ]
  [ "$(git -C "$P" rev-parse HEAD)" != "$REMOTE_SHA" ]
  grep -q 'forbidden_paths = \["protected/"\]' "$P/.agents/config.toml"
  # The next cycle reloads the new policy, publishes the preserved merge,
  # then sees its token cap rather than invoking the old budget/model path.
  run run_runner build "$P" --mode live
  [ "$status" -eq 0 ]
  events_json | jq -e 'select(.event=="build.skipped" and .reason=="budget" and .budget==1)' >/dev/null
  [ "$(git -C "$P" rev-parse HEAD)" = "$(git --git-dir="$ORIGIN" rev-parse main)" ]
  no_model
}

@test "trunk reconcile: policy changed before fetch snapshot still stops stale work" {
  flag true
  export REAL_GIT="$(command -v git)" FIXTURE_PROJECT="$P" FIXTURE_ONCE="$BATS_TEST_TMPDIR/config-once"
  export -f fixture_replace_in_place
  make_stub_script git '
if [ "${1:-}" = status ] && [ ! -e "$FIXTURE_ONCE" ]; then
  touch "$FIXTURE_ONCE"
  fixture_replace_in_place "$FIXTURE_PROJECT/.agents/config.toml" "^wall_clock_sec = 60$" "wall_clock_sec = 60\nforbidden_paths = [\"protected/\"]"
  "$REAL_GIT" -C "$FIXTURE_PROJECT" add .agents/config.toml
  "$REAL_GIT" -C "$FIXTURE_PROJECT" commit -qm local-policy
fi
exec "$REAL_GIT" "$@"'
  run run_runner build "$P" --mode live
  [ "$status" -eq 0 ]
  event_reason config_changed >/dev/null
  no_model
}

@test "trunk reconcile: integrated missing config fails before model" {
  flag true
  git -C "$B" rm -q .agents/config.toml
  git -C "$B" commit -qm remove-policy
  git -C "$B" push -q origin main
  run run_runner build "$P" --mode live
  [ "$status" -eq 1 ]
  event_reason config_read_failed >/dev/null
  no_model
}

@test "trunk reconcile: invalid integrated configuration fails without exposing its contents" {
  flag true
  printf 'invalid syntax SYNTHETIC_POLICY_SECRET\n' > "$B/.agents/config.toml"
  git -C "$B" add .agents/config.toml
  git -C "$B" commit -qm invalid-policy
  git -C "$B" push -q origin main
  run run_runner build "$P" --mode live
  [ "$status" -eq 1 ]
  event_reason config_read_failed >/dev/null
  [[ "$output" != *SYNTHETIC_POLICY_SECRET* ]]
  ! grep -q SYNTHETIC_POLICY_SECRET "$P/tmp/trunk-build-last-run.log"
  ! events_json | grep -q SYNTHETIC_POLICY_SECRET
  no_model
}
