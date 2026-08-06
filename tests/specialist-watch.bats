#!/usr/bin/env bats
# Specialist shoulder routing. Harness and delivery are deterministic stubs;
# these tests make no model or network call.

setup() {
  load helpers
  quartet_setup
}

WATCH="agents/release/critic-watch.sh"
SHIPYARD="skills/shipyard/shipyard.sh"

run_watch() {
  QUARTET_DIR="$QUARTET_ROOT" QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    CRITIC_IDLE_SEC=1 CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note" \
    bash "$QUARTET_ROOT/$WATCH" --project "$1" --session s1 --once
}

configure_specialist() {
  local project="$1" pattern="$2" external="${3:-}"
  QUARTET_DIR="$QUARTET_ROOT" bash "$QUARTET_ROOT/$SHIPYARD" \
    add-specialist security --project "$project" >/dev/null
  local manifest="$project/.agents/specialists/security.toml"
  fixture_replace_in_place "$manifest" \
    '^hunk_path_patterns = \[\]$' "hunk_path_patterns = [\"$pattern\"]"
  if [ -n "$external" ]; then
    fixture_replace_in_place "$manifest" \
      '^external_repository_triggers = \[\]$' \
      "external_repository_triggers = [\"$external\"]"
  fi
  fixture_replace_in_place "$manifest" '^live_docs = \[\]$' ''
  printf '\n[[live_docs]]\nlabel = "AWS EC2 AMI encryption"\nurl = "https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/AMIEncryption.html"\nauthority = "AWS"\naccess_mode = "public"\n' >>"$manifest"
}

queue_path() {
  printf '%s %s\n' "$2" "$(date +%s)" >"$1/tmp/critic-queue-s1"
  fixture_set_mtime_ago 120 "$1/tmp/critic-queue-s1"
}

stub_two_reviews() {
  ORDER_FILE="$BATS_TEST_TMPDIR/order"
  SPECIALIST_PROMPT="$BATS_TEST_TMPDIR/specialist-prompt"
  export ORDER_FILE SPECIALIST_PROMPT
  make_stub_script claude '
case "$*" in
  *"Specialist — generic subsystem-steward role"*)
    printf "specialist\n" >>"$ORDER_FILE"
    printf "%s" "$*" >"$SPECIALIST_PROMPT"
    jq -nc --arg result "block|src/infra.tf|missing source grant
source|https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/AMIEncryption.html|2026-08-04T18:00:00Z|success|shared encrypted AMIs require source and destination key authorization
TOKENS_HINT|<none>" \
      "{type:\"result\",result:\$result,usage:{input_tokens:20,output_tokens:10}}"
    ;;
  *)
    printf "generic\n" >>"$ORDER_FILE"
    jq -nc --arg result "warn|src/infra.tf|Missing   source grant
TOKENS_HINT|<none>" \
      "{type:\"result\",result:\$result,usage:{input_tokens:10,output_tokens:5}}"
    ;;
esac'
  make_stub claude-note 0
}

@test "matching real hunk runs generic first then specialist, builds bounded evidence prompt, and retains higher duplicate severity" {
  P="$(make_fixture_project specialist-match)"
  configure_specialist "$P" 'src/*.tf'
  mkdir -p "$P/src"
  printf 'resource "aws_instance" "worker" {}\n' >"$P/src/infra.tf"
  queue_path "$P" src/infra.tf
  stub_two_reviews

  run run_watch "$P"
  [ "$status" -eq 0 ]
  [ "$(cat "$ORDER_FILE")" = $'generic\nspecialist' ]
  grep -qF 'Specialist — generic subsystem-steward role' "$SPECIALIST_PROMPT"
  grep -qF 'Subsystem: **security**' "$SPECIALIST_PROMPT"
  grep -qF '## Invariants' "$SPECIALIST_PROMPT"
  grep -qF 'PROJECT GATES' "$SPECIALIST_PROMPT"
  grep -qF 'resource "aws_instance" "worker"' "$SPECIALIST_PROMPT"
  grep -qF 'https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/AMIEncryption.html' "$SPECIALIST_PROMPT"
  grep -qF 'read-only' "$SPECIALIST_PROMPT"
  [ "$(grep -c 'source grant' "$P/tmp/critic-findings-s1")" = "1" ]
  grep -qF 'block|src/infra.tf|missing source grant' "$P/tmp/critic-findings-s1"
  grep -qF 'source|https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/AMIEncryption.html|2026-08-04T18:00:00Z|success|' \
    "$P/tmp/critic-specialist-sources-s1"
}

@test "queued matching filename with no real hunk does not trigger specialist" {
  P="$(make_fixture_project specialist-no-hunk)"
  configure_specialist "$P" 'src/infra.tf'
  mkdir -p "$P/src"
  printf 'original\n' >"$P/src/infra.tf"
  git -C "$P" add src/infra.tf
  git -C "$P" commit -q -m baseline
  printf 'changed then reverted\n' >"$P/src/infra.tf"
  printf 'original\n' >"$P/src/infra.tf"
  printf 'real app hunk\n' >"$P/src/app.py"
  printf 'src/infra.tf %s\nsrc/app.py %s\n' "$(date +%s)" "$(date +%s)" \
    >"$P/tmp/critic-queue-s1"
  fixture_set_mtime_ago 120 "$P/tmp/critic-queue-s1"
  order="$BATS_TEST_TMPDIR/no-hunk-order"; export order
  make_stub_script claude 'printf "generic\n" >>"$order"
printf "%s\n" "{\"type\":\"result\",\"result\":\"note|src/app.py|generic only\\nTOKENS_HINT|<none>\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"'
  make_stub claude-note 0

  run run_watch "$P"
  [ "$status" -eq 0 ]
  [ "$(cat "$order")" = "generic" ]
  [ ! -e "$P/tmp/critic-specialist-sources-s1" ]
}

@test "malformed matching manifest fails closed after generic review and preserves queue" {
  P="$(make_fixture_project specialist-malformed)"
  configure_specialist "$P" 'src/*.tf'
  fixture_replace_in_place "$P/.agents/specialists/security.toml" \
    '^prompt_definition = ".*"$' 'prompt_definition = "../outside.md"'
  mkdir -p "$P/src"
  printf 'resource "aws_instance" "worker" {}\n' >"$P/src/infra.tf"
  queue_path "$P" src/infra.tf
  order="$BATS_TEST_TMPDIR/malformed-order"; export order
  make_stub_script claude 'printf "generic\n" >>"$order"
printf "%s\n" "{\"type\":\"result\",\"result\":\"note|src/infra.tf|generic complete\\nTOKENS_HINT|<none>\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"'
  make_stub claude-note 0

  run run_watch "$P"
  [ "$status" -eq 0 ]
  [ "$(cat "$order")" = "generic" ]
  [ -s "$P/tmp/critic-queue-s1" ]
  [ "$(stub_calls claude-note)" = "0" ]
  [[ "$output" == *"specialist manifest invalid"* ]]
}

@test "malformed specialist verdict fails closed and preserves queue" {
  P="$(make_fixture_project specialist-bad-response)"
  configure_specialist "$P" 'src/*.tf'
  mkdir -p "$P/src"
  printf 'resource "aws_instance" "worker" {}\n' >"$P/src/infra.tf"
  queue_path "$P" src/infra.tf
  order="$BATS_TEST_TMPDIR/bad-response-order"; export order
  make_stub_script claude '
case "$*" in
  *"Specialist — generic subsystem-steward role"*)
    printf "specialist\n" >>"$order"
    jq -nc --arg result "BLOCK" "{type:\"result\",result:\$result,usage:{input_tokens:1,output_tokens:1}}"
    ;;
  *)
    printf "generic\n" >>"$order"
    jq -nc --arg result "TOKENS_HINT|<none>" "{type:\"result\",result:\$result,usage:{input_tokens:1,output_tokens:1}}"
    ;;
esac'
  make_stub claude-note 0

  run run_watch "$P"
  [ "$status" -eq 0 ]
  [ "$(cat "$order")" = $'generic\nspecialist' ]
  [ -s "$P/tmp/critic-queue-s1" ]
  [ ! -e "$P/tmp/critic-findings-s1" ]
  [ ! -e "$P/tmp/critic-valid-response-s1" ]
  [ "$(stub_calls claude-note)" = "0" ]
  [[ "$output" == *"malformed review output"* ]]
}

@test "ticket hunk containing external repository trigger invokes specialist without a matching path glob" {
  P="$(make_fixture_project specialist-ticket)"
  configure_specialist "$P" 'src/*.tf' 'datavant/infrastructure'
  mkdir -p "$P/docs/tickets"
  printf 'Open a PR in datavant/infrastructure for the KMS policy.\n' \
    >"$P/docs/tickets/t1.md"
  queue_path "$P" docs/tickets/t1.md
  stub_two_reviews

  run run_watch "$P"
  [ "$status" -eq 0 ]
  [ "$(cat "$ORDER_FILE")" = $'generic\nspecialist' ]
  grep -qF 'docs/tickets/t1.md' "$SPECIALIST_PROMPT"
  grep -qF 'datavant/infrastructure' "$SPECIALIST_PROMPT"
}
