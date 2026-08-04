#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  quartet_setup
  make_stub_script systemctl '
u=""; for a in "$@"; do case "$a" in *.timer|*.service) u="$a";; esac; done
case "$*" in
  *is-enabled*|*is-active*) [ -f "$HOME/.config/systemd/user/$u" ]; exit $? ;;
  *show*)
    unit="$HOME/.config/systemd/user/$u"
    printf "FragmentPath=%s\n" "$unit"
    printf "ExecStart=%s\n" "$(sed -n "s/^ExecStart=//p" "$unit")"
    printf "EnvironmentFiles=%s (ignore_errors=yes)\n" "$(sed -n "s/^EnvironmentFile=-//p" "$unit")"
    ;;
  *) exit 0 ;;
esac'
  make_stub crontab 0 ""
  make_stub gh 0
  make_stub claude 0
  export XDG_STATE_HOME="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/state"
  mkdir -m 700 "$XDG_STATE_HOME"
  export CODEX_HOME="$BATS_TEST_TMPDIR/codex"
  mkdir -p "$CODEX_HOME"
  printf 'model = "fixture"\n' >"$CODEX_HOME/config.toml"
}

dual_project() {
  local name="$1" order="${2:-claude, codex}"
  P="$(make_fixture_project "$name" clean-install.toml)"
  cat >>"$P/.agents/config.toml" <<EOF

[shoulder]
auto_wire = true
harnesses = [$order]
critic_harness = "claude"
EOF
}

install_project() {
  QUARTET_DIR="$QUARTET_ROOT" QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    QUARTET_NOTIFY_CMD=true bash "$QUARTET_ROOT/install.sh" --project "$P" "$@"
}

@test "dual list wires ordered Claude primary and project-scoped Codex additional" {
  dual_project dual '"claude", "codex"'
  run install_project
  [ "$status" -eq 0 ]
  jq -e --arg q "$QUARTET_ROOT/agents/release/critic-queue.sh" \
    'any(.hooks.PostToolUse[]?.hooks[]?; .command == $q)' "$P/.claude/settings.json"
  grep -q -- '--codex-runtime-hook-scoped' "$CODEX_HOME/config.toml"
  grep -Fxq 'CRITIC_MULTI_AUTHOR=true' "$P/.agents/shoulder.env"
  grep -Fxq 'CRITIC_PRIMARY_HARNESS=claude' "$P/.agents/shoulder.env"
  grep -Fxq 'CRITIC_AUTHOR_HARNESSES=claude,codex' "$P/.agents/shoulder.env"
}

@test "Codex primary keeps the legacy hook while Claude secondary is namespaced" {
  dual_project dualreverse '"codex", "claude"'
  run install_project
  [ "$status" -eq 0 ]
  grep -q -- '--codex-runtime-hook ' "$CODEX_HOME/config.toml"
  ! grep -q -- '--codex-runtime-hook-scoped' "$CODEX_HOME/config.toml"
  jq -e --arg q \
    "CRITIC_QUEUE_NAMESPACE=claude CRITIC_AUTHOR_HARNESS=claude /bin/bash $QUARTET_ROOT/agents/release/critic-queue.sh" \
    'any(.hooks.PostToolUse[]?.hooks[]?; .command == $q)' \
    "$P/.claude/settings.json"
  grep -Fxq 'CRITIC_PRIMARY_HARNESS=codex' "$P/.agents/shoulder.env"
  grep -Fxq 'CRITIC_AUTHOR_HARNESSES=codex,claude' "$P/.agents/shoulder.env"
}

@test "same raw session stays legacy for primary and is isolated for additional" {
  P="$(make_fixture_project dualqueue)"
  claude_json="$(jq -nc '{session_id:"same",tool_input:{file_path:"src/a.ts"}}')"
  codex_patch="$(printf '*** Begin Patch\n*** Add File: src/b.ts\n+x\n*** End Patch')"
  codex_json="$(jq -nc --arg cwd "$P" --arg command "$codex_patch" \
    '{session_id:"same",cwd:$cwd,tool_input:{command:$command}}')"
  printf '%s' "$claude_json" | CLAUDE_PROJECT_DIR="$P" \
    bash "$QUARTET_ROOT/agents/release/critic-queue.sh"
  printf '%s' "$codex_json" | CRITIC_QUEUE_NAMESPACE=codex \
    bash "$QUARTET_ROOT/agents/release/critic-queue-codex.sh"
  [ -s "$P/tmp/critic-queue-same" ]
  [ -s "$P/tmp/critic-queue-codex--same" ]
}

@test "watcher isolates internal state but delivers raw ID through each author harness" {
  P="$(make_fixture_project dualdeliver)"
  mkdir -p "$P/src"
  printf 'primary\n' >"$P/src/primary.ts"
  printf 'additional\n' >"$P/src/additional.ts"
  now="$(date +%s)"
  printf 'src/primary.ts %s\n' "$now" >"$P/tmp/critic-queue-same"
  printf 'src/additional.ts %s\n' "$now" >"$P/tmp/critic-queue-codex--same"
  make_stub claude 0 '{"type":"result","result":"note|src/x.ts|checked","usage":{"input_tokens":1,"output_tokens":1}}'
  recorder="$BATS_TEST_TMPDIR/record-note.sh"
  cat >"$recorder" <<EOF
#!/bin/bash
printf '%s|%s\n' "\$CRITIC_NOTE_HARNESS" "\$1" >>"$BATS_TEST_TMPDIR/deliveries"
EOF
  chmod +x "$recorder"
  CRITIC_FEEDBACK_ADMIN=1 \
    "$QUARTET_ROOT/agents/release/critic-codex-feedback.sh" \
    --admin-allow-project "$P"
  run env QUARTET_DIR="$QUARTET_ROOT" QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    CRITIC_IDLE_SEC=0 CRITIC_MULTI_AUTHOR=true \
    CRITIC_PRIMARY_HARNESS=claude CRITIC_NOTE_HARNESS=claude \
    CLAUDE_NOTE_CMD=true CRITIC_NOTE_DELIVER_CMD="$recorder" \
    bash "$QUARTET_ROOT/agents/release/critic-watch.sh" --project "$P" --once
  [ "$status" -eq 0 ]
  grep -Fxq 'claude|same' "$BATS_TEST_TMPDIR/deliveries"
  grep -Fxq 'codex|same' "$BATS_TEST_TMPDIR/deliveries"
  [ -f "$P/tmp/critic-findings-same" ]
  [ -f "$P/tmp/critic-findings-codex--same" ]
}

@test "dual doctor reports each configured author independently" {
  dual_project dualdoctor '"claude", "codex"'
  install_project >/dev/null
  printf 'model = "fixture"\n' >"$CODEX_HOME/config.toml"
  run env QUARTET_DIR="$QUARTET_ROOT" bash "$QUARTET_ROOT/install.sh" \
    --doctor --project "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *"shoulder: codex"* ]]
  [[ "$output" != *"shoulder: claude capture hook"* ]]
}

@test "invalid second author fails before changing the primary config" {
  dual_project dualbad '"claude", "hermes"'
  mkdir -p "$P/.claude"
  printf '{"existing":true}\n' >"$P/.claude/settings.json"
  before="$(cksum "$P/.claude/settings.json")"
  run install_project
  [ "$status" -eq 2 ]
  [ "$(cksum "$P/.claude/settings.json")" = "$before" ]
  [ ! -f "$P/.agents/shoulder.env" ]
}

@test "duplicate and scalar-list ambiguous author configs fail before mutation" {
  for shoulder_config in \
    'harnesses = ["claude", "claude"]' \
    $'harness = "claude"\nharnesses = ["claude", "codex"]'; do
    P="$(make_fixture_project dual-invalid clean-install.toml)"
    printf '\n[shoulder]\nauto_wire = true\n%s\n' "$shoulder_config" \
      >>"$P/.agents/config.toml"
    mkdir -p "$P/.claude"
    printf '{"existing":true}\n' >"$P/.claude/settings.json"
    before="$(cksum "$P/.claude/settings.json")"
    run install_project
    [ "$status" -eq 2 ]
    [ "$(cksum "$P/.claude/settings.json")" = "$before" ]
    [ ! -f "$P/.agents/shoulder.env" ]
  done
}

@test "scalar Hermes configuration remains accepted" {
  P="$(make_fixture_project scalarhermes clean-install.toml)"
  cat >>"$P/.agents/config.toml" <<'EOF'

[shoulder]
auto_wire = true
harness = "hermes"
critic_harness = "claude"
EOF
  export HERMES_HOME="$BATS_TEST_TMPDIR/hermes"
  run install_project
  [ "$status" -eq 0 ]
  grep -q 'post_tool_call:' "$HERMES_HOME/config.yaml"
}
