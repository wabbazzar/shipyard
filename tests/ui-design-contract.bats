#!/usr/bin/env bats

setup() {
  SKILL="$BATS_TEST_DIRNAME/../skills/ui-design/SKILL.md"
  FEATURE="$BATS_TEST_DIRNAME/../skills/feature/SKILL.md"
  WRITE_TICKET="$BATS_TEST_DIRNAME/../skills/write-ticket/SKILL.md"
  POLISH_TICKET="$BATS_TEST_DIRNAME/../skills/polish-ticket/SKILL.md"
}

@test "ui-design skill exists with the shared four-role frontmatter contract" {
  [ -f "$SKILL" ]
  grep -Fxq 'name: ui-design' "$SKILL"
  grep -Fxq 'roles: [design, build, release, human]' "$SKILL"
  grep -Fxq 'disposition: adapted' "$SKILL"
  grep -Fxq 'kind: shared' "$SKILL"
}

@test "description names the capability and concrete UI trigger contexts" {
  grep -Fxq 'description: >' "$SKILL"
  grep -Fq 'Design and review front-end surfaces' "$SKILL"
  grep -Fq 'Use when planning, specifying, implementing, polishing, or critiquing' "$SKILL"
  grep -Fq 'website, app screen, dashboard, component system, or visual interaction' "$SKILL"
}

@test "body pins subject, audience, palette, type, structure, and signature" {
  grep -Fq 'Name the subject, audience, and job before choosing a visual direction.' "$SKILL"
  grep -Fq 'Define 4–6 named colors with hex values and explicit roles.' "$SKILL"
  grep -Fq 'Assign display, body, and utility type roles.' "$SKILL"
  grep -Fq 'Let content structure determine the layout.' "$SKILL"
  grep -Fq 'Choose one signature element that makes the surface recognizable.' "$SKILL"
}

@test "body pins responsive, accessibility, motion, and copy quality floors" {
  grep -Fq 'Make every layout responsive from the narrowest supported viewport.' "$SKILL"
  grep -Fq 'Preserve keyboard operation, visible focus, readable contrast, and semantic structure.' "$SKILL"
  grep -Fq 'Respect reduced-motion preferences.' "$SKILL"
  grep -Fq 'Write concise, active, sentence-case copy.' "$SKILL"
}

@test "body requires an iterative plan critique build critique loop" {
  grep -Fq 'Plan → critique → build → critique again.' "$SKILL"
  grep -Fq 'Inspect the rendered surface at every declared viewport' "$SKILL"
  grep -Fq 'Remove one accessory before calling the surface finished.' "$SKILL"
}

@test "skill stays independent of providers, plugins, models, and named tools" {
  [ -f "$SKILL" ]
  ! grep -Eqi \
    'anthropic|claude|openai|codex|gemini|frontend-design|plugin|provider|model|figma|playwright|puppeteer|screenshot tool' \
    "$SKILL"
}

@test "deferred naming-consistency policy is not smuggled into v1" {
  [ -f "$SKILL" ]
  ! grep -Eqi 'label[- ]family|naming[- ]consistency' "$SKILL"
}

@test "feature routes UI-shaped design intent through ui-design before write-ticket" {
  grep -Fq '**UI-shaped features — design readiness.** For a UI-shaped feature, run the' "$FEATURE"
  grep -Fq '`ui-design` skill before handing the scope to `write-ticket`.' "$FEATURE"
  grep -Fq 'Carry its design thesis into the design-intent acceptance criteria.' "$FEATURE"
  grep -Fq '**Skipping `ui-design` for a UI-shaped feature.**' "$FEATURE"
  ! grep -q 'new-spec' "$FEATURE"
}

@test "write-ticket consults ui-design for UI acceptance and design thesis" {
  grep -Fq 'For a UI-shaped scope, consult the `ui-design` skill before writing acceptance.' "$WRITE_TICKET"
  grep -Fq 'Carry its design thesis and viewport-specific proof into the ticket.' "$WRITE_TICKET"
}

@test "polish-ticket consults ui-design for UI gates and rendered viewport proof" {
  grep -Fq 'For a UI-shaped ticket, consult the `ui-design` skill while hardening its gates.' "$POLISH_TICKET"
  grep -Fq 'Require its declared viewports and rendered interaction states as proof.' "$POLISH_TICKET"
}
