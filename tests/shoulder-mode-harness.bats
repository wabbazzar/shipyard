#!/usr/bin/env bats
# tests/shoulder-mode-harness.bats — shoulder-mode capture + delivery on the
# non-claude harnesses (codex, hermes) and the generic delivery dispatcher.
# No real harness/model: payloads are canned JSON on stdin; delivery targets
# are recording stubs. The queue format is asserted identical to the claude
# hook's so critic-watch.sh drains all three unchanged.

setup() { load helpers; quartet_setup; }

CODEX_HOOK="agents/release/critic-queue-codex.sh"
HERMES_HOOK="agents/release/critic-queue-hermes.sh"
NOTE="agents/release/critic-note.sh"
STOP_CODEX="agents/release/critic-stop-gate-codex.sh"
STOP_HERMES="agents/release/critic-stop-gate-hermes.sh"

# seed_block <project> <session> — write a block-severity finding file.
seed_block() { printf 'block|src/auth.ts|removed the auth check\n' >"$1/tmp/critic-findings-$2"; }
# stop_payload <project> <session> — session-stop hook JSON.
stop_payload() { jq -nc --arg cwd "$1" --arg s "$2" '{session_id:$s,cwd:$cwd}'; }

# feed <json> <hook> — pipe a payload into a capture hook, capture status.
feed() { run bash -c 'printf "%s" "$1" | bash "$2"' _ "$1" "$QUARTET_ROOT/$2"; }

# ---------------------------------------------------------------------------
# codex capture (apply_patch → V4A patch in tool_input.command)
# ---------------------------------------------------------------------------

@test "codex apply_patch queues every touched file (relative) and exits 0" {
  P="$(make_fixture_project cdx)"
  cmd="$(printf '*** Begin Patch\n*** Add File: src/a.ts\n+x\n*** Update File: src/b.ts\n+y\n*** Delete File: src/c.ts\n*** End Patch')"
  json="$(jq -nc --arg cwd "$P" --arg cmd "$cmd" \
    '{session_id:"s1",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:$cmd}}')"
  feed "$json" "$CODEX_HOOK"
  [ "$status" -eq 0 ]
  Q="$P/tmp/critic-queue-s1"
  [ -f "$Q" ]
  grep -qE '^src/a\.ts [0-9]+$' "$Q"
  grep -qE '^src/b\.ts [0-9]+$' "$Q"
  grep -qE '^src/c\.ts [0-9]+$' "$Q"
}

@test "codex honors a direct tool_input.file_path (non-apply_patch tool)" {
  P="$(make_fixture_project cdx-fp)"
  json="$(jq -nc --arg cwd "$P" '{session_id:"s2",cwd:$cwd,tool_input:{file_path:"src/d.ts"}}')"
  feed "$json" "$CODEX_HOOK"
  [ "$status" -eq 0 ]
  grep -qE '^src/d\.ts [0-9]+$' "$P/tmp/critic-queue-s2"
}

@test "codex exits 0 on garbage stdin and queues nothing" {
  P="$(make_fixture_project cdx-garbage)"
  feed 'not json {{{[' "$CODEX_HOOK"
  [ "$status" -eq 0 ]
  run bash -c "ls '$P/tmp'/critic-queue-* 2>/dev/null"
  [ -z "$output" ]
}

@test "codex drops a patch path that escapes the project" {
  P="$(make_fixture_project cdx-escape)"
  cmd="$(printf '*** Begin Patch\n*** Add File: ../evil.ts\n+x\n*** End Patch')"
  json="$(jq -nc --arg cwd "$P" --arg cmd "$cmd" \
    '{session_id:"s3",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:$cmd}}')"
  feed "$json" "$CODEX_HOOK"
  [ "$status" -eq 0 ]
  run bash -c "ls '$P/tmp'/critic-queue-* 2>/dev/null"
  [ -z "$output" ]
}

@test "codex drops a gitignored patch path at enqueue time" {
  P="$(make_fixture_project cdx-ignore)"   # tmp/ is gitignored in the fixture
  cmd="$(printf '*** Begin Patch\n*** Add File: tmp/scratch.json\n+x\n*** End Patch')"
  json="$(jq -nc --arg cwd "$P" --arg cmd "$cmd" \
    '{session_id:"s4",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:$cmd}}')"
  feed "$json" "$CODEX_HOOK"
  [ "$status" -eq 0 ]
  run bash -c "ls '$P/tmp'/critic-queue-* 2>/dev/null"
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# generic delivery dispatcher (critic-note.sh)
# ---------------------------------------------------------------------------

@test "critic-note passes a configured injector's exit code through (3 = keep queue)" {
  inj="$BATS_TEST_TMPDIR/inj.sh"; printf '#!/bin/bash\nexit 3\n' >"$inj"; chmod +x "$inj"
  CRITIC_NOTE_DELIVER_CMD="$inj" run bash "$QUARTET_ROOT/$NOTE" --harness codex s1 "finding"
  [ "$status" -eq 3 ]
}

@test "critic-note injector exit 0 = delivered" {
  inj="$BATS_TEST_TMPDIR/inj0.sh"; printf '#!/bin/bash\nexit 0\n' >"$inj"; chmod +x "$inj"
  CRITIC_NOTE_DELIVER_CMD="$inj" run bash "$QUARTET_ROOT/$NOTE" --harness codex s1 "finding"
  [ "$status" -eq 0 ]
}

@test "critic-note falls back to QUARTET_NOTIFY_CMD (owner alert) and exits 0" {
  log="$BATS_TEST_TMPDIR/notify.log"
  nc="$BATS_TEST_TMPDIR/nc.sh"; printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s"\n' "$log" >"$nc"; chmod +x "$nc"
  QUARTET_NOTIFY_CMD="$nc" run bash "$QUARTET_ROOT/$NOTE" --harness codex s1 "the finding"
  [ "$status" -eq 0 ]
  grep -q "the finding" "$log"
}

@test "critic-note with no channel logs-and-skips (exit 0)" {
  run env -u QUARTET_NOTIFY_CMD -u CRITIC_NOTE_DELIVER_CMD \
    bash "$QUARTET_ROOT/$NOTE" --harness codex s1 "x"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no delivery channel"* ]]
}

@test "critic-note missing session is a usage error (exit 2)" {
  run bash "$QUARTET_ROOT/$NOTE" --harness codex
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# hermes capture (post_tool_call → tool_input.path or a V4A patch)
# ---------------------------------------------------------------------------

@test "hermes write_file queues tool_input.path and exits 0" {
  P="$(make_fixture_project hms)"
  json="$(jq -nc --arg cwd "$P" \
    '{hook_event_name:"post_tool_call",tool_name:"write_file",session_id:"h1",cwd:$cwd,tool_input:{path:"src/a.ts"}}')"
  feed "$json" "$HERMES_HOOK"
  [ "$status" -eq 0 ]
  grep -qE '^src/a\.ts [0-9]+$' "$P/tmp/critic-queue-h1"
}

@test "hermes patch(mode=patch) queues every V4A path" {
  P="$(make_fixture_project hms-patch)"
  patch="$(printf '*** Begin Patch\n*** Update File: src/x.ts\n+a\n*** Add File: src/y.ts\n+b\n*** End Patch')"
  json="$(jq -nc --arg cwd "$P" --arg p "$patch" \
    '{hook_event_name:"post_tool_call",tool_name:"patch",session_id:"h2",cwd:$cwd,tool_input:{mode:"patch",patch:$p}}')"
  feed "$json" "$HERMES_HOOK"
  [ "$status" -eq 0 ]
  grep -qE '^src/x\.ts [0-9]+$' "$P/tmp/critic-queue-h2"
  grep -qE '^src/y\.ts [0-9]+$' "$P/tmp/critic-queue-h2"
}

@test "hermes exits 0 on garbage stdin and queues nothing" {
  P="$(make_fixture_project hms-garbage)"
  feed 'not json {{{[' "$HERMES_HOOK"
  [ "$status" -eq 0 ]
  run bash -c "ls '$P/tmp'/critic-queue-* 2>/dev/null"
  [ -z "$output" ]
}

@test "hermes drops a path escaping the project" {
  P="$(make_fixture_project hms-escape)"
  json="$(jq -nc --arg cwd "$P" \
    '{tool_name:"write_file",session_id:"h3",cwd:$cwd,tool_input:{path:"../evil.ts"}}')"
  feed "$json" "$HERMES_HOOK"
  [ "$status" -eq 0 ]
  run bash -c "ls '$P/tmp'/critic-queue-* 2>/dev/null"
  [ -z "$output" ]
}

@test "critic-note hermes branch sends via 'hermes send' to the configured target" {
  make_stub hermes 0
  CRITIC_NOTE_TARGET="signal" \
    run bash "$QUARTET_ROOT/$NOTE" --harness hermes h1 "1 block across 2 files"
  [ "$status" -eq 0 ]
  run grep -E "send -t signal" "$SHIM_LOG/hermes.argv"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# stop-gate teeth parity (codex SessionEnd, hermes on_session_end)
# ---------------------------------------------------------------------------

@test "codex stop-gate: disarmed (no CRITIC_BLOCK) exits 0 even with a block finding" {
  P="$(make_fixture_project sgc)"; seed_block "$P" s1
  run bash -c 'printf "%s" "$1" | bash "$2"' _ "$(stop_payload "$P" s1)" "$QUARTET_ROOT/$STOP_CODEX"
  [ "$status" -eq 0 ]
}

@test "codex stop-gate: armed + block finding exits 2 and names it (via payload .cwd)" {
  P="$(make_fixture_project sgc2)"; seed_block "$P" s1
  CRITIC_BLOCK=1 run bash -c 'printf "%s" "$1" | bash "$2"' _ "$(stop_payload "$P" s1)" "$QUARTET_ROOT/$STOP_CODEX"
  [ "$status" -eq 2 ]
  [[ "$output" == *"removed the auth check"* ]]
}

@test "codex stop-gate: armed but only warn/note findings exits 0" {
  P="$(make_fixture_project sgc3)"; printf 'warn|x|y\n' >"$P/tmp/critic-findings-s1"
  CRITIC_BLOCK=1 run bash -c 'printf "%s" "$1" | bash "$2"' _ "$(stop_payload "$P" s1)" "$QUARTET_ROOT/$STOP_CODEX"
  [ "$status" -eq 0 ]
}

@test "hermes stop-gate: disarmed exits 0" {
  P="$(make_fixture_project sgh)"; seed_block "$P" s1
  run bash -c 'printf "%s" "$1" | bash "$2"' _ "$(stop_payload "$P" s1)" "$QUARTET_ROOT/$STOP_HERMES"
  [ "$status" -eq 0 ]
}

@test "hermes stop-gate: armed + block finding exits 2" {
  P="$(make_fixture_project sgh2)"; seed_block "$P" s1
  CRITIC_BLOCK=1 run bash -c 'printf "%s" "$1" | bash "$2"' _ "$(stop_payload "$P" s1)" "$QUARTET_ROOT/$STOP_HERMES"
  [ "$status" -eq 2 ]
  [[ "$output" == *"removed the auth check"* ]]
}
