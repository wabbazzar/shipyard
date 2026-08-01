#!/usr/bin/env bats
#
# delegation-contract.bats — the Delegation Plan contract across the pipeline
# skills (docs/tickets/delegation-plan-pipeline.md).
#
# These are GUARD tests: they assert the contract's load-bearing clauses are
# present and haven't been silently dropped by a later prose edit. They cannot
# prove the behavior works — that is Phase 7's job, measured with
# scripts/delegation-report.py against the recorded baseline. Their value is
# that removing a clause turns red instead of going unnoticed.
#
# Coverage grows one phase at a time — a case is added only when the clause it
# asserts has landed, so the suite is never red at a phase boundary:
#   * execute-ticket — delegation as the DEFAULT, the exception list, the
#     return-shape contract, the no-exploratory-Read rule, the `builder:`
#     Ledger trace, and (guard) that verify-before-commit survived the edit;
#   * write-ticket   — a per-phase `Delegation:` line in the emitted template;
#   * polish-ticket  — hardening intent into briefs + the `builder:` Ledger field;
#   * feature/bugfix — investigation sweeps delegated, repro rule intact.
#
# No network, no model, no filesystem writes — pure content assertions against
# the skill files in this repo.

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
# execute-ticket
# ---------------------------------------------------------------------------

@test "execute-ticket: delegation is the DEFAULT, not an option" {
  f="$SKILLS/execute-ticket/SKILL.md"
  has "$f" 'delegat.*(is the )?DEFAULT|DEFAULT, not an option'
}

@test "execute-ticket: names the inline exception list" {
  f="$SKILLS/execute-ticket/SKILL.md"
  has "$f" 'exception'
  has "$f" 'single-file edit'
}

@test "execute-ticket: imposes the bounded return-shape contract on subagents" {
  f="$SKILLS/execute-ticket/SKILL.md"
  has "$f" '40 lines'
  has "$f" 'exit codes'
}

@test "execute-ticket: forbids exploratory Read" {
  f="$SKILLS/execute-ticket/SKILL.md"
  has "$f" 'never Read to explore|not a Read|Ask for the answer, not the file'
}

@test "execute-ticket: requires a builder: line in the Ledger" {
  f="$SKILLS/execute-ticket/SKILL.md"
  has "$f" 'builder:'
  has "$f" 'inline.*no stated reason is a defect|no recorded reason is a defect'
}

@test "execute-ticket: verify-before-commit survived the delegation edit" {
  # Guard: delegation must never become a laundering path for unverified work.
  f="$SKILLS/execute-ticket/SKILL.md"
  has "$f" 'VERIFY-BEFORE-COMMIT'
  # Phrase, not sentence: the source hard-wraps, so a regex spanning the
  # "Never / trust a subagent" line break can never match.
  has "$f" "trust a subagent"
}

@test "execute-ticket: keeps the verbatim anti-cheating clause" {
  f="$SKILLS/execute-ticket/SKILL.md"
  has "$f" 'NEVER fake'
}

@test "execute-ticket: emits one hidden Codex invocation marker first" {
  f="$SKILLS/execute-ticket/SKILL.md"
  marker='<!-- shipyard-skill:execute-ticket:v1 -->'
  [ "$(grep -oF -- "$marker" "$f" | wc -l)" -eq 1 ]
  # Keep these assertions source-line-safe: each phrase must fit on one line.
  has "$f" 'first assistant commentary'
  has "$f" 'exactly once'
  has "$f" 'HTML comment'
}

# ---------------------------------------------------------------------------
# write-ticket
# ---------------------------------------------------------------------------

@test "write-ticket: emits a per-phase Delegation line in its template" {
  f="$SKILLS/write-ticket/SKILL.md"
  has "$f" 'Delegation:'
  has "$f" 'subagent'
}

@test "write-ticket: refuses a phase with no Delegation line" {
  f="$SKILLS/write-ticket/SKILL.md"
  has "$f" 'no Delegation line|without a Delegation line'
}

@test "write-ticket: delegates wide sweeps but still reads deep itself" {
  f="$SKILLS/write-ticket/SKILL.md"
  has "$f" 'wide sweep'
  has "$f" 'path:line'
}

@test "write-ticket: names intent only, leaving the brief to polish-ticket" {
  # Guard on the three-skill separation: write-ticket must not start writing
  # hardened briefs.
  f="$SKILLS/write-ticket/SKILL.md"
  has "$f" 'intent'
  has "$f" "polish-ticket.*(brief|harden)|harden.*polish-ticket"
}

@test "write-ticket: still defers hardening to polish-ticket" {
  # Guard on the three-skill separation this repo enforces.
  f="$SKILLS/write-ticket/SKILL.md"
  has "$f" "polish-ticket"
  has "$f" 'Hardening here'
}

# ---------------------------------------------------------------------------
# polish-ticket
# ---------------------------------------------------------------------------

@test "polish-ticket: hardens each Delegation intent into a concrete brief" {
  f="$SKILLS/polish-ticket/SKILL.md"
  has "$f" 'Delegation:'
  has "$f" 'brief'
  has "$f" '40 lines'
}

@test "polish-ticket: adds a Delegation line to a phase that lacks one" {
  f="$SKILLS/polish-ticket/SKILL.md"
  has "$f" 'no .Delegation:. line|Silence defaults to inline'
}

@test "polish-ticket: consumes the specialist table and tolerates its absence" {
  f="$SKILLS/polish-ticket/SKILL.md"
  has "$f" 'build\.md'
  has "$f" 'absent'
  has "$f" 'never invent a specialist'
}

@test "polish-ticket: Ledger section carries the builder: field" {
  f="$SKILLS/polish-ticket/SKILL.md"
  has "$f" 'builder:'
}

@test "polish-ticket: keeps the verbatim anti-cheating clause" {
  # Guard: the brief-hardening rewrite must not displace it.
  f="$SKILLS/polish-ticket/SKILL.md"
  has "$f" 'NEVER fake green'
}

# ---------------------------------------------------------------------------
# front doors
# ---------------------------------------------------------------------------

@test "feature: assumption probes run as subagents with a bounded return" {
  f="$SKILLS/feature/SKILL.md"
  has "$f" 'subagent'
  has "$f" '40 lines'
}

@test "feature: probes still may not fabricate a citation" {
  # Guard: delegating a probe must not weaken the Unverified discipline.
  f="$SKILLS/feature/SKILL.md"
  has "$f" 'never guess a citation|Unverified'
}

@test "bugfix: the repro hunt runs as a subagent" {
  f="$SKILLS/bugfix/SKILL.md"
  has "$f" 'subagent'
  has "$f" '40 lines'
}

@test "bugfix: rival-cause probes are delegated one cause each" {
  f="$SKILLS/bugfix/SKILL.md"
  has "$f" 'one cause each|one cause per'
  # Phrase kept short: the source hard-wraps, so a longer regex would straddle
  # the line break and never match (same trap as the execute-ticket guard).
  has "$f" 'rule their own'
}

@test "bugfix: a delegated summary is not a reproduction" {
  # The repro must stay verbatim evidence — it is the ticket's acceptance anchor.
  f="$SKILLS/bugfix/SKILL.md"
  has "$f" "summary of a.*failure is not a reproduction|verbatim failing output"
}

@test "bugfix: the no-reproduction-no-ticket rule is intact" {
  # Guard: delegating the sweep must not weaken the reproduction requirement.
  f="$SKILLS/bugfix/SKILL.md"
  has "$f" 'no reproduction = no ticket|reproduce first'
}

# ---------------------------------------------------------------------------
# gate files
# ---------------------------------------------------------------------------

@test "gates template declares the Delegation contract gate class" {
  f="$QUARTET_ROOT/skills/gates.md.template"
  has "$f" '### Delegation contract'
  has "$f" 'builder:'
}

@test "gates template requires visual and semantic served-app proof" {
  f="$QUARTET_ROOT/skills/gates.md.template"
  has "$f" 'visual screenshot inspection'
  has "$f" 'semantic assertions against the live page'
  has "$f" 'Browser-runtime absence is RED'
  has "$f" 'zero request origins outside the loopback server'
}

# .agents/ is gitignored (this box's self-install), so a fresh clone — CI
# included — has no gate file to assert against. These cases check the LOCAL
# install when it exists and skip when it doesn't; the tracked contract lives in
# gates.md.template above and is asserted unconditionally.
local_gates() {
  f="$QUARTET_ROOT/.agents/gates.md"
  [ -f "$f" ] || skip "no local .agents/gates.md (gitignored self-install)"
}

@test "this repo's own gate file declares the Delegation contract gate class" {
  local_gates
  has "$f" '### Delegation contract'
  has "$f" 'builder:'
}

@test "gate file pins the leak-check-scans-tracked-files-only trap" {
  local_gates
  has "$f" 'git ls-files|tracked files only|add -N'
}

@test "gate file pins the hard-wrap trap for content assertions" {
  local_gates
  has "$f" 'straddles a line break|hard-wrapped'
}

@test "the shipped template keeps delegation from laundering verification" {
  f="$QUARTET_ROOT/skills/gates.md.template"
  has "$f" 'never moves the verification|re-runs the phase'
}

@test "delegation report exposes a bounded operator relationship contract" {
  f="$QUARTET_ROOT/scripts/delegation-report.py"
  has "$f" 'operator-json'
  has "$f" 'MAX_.*AGGREGATES'
  has "$f" 'unsupported_provider'
  has "$f" 'transcript_root_missing'
  has "$f" 'skill_marker_coverage_partial'
  has "$f" 'opaque_callee'
}

@test "delegation report skill evidence is exact-marker only" {
  f="$QUARTET_ROOT/scripts/delegation-report.py"
  has "$f" 'shipyard-skill:'
  has "$f" 'tool_use'
  has "$f" 'name.*Skill|Skill.*name'
}
