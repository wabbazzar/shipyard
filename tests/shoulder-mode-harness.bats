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
