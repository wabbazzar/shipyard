#!/usr/bin/env bats

setup() {
  load helpers
  quartet_setup
  export PROMPT_LOG="$BATS_TEST_TMPDIR/prompt.txt"
  make_stub_script claude '
last="${!#}"
printf "%s" "$last" >"$PROMPT_LOG"
printf "%s\n" '\''{"type":"result","result":"note|src/value.txt|reviewed","usage":{"input_tokens":1,"output_tokens":1}}'\''
'
}

prepare_review() {
  local project="$1"
  mkdir -p "$project/src"
  printf 'base\n' >"$project/src/value.txt"
  git -C "$project" add src/value.txt
  git -C "$project" commit -m base >/dev/null
}

run_review() {
  local project="$1"
  printf 'src/value.txt %s\n' "$(date +%s)" >"$project/tmp/critic-queue-review"
  CRITIC_IDLE_SEC=0 QUARTET_DIR="$QUARTET_ROOT" QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    /bin/bash "$QUARTET_ROOT/agents/release/critic-watch.sh" \
    --project "$project" --session review --once
}

@test "shoulder diff prefers origin configured branch over divergent local branch" {
  P="$(make_fixture_project revieworigin clean-install.toml)"
  prepare_review "$P"
  remote="$BATS_TEST_TMPDIR/origin.git"
  git init --bare -q "$remote"
  git -C "$P" remote add origin "$remote"
  git -C "$P" push -q -u origin main

  printf 'local-main\n' >"$P/src/value.txt"
  git -C "$P" commit -am 'diverge local main' >/dev/null
  git -C "$P" switch -q -c feature origin/main
  printf 'feature\n' >"$P/src/value.txt"

  run run_review "$P"
  [ "$status" -eq 0 ]
  grep -Fq -- '-base' "$PROMPT_LOG"
  grep -Fq -- '+feature' "$PROMPT_LOG"
  ! grep -Fq -- '-local-main' "$PROMPT_LOG"
}

@test "shoulder diff falls back to configured local branch when origin ref is absent" {
  P="$(make_fixture_project reviewfallback clean-install.toml)"
  prepare_review "$P"
  base="$(git -C "$P" rev-parse HEAD)"
  printf 'local-main\n' >"$P/src/value.txt"
  git -C "$P" commit -am 'advance local main' >/dev/null
  git -C "$P" switch -q -c feature "$base"
  printf 'feature\n' >"$P/src/value.txt"

  run run_review "$P"
  [ "$status" -eq 0 ]
  grep -Fq -- '-local-main' "$PROMPT_LOG"
  grep -Fq -- '+feature' "$PROMPT_LOG"
}

@test "explicit origin ref remains the shoulder review base" {
  P="$(make_fixture_project reviewexplicit clean-install.toml)"
  fixture_replace_in_place "$P/.agents/config.toml" \
    '^branch\s*=\s*"main"' 'branch = "origin/main"' 1
  prepare_review "$P"
  remote="$BATS_TEST_TMPDIR/explicit-origin.git"
  git init --bare -q "$remote"
  git -C "$P" remote add origin "$remote"
  git -C "$P" push -q -u origin main
  printf 'local-main\n' >"$P/src/value.txt"
  git -C "$P" commit -am 'diverge explicit local main' >/dev/null
  git -C "$P" switch -q -c feature origin/main
  printf 'feature\n' >"$P/src/value.txt"

  run run_review "$P"
  [ "$status" -eq 0 ]
  grep -Fq -- '-base' "$PROMPT_LOG"
  ! grep -Fq -- '-local-main' "$PROMPT_LOG"
}
