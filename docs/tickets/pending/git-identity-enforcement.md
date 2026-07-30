# Enforce Shipyard's public Git identity

- **Status:** pending — draft ready for polish
- **Priority:** urgent
- **Type:** feature
- **Estimated Points:** 8 (P1 3 · P2 3 · P3 2)

## Summary

Remove non-canonical author and committer identities from Shipyard's published
`main` history, then enforce one owner-approved identity across local commits,
pushes, CI, and GitHub branch governance. The canonical email remains in
repository-local/GitHub configuration rather than tracked files so the public
source does not create a second identity disclosure surface.

## Problem / Background

The Workmac bootstrap bundle was valid and its changes passed the repository
gates, but four cherry-picked commits retained their original work-machine
author name and work-domain email. The local pre-commit hook ran
`scripts/leak-check.sh --staged`, yet that check enumerates file paths and
contents (`scripts/leak-check.sh:36-59`), not commit-object author or committer
metadata. The invalid identity therefore reached public `main`.

A complete raw-history audit found six non-canonical commits among 242:

- four Workmac commits have a non-canonical author name and work-domain email;
- two older pull-request merge commits have GitHub's system committer identity.

All other reachable commits use the owner-confirmed canonical author and
committer name plus the same owner-confirmed personal email. The current
effective checkout identity comes from global Git configuration; the
repository itself records only `project_owner = "wabbazzar"`
(`.agents/config.toml:10-13`) and has no deterministic commit-identity
contract.

The existing local enforcement surfaces are incomplete:

- `.githooks/pre-commit:1-29` checks staged file contents and deck completeness
  but does not validate the pending author or committer identity.
- `.githooks/pre-push:7-30` consumes pushed ref updates but is deliberately
  non-blocking and only drives deck mirroring.
- `.github/workflows/checks.yml:1-50` runs on `main` pushes and pull requests,
  but checkout depth defaults to one commit and no job inspects raw commit
  metadata.
- `.git/config` enables `.githooks` only in this checkout; `install.sh` does
  not establish or audit hook activation for a fresh Shipyard checkout.
- GitHub currently has no ruleset or branch protection on `main`, so a local
  hook can be bypassed and CI observes a direct push only after publication.

GitHub documents that web-created merges use a GitHub no-reply committer and
that exact committer-email restrictions must account for that identity. This
ticket intentionally does not: the owner confirmed one exact author and
committer identity. Therefore the final governance must reject web-created
merge metadata and retain an auditable PR-associated merge path that creates
the final commit locally with the canonical identity. If the repository plan
cannot enforce that server-side contract, completion is blocked rather than
silently widening the allowlist.

## Confirmed decisions

| # | Decision | Locked value | Why |
|---|---|---|---|
| D-1 | Canonical name | `wabbazzar` for both author and committer | Explicit owner confirmation; aliases are not accepted. |
| D-2 | Canonical email | One owner-confirmed personal address, stored outside tracked files | The address is already public in commit objects, but duplicating it in source violates Shipyard's public-file hygiene rule. |
| D-3 | Coverage | Validate both names and both emails from raw commit objects, without mailmap rewriting | Display-only normalization would leave the underlying metadata leak intact. |
| D-4 | History scope | Rewrite every reachable non-canonical commit, currently six, not only the four newly imported commits | The exact allowlist must be true for all of `main`, not just the latest push. |
| D-5 | Local enforcement | Blocking pre-commit plus blocking pre-push, installed/audited for opted-in Shipyard checkouts | Pre-commit gives fast feedback; pre-push closes bypasses and multi-commit/range gaps before publication. |
| D-6 | Server enforcement | PR-associated changes only, required identity status check, no bypass actor | A local hook alone cannot prevent `--no-verify` or another clone from publishing bad metadata. |
| D-7 | Failure posture | Missing policy, missing range endpoint, shallow history, malformed metadata, or unsupported GitHub enforcement fails closed | Identity protection must never degrade to a warning or a vacuous green. |
| D-8 | Active work | Preserve the paused `ar-codex` Phase 1 tree byte-for-byte across the rewrite | The release-feedback repair is the priority workload and must resume immediately on rewritten history. |

## Technical Requirements

### Canonical policy without a tracked personal email

- Add an opt-in `[git_identity]` section to Shipyard's project config containing
  only non-sensitive behavior (`enforce = true`) and the canonical public name.
- Store the canonical email in repository-local Git configuration and in a
  GitHub Actions repository variable. The checker must fail closed when either
  surface is absent.
- Add a deterministic configuration command that sets the local policy from an
  explicitly supplied/effective identity, verifies the name against
  `project_owner`, installs `core.hooksPath=.githooks`, and prints only a
  redacted email result.
- Extend `install.sh --doctor --project .` to report missing/mismatched identity
  policy or hook activation when the opt-in is enabled. Projects without the
  section retain byte-identical behavior.

### Raw commit checker

- Add `scripts/check-git-identity.sh` with explicit modes for:
  - the pending commit identity (`git var GIT_AUTHOR_IDENT` and
    `GIT_COMMITTER_IDENT`);
  - one or more revision ranges supplied by pre-push/CI;
  - complete reachable `main` history for post-rewrite and scheduled audits.
- Read raw `%an`, `%ae`, `%cn`, and `%ce` fields; do not use `.mailmap`,
  `%aN/%aE/%cN/%cE`, GitHub display attribution, or co-author trailers as a
  substitute.
- Emit the offending commit hash and field name with the value redacted enough
  to avoid copying a disallowed address into logs. Return `0` only when every
  inspected field matches; return `1` on a mismatch and `2` on bad
  invocation/config/range.
- Pre-push must inspect every non-delete ref update. Existing refs use
  `<remote-sha>..<local-sha>`; new refs must exclude commits already reachable
  from advertised remote refs rather than passing the all-zero SHA to Git.
  Multiple ref lines must be unioned without skipping commits.

### Hook, CI, and GitHub governance

- Invoke pending-identity mode from `.githooks/pre-commit` before other gates.
- Make `.githooks/pre-push` block on identity failure before the existing
  best-effort deck cascade. Preserve deck no-op/failure as non-blocking.
- Add a dedicated required GitHub Actions job with `fetch-depth: 0`. On pull
  requests it checks every introduced head commit; on `main` it audits complete
  reachable history so a bypass cannot create a false green.
- Configure the GitHub repository variable for the canonical email without
  printing it.
- Create active, no-bypass governance for `refs/heads/main` requiring a pull
  request and the identity status check. Add exact server-side author and
  committer email restrictions if the repository plan exposes them.
- Validate the actual merge path with a disposable canonical PR. The accepted
  final `main` commit must have the exact canonical author and committer fields;
  a GitHub web merge with no-reply committer metadata must be rejected. If this
  is impossible under the available GitHub plan, stop with the API response and
  do not claim complete enforcement.

### Published-history rewrite

- Create immutable local backup refs for the pre-rewrite `main` and paused
  Phase 1 stash. Record remote `main` immediately before publication.
- Rewrite only metadata: every commit tree, parent topology, subject/body,
  author/committer dates, and ordering must remain unchanged except where
  descendant hashes necessarily change.
- Set both author and committer identity on all six non-canonical commits to the
  confirmed canonical values. Preserve already-canonical identities on every
  other commit.
- Prove old and rewritten histories have identical ordered tree hashes,
  messages, dates, and parent counts; prove all reachable raw identities match.
- Restore the Phase 1 stash without consuming its backup, restore its original
  intent-to-add index shape, and verify the eight recorded file checksums.
- Publish once with `--force-with-lease` against the recorded remote hash, then
  verify GitHub's raw commit API and CI before releasing `ar-codex`.

## Implementation Plan

### Phase 1 — Deterministic raw identity checker (3 pts)

Build the policy reader and raw commit checker, including current-identity,
revision-range, multi-ref, new-ref, delete, and full-history behavior. Add
hermetic Git fixtures that demonstrate the current pre-push path accepts a
wrong author before the change.

Files: new `scripts/check-git-identity.sh`, new
`tests/git-identity-enforcement.bats`, focused helper additions if required.

High-level proof: Bats red-first, shell execution, and public-hygiene gate
classes. Cover author name/email and committer name/email independently,
mixed-good/bad ranges, merge commits, zero-SHA ref cases, malformed policy, and
redacted diagnostics.

Delegation: subagent — implement the checker and hermetic regression surface;
return files, red/green case names, exact exits, and blockers.

### Phase 2 — Local, CI, and install/doctor enforcement (3 pts)

Wire the checker into pre-commit, blocking pre-push, full-depth Actions, and the
opt-in Shipyard install/doctor path. Add the external repository variable
contract and document the canonical setup/PR-associated merge workflow without
printing the personal email.

Files: `.githooks/pre-commit`, `.githooks/pre-push`,
`.github/workflows/checks.yml`, `install.sh`, `.agents/config.toml`, existing
README/install documentation, and focused hook/installer tests.

High-level proof: Bats, shell, config-gated additivity, installer dry-run/doctor,
workflow-shape, leak, and full repository gate classes. Prove unset projects
are unchanged and a fresh opted-in Shipyard checkout cannot pass doctor until
its external policy and hooks are configured.

Delegation: subagent — implement hook/CI/installer wiring and focused tests
without modifying live GitHub governance; return files, generated outputs,
exact exits, and blockers.

### Phase 3 — Rewrite, server enforcement, and handback (2 pts)

Create backup refs, rewrite all six non-canonical commits, verify metadata-only
equivalence, restore the paused Phase 1 tree, force-with-lease the single
rewritten history, configure active no-bypass GitHub governance, and prove a
real canonical PR path plus required CI. Release `ar-codex` only after its
checksums and index state match the recorded snapshot.

Files/state: Git commit graph and local backup refs; GitHub Actions variable,
ruleset/branch governance, repository merge settings; no Phase 1 source edits.

High-level proof: history-equivalence, raw-identity, stash-integrity, full local
gate, force-with-lease, GitHub raw-API, required-check, ruleset, rejected bad
identity, accepted canonical PR, and post-push CI evidence.

Delegation: inline (published-history rewrite, owner GitHub governance, and
cross-session worktree restoration are destructive shared-state operations the
orchestrator must personally verify).

## Testing Strategy

- Demonstrate the new Bats regression fails against pre-change `main` because
  the real pre-push hook accepts a commit with one wrong metadata field.
- Test all four identity fields independently, plus combinations, merge
  commits, multiple pushed refs, new refs, deletions, historical commits outside
  the pushed range, shallow/missing ranges, missing policy, and diagnostic
  redaction.
- Run the real pre-commit and pre-push hooks in hermetic local bare repositories;
  tests must never contact GitHub or a model.
- Prove opt-in install/reinstall byte stability, doctor failure on missing
  identity configuration, doctor success after configuration, and exact
  unset-project invariance.
- Run `bats tests/`, the complete shell/Python syntax sweep, leak check, deck
  freshness/completeness/render, ticket lifecycle, installer dry-run/doctor,
  delegation report, and `git diff --check`.
- After the rewrite, compare every old/new commit's tree hash, message, author
  and committer dates, and parent count while permitting only the six intended
  identity changes and descendant hashes.
- Verify GitHub's raw commit API, required Actions job, active ruleset with an
  empty bypass list, rejection of a disposable bad-identity update, and
  acceptance of the canonical PR-associated merge path.

## Acceptance Criteria / Definition of Done

- [ ] Every commit reachable from published `main` has raw author and committer
      name `wabbazzar` and the owner-confirmed canonical email.
- [ ] No reachable commit or tracked file contains the work-domain email.
- [ ] The rewrite changes no tree, message, date, parent count, or topology
      beyond the six intended identity records and unavoidable descendant
      hashes.
- [ ] Pre-commit blocks a wrong pending author or committer before other gates.
- [ ] Pre-push blocks every wrong identity across existing refs, new refs,
      multiple ref lines, and merge commits while preserving non-blocking deck
      mirroring.
- [ ] CI fetches complete history, checks raw metadata on pull requests, audits
      all reachable `main`, and fails closed on missing policy/ranges.
- [ ] A fresh opted-in Shipyard install configures/audits `.githooks` and local
      identity policy; unset projects remain byte-identical.
- [ ] GitHub `main` requires a pull request and the identity check, has no bypass
      actor, rejects web/no-reply or other non-canonical metadata, and accepts
      the documented canonical PR-associated merge path.
- [ ] Hermetic red-first coverage exercises every raw identity field and all
      range/ref edge cases without network or model access.
- [ ] The paused `ar-codex` Phase 1 work is restored with all eight file
      checksums and intent-to-add states unchanged.
- [ ] Full local gates and post-rewrite GitHub CI/Pages are green.

## Boundaries

### Always

- Preserve active `ar-codex` work and retain recoverable backup refs/stash until
  the owner explicitly accepts the rewritten remote.
- Use raw Git metadata, exact comparisons, redacted diagnostics, and
  `--force-with-lease`.
- Fail closed when local policy, CI context, or server enforcement is missing.

### Ask first

- Any canonical identity change after this ticket.
- Any additional history rewrite after the verified six-commit remediation.
- Any GitHub governance change that relaxes PR association, required checks, or
  bypass restrictions.

### Never

- Never add a second allowed author/committer identity, including GitHub
  no-reply, to make web merges convenient.
- Never store the canonical personal email or disallowed work email in tracked
  source, tests, fixtures, logs, or ticket prose.
- Never replace raw-object validation with `.mailmap`, display attribution, or
  a warning-only check.
- Never introduce a new runtime dependency or a network/model call into local
  hooks/tests.
- Never discard or silently restage another agent's work.

## Dependencies

- Blocked by: availability of enforceable GitHub branch governance that can
  reject non-canonical final commit metadata while accepting a PR-associated
  locally created canonical merge.
- External state: GitHub Actions repository variable, ruleset/branch
  protection, and merge-method settings for `wabbazzar/shipyard`.
- Blocks: resumption and publication of the Codex release-feedback repair.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Rewriting six early commits changes nearly all descendant hashes | Create immutable backup refs, compare every commit pair by ordered semantic metadata/tree, use one force-with-lease publication, and retain backup refs through owner acceptance. |
| Paused Phase 1 work is lost or restaged | Named stash plus recorded file checksums/status before rewrite; apply without dropping, restore intent-to-add entries, and compare all eight hashes. |
| Local hooks are bypassed | Required PR and identity status check with no bypass; full-history audit on every `main` run. |
| GitHub web merge creates no-reply committer metadata | Server-side committer restriction plus a documented PR-associated local merge; prove both rejection and acceptance before completion. |
| GitHub plan lacks metadata restrictions | Stop with the exact API/plan evidence; do not widen the allowlist or claim full prevention. |
| Personal email appears in diagnostics or source | Store it only in local/GitHub configuration and redact all mismatch output; retain leak-check. |
| Rewrite races another push | Traffic stop, recorded remote lease, process audit, and immediate remote verification. |

## Out of scope

- A multi-user contributor allowlist or organization-wide identity policy.
- Rewriting forks, pull-request refs, GitHub caches, or commits not reachable
  from Shipyard `main`.
- Replacing the personal canonical email with a GitHub no-reply address.
- Signed-commit or DCO policy beyond exact author/committer metadata.
- General-purpose secret scanning or content-leak rules unrelated to Git
  identity.
