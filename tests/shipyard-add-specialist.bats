#!/usr/bin/env bats
# tests/shipyard-add-specialist.bats — `/shipyard add-specialist <subsystem>`
# scaffolds the domain-specialist archetype for a named subsystem and wires it
# into three surfaces (write_ticket context, gates note, hunk-keyed release
# block). Deterministic: the decision log is instantiated from the template, so
# NO model is called — hermetic, no stubs needed.

setup() {
  load helpers
  quartet_setup
}

SH="skills/shipyard/shipyard.sh"
run_shipyard() { QUARTET_DIR="$QUARTET_ROOT" bash "$QUARTET_ROOT/$SH" "$@"; }

@test "missing subsystem arg exits 2" {
  P="$(make_fixture_project p1)"
  run run_shipyard add-specialist --project "$P"
  [ "$status" -eq 2 ]
}

@test "invalid subsystem slug exits 2" {
  P="$(make_fixture_project p2)"
  run run_shipyard add-specialist "bad/slug" --project "$P"
  [ "$status" -eq 2 ]
}

@test "scaffold lands the agent def + decision log from the template" {
  P="$(make_fixture_project p3)"
  run run_shipyard add-specialist payments --project "$P"
  [ "$status" -eq 0 ]
  [ -f "$P/.claude/agents/payments-specialist.md" ]
  [ -f "$P/docs/payments-decisions.md" ]
  # the log came from the template (has the section anchors) with <subsystem>
  # substituted for the real name
  grep -qF "## Invariants" "$P/docs/payments-decisions.md"
  grep -qF "payments — decision log" "$P/docs/payments-decisions.md"
  # the agent def embeds the archetype role
  grep -qF "you REVIEW; you do not redesign" "$P/.claude/agents/payments-specialist.md"
}

@test "wires write_ticket.context_files (config still parses, path present)" {
  P="$(make_fixture_project p4)"
  run run_shipyard add-specialist payments --project "$P"
  [ "$status" -eq 0 ]
  run python3 -c "import tomllib;print('docs/payments-decisions.md' in tomllib.load(open('$P/.agents/config.toml','rb')).get('write_ticket',{}).get('context_files',[]))"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "wires a gates note and a HUNK-KEYED release block (not membership)" {
  P="$(make_fixture_project p5)"
  run run_shipyard add-specialist payments --project "$P"
  [ "$status" -eq 0 ]
  grep -qF "shipyard:specialist:payments" "$P/.agents/gates.md"
  grep -qF "shipyard:specialist:payments" "$P/.agents/release.md"
  # the release gate must key on DIFF hunks, explicitly NOT list membership
  grep -qF "Key on the presence of hunks in DIFF" "$P/.agents/release.md"
  grep -qi "NOT on mere membership" "$P/.agents/release.md"
}

@test "re-running is idempotent (exit 0, no duplicate context_files entry)" {
  P="$(make_fixture_project p6)"
  run_shipyard add-specialist payments --project "$P"
  run run_shipyard add-specialist payments --project "$P"
  [ "$status" -eq 0 ]
  run python3 -c "import tomllib;c=tomllib.load(open('$P/.agents/config.toml','rb'))['write_ticket']['context_files'];print(c.count('docs/payments-decisions.md'))"
  [ "$output" = "1" ]
}

@test "add-specialist makes NO uncapped model call (no bare claude/codex/hermes)" {
  # the scaffolder is deterministic; any future model call must go through
  # spawn_model (timeout+token cap). Guard that no bare harness call sneaks in.
  run grep -nE '^[[:space:]]*(claude|codex|hermes)[[:space:]]' "$QUARTET_ROOT/$SH"
  [ "$status" -ne 0 ]
}
