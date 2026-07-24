#!/usr/bin/env bats
# tests/specialist-archetype.bats — the domain-specialist archetype ships as a
# generic, placeholder-only role template pair (role.md + decision-log.template)
# with the section anchors the /shipyard add-specialist scaffolder and the
# specialist role both depend on. Pure file assertions — no runner, no model.

setup() { load helpers; }

ROLE="agents/specialist/role.md"
TMPL="agents/specialist/decision-log.template.md"

@test "specialist archetype files exist" {
  [ -f "$QUARTET_ROOT/$ROLE" ]
  [ -f "$QUARTET_ROOT/$TMPL" ]
}

@test "role.md states the review-not-redesign boundary and reads the log first" {
  run cat "$QUARTET_ROOT/$ROLE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qiF "you REVIEW; you do not redesign"
  echo "$output" | grep -qi "decision log"
  echo "$output" | grep -qF "## What you do"
  echo "$output" | grep -qF "## Evidence discipline"
}

@test "decision-log template carries all required section anchors" {
  run cat "$QUARTET_ROOT/$TMPL"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "## Objectives"
  echo "$output" | grep -qF "## Choices & rationale"
  echo "$output" | grep -qF "## Tried & rejected"
  echo "$output" | grep -qF "## Invariants"
  echo "$output" | grep -qF "## Open tensions"
}

@test "templates are placeholder-only (angle-bracket tokens, no real home path)" {
  run cat "$QUARTET_ROOT/$TMPL"
  [ "$status" -eq 0 ]
  # a template must still carry fill-in tokens
  echo "$output" | grep -qF "<subsystem>"
  echo "$output" | grep -qF "<placeholder>"
  # and must NOT leak an absolute home path (leak-check enforces repo-wide;
  # this pins the intent locally)
  ! echo "$output" | grep -qE "/home/[a-z]"
}
