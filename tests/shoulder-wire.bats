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
u=""; for a in "$@"; do case "$a" in *.timer) u="$a";; esac; done
case "$*" in
  *is-enabled*) [ -n "$u" ] && [ -f "$HOME/.config/systemd/user/$u" ] && exit 0 || exit 1 ;;
  *) exit 0 ;;
esac'
  make_stub crontab 0 ""
  make_stub gh 0
  make_stub claude 0
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

@test "UNSET-INVARIANCE: install without --wire-shoulder touches no harness config" {
  _install
  [ ! -f "$P/.agents/shoulder.env" ]
  [ ! -f "$P/.claude/settings.json" ]
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
