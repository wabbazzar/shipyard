#!/usr/bin/env bats
#
# ticket-lifecycle.bats — the lifecycle-folder contract
# (docs/tickets/ticket-lifecycle-folders.md).
#
# Phases 1-3 change PROSE in a SKILL.md, so there is no executable surface to
# drive: these are CONTENT-CONTRACT cases, asserting the instruction is present
# and hasn't been silently dropped. Phase 4 changes real bash in shipyard.sh and
# gets genuine behavioral cases.
#
# Two rules inherited from tests/delegation-contract.bats, both learned the hard
# way (see .agents/gates.md Traps):
#   * assert a phrase that fits WITHIN ONE SOURCE LINE — the Markdown is
#     hard-wrapped, so a regex spanning a line break can never match;
#   * a GUARD case (asserting existing behavior survived) must be shown PASSING
#     against the pre-change file, or it is guarding nothing.
#
# Cases are added per phase as each lands, so the suite is never red at a phase
# boundary. No network, no model.

setup() {
  load helpers
  quartet_setup
  SKILLS="$QUARTET_ROOT/skills"
}

# has <file> <extended-regex> — case-insensitive, whole-file
has() {
  grep -qiE "$2" "$1"
}

# ---------------------------------------------------------------------------
# Phase 1 — write-ticket: name the birth folder
# ---------------------------------------------------------------------------

@test "write-ticket: documents the lifecycle_dirs config key" {
  has "$SKILLS/write-ticket/SKILL.md" 'lifecycle_dirs'
}

@test "write-ticket: new tickets are born in ticket_dir" {
  f="$SKILLS/write-ticket/SKILL.md"
  has "$f" 'born in|written to .ticket_dir'
}

@test "write-ticket: ids never reused and never renumbered" {
  f="$SKILLS/write-ticket/SKILL.md"
  has "$f" 'never renumber'
}

@test "write-ticket: unset lifecycle_dirs keeps today's flat behavior" {
  # The config-gated-additivity rule: the unset value must be exactly today's
  # behavior, and the skill must say so.
  # Asserts the SPECIFIC new clause, not the words "unset"/"flat", which already
  # appear elsewhere in the file — a generic match here passes pre-change and so
  # cannot fail on the defect.
  f="$SKILLS/write-ticket/SKILL.md"
  has "$f" 'absent .lifecycle_dirs|lifecycle_dirs. unset'
}

@test "write-ticket: still scans all dirs when resolving the next id" {
  # GUARD: this rule predates the ticket and must survive the edit.
  f="$SKILLS/write-ticket/SKILL.md"
  has "$f" 'scan all of them|across all of them'
}

@test "write-ticket: still defers hardening to polish-ticket" {
  # GUARD: the three-skill separation.
  f="$SKILLS/write-ticket/SKILL.md"
  has "$f" 'Hardening here'
}

# Phases 2-4 append their cases here as they land — see
# docs/tickets/ticket-lifecycle-folders.md.
