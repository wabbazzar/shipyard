# Restore GitHub CI integrity after canonical merges

- **Created:** 2026-08-03
- **Owner:** wabbazzar
- **Status:** in progress — D-4 resolved; execution started
- **Priority:** urgent
- **Type:** bugfix
- **Estimated Points:** 8 (P1 3 · P2 3 · P3 2)
- **Refs:** `.github/workflows/checks.yml`,
  `scripts/check-git-identity.sh`,
  `agents/release/critic-codex-feedback.sh`,
  `tests/git-identity-enforcement.bats`,
  `tests/codex-feedback-delivery.bats`,
  `docs/tickets/pending/git-identity-enforcement.md`, `.agents/gates.md`

## Goal

Return the exact `checks` workflow on published `main` to deterministic green
without silently weakening Shipyard's raw Git-identity policy, and close the
independent mailbox handoff race exposed by the same workflow run.

Completion means the captured identity reproduction and deterministic mailbox
handoff reproduction both pass, the coverage gaps that admitted them are
closed, every local repository gate is green, and GitHub reports terminal
success for the exact pushed commit.

## Problem / Background

GitHub Actions run `30818972922` for published `main` commit
`8424e353b2a44164b4d9943444048d8ad6ebfac1` completed `failure` while Pages run
`30818971634` for the same commit completed `success`. The failed workflow has
two independent causes:

1. The `git-identity` job audits all commits reachable from a `main` push
   (`.github/workflows/checks.yml:35-44`). It correctly rejects six merge
   commits whose committer is GitHub rather than the one exact canonical
   identity required by `docs/tickets/pending/git-identity-enforcement.md`.
   Pull-request checks passed because they audit only the proposed branch
   range, before GitHub creates the final merge commit. The observable defect
   is therefore the merge path and its missing pre-merge coverage, not a stale
   secret or a false-negative checker.
2. The Bats job intermittently loses one of eight simultaneous Codex feedback
   deposits. A deterministic handoff reproduction exits `75`, leaves only the
   seeded pending item, and leaves no lock:

   ```text
   forced_handoff_rc=75
   output=''
   pending=1 lock_exists=no
   ```

   In `lock_mailbox`, a contender can validate `.lock` at
   `agents/release/critic-codex-feedback.sh:653-663`, then the live owner can
   release it before `lock_generation` at lines 664-665. The vanished normal
   handoff is treated as fatal instead of retrying acquisition. The natural
   isolated test reproduced the same missing-item signature in 791 ms, far
   below the configured 5-second contention timeout and without the timeout
   diagnostic.

### Root-cause record

| Defect | Where it lives | When it started | Same class elsewhere | Why coverage missed it |
|---|---|---|---|---|
| Web merge violates canonical identity | The integration between GitHub's merge operation and the all-history push audit in `.github/workflows/checks.yml:35-44`; six current merge objects have non-canonical committer fields | Full-history push enforcement entered in `69313b0` on 2026-07-30; the first incompatible web merge is `f8df8be` | Every future GitHub-created merge under the current exact-identity policy; PR-range checks remain green because the merge object does not exist yet | `tests/git-identity-enforcement.bats:758-766` asserts workflow strings but does not execute a GitHub-authored merge topology through both PR and push event contracts; the governing identity ticket recorded the server limitation but the merge operation did not enforce it |
| Mailbox owner-release handoff | `agents/release/critic-codex-feedback.sh:653-665` returns `75` when `.lock` vanishes between validation and generation lookup | Mailbox implementation and its probabilistic concurrency test entered together in `19abfe27` on 2026-07-30 | Generation lookups at lines 698-700 and 721-724 can meet equivalent recovery-contender handoffs and require audit | `tests/codex-feedback-delivery.bats:633-660` runs one timing-sensitive eight-writer sample, uses a bare `wait`, and has no deterministic seam for owner release after validation; tracing perturbs the race |

Rivals are falsified. The mailbox directory-creation theory is false because
the script establishes `umask 077` and a measured new directory is already
mode `0700`; legitimate lock exhaustion is false because the failure occurs
well before the wait budget and lacks `mailbox lock unavailable`. For identity,
the same policy passes the PR head range and fails only the resulting
GitHub-committed merge objects, ruling out bad branch commits, a missing
secret, or shallow checkout.

## Verified Polishing Baseline — 2026-08-03 CDT

- `gh run view 30818972922` identifies a completed failed `checks` push run
  for `8424e353`; its Bats job passed 732/733 and failed only the simultaneous
  writer case. Pages run `30818971634` for the same SHA completed successfully.
- `bash scripts/check-git-identity.sh --all HEAD --project .` exits `1` and
  reports exactly six unique offending hashes: `f8df8be`, `539eef2`,
  `bca4b49`, `b1e7eec`, `525dee1`, and `8424e35`. Only committer name/email
  fields mismatch; values remain redacted.
- The deterministic mailbox handoff probe exits `75` with
  `pending=1 lock_exists=no`. A natural isolated loop reproduced in run 15 in
  791 ms. The existing timing-sensitive case has also failed locally and on
  GitHub, always by producing fewer than eight pending records.
- `bats tests/git-identity-enforcement.bats` passes 37/37 in 6 seconds and
  `bats tests/codex-feedback-delivery.bats` passes 52/52 in 29 seconds when the
  race is not forced. `bats --count tests/` reports 733 cases. The pre-ticket
  local full suite passed 733/733; the latest GitHub run is the contradictory
  post-merge evidence this ticket must close.
- `bash -n agents/release/critic-codex-feedback.sh
  scripts/check-git-identity.sh` exits `0`. Bats 1.10.0, Git 2.43.0, Python
  3.12.3, jq 1.7, Node 24.12.0, and authenticated `gh` 2.83.2 are available.
  `actionlint` is absent; hermetic workflow topology tests plus the pushed
  GitHub run are required instead.
- The canonical checkout is on `main`; after the draft commit it is one local
  ticket commit ahead of `origin/main`. Project instructions forbid branches
  and worktrees here because this checkout is fleet-live. Execution stays in
  this checkout, commits thin green phases to `main`, and does not push until
  the selected identity remediation makes the all-history audit green.
- No sibling repository, systemd unit, served port, event stream, model call,
  skill frontmatter, or generated deck input is touched by this ticket.

## Decisions

### Locked decisions

| # | Decision | Locked value | Why |
|---|---|---|---|
| D-1 | Mailbox handoff | A lock generation that vanishes during a validated normal handoff retries acquisition; symlink/non-directory replacements and unsafe generations remain fatal | This repairs the proven TOCTOU without weakening the mailbox trust boundary or hiding real corruption |
| D-2 | Coverage posture | Both regressions receive deterministic, hermetic red-first cases; the existing probabilistic concurrency case remains as defense in depth | Acceptance is the captured repro passing and the named coverage gaps closing, not a retry around a flaky suite |
| D-3 | CI evidence | Completion requires terminal success from GitHub's exact `checks` run on the published repaired commit, in addition to local gates | The current incident was visible only after merge, and `.agents/gates.md` explicitly requires checking CI rather than assuming local parity |

### Resolved user decision

| # | Owner choice | Rationale |
|---|---|---|
| D-4 | **Support GitHub web merges** through an explicit, narrow policy exemption; do not rewrite history | On 2026-08-03 the owner expressed no preference and asked for the easier policy to maintain. Native GitHub merges avoid recurrent metadata rewrites and a custom merge ceremony. Authors and all non-merge committers remain canonical. |

The exemption is metadata conformance, not cryptographic provenance—the same
boundary as the existing canonical tuple check. It is limited to two-parent
objects and one tracked SHA-256 digest of the accepted system committer tuple;
the raw tuple is never duplicated in tracked source or logs.

There are no open user-decision-class items.

**Auto-gate: PROCEED.**

## Technical Requirements

### Mailbox handoff repair

- Add a hermetic deterministic regression in
  `tests/codex-feedback-delivery.bats` that forces the owner to release the
  validated lock before the contender's generation lookup, then proves the
  contender exits `0`, deposits exactly once, and leaves no `.lock`.
- Change `lock_mailbox` only so a generation lookup that observes a vanished
  lock during normal handoff retries the bounded acquisition loop. Re-check
  inode safety before retrying so a symlink or non-directory replacement still
  exits `75` immediately.
- Audit and cover the same-class generation lookups at
  `agents/release/critic-codex-feedback.sh:698-700` and `:721-724`; distinguish
  a peer-completed recovery from an unsafe replacement or malformed live
  generation.
- Keep the existing wait budget, lease semantics, process-identity checks,
  durable rename/fsync path, and no-`ps` portability unchanged.

### GitHub merge identity policy

- Add tracked `.shipyard-git-identity.toml` key
  `allow_github_merge_committer = true`, whose absent/false value preserves the
  exact current behavior. Add `github_merge_committer_sha256` containing the
  SHA-256 digest of the NUL-delimited system committer name/email tuple. Never
  track or print the raw tuple. Require both keys together and reject malformed
  booleans/digests as configuration exit `2`.
- Accept the configured digest only for a two-parent commit whose author fields
  are canonical. Canonical committers continue to pass on any topology;
  one-parent/root commits and wrong author fields never receive the exemption.
- Add red-first fixtures for arbitrary wrong committers, forged merge-like
  subjects, wrong parent counts, malformed/missing policy digests, and
  qualifying platform merges. Pin that tuple spoofing is outside this metadata
  policy's threat model, exactly as spoofing the canonical tuple already is.
- Extract the inline workflow dispatcher into
  `scripts/check-git-identity-ci.sh`; the workflow calls the script and Bats
  executes it against hermetic PR and post-merge push topologies. Preserve
  secret redaction, full-depth checks, and event failure posture.
- Update the prior identity ticket's status/boundary and canonical README claim
  so the parked exact-server-governance goal no longer contradicts supported
  web merges.

### Workflow contract and publication

- Replace static workflow-string confidence with a hermetic Git topology that
  exercises the pull-request range and the corresponding post-merge push
  audit. The resolved D-4 policy must make both paths agree before publication.
- Preserve `fetch-depth: 0`, secret redaction, failure on malformed/missing
  event endpoints, and the distinction between PR-introduced commits and the
  final merge object.
- Run every applicable local gate from `.agents/gates.md`, push through the
  selected compatible path, and inspect the exact GitHub run to terminal
  success. Pages success is recorded separately and never substitutes for the
  `checks` workflow.

## Implementation Plan

The builder is the orchestrator. It delegates the bounded code slices, keeps
shared Git/GitHub mutation inline, re-runs every named gate personally, and
records exact evidence in the Ledger. Work only in the canonical `main`
checkout; never create a branch or worktree, never push an intermediate red
phase, and scope every `git add` to ticket-owned files.

### Phase 1 — Deterministic mailbox handoff repair (3 pts)

**Delegation: subagent — mailbox regression and minimal lock-state repair.**
Receive the captured `forced_handoff_rc=75`, `pending=1 lock_exists=no`
signature; the natural 791-ms failure; and source ranges
`agents/release/critic-codex-feedback.sh:633-733` and
`tests/codex-feedback-delivery.bats:633-660`. First add a deterministic PATH
`stat` shim that lets `safe_dir(.lock)` succeed, synchronously releases the
owner, and makes the next generation stat observe `ENOENT`. Assert contender
exit `0`, exactly one new durable item, and no lock after the code change; add
near-miss cases for symlink/non-directory replacement and same-class lookups at
lines 698/721. Return in at most 40 lines: files changed; commands plus exit
codes; red-first assertion/output; focused/full counts; unsafe-replacement
evidence; blockers. Touch only
`agents/release/critic-codex-feedback.sh`,
`tests/codex-feedback-delivery.bats`, and this ticket's Ledger.

> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

Prove the deterministic test fails with contender exit `75` before the source
change, then make normal handoff retry without broad sleep/retry masking. Bats,
shell syntax, and public-repo hygiene gate classes apply. Commit this slice
independently only after the orchestrator repeats every gate.

**Gate classes:** shell scripts, Bats suite, public-repo hygiene, delegation
contract. Config-gated additivity does not apply: this repairs an existing
lock contract and retains fail-closed unsafe-state behavior.

**Exact verification:**

```bash
bats --filter 'owner release between validation and generation retries safely' \
  tests/codex-feedback-delivery.bats
bats tests/codex-feedback-delivery.bats
bash -n agents/release/critic-codex-feedback.sh agents/release/critic-note.sh
bats tests/
bash -n install.sh agents/lib/*.sh agents/*/runner.sh \
  agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit \
  .githooks/pre-push
python3 -m py_compile scripts/gen-deck-data.py
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bash scripts/check-deck-complete.sh
bash scripts/ticket-lifecycle.sh --project . --check
python3 scripts/delegation-report.py
git diff --check
```

**Phase acceptance:** the named deterministic case fails on the untouched
source with exit `75`, passes after the repair with one deposit/no lock, every
individual simultaneous writer exits zero, all 52+ focused cases pass, the
complete 733+ suite passes, and unsafe replacements remain fatal.

### Phase 2 — Resolve identity contract and prevent recurrence (3 pts)

**Delegation: subagent — implement the resolved D-4 policy and hermetic
merge-event coverage; no live refs, pushes, or history mutation.** Receive the
confirmed D-4 outcome; `docs/tickets/pending/git-identity-enforcement.md`;
workflow lines 8-49; checker modes; the tracked digest design; and the six
redacted offending hashes. Own the tracked opt-in, checker, extracted CI
dispatcher/workflow, their near-miss fixtures, and the prior-ticket/README
reconciliation. Never read or print raw tuple values. Return in at most 40
lines: files
changed; commands plus exit codes; red-first event-topology evidence;
focused/full counts; exact fixture graph; blockers.

> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

Implement only the non-destructive checker/workflow/tooling/docs policy. The
pull-request and push topology tests, Bats, shell syntax,
deck coupling if applicable, and public-repo hygiene gate classes apply. The
orchestrator repeats every gate and commits the slice before any shared-history
operation.

**Gate classes:** shell scripts, Bats suite, config-gated additivity,
public-repo hygiene, delegation contract. Deck coupling applies only if skill
frontmatter or `GENERIC_SKILLS` changes; neither is expected.

**Exact verification:**

```bash
bats tests/git-identity-enforcement.bats
bash -n scripts/check-git-identity.sh scripts/check-git-identity-ci.sh \
  install.sh .githooks/pre-commit .githooks/pre-push
bats --filter 'workflow executes PR and GitHub merge push identity contracts' \
  tests/git-identity-enforcement.bats
bash scripts/check-git-identity.sh --all HEAD --project .
bats tests/
bash -n install.sh agents/lib/*.sh agents/*/runner.sh \
  agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit \
  .githooks/pre-push
python3 -m py_compile scripts/gen-deck-data.py
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bash scripts/check-deck-complete.sh
bash scripts/ticket-lifecycle.sh --project . --check
python3 scripts/delegation-report.py
git diff --check
```

The configured system tuple stays redacted. All merge behavior tests use
fixture repositories; no test reaches GitHub or mutates a live ref.

**Phase acceptance:** the executed PR-to-push fixture fails on the pre-change
contract and passes under the selected D-4 contract, arbitrary wrong metadata
still fails, unset policy behavior is unchanged, focused 37+ and full 733+
tests pass, and no live ref/history/GitHub state changed.

### Phase 3 — Publish and prove GitHub CI (2 pts)

**Delegation: inline (canonical push and live GitHub verification are shared
remote-state operations the orchestrator must perform and inspect directly).**

No history rewrite or force-push is allowed. Publish the verified additive
commits through the existing canonical pre-push hook. Inspect the exact
`checks` and Pages run IDs to terminal state, record conclusions in the Ledger,
and leave the canonical checkout clean and synchronized with `origin/main`.

Before publication, require a clean `main` checkout, record
`git ls-remote origin refs/heads/main`, fetch, and require the recorded remote
tip to equal `origin/main`. A concurrent update stops the push for rebase and
full re-verification; it is never overwritten.
After all local and live evidence is terminal green, update this ticket's
status to `Complete — built and verified 2026-08-03 CDT`, finish its Ledger,
run `bash scripts/ticket-lifecycle.sh --project . --graduate
docs/tickets/pending/restore-github-ci-integrity.md`, repeat lifecycle/leak/diff
checks against the staged move, and include that graduation in the final
canonical commit before publication.

**Gate classes:** shell scripts, Bats suite, public-repo hygiene, delegation
contract, live GitHub publication. There is no served-app/systemd/event-stream
gate.

**Exact verification:**

```bash
bash scripts/check-git-identity.sh --all main --project .
git fsck --full
bats tests/
bash -n install.sh agents/lib/*.sh agents/*/runner.sh \
  agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit \
  .githooks/pre-push
python3 -m py_compile scripts/gen-deck-data.py
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bash scripts/check-deck-complete.sh
node scripts/check-deck-render.mjs
bash scripts/ticket-lifecycle.sh --project . --check
python3 scripts/delegation-report.py
git diff --check
published_sha="$(git rev-parse main)"
checks_run_id="$(gh run list --commit "$published_sha" --workflow checks.yml \
  --limit 1 --json databaseId --jq '.[0].databaseId')"
test -n "$checks_run_id"
gh run watch "$checks_run_id" --exit-status
gh run view "$checks_run_id" --json status,conclusion,headSha,jobs
gh run list --commit "$published_sha" --workflow pages-build-deployment \
  --limit 1 --json databaseId,status,conclusion,headSha
git status --short --branch
```

Deck render exit `3` is the only permitted skip. **Phase acceptance:** the
candidate passes all-history identity under the explicit merge exemption; all
733+ local tests and other gates pass; exact GitHub `checks` and Pages runs for
the published SHA are terminal success; `main`, `origin/main`, and the clean
canonical checkout agree.

## Testing Strategy

- Focused mailbox regression:
  `bats tests/codex-feedback-delivery.bats`, including a deterministic
  validation-to-generation owner-release case and per-writer status assertions.
- Focused identity/workflow regression:
  `bats tests/git-identity-enforcement.bats`, including executed PR/merge/push
  topologies for the selected D-4 contract.
- Canonical repository gate: `bats tests/`.
- Shell syntax, leak firewall, deck freshness/completeness, lifecycle, and
  optional render gates as declared in `.agents/gates.md`.
- Live evidence: terminal GitHub `checks` success for the exact published SHA;
  Pages is checked and reported independently.

## Acceptance Criteria / Definition of Done

- [ ] The deterministic owner-release reproduction that currently exits `75`
      exits `0`, deposits exactly once, and leaves no lock.
- [ ] Unsafe lock replacements, malformed generations, genuine wait exhaustion,
      and stale-owner recovery preserve their fail-closed contracts.
- [ ] The eight-writer test checks individual writer status and reliably yields
      eight valid, unique pending records without `ps`.
- [ ] D-4 is explicitly resolved and the implemented identity behavior exactly
      matches the recorded owner choice.
- [ ] The current six-commit all-history identity reproduction passes under the
      selected contract without silently exempting arbitrary branch commits.
- [ ] A hermetic PR-range plus final-merge push topology fails against the
      pre-change integration and passes after the repair.
- [ ] The prior identity ticket and README no longer contradict the supported
      merge path.
- [ ] `bats tests/`, syntax, leak, deck, lifecycle, delegation, and diff gates
      are green with exact exit codes recorded.
- [ ] GitHub's exact `checks` workflow for the published repaired SHA completes
      successfully; Pages status is separately recorded.
- [ ] The shared checkout is clean, on `main`, synchronized with `origin/main`,
      with no temporary worktree/branch or untracked diagnostic artifact.

## Ledger

Append exact phase evidence during execution. Never record canonical or
rejected email values in tracked text.

### Phase 1

- `builder: subagent (1 agent)`
- `plan:` add the deterministic lock-handoff regression and minimal retry-only
  repair; the orchestrator repeats every gate and commits the slice.
- `red-first:` deterministic owner-release case exited `1`; the contender
  returned `75` with the retry-required diagnostic and no second deposit.
- `commit:` pending
- `focused/full gates:` handoff/live-owner/successor matrix `4/4`; complete
  feedback file `53/53`; repository Bats `734/734`; shell syntax, Python
  bytecode, leak, deck freshness/completeness, lifecycle, delegation, and diff
  checks all exited `0` under independent orchestrator reruns.
- `notes/blockers:` all eight writer PIDs are now asserted individually. The
  retry classifier accepts only an absent lock or a fully safe successor;
  symlink, non-directory, unsafe-mode, and uninspectable states remain fatal.

### Phase 2

- `builder: subagent (1 agent)`
- `plan:` implement the digest-gated two-parent merge exemption, executable CI
  event topology, and policy documentation; the orchestrator repeats every
  gate and commits the slice.
- `decision: D-4 Option B — native GitHub web merges with narrow digest policy`
- `red-first:` pending
- `commit:` pending
- `focused/full gates:` pending
- `notes/blockers:` pending

### Phase 3

- `builder: inline (canonical push/live GitHub state must be performed and
  inspected directly by the orchestrator)`
- `remote preflight:` pending
- `published SHA:` pending
- `GitHub checks / Pages:` pending
- `notes/blockers:` pending

## Dependencies

- Blocked by: None.
- External state: GitHub Actions and remote `main`.
- Blocks: a trustworthy green `main` CI baseline and any subsequent merge whose
result would otherwise inherit the red all-history audit.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Normal handoff retry accidentally accepts a hostile replacement | Re-validate inode kind/ownership/mode before retry and retain deterministic symlink/non-directory failure tests |
| A broad identity exception turns the guard into theater | Require explicit D-4 choice, config-gate any revision, and pin rejected near-miss merge fixtures |
| A future GitHub system tuple changes | The exact digest fails closed; update it through a reviewed policy commit after verifying the new tuple instead of widening matching logic |
| Another web merge immediately makes CI red | Execute the real PR-to-push topology in Bats and prove the published all-history audit accepts only the configured two-parent merge case |
| Local green is mistaken for incident closure | Completion requires the exact terminal GitHub run for the published SHA |

## Out of scope

- Weakening unrelated repository gates or treating Pages success as CI success.
- Retrying the full Bats workflow until the mailbox race happens not to fire.
- Changing mailbox persistence format, lease duration, feedback schema, or
  cross-harness delivery semantics.
- Rewriting any published commit or force-pushing `main`.
- Adding GitHub organization/Enterprise governance unavailable to this personal
  repository.

Execution is active through
`execute-ticket docs/tickets/pending/restore-github-ci-integrity.md`.
