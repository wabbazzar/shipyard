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
  grep -Fq 'When no specialist manifests are installed, perform no specialist invocation and preserve the existing polish flow unchanged.' "$SKILL"
}
