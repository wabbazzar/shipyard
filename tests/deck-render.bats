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
  INDEX="$QUARTET_ROOT/docs/index.html"
  EDITORIAL="$QUARTET_ROOT/docs/deck-editorial.json"
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

@test "the closed trial result is exact and routed to its follow-up" {
  run python3 - "$QUARTET_ROOT/README.md" "$INDEX" "$EDITORIAL" <<'PY'
import json
import pathlib
import re
import sys

readme = pathlib.Path(sys.argv[1]).read_text()
source = pathlib.Path(sys.argv[2]).read_text()
editorial = json.loads(pathlib.Path(sys.argv[3]).read_text())

assert readme.count("trial met **2/4 floors**") == 1
assert "T2 MISS (2/3 projects)" in readme
assert "T3 MISS (0 valid ordered chains)" in readme
assert "docs/tickets/pending/close-five-day-trial-findings.md" in readme

table = source.split('<table class="ship-table" id="trial-results">', 1)[1].split("</table>", 1)[0]
assert re.findall(r'<th scope="col">([^<]+)</th>', table) == ["Criterion", "Floor", "Result"]
rows = re.findall(r'<tr data-trial-result="(pass|miss)">(.*?)</tr>', table, re.S)
assert [kind for kind, _ in rows] == ["pass", "miss", "miss", "pass"]
assert all(len(re.findall(r"<td>", row)) == 3 for _, row in rows)
assert source.count("Final result: 2/4 floors met.") == 1
assert "T2 and T3 are written findings" in source
assert "docs/tickets/pending/close-five-day-trial-findings.md" in source

phase = next(item for item in editorial["phases"] if item["id"] == 12)
assert phase == {
    "id": 12,
    "title": "5-day fleet trial",
    "status": "done",
    "gist": "2/4 floors met · T1 PASS · T2 MISS (2/3) · T3 MISS (0 valid ordered chains) · T4 PASS. T2 and T3 are written findings with a tracked follow-up.",
    "completed": "2026-08-04",
}
PY
  [ "$status" -eq 0 ]
}

@test "fixed deck controls clear the top safe area" {
  STYLES="$QUARTET_ROOT/docs/styles.css"
  [ "$(grep -Fc 'top: calc(1.5rem + env(safe-area-inset-top, 0px));' "$STYLES")" -eq 2 ]
  grep -Fq '.mode-toggle {' "$STYLES"
  grep -Fq '.sim-pill {' "$STYLES"
}

@test "detail renderer splits blank lines into escaped linked paragraphs" {
  grep -Fq 'function renderParagraphs(text) {' "$INDEX"
  grep -Fq '.split(/\n\s*\n/)' "$INDEX"
  grep -Fq '.map(paragraph => `<p>${linkGloss(esc(paragraph))}</p>`)' "$INDEX"
}

@test "successive detail paragraphs receive visible spacing" {
  grep -Fq '.skill-body p + p,' "$INDEX"
  grep -Fq '.crew-drawer .skill-detail p + p { margin-top: 0.65rem; }' "$INDEX"
}

@test "crew-card detail uses the shared paragraph renderer" {
  run python3 - "$INDEX" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
crew = source.split("function openCrew(id) {", 1)[1].split("function closeCrew()", 1)[0]
assert "renderParagraphs(s.detail)" in crew
assert "linkGloss(esc(s.detail))" not in crew
PY
  [ "$status" -eq 0 ]
}

@test "graph detail uses the shared paragraph renderer" {
  run python3 - "$INDEX" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
drawer = source.split("function openSkill(label) {", 1)[1].split("} else {", 1)[0]
assert "renderParagraphs(s.detail)" in drawer
assert "linkGloss(esc(s.detail))" not in drawer
PY
  [ "$status" -eq 0 ]
}

@test "shoulder detail is four paragraphs at no more than 154 words" {
  run python3 - "$EDITORIAL" <<'PY'
import json
import pathlib
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text())
skills = (skill for crew in data["crew"] for skill in crew.get("skills", []))
detail = next(skill["detail"] for skill in skills if skill["name"] == "shoulder-mode critic")
paragraphs = [part.strip() for part in detail.split("\n\n") if part.strip()]
assert len(paragraphs) == 4, len(paragraphs)
assert len(detail.split()) <= 154, len(detail.split())
PY
  [ "$status" -eq 0 ]
}

@test "shoulder detail retains the current cross-harness contract" {
  run python3 - "$EDITORIAL" <<'PY'
import json
import pathlib
import re
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text())
skills = (skill for crew in data["crew"] for skill in crew.get("skills", []))
detail = next(skill["detail"] for skill in skills if skill["name"] == "shoulder-mode critic")
contracts = {
    "cold diff without transcript": r"cold diff.*never.*transcript",
    "debounce": r"5 min.*8 .*files",
    "severity": r"block\s*/\s*warn\s*/\s*note",
    "generic unset delivery": r"generic.*delivery.*unset.*logs-and-skips",
    "daily budget": r"1M[- ]token.*/day",
    "never writes": r"never writes code",
    "opt-in teeth": r"teeth are opt-in",
    "opt-in wiring": r"wiring.*opt-in",
    "three harnesses": r"claude.*codex.*hermes",
}
missing = [name for name, pattern in contracts.items() if not re.search(pattern, detail, re.I | re.S)]
assert not missing, missing
PY
  [ "$status" -eq 0 ]
}
