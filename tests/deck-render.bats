#!/usr/bin/env bats
# tests/deck-render.bats — the deck's rendered DOM must match what its CSS and
# click handlers assume.
#
# Two layers, on purpose:
#
#   1. A SOURCE invariant that always runs (no browser, CI-safe): the clickable
#      glossary element must never be an interactive element. The deck injects
#      it into authored prose, and one of those prose slots is inside
#      <button class="skill-toggle"> — a nested <button> makes the parser close
#      the toggle and reparent the chip and chevron out of it.
#   2. A REAL RENDER check (scripts/check-deck-render.mjs) that opens every crew
#      drawer in a headless browser and asserts the structure and the click
#      behavior. Skipped when playwright is unavailable; point NODE_PATH or
#      PLAYWRIGHT_MODULE_DIR at an install to enable it.

setup() {
  QUARTET_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

@test "the glossary element is not an interactive element (no nested-button hazard)" {
  run grep -n '<button class="gloss"' "$QUARTET_ROOT/docs/index.html"
  [ "$status" -ne 0 ] || {
    echo "docs/index.html emits a <button> for glossary links:"
    echo "$output"
    echo "It is injected into <button class=\"skill-toggle\"> prose — nested buttons"
    echo "are invalid HTML and the parser reparents the chip and chevron out of the row."
    false
  }
}

@test "the writing-site copy carries the same invariant (when present)" {
  SITE="$QUARTET_ROOT/../wabbazzar.github.io/writing/the-shipyard/index.html"
  [ -f "$SITE" ] || skip "writing-site copy not checked out beside this repo"
  run grep -n '<button class="gloss"' "$SITE"
  [ "$status" -ne 0 ]
}

@test "rendered deck: every skill item keeps its toggle, chip and chevron" {
  run node "$QUARTET_ROOT/scripts/check-deck-render.mjs"
  if [ "$status" -eq 3 ]; then skip "playwright unavailable: $output"; fi
  echo "$output"
  [ "$status" -eq 0 ]
}
