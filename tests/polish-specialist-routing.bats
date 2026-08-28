#!/usr/bin/env bats
# polish-specialist-routing.bats — prompt-contract coverage for deterministic
# specialist routing during polish. Pure content assertions: no model/network.

setup() {
  load helpers
  quartet_setup
  SKILL="$QUARTET_ROOT/skills/polish-ticket/SKILL.md"
}

@test "polish discovers and validates installed specialist manifests deterministically" {
  grep -Fq 'Enumerate `.agents/specialists/*.toml` in bytewise filename order.' "$SKILL"
  grep -Fq 'Validate every candidate with `agents/specialist/validate-manifest.py` from the installed Shipyard core.' "$SKILL"
}

@test "ticket semantics and explicitly named files select applicable specialists" {
  grep -Fq 'A manifest matches when normalized ticket text contains a literal `ticket_triggers` entry.' "$SKILL"
  grep -Fq 'A manifest also matches when a project-relative file explicitly named by the ticket matches `hunk_path_patterns`.' "$SKILL"
}

@test "specialist invocation is evidence-bearing and cited in the polished ticket" {
  grep -Fq 'Invoke each selected specialist with the manifest, generic role, project prompt, decision log, gates, and complete ticket.' "$SKILL"
  grep -Fq 'Cite the specialist slug, verdict, finding, evidence location, and live-source retrieval record in the polished ticket.' "$SKILL"
}

@test "external infrastructure escalation waits for the complete local evidence matrix" {
  grep -Fq 'A configured external Infrastructure or Platform PR phase stays non-executable until all five preflight rows are evidenced.' "$SKILL"
  grep -Fq 'The five rows are current primary documentation, live read-only state, existing internal patterns, local IAM/resource behavior, and narrower local fixes.' "$SKILL"
}

@test "specialist authority remains review-only" {
  grep -Fq 'A polish specialist returns review evidence only; it cannot edit product code, create a PR, or mutate cloud state.' "$SKILL"
}

@test "projects without installed specialists retain the legacy polish path" {
  grep -Fq 'When no specialist manifests are installed, perform no specialist invocation and preserve the existing specialist flow unchanged.' "$SKILL"
  grep -Fq 'This specialist-only no-op does not suppress an independently configured project rules-memory query.' "$SKILL"
}

@test "planning memory query completes before the auto-gate and exact-diff review remains independent" {
  query_line="$(grep -nF 'Run `shipyard memory query --scope-file <bounded-ticket-copy>` from the project root before finalizing executable phases and before the Decisions auto-gate.' "$SKILL" | cut -d: -f1)"
  gate_line="$(grep -nF 'Then **auto-gate** on the ticket' "$SKILL" | cut -d: -f1)"
  [ -n "$query_line" ]
  [ -n "$gate_line" ]
  [ "$query_line" -lt "$gate_line" ]
  grep -Fq 'This planning query does not write an exact-diff receipt.' "$SKILL"
  grep -Fq 'The later release' "$SKILL"
  grep -Fq 'shoulder must independently run `shipyard memory query --diff-file <exact-full-diff>`' "$SKILL"
}

@test "planning memory uses a fresh bounded review and validates exact dispositions" {
  grep -Fq 'Start one fresh, cold, read-only review subagent for the nonempty review set.' "$SKILL"
  grep -Fq 'Do not reuse the ticket author, an' "$SKILL"
  grep -Fq 'installed-specialist invocation, a prior memory reviewer, or any of their' "$SKILL"
  grep -Fq 'Require exactly one disposition for every review-set ID and no other IDs:' "$SKILL"
  grep -Fq '`applies`, `requires_evidence`, `falsified`, `informational`, or `superseded`.' "$SKILL"
  grep -Fq 'Duplicate, missing, extra, omitted-candidate, unknown, or uncited dispositions' "$SKILL"
  grep -Fq 'Every disposition must cite the original ledger ID and source plus' "$SKILL"
}

@test "prompt bound defines deterministic review set and records omitted candidates" {
  grep -Fq 'The review set is exactly the first `max_prompt_records` candidates;' "$SKILL"
  grep -Fq 'remaining candidate ID, in order, as omitted from the bounded packet by the' "$SKILL"
  grep -Fq 'That omission is bounded out-of-packet coverage, not a' "$SKILL"
  grep -Fq 'reviewer disposition or memory-stage failure. If any ID is omitted, report' "$SKILL"
  grep -Fq 'coverage as `bounded`, never `full` or `clean`, in both `advisory` and `required`' "$SKILL"
  grep -Fq 'mode; required mode does not permit stronger coverage wording.' "$SKILL"
  grep -Fq 'as nonblocking planning evidence. Record the query identity, ordered query' "$SKILL"
  grep -Fq 'candidate IDs, review-set IDs, ordered out-of-packet IDs, dispositions, and' "$SKILL"
}

@test "planning memory materializes applicable rules and preserves nonblocking dispositions" {
  grep -Fq 'Materialize every `applies` rule as a cited ticket requirement and deterministic' "$SKILL"
  grep -Fq 'In `required` mode, materialize every `requires_evidence` rule as a cited' "$SKILL"
  grep -Fq 'blocking preflight/phase gate and keep it incomplete until the named evidence' "$SKILL"
  grep -Fq 'In `advisory` mode, record it instead as an explicitly nonblocking' "$SKILL"
  grep -Fq 'it must not become an open' "$SKILL"
  grep -Fq 'Decision or stop gate and must not claim the evidence exists.' "$SKILL"
  grep -Fq '`falsified`, `informational`, and `superseded` dispositions with their citations' "$SKILL"
  grep -Fq 'as nonblocking planning evidence.' "$SKILL"
}

@test "required memory blocks first while advisory degradation remains honest" {
  memory_line="$(grep -nF -- '- **Required-memory precondition:**' "$SKILL" | cut -d: -f1)"
  advisory_line="$(grep -nF -- '- **Advisory-memory handling:**' "$SKILL" | cut -d: -f1)"
  specialist_line="$(grep -nF -- '- **Specialist precondition:**' "$SKILL" | cut -d: -f1)"
  [ -n "$memory_line" ]
  [ -n "$advisory_line" ]
  [ -n "$specialist_line" ]
  [ "$memory_line" -lt "$specialist_line" ]
  [ "$advisory_line" -lt "$specialist_line" ]
  grep -Fq 'It prevents `execute-ticket`, including when `autonomous = true`.' "$SKILL"
  grep -Fq 'completion and dispositions are not an auto-gate' "$SKILL"
  grep -Fq 'precondition. A stage or reviewer failure records explicit degradation beside' "$SKILL"
  grep -Fq 'coverage is degraded; never emit or imply a clean/full-memory verdict.' "$SKILL"
}

@test "absent memory and zero candidates preserve the no-call path" {
  grep -Fq 'When `.agents/config.toml` has no `[memory]` table, perform no memory query,' "$SKILL"
  grep -Fq 'legacy polish flow, bytes, and model/network-call count.' "$SKILL"
  grep -Fq 'A successful query with zero candidates starts no memory reviewer and is not a' "$SKILL"
  grep -Fq 'an empty initialized ledger therefore adds no model call.' "$SKILL"
}

@test "configured zero result validates empty-ledger and indexed-no-match shapes" {
  grep -Fq 'Both configured' "$SKILL"
  grep -Fq 'zero-result shapes share this stable schema: version 1, command `query`,' "$SKILL"
  grep -Fq '`state = "ready"`, `valid = true`, configured mode and ledger identity, bound' "$SKILL"
  grep -Fq '`candidate_count = 0`, `candidates = []`,' "$SKILL"
  grep -Fq 'When `active_count = 0`, require `index = null`; when' "$SKILL"
  grep -Fq '`active_count > 0` produced no match, require a complete index object.' "$SKILL"
  grep -Fq 'per-candidate citation exists in either zero-result shape.' "$SKILL"
  grep -Fq 'A null index for a' "$SKILL"
  grep -Fq 'nonempty active ledger, an index object for an empty active ledger' "$SKILL"
}
