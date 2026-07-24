# Deck clarity — shoulder mode: shorter, scannable, and honest about harness support

- **Created:** 2026-07-24
- **Owner:** wabbazzar
- **Status:** Polished — ready for `execute-ticket`; queued for a human stamp (not built)
- **Type:** docs
- **Estimated Points:** 3 (P1 2 · P2 1)
- **Refs:** `docs/deck-editorial.json` (prose source), `scripts/gen-deck-data.py`
  (generator), `.agents/gates.md` (Deck coupling + Public-repo hygiene classes).

> Build with `execute-ticket`. **Anti-cheating brief (verbatim):** Converge
> honestly or report the precise blocker with the actual evidence — NEVER fake
> green, weaken a check, or hand-wave "should work". Run the real gate, read the
> real diff, render the real page, and report exact output — and **look at the
> screenshot** (the last deck bug shipped because no one did).

## Goal

Make the deck's shoulder-mode content **materially shorter and clearer**: convey
the mechanism (capture → cold critique → delivery → optional teeth) so a reader
gets the shape at a glance, and state **harness support accurately**.

## Context & pointers (read before building)

- **Prose source:** `docs/deck-editorial.json` — the shoulder-mode critic card
  `detail` (search `"shoulder-mode critic"`; currently one ~180-word paragraph).
  Glossary terms already anchor to shipped files (`critic-queue.sh`,
  `critic-watch.sh`, `critic-stop-gate.sh`, `$CLAUDE_NOTE_CMD`) — **keep those
  anchors.**
- **Generated, never hand-edited:** `docs/shipyard-data.json` is produced by
  `python3 scripts/gen-deck-data.py`; `check-deck-fresh.sh` fails if the tracked
  file drifts from the generator. Edit editorial → regenerate → commit both.
- **RENDER CONSTRAINT (pinned during polish):** `docs/index.html:949` renders the
  detail as `` `<p>${linkGloss(esc(s.detail))}</p>` `` — the string is
  **HTML-escaped** and dropped into a **single `<p>`** with no
  `white-space: pre-line` (`index.html:213-214`). **Consequence:** embedded
  markup and newlines do NOT render — you cannot get bullets or line breaks from
  the data alone. True scannable structure needs a minimal render change (see
  D-B1), otherwise "clearer" means tighter prose in one paragraph.
- **Must-survive facts** (do not drop when trimming): cold-context / diff-only /
  no-transcript (goal-contamination avoidance); the debounce trigger (5 min idle
  OR 8 files); block/warn/note grading; delivery via the `$…_NOTE_CMD` contract
  (unset ⇒ log-and-skip); the 1M-token/day budget; never-writes-code; opt-in teeth.
- **Recent lesson (must respect):** a graph node added without a hand-tuned
  coordinate in the `P` map (`docs/index.html:678`) overlapped `/bugfix` and
  shipped because no one looked. **Any layout-affecting change is verified by
  screenshot.**

## Discovery baseline (captured 2026-07-24 — re-verify if stale)

Toolchain verified during polish:
- `python3 scripts/gen-deck-data.py` + `bash scripts/check-deck-fresh.sh` →
  `deck is in sync` (exit 0).
- `bash scripts/leak-check.sh` → `clean`.
- Deck render gate needs playwright resolved from an ambient dir on this box:
  **`PLAYWRIGHT_MODULE_DIR=~/code/node_modules node
  scripts/check-deck-render.mjs`** → `all assertions pass`. (Bare `node
  scripts/check-deck-render.mjs` also passes here; exit 3 = playwright absent →
  SKIP, not a failure.)

## Decisions

### Locked
| # | Decision |
|---|---|
| **L1** | Prose edits live only in `deck-editorial.json`; `shipyard-data.json` is regenerated, never hand-edited. |
| **L2** | Glossary anchors to shipped files stay (`path:line` sources preserved). |

### Open (default applied; record + proceed)
| # | Question | Default |
|---|---|---|
| **D-B1** | The detail is one escaped `<p>` (can't render bullets/breaks). How to make it *scannable*? | **Minimal render tweak:** split the detail on blank lines into stacked `<p>`s (or set `.skill-detail p { white-space: pre-line }` at `index.html:213`) so a short capture/critique/delivery/teeth breakdown renders as separate lines. Small, additive, screenshot-verified. **Fallback if the reviewer wants zero index.html change:** keep one paragraph and achieve clarity by tightening wording only (no bullets). This changes the render path, so it is called out for review. |
| **D-B2** | Length target | **≤ ~60%** of current length. |
| **D-B3** | Harness-support phrasing if B ships before A | State **"claude today; codex/hermes in progress"** rather than blocking on Ticket A. |

## Implementation Plan

### Phase 1 — rewrite the detail + harness line (2 pts)
- Trim the shoulder-mode `detail` in `deck-editorial.json` to ≤ ~60% length,
  restructured into a capture/critique/delivery/teeth breakdown, keeping every
  must-survive fact.
- If D-B1 default is taken, make the minimal `index.html` render tweak so the
  breakdown renders as separate lines (escaped text only — no data-side markup).
- Add/adjust the harness-support statement (D-B3).
- Regenerate: `python3 scripts/gen-deck-data.py`.
- **Verification surface:**
  - `bash scripts/check-deck-fresh.sh` → `deck is in sync`.
  - `bash scripts/leak-check.sh` → `clean`.
  - `git diff docs/shipyard-data.json` shows the regenerated content (proof the
    JSON was regenerated, not hand-edited).
- **DoD:** detail ≤ ~60% length; all must-survive facts present; deck-fresh green.

### Phase 2 — visual verification + gate sweep (1 pt)
- Render the deck, open the shoulder-mode drawer and the skill graph at the deck
  viewport, **capture a screenshot**, and confirm: the detail reads as a scannable
  breakdown, no text overflow, and the skill graph has **no node overlap** (the
  prior bug).
- **Verification surface:**
  - `PLAYWRIGHT_MODULE_DIR=~/code/node_modules node
    scripts/check-deck-render.mjs` → `all assertions pass`.
  - A manual screenshot of the shoulder-mode drawer + the skill graph (serve
    `docs/` over http — the deck `fetch`es JSON, so `file://` fails CORS — then
    screenshot the `#skill-graph` and the opened `.crew-drawer`).
  - `bash scripts/check-deck-fresh.sh` and `bash scripts/leak-check.sh` green.
- **DoD:** screenshot shows a clean, scannable drawer and a non-overlapping graph;
  all three gates green.

## Testing Strategy

- `scripts/check-deck-fresh.sh` — regenerated JSON byte-identical to generator.
- `scripts/check-deck-render.mjs` — DOM assertions pass (exact invocation pinned
  in Discovery).
- **Manual screenshot** — the automated render gate does **not** catch node
  overlap; a human/agent looks (the pinned lesson).
- `scripts/leak-check.sh` — clean.

## Acceptance Criteria / Definition of Done

- [ ] The shoulder-mode `detail` is **≤ ~60%** of its current length with no
      must-survive fact dropped.
- [ ] The mechanism reads as a **scannable breakdown** (capture / critique /
      delivery / optional teeth) — achieved by the D-B1 mechanism actually chosen,
      not by embedding markup the renderer escapes.
- [ ] Harness support is stated **accurately** for the ship order.
- [ ] All prose edits are in `deck-editorial.json`; `shipyard-data.json`
      regenerated and byte-identical (`check-deck-fresh` green).
- [ ] The drawer + skill graph render cleanly at the deck viewport, **verified by
      screenshot** — no overflow, no overlap.
- [ ] Glossary terms remain anchored to shipped files with `path:line` sources.
- [ ] Gates green: `check-deck-fresh`, `check-deck-render` (pinned invocation),
      `leak-check`.

## Dependencies

- **Blocked by (soft):** `harness-agnostic-shoulder-mode.md` (Ticket A) — the
  harness-support claim is fully accurate only after A lands; D-B3 covers shipping
  first. No code dependency; either build order works.

## Risks & Mitigations

- **Trimming drops a must-survive fact** → DoD pins the list; reviewer checks against it.
- **A layout-affecting edit ships unseen** (the exact prior bug) → Phase 2
  screenshot is a hard gate.
- **D-B1 render tweak breaks other cards' detail rendering** → the tweak is
  escaped-text-only and applies to all `.skill-detail`; screenshot-verify at least
  one other card's drawer renders unchanged.
- **Harness claim goes stale vs Ticket A** → phrase to ship order (D-B3): "in
  progress," never "supported," until A merges.

## Out of scope

- Any code change to the shoulder-mode implementation (Ticket A).
- Hand-editing `shipyard-data.json` or the skill-graph layout / `P` map.
- New graph nodes (none needed; one would require a hand-tuned coordinate).
- New deck build dependencies.

## Ledger

_(builder appends per phase: plan → commit hash → notes, incl. which D-B1 option
was taken and the Phase-2 screenshot evidence.)_

---
Run it: `execute-ticket docs/tickets/deck-shoulder-mode-clarity.md`
