---
name: ui-design
description: >
  Design and review front-end surfaces grounded in the subject, audience, and job.
  Use when planning, specifying, implementing, polishing, or critiquing a
  website, app screen, dashboard, component system, or visual interaction.
roles: [design, build, release, human]
disposition: adapted
kind: shared
---

# ui-design

Create a coherent interface from the work's meaning, not from a stock visual
formula. Make each choice explainable, observable at real viewports, and useful
to the person operating the surface.

## Ground the direction

- Name the subject, audience, and job before choosing a visual direction.
- State a one-sentence design thesis that connects those facts to the intended
  feeling and interaction.
- Identify the information hierarchy, primary action, and moments of risk or
  uncertainty before arranging components.
- Reject decorative choices that could be transplanted unchanged into an
  unrelated product.

## Define the visual system

- Define 4–6 named colors with hex values and explicit roles.
- Include surface, text, accent, and status roles; verify text/background
  combinations remain readable.
- Assign display, body, and utility type roles.
- Choose a deliberate scale and weight hierarchy; use fewer roles when an extra
  distinction carries no meaning.
- Reuse spacing, radius, border, and elevation decisions consistently without
  making every element look identical.

## Let structure carry the design

- Let content structure determine the layout.
- Establish the reading order and grouping before adding decoration.
- Choose one signature element that makes the surface recognizable.
- Let that element reinforce the subject or interaction; do not repeat it until
  it becomes noise.
- Make every layout responsive from the narrowest supported viewport.
- Recompose hierarchy and controls when space changes instead of merely
  shrinking the desktop arrangement.

## Make interaction legible

- Preserve keyboard operation, visible focus, readable contrast, and semantic structure.
- Respect reduced-motion preferences.
- Use motion only to explain state, continuity, or cause and effect.
- Write concise, active, sentence-case copy.
- Name actions by what they change; make empty, loading, success, and failure
  states tell the person what happened and what to do next.

## Work in a critique loop

- Plan → critique → build → critique again.
- Before building, challenge the plan for generic styling, weak hierarchy,
  unnecessary accessories, and choices unrelated to the subject.
- Inspect the rendered surface at every declared viewport before judging it finished.
- Check the real interaction states, keyboard path, focus visibility, contrast,
  overflow, and reduced-motion behavior.
- Compare the result with the design thesis and revise the largest mismatch
  first.
- Remove one accessory before calling the surface finished.

## Leave an actionable record

Record the design thesis, palette roles, type roles, layout concept, signature
element, responsive decisions, state copy, and critique findings in the ticket
or review artifact. Distinguish verified observations from recommendations.
