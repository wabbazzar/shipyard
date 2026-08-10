#!/usr/bin/env bats

setup() {
  load helpers
  quartet_setup
}

make_scribe_fixture() {
  local name="$1" lifecycle="${2:-true}"
  local archive_dir="${3:-docs/tickets/complete}"
  local auto_commit="${4:-false}" auto_push="${5:-false}"

  NAME="$name"
  P="$(make_fixture_project "$name" branch-present.toml)"
  mkdir -p "$P/docs/tickets/pending" "$P/docs/tickets/complete" \
    "$P/docs/tickets/freezer"
  cat >>"$P/.agents/config.toml" <<EOF

[scribe]
content_paths = ["docs/tickets"]
auto_commit = $auto_commit
auto_push = $auto_push
EOF
  if [ "$lifecycle" = "true" ]; then
    cat >>"$P/.agents/config.toml" <<EOF

[write_ticket]
ticket_dir = "docs/tickets/pending"
archive_dir = "$archive_dir"
backlog_dir = "docs/tickets/freezer"
lifecycle_dirs = true
EOF
  fi

  TICKET="$P/docs/tickets/pending/001_fixture.md"
  printf '# Fixture ticket\n\n**Status:** Open\n' >"$TICKET"
  git -C "$P" add .agents/config.toml docs/tickets
  git -C "$P" commit -qm "fixture: configure scribe lifecycle"
  export NAME P TICKET
}

stub_scribe_model() {
  export MODEL_STATUS="${1:-}"
  export MODEL_PASS="${2:-true}"
  export MODEL_RESULT="$P/tmp/$NAME-scribe-result.json"
  make_stub_script claude '
if [ -n "${MODEL_STATUS:-}" ]; then
  printf "# Fixture ticket\n\n**Status:** %s\n" "$MODEL_STATUS" >"$TICKET"
fi
printf "{\"pass\":%s}\n" "$MODEL_PASS" >"$MODEL_RESULT"
printf "%s\n" "{\"result\":\"fixture\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
'
}

@test "scribe reconciles a model-shipped pending ticket before changed-file accounting" {
  make_scribe_fixture lifecycle-primary
  stub_scribe_model "Shipped (verified fixture, last commit abc1234)"

  run run_runner scribe "$P" --mode daily
  [ "$status" -eq 0 ]
  [ ! -e "$P/docs/tickets/pending/001_fixture.md" ]
  [ -f "$P/docs/tickets/complete/001_fixture.md" ]
  grep -q 'git mv docs/tickets/pending/001_fixture.md docs/tickets/complete/001_fixture.md' \
    "$P/tmp/$NAME-scribe-last-run.log"
  grep -q 'lifecycle: check rc=0' "$P/tmp/$NAME-scribe-last-run.log"
  run env QUARTET_DIR="$QUARTET_ROOT" bash \
    "$QUARTET_ROOT/scripts/ticket-lifecycle.sh" --project "$P" --check
  [ "$status" -eq 0 ]
}

@test "guard: an open pending ticket stays pending" {
  make_scribe_fixture lifecycle-open
  stub_scribe_model

  run run_runner scribe "$P" --mode daily
  [ "$status" -eq 0 ]
  [ -f "$P/docs/tickets/pending/001_fixture.md" ]
  [ ! -e "$P/docs/tickets/complete/001_fixture.md" ]
}

@test "guard: lifecycle_dirs unset preserves the legacy no-op" {
  make_scribe_fixture lifecycle-unset false
  stub_scribe_model "Shipped (verified fixture, last commit abc1234)"

  run run_runner scribe "$P" --mode daily
  [ "$status" -eq 0 ]
  [ -f "$P/docs/tickets/pending/001_fixture.md" ]
  [ ! -e "$P/docs/tickets/complete/001_fixture.md" ]
  job_end="$(events_json | jq -c 'select(.event=="job.end")')"
  [ "$(jq -r '.status' <<<"$job_end")" = "ok" ]
  jq -e 'has("lifecycle_gate") | not' <<<"$job_end" >/dev/null
}

@test "lifecycle failure fails the job and blocks commit and push" {
  make_scribe_fixture lifecycle-failure true docs/tickets/archive-target true true
  printf 'not a directory\n' >"$P/docs/tickets/archive-target"
  git -C "$P" add docs/tickets/archive-target
  git -C "$P" commit -qm "fixture: block archive destination"

  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  git init -q --bare -b main "$ORIGIN"
  git -C "$P" remote add origin "$ORIGIN"
  git -C "$P" push -q -u origin main
  BEFORE_LOCAL="$(git -C "$P" rev-parse HEAD)"
  BEFORE_ORIGIN="$(git --git-dir="$ORIGIN" rev-parse refs/heads/main)"
  REAL_GIT="$(command -v git)"
  export ORIGIN BEFORE_LOCAL BEFORE_ORIGIN REAL_GIT
  make_stub_script git 'exec "'$REAL_GIT'" "$@"'
  stub_scribe_model "Shipped (verified fixture, last commit abc1234)"

  run run_runner scribe "$P" --mode daily
  [ "$status" -eq 0 ]
  job_end="$(events_json | jq -c 'select(.event=="job.end")')"
  [ "$(jq -r '.status' <<<"$job_end")" = "fail" ]
  [ "$(jq -r '.lifecycle_gate' <<<"$job_end")" = "false" ]
  [ "$(jq -r '.commit_outcome' <<<"$job_end")" = "skipped" ]
  [ "$($REAL_GIT -C "$P" rev-parse HEAD)" = "$BEFORE_LOCAL" ]
  [ "$($REAL_GIT --git-dir="$ORIGIN" rev-parse refs/heads/main)" = "$BEFORE_ORIGIN" ]
  ! stub_argv git | grep -qE '(^|[[:space:]])push([[:space:]]|$)'
  [ -f "$P/docs/tickets/pending/001_fixture.md" ]
  grep -q 'FAILED: git mv' "$P/tmp/$NAME-scribe-last-run.log"
  grep -q 'lifecycle: check rc=1' "$P/tmp/$NAME-scribe-last-run.log"
}
