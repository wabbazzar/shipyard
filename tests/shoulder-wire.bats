#!/usr/bin/env bats
# tests/shoulder-wire.bats — opt-in shoulder-mode wiring (install.sh
# --wire-shoulder + agents/lib/shoulder-wire.sh) and its doctor drift check.
# Core invariant: with the opt-in UNSET, install touches no harness config
# (byte-identical to every prior install).

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  quartet_setup
  make_stub_script systemctl '
u=""; for a in "$@"; do case "$a" in *.timer|*.service) u="$a";; esac; done
case "$*" in
  *is-enabled*) [ -n "$u" ] && [ -f "$HOME/.config/systemd/user/$u" ] && exit 0 || exit 1 ;;
  *is-active*) [ -n "$u" ] && [ -f "$HOME/.config/systemd/user/$u" ] && exit 0 || exit 1 ;;
  *show*)
    if [ "${SYSTEMCTL_STALE_LOADED:-0}" = "1" ]; then
      printf "FragmentPath=%s\n" "$HOME/.config/systemd/user/$u"
      printf "ExecStart={ path=/legacy/watch ; argv[]=/legacy/watch ; }\n"
      printf "EnvironmentFiles=/legacy/shoulder.env (ignore_errors=yes)\n"
    else
      unit="$HOME/.config/systemd/user/$u"
      printf "FragmentPath=%s\n" "$unit"
      printf "ExecStart=%s\n" "$(sed -n "s/^ExecStart=//p" "$unit")"
      printf "EnvironmentFiles=%s (ignore_errors=yes)\n" \
        "$(sed -n "s/^EnvironmentFile=-//p" "$unit")"
    fi
    exit 0
    ;;
  *try-restart*) [ "${SYSTEMCTL_FAIL_TRY_RESTART:-0}" = "1" ] && exit 1 || exit 0 ;;
  *) exit 0 ;;
esac'
  make_stub crontab 0 ""
  make_stub gh 0
  make_stub claude 0
  export XDG_STATE_HOME="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/state"
  export CODEX_HOME="$BATS_TEST_TMPDIR/codex"
  export HERMES_HOME="$BATS_TEST_TMPDIR/hermes"
  WIRE="agents/lib/shoulder-wire.sh"
}

# ---------------------------------------------------------------------------
# (A) shoulder-wire.sh merge functions — additive, idempotent, safe
# ---------------------------------------------------------------------------

@test "claude wire is additive (existing hook survives) and idempotent" {
  f="$BATS_TEST_TMPDIR/settings.json"
  printf '{"hooks":{"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/keep.sh"}]}]}}' >"$f"
  run bash -c ". '$QUARTET_ROOT/$WIRE'; sw_wire claude '$f' '/q/cq.sh'; sw_wire claude '$f' '/q/cq.sh'"
  [ "$status" -eq 0 ]
  [ "$(jq '.hooks.PostToolUse | length' "$f")" -eq 2 ]
  jq -e 'any(.hooks.PostToolUse[].hooks[]; .command=="/keep.sh")' "$f"
  jq -e 'any(.hooks.PostToolUse[].hooks[]; .command=="/q/cq.sh")' "$f"
}

@test "codex wire appends a hooks block, keeps prior content, idempotent" {
  f="$BATS_TEST_TMPDIR/config.toml"; printf 'model = "gpt-5.6"\n' >"$f"
  bash -c ". '$QUARTET_ROOT/$WIRE'; sw_wire codex '$f' '/q/cqc.sh'; sw_wire codex '$f' '/q/cqc.sh'" >/dev/null
  [ "$(grep -c '^\[\[hooks.PostToolUse\]\]' "$f")" -eq 1 ]
  grep -q 'model = "gpt-5.6"' "$f"
  run bash -c ". '$QUARTET_ROOT/$WIRE'; sw_wired codex '$f' '/q/cqc.sh'"
  [ "$status" -eq 0 ]
}

@test "codex bundle is additive, exact, and idempotent across three hooks" {
  f="$BATS_TEST_TMPDIR/config.toml"
  p="$BATS_TEST_TMPDIR/project"
  mkdir -p "$p"
  printf 'model = "gpt-5.6"\n\n[[hooks.PostToolUse]]\nmatcher = "Bash"\n[[hooks.PostToolUse.hooks]]\ntype = "command"\ncommand = "/keep.sh"\n' >"$f"

  run bash -c ". '$QUARTET_ROOT/$WIRE'; \
    sw_wire_codex_bundle '$f' '$p' /q/capture.sh /q/feedback.sh /q/stop.sh; \
    sw_wire_codex_bundle '$f' '$p' /q/capture.sh /q/feedback.sh /q/stop.sh; \
    sw_codex_bundle_wired '$f' '$p' /q/capture.sh /q/feedback.sh /q/stop.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^\[\[hooks.PostToolUse\]\]' "$f")" -eq 3 ]
  [ "$(grep -c '^\[\[hooks.Stop\]\]' "$f")" -eq 1 ]
  python3 - "$f" <<'PY'
import sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib

with open(sys.argv[1], "rb") as handle:
    hooks = tomllib.load(handle)["hooks"]
post = hooks["PostToolUse"]
stop = hooks["Stop"]
assert any(row.get("matcher") == "Bash" for row in post)
assert sum(row.get("matcher") == "apply_patch" for row in post) == 1
assert sum(row.get("matcher") == "*" for row in post) == 1
assert len(stop) == 1 and stop[0].get("matcher") == "*"
commands = [
    hook["command"]
    for row in post + stop
    for hook in row["hooks"]
]
assert "/keep.sh" in commands
assert sum("--codex-runtime-hook" in command for command in commands) == 2
PY
}

@test "hermes wire writes a fresh hooks block and is detectable" {
  f="$BATS_TEST_TMPDIR/config.yaml"; : >"$f"
  bash -c ". '$QUARTET_ROOT/$WIRE'; sw_wire hermes '$f' '/q/cqh.sh'" >/dev/null
  grep -q 'post_tool_call:' "$f"
  run bash -c ". '$QUARTET_ROOT/$WIRE'; sw_wired hermes '$f' '/q/cqh.sh'"
  [ "$status" -eq 0 ]
}

@test "hermes wire REFUSES (rc 2) to corrupt an existing hooks: block" {
  f="$BATS_TEST_TMPDIR/c2.yaml"
  printf 'hooks:\n  pre_tool_call:\n    - matcher: ".*"\n      command: "/x.sh"\n' >"$f"
  before="$(cat "$f")"
  run bash -c ". '$QUARTET_ROOT/$WIRE'; sw_wire hermes '$f' '/q/cqh.sh'"
  [ "$status" -eq 2 ]
  [ "$(cat "$f")" = "$before" ]   # file untouched
}

# ---------------------------------------------------------------------------
# (B) install integration — the opt-in gate
# ---------------------------------------------------------------------------

_install() { # extra args...
  P="$(make_fixture_project shp clean-install.toml)"
  QUARTET_DIR="$QUARTET_ROOT" QUARTET_EVENTS_DIR="$EVENTS_DIR" QUARTET_NOTIFY_CMD="true" \
    bash "$QUARTET_ROOT/install.sh" --project "$P" "$@" >/dev/null 2>&1
}

_shoulder_config() {
  local project="$1" harness="$2" critic_harness="$3"
  cat >>"$project/.agents/config.toml" <<EOF

[shoulder]
auto_wire = true
harness = "$harness"
critic_harness = "$critic_harness"
EOF
}

_install_project() {
  local project="$1"
  shift
  QUARTET_DIR="$QUARTET_ROOT" QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    QUARTET_NOTIFY_CMD="true" \
    bash "$QUARTET_ROOT/install.sh" --project "$project" "$@"
}

@test "UNSET-INVARIANCE: install without --wire-shoulder touches no harness config" {
  _install
  [ ! -f "$P/.agents/shoulder.env" ]
  [ ! -f "$P/.claude/settings.json" ]
  [ ! -e "$HOME/.config/systemd/user/shp-release-watch.service" ]
  [ ! -e "$XDG_STATE_HOME/shipyard/critic-feedback" ]
}

@test "install --wire-shoulder wires the claude capture hook + writes delivery env" {
  _install --wire-shoulder
  [ -f "$P/.agents/shoulder.env" ]
  [ -f "$P/.claude/settings.json" ]
  run bash -c ". '$QUARTET_ROOT/$WIRE'; sw_wired claude '$P/.claude/settings.json' '$QUARTET_ROOT/agents/release/critic-queue.sh'"
  [ "$status" -eq 0 ]
  grep -q 'CLAUDE_NOTE_CMD' "$P/.agents/shoulder.env"
}

@test "install --dry-run --wire-shoulder previews without writing" {
  P="$(make_fixture_project shpd clean-install.toml)"
  run env QUARTET_DIR="$QUARTET_ROOT" QUARTET_NOTIFY_CMD="true" \
    bash "$QUARTET_ROOT/install.sh" --project "$P" --dry-run --wire-shoulder
  [[ "$output" == *"would wire"* ]]
  [ ! -f "$P/.agents/shoulder.env" ]
}

@test "codex opt-in installs three hooks, authorization, env, and watcher unit" {
  P="$(make_fixture_project shpcodex clean-install.toml)"
  _shoulder_config "$P" codex hermes
  mkdir -p "$CODEX_HOME"
  printf 'model = "gpt-5.6"\n' >"$CODEX_HOME/config.toml"

  run _install_project "$P"
  [ "$status" -eq 0 ]
  python3 - "$CODEX_HOME/config.toml" <<'PY'
import sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib

with open(sys.argv[1], "rb") as handle:
    hooks = tomllib.load(handle)["hooks"]
assert sum(row.get("matcher") == "apply_patch" for row in hooks["PostToolUse"]) == 1
assert sum(row.get("matcher") == "*" for row in hooks["PostToolUse"]) == 1
assert len(hooks["Stop"]) == 1
PY
  grep -Fxq "CRITIC_PROJECT_DIR=$P" "$P/.agents/shoulder.env"
  grep -Fxq "CRITIC_HARNESS=hermes" "$P/.agents/shoulder.env"
  grep -Fxq "CRITIC_NOTE_HARNESS=codex" "$P/.agents/shoulder.env"
  [ "$(find "$XDG_STATE_HOME/shipyard/critic-feedback/projects" -name '*.json' | wc -l | tr -d ' ')" -eq 1 ]
  jq -e --arg project "$(cd "$P" && pwd -P)" '.canonical_project == $project' \
    "$XDG_STATE_HOME"/shipyard/critic-feedback/projects/*.json

  unit="$HOME/.config/systemd/user/shpcodex-release-watch.service"
  [ -f "$unit" ]
  grep -Fxq "WorkingDirectory=$P" "$unit"
  grep -Fxq "EnvironmentFile=-$P/.agents/shoulder.env" "$unit"
  grep -Fxq "ExecStart=/bin/bash $QUARTET_ROOT/agents/release/critic-watch.sh --project $P" "$unit"
  grep -Fxq "Restart=on-failure" "$unit"
  grep -Fxq "RestartSec=5" "$unit"
  grep -Fxq "WantedBy=default.target" "$unit"
}

@test "codex install remains idempotent and replaces a legacy watcher after reload" {
  P="$(make_fixture_project shplegacy clean-install.toml)"
  _shoulder_config "$P" codex codex
  mkdir -p "$CODEX_HOME" "$HOME/.config/systemd/user"
  cat >"$CODEX_HOME/config.toml" <<EOF
[[hooks.PostToolUse]]
matcher = "apply_patch"
[[hooks.PostToolUse.hooks]]
type = "command"
command = "$QUARTET_ROOT/agents/release/critic-queue-codex.sh"
EOF
  printf '[Service]\nExecStart=/legacy/watch\n' \
    >"$HOME/.config/systemd/user/shplegacy-release-watch.service"

  run _install_project "$P"
  [ "$status" -eq 0 ]
  ! grep -q '/legacy/watch' \
    "$HOME/.config/systemd/user/shplegacy-release-watch.service"
  grep -q '^--user daemon-reload$' "$SHIM_LOG/systemctl.argv"
  grep -q '^--user try-restart shplegacy-release-watch.service$' \
    "$SHIM_LOG/systemctl.argv"

  run _install_project "$P"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^\[\[hooks.PostToolUse\]\]' "$CODEX_HOME/config.toml")" -eq 2 ]
  [ "$(grep -c '^\[\[hooks.Stop\]\]' "$CODEX_HOME/config.toml")" -eq 1 ]
  [ -z "$(find "$P/.agents" "$HOME/.config/systemd/user" \
    -maxdepth 1 -name '.shoulder-*' -print)" ]
}

@test "watcher install failure atomically restores prior env and unit" {
  P="$(make_fixture_project shprollback clean-install.toml)"
  _shoulder_config "$P" codex codex
  mkdir -p "$CODEX_HOME" "$HOME/.config/systemd/user"
  env_file="$P/.agents/shoulder.env"
  unit="$HOME/.config/systemd/user/shprollback-release-watch.service"
  printf 'CRITIC_HARNESS=claude\n' >"$env_file"
  printf '[Service]\nExecStart=/prior/watch\n' >"$unit"
  env_before="$(cksum "$env_file")"
  unit_before="$(cksum "$unit")"

  export SYSTEMCTL_FAIL_TRY_RESTART=1
  run _install_project "$P"
  unset SYSTEMCTL_FAIL_TRY_RESTART
  [ "$status" -eq 2 ]
  [ "$(cksum "$env_file")" = "$env_before" ]
  [ "$(cksum "$unit")" = "$unit_before" ]
  grep -q '^--user daemon-reload$' "$SHIM_LOG/systemctl.argv"
  grep -q '^--user restart shprollback-release-watch.service$' \
    "$SHIM_LOG/systemctl.argv"
  [ -z "$(find "$P/.agents" "$HOME/.config/systemd/user" \
    -maxdepth 1 -name '.shoulder-*' -print)" ]
}

@test "dry-run prints the exact watcher definition and changes no shoulder state" {
  P="$(make_fixture_project shppreview clean-install.toml)"
  _shoulder_config "$P" codex claude
  run _install_project "$P"
  [ "$status" -eq 0 ]
  env_before="$(cksum "$P/.agents/shoulder.env")"
  unit="$HOME/.config/systemd/user/shppreview-release-watch.service"
  unit_before="$(cksum "$unit")"
  config_before="$(cksum "$CODEX_HOME/config.toml")"

  run _install_project "$P" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"WorkingDirectory=$P"* ]]
  [[ "$output" == *"EnvironmentFile=-$P/.agents/shoulder.env"* ]]
  [[ "$output" == *"ExecStart=/bin/bash $QUARTET_ROOT/agents/release/critic-watch.sh --project $P"* ]]
  [ "$(cksum "$P/.agents/shoulder.env")" = "$env_before" ]
  [ "$(cksum "$unit")" = "$unit_before" ]
  [ "$(cksum "$CODEX_HOME/config.toml")" = "$config_before" ]
}

@test "authoring and critic harnesses validate independently" {
  for key in harness critic_harness; do
    P="$(make_fixture_project "shpinvalid-$key" clean-install.toml)"
    cat >>"$P/.agents/config.toml" <<EOF

[shoulder]
auto_wire = true
harness = "$([ "$key" = harness ] && printf invalid || printf claude)"
critic_harness = "$([ "$key" = critic_harness ] && printf invalid || printf claude)"
EOF
    run _install_project "$P" --dry-run
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid [shoulder] $key"* ]]
  done

  for pair in "claude hermes" "codex claude" "hermes codex"; do
    set -- $pair
    P="$(make_fixture_project "shpvalid-$1-$2" clean-install.toml)"
    _shoulder_config "$P" "$1" "$2"
    run _install_project "$P"
    [ "$status" -eq 0 ]
    grep -Fxq "CRITIC_HARNESS=$2" "$P/.agents/shoulder.env"
    grep -Fxq "CRITIC_NOTE_HARNESS=$1" "$P/.agents/shoulder.env"
  done
}

# ---------------------------------------------------------------------------
# (C) doctor drift — only fires when opted in
# ---------------------------------------------------------------------------

@test "doctor: opted-in project with the hook unwired reports shoulder drift" {
  P="$(make_fixture_project shpdr clean-install.toml)"
  QUARTET_DIR="$QUARTET_ROOT" QUARTET_NOTIFY_CMD="true" \
    bash "$QUARTET_ROOT/install.sh" --project "$P" >/dev/null 2>&1
  printf 'export CRITIC_NOTE_HARNESS=claude\n' >"$P/.agents/shoulder.env"  # opted in, but hook NOT wired
  run env QUARTET_DIR="$QUARTET_ROOT" bash "$QUARTET_ROOT/install.sh" --doctor --project "$P"
  [[ "$output" == *"DOCTOR shoulder:"* ]]
  [ "$status" -eq 1 ]
}

@test "doctor: project that never opted in has no shoulder finding" {
  P="$(make_fixture_project shpclean clean-install.toml)"
  QUARTET_DIR="$QUARTET_ROOT" QUARTET_NOTIFY_CMD="true" \
    bash "$QUARTET_ROOT/install.sh" --project "$P" >/dev/null 2>&1
  run env QUARTET_DIR="$QUARTET_ROOT" bash "$QUARTET_ROOT/install.sh" --doctor --project "$P"
  [[ "$output" != *"DOCTOR shoulder:"* ]]
}

@test "doctor distinguishes missing definition, runtime-unverified, and executed" {
  P="$(make_fixture_project shpdoctor clean-install.toml)"
  _shoulder_config "$P" codex codex
  mkdir -p "$CODEX_HOME"

  run _install_project "$P"
  [ "$status" -eq 0 ]

  run env QUARTET_DIR="$QUARTET_ROOT" bash "$QUARTET_ROOT/install.sh" \
    --doctor --project "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *"configured but trust/runtime unverified since install"* ]]

  command="$(
    python3 - "$CODEX_HOME/config.toml" <<'PY'
import sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib
with open(sys.argv[1], "rb") as handle:
    rows = tomllib.load(handle)["hooks"]["PostToolUse"]
print(next(
    hook["command"]
    for row in rows if row.get("matcher") == "*"
    for hook in row["hooks"]
))
PY
  )"
  jq -nc --arg cwd "$P" \
    '{hook_event_name:"PostToolUse",session_id:"doctor-session",cwd:$cwd}' |
    bash -c "$command" >/dev/null

  marker="$(
    bash -c ". '$QUARTET_ROOT/$WIRE'; sw_codex_runtime_marker '$P'"
  )"
  jq -e '
    keys == ["definition_sha256","definition_version","invocation_epoch","schema_version"]
    and .schema_version == 1
    and .definition_version == "codex-three-hook-v1"
    and (.definition_sha256 | test("^[0-9a-f]{64}$"))
    and (.invocation_epoch | type == "number")
  ' "$marker"
  [ "$(stat -c '%a' "$(dirname "$marker")" 2>/dev/null || stat -f '%Lp' "$(dirname "$marker")")" = "700" ]
  [ "$(stat -c '%a' "$marker" 2>/dev/null || stat -f '%Lp' "$marker")" = "600" ]
  run env QUARTET_DIR="$QUARTET_ROOT" bash "$QUARTET_ROOT/install.sh" \
    --doctor --project "$P"
  [ "$status" -eq 0 ]
  [[ "$output" != *"DOCTOR shoulder:"* ]]

  external="$BATS_TEST_TMPDIR/runtime-marker-hardlink"
  ln "$marker" "$external"
  run env QUARTET_DIR="$QUARTET_ROOT" bash "$QUARTET_ROOT/install.sh" \
    --doctor --project "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *"configured but trust/runtime unverified since install"* ]]
  rm -f "$external"

  printf 'model = "gpt-5.6"\n' >"$CODEX_HOME/config.toml"
  run env QUARTET_DIR="$QUARTET_ROOT" bash "$QUARTET_ROOT/install.sh" \
    --doctor --project "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *"definition missing"* ]]
}

@test "doctor rejects a stale loaded watcher despite a repaired unit file" {
  P="$(make_fixture_project shploaded clean-install.toml)"
  _shoulder_config "$P" claude codex
  run _install_project "$P"
  [ "$status" -eq 0 ]

  export SYSTEMCTL_STALE_LOADED=1
  run env QUARTET_DIR="$QUARTET_ROOT" bash "$QUARTET_ROOT/install.sh" \
    --doctor --project "$P"
  unset SYSTEMCTL_STALE_LOADED
  [ "$status" -eq 1 ]
  [[ "$output" == *"loaded watcher ExecStart"* ]]
  [[ "$output" == *"loaded watcher EnvironmentFile"* ]]
}

@test "runtime wrapper rejects oversized hook input before target or marker" {
  P="$(make_fixture_project shpcap clean-install.toml)"
  _shoulder_config "$P" codex codex
  mkdir -p "$CODEX_HOME"
  run _install_project "$P"
  [ "$status" -eq 0 ]

  command="$(
    python3 - "$CODEX_HOME/config.toml" <<'PY'
try:
    import tomllib
except ImportError:
    import tomli as tomllib
import sys
with open(sys.argv[1], "rb") as handle:
    rows = tomllib.load(handle)["hooks"]["PostToolUse"]
print(next(
    hook["command"]
    for row in rows if row.get("matcher") == "*"
    for hook in row["hooks"]
))
PY
  )"
  marker="$(
    bash -c ". '$QUARTET_ROOT/$WIRE'; sw_codex_runtime_marker '$P'"
  )"
  run bash -c '
    python3 -c '"'"'
import json
import sys
json.dump(
    {
        "hook_event_name": "PostToolUse",
        "session_id": "oversized",
        "cwd": sys.argv[1],
        "padding": "x" * 140000,
    },
    sys.stdout,
)
'"'"' "$2" | bash -c "$1"
  ' _ "$command" "$P"
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
}

@test "doctor rejects missing env fields and a legacy watcher shape" {
  P="$(make_fixture_project shpdrift clean-install.toml)"
  _shoulder_config "$P" claude hermes
  run _install_project "$P"
  [ "$status" -eq 0 ]

  grep -v '^CRITIC_PROJECT_DIR=' "$P/.agents/shoulder.env" \
    >"$P/.agents/shoulder.env.tmp"
  mv "$P/.agents/shoulder.env.tmp" "$P/.agents/shoulder.env"
  printf '[Service]\nExecStart=/legacy/watch\n' \
    >"$HOME/.config/systemd/user/shpdrift-release-watch.service"

  run env QUARTET_DIR="$QUARTET_ROOT" bash "$QUARTET_ROOT/install.sh" \
    --doctor --project "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRITIC_PROJECT_DIR"* ]]
  [[ "$output" == *"watcher ExecStart"* ]]
  [[ "$output" == *"watcher EnvironmentFile"* ]]
}
