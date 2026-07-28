# Deck clarity — shoulder mode: shorter, scannable, and honest about harness support

- **Created:** 2026-07-24
- **Owner:** wabbazzar
- **Status:** Polished — refreshed 2026-07-28; ready for `execute-ticket`
- **Type:** docs
- **Estimated Points:** 3 (P1 2 · P2 1)
- **Refs:** `docs/deck-editorial.json` (prose source), `docs/index.html`
  (both drawer render paths), `scripts/check-deck-render.mjs`,
  `scripts/gen-deck-data.py`, `CLAUDE.md` (repository policy), README Deck
  publishing, `.agents/gates.md`.

> Build with `execute-ticket`. **Anti-cheating brief (verbatim):** Converge
> honestly or report the precise blocker with the actual evidence — NEVER fake
> green, weaken a check, or hand-wave "should work". Run the real gate, read the
> real diff, render the real page, and report exact output — and **look at the
> screenshot** (the last deck bug shipped because no one did).

## Goal

Make the deck's shoulder-mode content **materially shorter and clearer**: convey
the mechanism (capture → cold critique → delivery → optional teeth) so a reader
gets the shape at a glance, and state **harness support accurately**.

Make the user's documentation rule explicit in the existing repository policy:
prefer editing the canonical document over creating a parallel explainer, and
keep the GitHub Pages deck current whenever shipped behavior or public claims
change. This ticket creates no new guide.

## Context & pointers (read before building)

- **Prose source:** `docs/deck-editorial.json` — the shoulder-mode critic card
  `detail` (search `"shoulder-mode critic"`; currently 258 words).
  Glossary terms already anchor to shipped files (`critic-queue.sh`,
  `critic-watch.sh`, `critic-stop-gate.sh`, `$CLAUDE_NOTE_CMD`) — **keep those
  anchors.**
- **Generated, never hand-edited:** `docs/shipyard-data.json` is produced by
  `python3 scripts/gen-deck-data.py`; `check-deck-fresh.sh` fails if the tracked
  file drifts from the generator. Edit editorial → regenerate → commit both.
- **Render constraint:** both the release crew card (`docs/index.html:921-929`)
  and graph/single-skill drawer (`:937-949`) escape `detail` into one `<p>`.
  CSS-only `.skill-detail` changes miss the crew path. Both paths must use one
  escaped-text paragraph helper that splits only on blank lines; data-side HTML
  stays inert.
- **Must-survive facts:** cold diff/no transcript (goal-contamination
  avoidance); 5 min idle OR 8 files; block/warn/note; shipped generic delivery
  with unset ⇒ log-and-skip; 1M tokens/day; never writes code; opt-in stop gate;
  claude, codex, and hermes capture/delivery/teeth with opt-in wiring.
- **Recent lesson (must respect):** a graph node added without a hand-tuned
  coordinate in the `P` map (`docs/index.html:678`) overlapped `/bugfix` and
  shipped because no one looked. **Any layout-affecting change is verified by
  screenshot.**

## Discovery baseline (captured 2026-07-24 — re-verify if stale)

Toolchain re-verified on `main` at `b0965a7`:
- `python3 scripts/gen-deck-data.py` + `bash scripts/check-deck-fresh.sh` →
  `deck is in sync` (exit 0).
- `bats tests/` → 405/405; syntax + `py_compile`, leak, deck freshness,
  completeness (8 installed skills), lifecycle, and doctor exit 0.
- Deck render gate needs playwright resolved from an ambient dir on this box:
  **`PLAYWRIGHT_MODULE_DIR=~/code/node_modules node
  scripts/check-deck-render.mjs`** → `all assertions pass`. (Bare `node
  scripts/check-deck-render.mjs` also passes here; exit 3 = playwright absent →
  SKIP, not a failure.)

## Locked decisions

| # | Decision |
|---|---|
| **L1** | Prose edits live only in `deck-editorial.json`; `shipyard-data.json` is regenerated, never hand-edited. |
| **L2** | Glossary anchors to shipped files stay (`path:line` sources preserved). |
| **L3** | One escaped paragraph helper splits blank-line-separated text for both drawer paths; no data-side markup and no CSS-only partial fix. |
| **L4** | Detail is ≤154 words (60% of the measured 258), in four short paragraphs: capture, critique, delivery, teeth. |
| **L5** | State current truth: claude, codex, and hermes are supported; wiring and teeth remain opt-in. |
| **L6** | No documentation bloat: amend `CLAUDE.md` and existing README/deck surfaces only; no new guide/heading. Published Pages bytes must match local before completion. |

There are no open decisions or dependencies.

## Implementation Plan

### Phase 1 — contract, render, prose, and policy (2 pts)

**Delegation: subagent (1) — own only `tests/deck-render.bats`,
`docs/index.html`, `docs/deck-editorial.json`, and generated
`docs/shipyard-data.json`. Add failing assertions for both drawer paths before
implementation. Implement the escaped paragraph helper, rewrite to ≤154 words
with all must-survive facts, regenerate, and return ≤40 lines with RED/GREEN,
word count, files, exact diagnostics, and blockers. Converge honestly or report
the precise blocker; never weaken the checks or hand-wave a render.**

The orchestrator separately adds the no-bloat/Pages-current rule to the existing
Deck coupling paragraph in `CLAUDE.md` and corrects existing README presentation
only (including the stale “seven shared skills” layout line). No new document.

Verification: focused render tests, generator, freshness, completeness, leak,
syntax, current-harness assertions, and exact word count. Observable DoD: both
drawer paths render four escaped paragraphs; 154 words maximum; policy exists
once in canonical instructions; generated JSON is current.

### Phase 2 — visual, published, and graduation proof (1 pt)

**Delegation: inline (the orchestrator must personally inspect screenshots,
full gates, published hashes, CI, and the lifecycle move).**

Run the full gate and targeted render/shoulder suites. At 1280×900, serve the
deck on loopback with cleanup traps; capture and inspect the release crew
shoulder card, graph-node shoulder drawer, one unchanged card, and full graph.
Require four readable paragraphs, no overflow, no graph-node overlap, and no
orphan browser/server. Push, require exact-SHA CI success, then require both
published `shipyard-data.json` URLs to return 200 with the local SHA-256.
Record screenshot paths/hashes and graduate with
`scripts/ticket-lifecycle.sh --project . --graduate <ticket>`.

## Testing Strategy

- `scripts/check-deck-fresh.sh` — regenerated JSON byte-identical to generator.
- `scripts/check-deck-render.mjs` — DOM assertions pass (exact invocation pinned
  in Discovery).
- **Manual screenshot** — the automated render gate does **not** catch node
  overlap; a human/agent looks (the pinned lesson).
- `scripts/leak-check.sh` — clean.

## Acceptance Criteria / Definition of Done

- [ ] The shoulder-mode `detail` is **≤154 words** with no
      must-survive fact dropped.
- [ ] The mechanism reads as a **scannable breakdown** (capture / critique /
      delivery / optional teeth) through the locked escaped paragraph helper,
      not by embedding markup the renderer escapes.
- [ ] Harness support names claude, codex, and hermes accurately.
- [ ] All prose edits are in `deck-editorial.json`; `shipyard-data.json`
      regenerated and byte-identical (`check-deck-fresh` green).
- [ ] The drawer + skill graph render cleanly at the deck viewport, **verified by
      screenshot** — no overflow, no overlap.
- [ ] Glossary terms remain anchored to shipped files with `path:line` sources.
- [ ] Existing CLAUDE/README/deck surfaces carry the canonical no-bloat and
      Pages-current policy/presentation; no new guide exists.
- [ ] Full 405+ suite and syntax, `py_compile`, leak, lifecycle, deck
      fresh/complete/render, doctor, exact-SHA CI, and both Pages hashes green.

## Risks & Mitigations

- **Trimming drops a must-survive fact** → DoD pins the list; reviewer checks against it.
- **A layout-affecting edit ships unseen** (the exact prior bug) → Phase 2
  screenshot is a hard gate.
- **Paragraph helper breaks other cards' detail rendering** → the tweak is
  escaped-text-only and applies to all `.skill-detail`; screenshot-verify at least
  one other card's drawer renders unchanged.
- **Harness claim goes stale** → pin it to completed implementation/tests, not
  the old ticket order.

## Out of scope

- Any code change to the shoulder-mode implementation (Ticket A).
- Hand-editing `shipyard-data.json` or the skill-graph layout / `P` map.
- New graph nodes (none needed; one would require a hand-tuned coordinate).
- New deck build dependencies.

## Ledger

- Re-polish — `builder: subagent (1 read-only audit agent)` measured 258 words,
  both render paths, current three-harness support, 405 tests, and the missing
  no-bloat policy. Ticket now has locked decisions and per-phase delegation.
- P1 — pending
- P2 — pending

---
Run it: `execute-ticket docs/tickets/pending/deck-shoulder-mode-clarity.md`
