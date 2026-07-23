# Deck mirror cascade — push shipyard's deck to the wabbazzar.com writing mirror

- **Status:** draft (ready for `polish-ticket`; awaiting human stamp)
- **Priority:** medium
- **Type:** feature
- **Estimated Points:** 10 (P1 5 · P2 3 · P3 2)

## Summary

The shipyard deck is published in two places under `wabbazzar.com`, and one of
them drifts silently. Make the second **cascade deterministically from the
first**: a `scripts/sync-deck-mirror.sh` that copies `shipyard/docs/` into the
`wabbazzar.github.io` writing mirror (re-applying the 2 destination-specific
lines), commits, and pushes — wired as a **pre-push hook** on shipyard that
fires **only when `main` is pushed**, cascading the **committed** deck (not the
worktree) so `/shipyard/` and `/writing/the-shipyard/` publish the same bytes
together. Auto-deploy is intended (personal portfolio; the point is determinism).

## Build context & verified toolchain (baselined 2026-07-23)

Every gate is green on this box today; use as the regression baseline: `bats
tests/` = **138 pass**; `bash scripts/leak-check.sh` = clean; `bash -n` sweep
= clean. This ticket adds shell + a hook + bats; it changes no model invocation
(`token-caps.bats` untouched) and no deck-generation logic.

**Verified on this box during polish (2026-07-23):**
- `git -C ~/code/shipyard config core.hooksPath` → **`.githooks`** — a new
  `.githooks/pre-push` **will** fire on push. (If a future clone lacks this,
  `install.sh` sets it; the hook is a no-op without `mirror_dir` regardless.)
- `agents/lib/load-config.sh:18 load_config_json` dumps the **entire** TOML to
  JSON via `tomllib`→`json.dumps` (`load-config.sh:28-32`), so a `[deck]` section
  reads as `.deck.mirror_dir` through `jq` — no loader change needed.
- Mirror repo present and healthy: `~/code/wabbazzar.github.io` has
  `writing/the-shipyard/{index.html,styles.css,shipyard-data.json}`, is on
  `main`, clean tree, push remote `git@github.com:wabbazzar/wabbazzar.github.io.git`.
- **Sibling commit convention** (`~/code/wabbazzar.github.io/CLAUDE.md:3-6`):
  **no Claude/AI attribution** in that repo's commit messages — the cascade's
  mirror commit MUST omit any `Co-Authored-By`/generation footprint.

**Publish topology (verified 2026-07-23):**
- `wabbazzar.com/shipyard/` ← **this repo**, GitHub Pages `main:/docs`
  (branch-serve). `shipyard/docs/` *is* the published site; a push to shipyard
  `main` auto-deploys it (~1 min). No copy step.
- `wabbazzar.com/writing/the-shipyard/` ← **`wabbazzar.github.io`** repo,
  Pages `main:/`, custom domain `wabbazzar.com`. The dir
  `wabbazzar.github.io/writing/the-shipyard/{index.html,styles.css,shipyard-data.json}`
  is a **hand-maintained copy** — no automation exists today; drift is caught
  only by a `diff` run during a ticket.
- Current state (probed): the two copies are **in sync**. `shipyard-data.json`
  and `styles.css` are byte-identical; `index.html` differs by **exactly 2
  hunks** (below).

**The 2 destination transforms** (shipyard value → writing value), the only
lines that may differ:
- `docs/index.html:273` — `href="https://github.com/wabbazzar/shipyard">&larr; Repo`
  → `href="/writing/">&larr; Writing`
- `docs/index.html:467` — `SOURCES = ['./shipyard-data.json'];`
  → `SOURCES = ['/shipyard/shipyard-data.json', './shipyard-data.json'];`

## Build protocol (orchestrator + honesty)

The builder is an orchestrator; delegate wide work, re-verify every gate
personally. **Never touch the real `wabbazzar.github.io` repo or the network in
a test** — all bats run against a fixture mirror (a local bare repo as
`origin`) with `git push` exercised only there. Embed verbatim in subagent
briefs:

> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, report exact output (exit codes, `git diff`,
> the bats tally), not adjectives. Never push to a real remote from a test.

## Decisions (default-and-record — veto at review)

| # | Decision | Locked default | Why |
|---|----------|----------------|-----|
| D-1 | Source of truth | **shipyard/docs** cascades → writing mirror; the 2 lines are destination overrides applied during cascade | User: "cascade to that place from this place." Inverts the prior "writing is HTML SoT" convention deliberately. |
| D-2 | Publish reach | **Auto-commit + auto-push** `wabbazzar.github.io` (live on wabbazzar.com) | User: "ok to auto deploy … the whole point is for shipyard to be deterministic." |
| D-3 | Trigger | **`.githooks/pre-push`** on shipyard → run `sync-deck-mirror.sh` before the shipyard push completes | User choice: couples the two decks on every push. Fires on human push, not on agent commits. |
| D-4 | Mirror path source | `[deck] mirror_dir` in the (gitignored, machine-local) `.agents/config.toml`, with `$DECK_MIRROR_DIR` env override. **Unset ⇒ the hook is a silent no-op.** | Cross-repo absolute path must never be baked into a tracked file (leak-check). Unset = safe for a stranger cloning shipyard; additive. |
| D-5 | Cascade-failure policy | **Warn loud + print the manual re-sync command; do NOT block the shipyard push** | `/shipyard/` is the primary deck; a mirror-repo hiccup (dirty tree, auth, network) shouldn't strand your shipyard push. Veto to "block" if you want strict coupling. |
| D-6 | Determinism guard | Script asserts post-copy that `diff shipyard/docs/index.html mirror/index.html` is **exactly the 2 known hunks**, copies data/styles byte-verbatim, and is **idempotent** (skip commit+push when the mirror is already identical — no empty deploys) | "Deterministic": same shipyard docs ⇒ same mirror, reproducibly; no drift, no churn. |
| D-7 | **Cascade only when `main` is pushed** | The pre-push hook parses its stdin (`<localref> <localsha> <remoteref> <remotesha>` per ref) and runs the cascade **only if `refs/heads/main` is among the pushed refs**; pushing any other branch (incl. from a build worktree) is a no-op | A pre-push hook fires on *every* push; without this, pushing a feature branch would republish the public mirror from whatever `docs/` is checked out. Only `main:/docs` actually serves `/shipyard/`, so only a main push should cascade. **(Polish finding — not in the draft.)** |
| D-8 | **Cascade the pushed `main` content, not the worktree** | The script sources `docs/{index.html,styles.css,shipyard-data.json}` from the **committed sha being pushed to main** (the `<localsha>` from the hook, via `git show <sha>:docs/…`), not the (possibly dirty/ahead) working tree | `/shipyard/` serves committed `main:/docs`. Cascading a dirty worktree would publish a mirror that doesn't match `/shipyard/` — the opposite of "deterministic." When run standalone (no sha, e.g. a manual re-sync), fall back to `HEAD:docs/…`; never the dirty worktree. **(Polish finding — not in the draft.)** |
| D-9 | Mirror commit hygiene | Commit **only** the 3 pathspecs (`git -C "$MIRROR" commit -- writing/the-shipyard/{index.html,styles.css,shipyard-data.json}`), with a **clean message and no attribution** (sibling `CLAUDE.md:3-6`); never `git add -A`, so the mirror's unrelated files (iframe/ascii-art assets) are untouched | Honors the sibling repo's convention and blast-radius: the cascade must not sweep in or clobber anything but the deck mirror. |

## Technical Requirements

**New — `scripts/sync-deck-mirror.sh`** (`set -uo pipefail`; resolve repo root
from `BASH_SOURCE`; leak-check clean — no home path):
1. Resolve `MIRROR` = `$DECK_MIRROR_DIR` else `[deck] mirror_dir` from
   `.agents/config.toml` (via `agents/lib/load-config.sh` → `load_config_json`
   → `jq '.deck.mirror_dir // empty'`). **Empty/unset ⇒ exit 0 as a no-op.**
2. Resolve the **source sha** (D-8): first arg `$1` (the pushed `main` sha the
   hook passes) else `HEAD`. Sanity: `MIRROR` exists, is a git worktree, has
   `writing/the-shipyard/`; else exit 2.
3. Materialize the deck **from the committed sha, not the worktree** (D-8):
   `git show <sha>:docs/shipyard-data.json` and `:docs/styles.css` → the mirror
   verbatim; `git show <sha>:docs/index.html` → a temp, apply the 2 D-transforms
   (deterministic replacement of the exact L273 + L467 strings) → the mirror.
4. **Determinism guard (D-6):** assert `diff <(git show <sha>:docs/index.html)
   <mirror>/…/index.html` equals exactly the 2 expected hunks (else exit 2 — the
   transform map is stale vs. a restructured deck).
5. Idempotent + scoped commit (D-9): if `git -C "$MIRROR" diff --quiet --
   writing/the-shipyard/` ⇒ unchanged, exit 3 (no empty deploy). Else
   `git -C "$MIRROR" commit -- writing/the-shipyard/{index.html,styles.css,
   shipyard-data.json}` with a **clean, attribution-free** message (sibling
   `CLAUDE.md:3-6`) — **never `git add -A`** — then (D-2) `git -C "$MIRROR" push`.
   Exit codes: `2` = bad config/guard, `3` = deliberate no-op (unset/unchanged),
   `0` = cascade pushed.
6. Per D-5, on commit/push failure print a loud warning + the manual re-run
   command and return nonzero **to the script**; the **hook** does not propagate
   it as a block. Refuse to proceed if the mirror is not on `main` or its
   `writing/the-shipyard/` has *other* uncommitted edits (warn, exit nonzero —
   don't clobber a human's in-progress mirror edit).

**New — `.githooks/pre-push`** (shipyard uses `core.hooksPath=.githooks`,
verified active):
- Reads stdin; for each `<localref> <localsha> <remoteref> <remotesha>` line,
  detect whether `<remoteref>` is `refs/heads/main` with a non-zero `<localsha>`
  (a real update, not a delete). **Only then** call
  `scripts/sync-deck-mirror.sh "<localsha>"` (D-7 + D-8). Pushing any other
  branch ⇒ no cascade.
- Per D-5 it logs the result and **always exits 0** (never blocks the shipyard
  push). No-op when `mirror_dir` is unset. Recursion-safe: the mirror repo has
  **no** hooks dir (verified), and the mirror push targets a different repo.

**Config / docs:** document `[deck] mirror_dir` and `$DECK_MIRROR_DIR` in the
README env-knob table; add a Traps line to `.agents/gates.md`. The key lives
only in the gitignored `.agents/config.toml` on this box — never tracked.

## Implementation Plan

### Phase 1 — `sync-deck-mirror.sh` (behind config; unset = no-op) (5 pts)
Steps: author the script (copy + transforms + determinism guard + idempotent
commit + push), gated on `mirror_dir`. Do **not** wire the hook yet — so push
behavior is unchanged this phase.
Verification surface:
- Build a **fixture**: a throwaway mirror git repo (`make_git_topology` /
  `make_fixture_project`) with a local **bare** `origin`, seeded with a
  `writing/the-shipyard/` copy; point `$DECK_MIRROR_DIR` at it. Stub/redirect so
  no real remote is reachable.
- `DECK_MIRROR_DIR=<fixture> bash scripts/sync-deck-mirror.sh <sha>` (sha = a
  commit whose `docs/` is known) → mirror's `shipyard-data.json`/`styles.css`
  byte-identical to `git show <sha>:docs/…`; `diff` of the two `index.html` ==
  exactly the 2 hunks; a commit + push landed in the bare origin.
- **D-8 (from-sha, not worktree):** dirty the working-tree `docs/index.html`,
  then cascade from a clean `<sha>` → the mirror reflects `<sha>` content, **not**
  the dirty worktree. Proves the mirror matches what `/shipyard/` serves.
- **D-9 (scoped + no attribution):** after cascade, `git -C <fixture> show
  --stat HEAD` touches **only** `writing/the-shipyard/{index.html,styles.css,
  shipyard-data.json}`; `git -C <fixture> log -1 --format=%B` contains **no**
  `Co-Authored-By`/Claude footprint; a pre-existing unrelated dirty file in the
  mirror is left uncommitted.
- Idempotency: run again → **exit 3, no new commit** in the bare origin.
- Unset path: `unset DECK_MIRROR_DIR`, no config key → **exit 0, no-op**.
- Guard: perturb the source `docs/index.html` structurally → **exit 2**.
- Safety: mirror **not on `main`** or its `writing/the-shipyard/` has other
  uncommitted edits → script **warns + exits nonzero, no clobber**. `bash -n` clean.
Observable DoD: mirror byte-correct **from the sha** and idempotent; unset =
no-op; scoped attribution-free commit; guard + not-on-main safety fire; real
`wabbazzar.github.io` never touched (assert only the fixture path was used).

### Phase 2 — Wire `.githooks/pre-push` + bats (3 pts)
Steps: add `.githooks/pre-push` that parses stdin and, **only when
`refs/heads/main` is pushed** (D-7), calls the script with the pushed sha (D-8);
per D-5 it never blocks. Add `tests/deck-mirror.bats`, **failing-first**.
Verification surface (feed the hook synthetic stdin lines — no real push):
- **D-7 main-only:** pipe a `refs/heads/main` line → cascade runs (mirror bare
  origin gets the commit); pipe a `refs/heads/feature-x` line → **no cascade,
  exit 0** (shown red first against a naive hook that ignores the ref). This is
  the failing-first case.
- Delete/zero sha for main (`0000…`) → no cascade.
- `git push` never-blocked (D-5): force the cascade to fail (unwritable mirror)
  → the hook still **exits 0**.
- `bats tests/deck-mirror.bats` green; `bats tests/` green at **138+N**;
  `bash -n .githooks/pre-push scripts/sync-deck-mirror.sh` clean.
Observable DoD: hook cascades **only on a main push**, passes the pushed sha,
never blocks; unset mirror = clean no-op; suite green.

### Phase 3 — Docs + leak-check + e2e (2 pts)
Steps: README env-knob rows for `[deck] mirror_dir` / `$DECK_MIRROR_DIR`; a
`.agents/gates.md` Traps line ("pre-push cascades the deck to the wabbazzar.com
writing mirror; unset mirror_dir = no-op; failures warn, don't block").
Verification surface:
- `bash scripts/leak-check.sh` → clean (no home path / key in the tracked hook,
  script, README, or gates — the absolute mirror path lives only in gitignored
  config).
- `grep -rn '/home/' .githooks/pre-push scripts/sync-deck-mirror.sh` → nothing.
- Full re-run: `bats tests/ && bash scripts/leak-check.sh && bash -n install.sh
  .githooks/pre-push scripts/sync-deck-mirror.sh` → all exit 0; `git status`
  clean.
Observable DoD: leak-check clean; no home path in any tracked file; e2e one-liner
exits 0.

## Testing Strategy

- `tests/deck-mirror.bats` (new) — hermetic: a fixture mirror repo with a local
  bare `origin`; `git push` exercised only there; the real `wabbazzar.github.io`
  and the network are never reachable (`make_stub` / fixture paths per
  `tests/helpers.bash`). Covers: byte-correct copy, exact-2-line index transform,
  idempotency, unset = no-op, guard-trips-on-structural-change, hook-does-not-block.
- `bash scripts/leak-check.sh` — the tracked script + hook + docs carry no home
  path or key; the mirror path is config-only.
- `bash -n` on the new shell + `.githooks/pre-push`.

## Acceptance Criteria / Definition of Done

- [ ] `scripts/sync-deck-mirror.sh` copies `docs/{shipyard-data.json,styles.css}`
      verbatim and `docs/index.html` with exactly the 2 D-transforms into
      `[deck] mirror_dir`; asserts the resulting `index.html` diff is exactly the
      2 known hunks (else exit 2); is idempotent (unchanged ⇒ exit 3/0, no empty
      commit); exit codes `2`/`3`/`0` as specified.
- [ ] Unset `mirror_dir`/`$DECK_MIRROR_DIR` ⇒ the script **and** the hook are a
      **no-op** (exit 0), proven by bats — safe for a stranger who cloned
      shipyard with no mirror.
- [ ] With `mirror_dir` set, a cascade **commits and pushes** the mirror repo
      (D-2), verified against a fixture bare `origin` — never the real
      `wabbazzar.github.io`.
- [ ] `.githooks/pre-push` cascades **only when `refs/heads/main` is pushed**
      (D-7) and passes that pushed sha to the script (D-8); pushing any other
      branch is a no-op; a forced cascade failure still lets the shipyard push
      proceed (D-5, never blocks). All proven by bats.
- [ ] The cascade sources the deck from the **committed pushed sha, not the
      working tree** (D-8) — proven by a dirty-worktree test where the mirror
      matches the sha; and the mirror commit touches **only** the 3
      `writing/the-shipyard/` paths with a **no-attribution** message (D-9,
      sibling `CLAUDE.md:3-6`).
- [ ] `bash scripts/leak-check.sh` clean; `grep -rn '/home/'` over the tracked
      script + hook returns nothing; README env-knob table + `.agents/gates.md`
      Traps updated.
- [ ] `bats tests/` fully green at the new count; `bash -n` sweep green;
      `token-caps.bats` still green.

## Dependencies

- **External:** the `wabbazzar.github.io` checkout must exist at `mirror_dir`
  with a `writing/the-shipyard/` layout and a push remote (owner's box only).
  Tests never require it — they use a fixture.
- **Blocks / Blocked-by:** none. Independent of the ui-design ticket, though it
  is the "layer 3" enforcement complementing that ticket's deck-completeness
  gate (source complete → cascade keeps the mirror complete).

## Risks & Mitigations

- **Auto-push to a public site from a hook** — approved (D-2), but a bug could
  publish a bad mirror → the determinism guard (D-6) refuses to commit anything
  but a byte-correct transform; idempotency prevents churn; `/shipyard/` (the
  primary) is unaffected by the mirror.
- **Baked home path in a tracked file** (leak-check hazard) — the absolute
  mirror path lives **only** in gitignored `.agents/config.toml`; the tracked
  hook/script read it via the config loader; acceptance greps for `/home/`.
- **Test touches the real mirror / network** — forbidden; all bats use a fixture
  bare repo; acceptance asserts the real repo path never appears in a test.
- **Transform map goes stale** (deck HTML restructured so L273/L467 move) — the
  D-6 guard fails the cascade loudly (exit 2) rather than shipping a broken
  mirror; fix = update the transform strings.
- **Hook blocks a legitimate shipyard push** — D-5 makes the hook always exit 0;
  cascade failures warn, never block.
- **Feature-branch / worktree push republishes the public mirror** — a pre-push
  hook fires on every push; D-7 gates the cascade to `refs/heads/main` only, so
  pushing a WIP branch (incl. from a build agent's worktree) never touches
  wabbazzar.com.
- **Mirror diverges from `/shipyard/`** (dirty or ahead worktree) — D-8 cascades
  the *committed pushed sha* via `git show`, so the mirror is exactly what
  `main:/docs` serves; the not-on-main / other-dirty-edits guard refuses rather
  than clobber a human's in-progress mirror change.

## Out of scope

- Changing how `/shipyard/` deploys (already automatic on push to shipyard main).
- Making the crew (chronicler) run the cascade — the trigger is the pre-push
  hook (D-3); a scheduled/agent cascade is a later option, not this ticket.
- A drift-detection-only gate — superseded by this auto-cascade (drift can't
  accumulate if every push re-syncs).
- Any change to `auto_push` for the shipyard repo itself, or to the deck
  generator / completeness gate (separate ticket).

## Ledger

_(builder appends per phase: plan, commit hash, gate output — bats tally,
`git diff`, exit codes — and honest notes on anything deferred.)_

- **P1 — `1b11750`** `scripts/sync-deck-mirror.sh`. Verified against a fixture
  mirror (bare origin): cascade byte-matches the sha for data/styles, index diff
  == exactly the 2 hunks, clean scoped commit (empty body — no attribution),
  pushed; idempotent (exit 3); unset no-op (exit 3); D-8 from-sha (dirty worktree
  ignored); determinism guard, not-on-main, dirty-deck all exit 2; leak-check
  clean, no `/home/`. Chose exit **3** (not 0) for the unset no-op so the hook can
  tell "nothing configured" from "cascaded"; hook treats both as success.
- **P2 — `9f29242`** `.githooks/pre-push` + `tests/deck-mirror.bats` (10 cases).
  Hook gained a `QUARTET_DIR` override for testability (harmless in prod:
  unset ⇒ `git rev-parse --show-toplevel`). Failing-first proven: a naive hook
  that ignores the ref FAILS the main-only case; real hook passes. Full suite
  **138 → 148**, leak-check clean.
- **P3 — this commit** README "Deck publishing" section (`[deck] mirror_dir` /
  `$DECK_MIRROR_DIR`, the hook, manual run + exit codes). Final e2e gate green.
  **Deferred (machine-local):** the `.agents/gates.md` Traps line — that file is
  gitignored/per-box (absent in the worktree), so it's a local doc edit, not a
  branch change; apply on the box if wanted. **Not done (by design):** no
  `mirror_dir` was set and nothing was pushed to the real `wabbazzar.github.io` —
  the branch is inert until stamped + configured.

## Run it

Hardened and ready for **`execute-ticket`** at
`docs/tickets/deck-mirror-cascade.md`. One user-approved outward-facing behavior
(auto-push to `wabbazzar.com`, D-2) is recorded, not a blocker; every other
choice has a locked default. Land it on a branch (e.g. `feat/deck-mirror-cascade`)
— the hook + script are read live, but stay a no-op until `[deck] mirror_dir` is
set on this box.
