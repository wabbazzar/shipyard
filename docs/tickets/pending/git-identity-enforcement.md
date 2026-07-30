# Enforce Shipyard's public Git identity

- **Created:** 2026-07-30
- **Owner:** wabbazzar
- **Status:** pending — polished, auto-gate ready
- **Priority:** urgent
- **Type:** feature
- **Estimated Points:** 8 (P1 3 · P2 3 · P3 2)
- **Refs:** `.githooks/pre-commit`, `.githooks/pre-push`,
  `.github/workflows/checks.yml`, `install.sh`, `.agents/config.toml`,
  `.shipyard-git-identity.toml`, `.agents/gates.md`

## Goal

Remove non-canonical author and committer identities from Shipyard's published
`main` history, then enforce one owner-approved identity across local commits,
pushes, CI, and GitHub branch governance. The canonical email remains in
repository-local/GitHub configuration rather than tracked files so the public
source does not create a second identity disclosure surface.

Completion means the raw `%an`, `%ae`, `%cn`, and `%ce` values of every commit
reachable from GitHub `main` exactly match the owner-confirmed identity; local
creation and publication paths reject every other value; GitHub `main` is
PR-only with the identity check required and no bypass actor; and the paused
Aurora-blocking `ar-codex` tree is restored byte-for-byte.

## Context and pointers

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

Authoritative implementation surfaces:

- `scripts/leak-check.sh:36-59` — tracked-content firewall; it does not inspect
  Git objects and cannot enforce this contract.
- `.githooks/pre-commit:1-29` — pending-commit gate entry point.
- `.githooks/pre-push:7-30` — receives every pushed ref update; identity must
  block before its best-effort deck cascade.
- `.github/workflows/checks.yml:1-50` — current shallow CI surface.
- `install.sh` and its existing `--dry-run`/`--doctor` paths — fresh-checkout
  hook and policy setup/audit.
- `.agents/config.toml:10-13` — ignored local project-owner metadata;
  machine-specific `.agents/**` cannot be the tracked CI policy surface.
- `.shipyard-git-identity.toml` — dedicated tracked, non-sensitive opt-in
  policy shared by fresh clones, hooks, installer/doctor, and CI.
- `.agents/gates.md` — exact per-phase repository gates and incident traps.
- named stash `ar-codex Phase 1 paused for owner-authorized identity rewrite
  2026-07-30` — immutable recovery source for the priority shared-tree work.

No sibling repository source, service, event stream, model call, served port,
skill frontmatter, or generated deck input is in scope. `install.sh` is
fleet-live, so its unset-policy behavior must remain byte-identical and all
work/commits occur in this canonical checkout on `main`.

## Decisions

### Locked decisions

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

### Open decisions

None.

### User-decision class

None. The owner explicitly authorized the one history rewrite,
`--force-with-lease` publication, GitHub governance change, and exact canonical
identity. The canonical address must be read from effective Git configuration
and written only to repository-local Git configuration/GitHub Actions state,
never copied into this ticket or another tracked file.

**Auto-gate: PROCEED.**

## Technical Requirements

### Canonical policy without a tracked personal email

- Add a tracked root `.shipyard-git-identity.toml` containing only the opt-in
  `[git_identity]` behavior (`enforce = true`) and canonical public name.
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

## Polishing Baseline

Measured 2026-07-30 from the canonical checkout:

```text
$ bats --version
Bats 1.10.0
$ gh --version | head -1
gh version 2.83.2 (2025-12-10)
$ git --version
git version 2.43.0
$ python3 --version
Python 3.12.3
$ jq --version
jq-1.7
$ command -v actionlint
exit 1 (absent)
$ gh auth status -h github.com
exit 0
$ git rev-list --count main
243
$ <raw four-field audit using effective Git identity>
6 non-canonical commits
$ gh api repos/wabbazzar/shipyard/rulesets --jq 'length'
0
$ gh api repos/wabbazzar/shipyard/branches/main/protection
exit 1 (no branch protection)
```

The full pre-polish suite was `523/523` green; leak, lifecycle, syntax,
Python-bytecode, deck freshness/completeness/render, and diff checks were also
green. The new ticket was staged before the content-only leak gate so it was
actually inspected. `actionlint` is not installed, so workflow syntax/shape
must have hermetic tests and the pushed workflow must be proven by the real
GitHub Actions run; no local substitute may be described as CI evidence.

## Implementation Plan

The builder is the orchestrator: delegate the bounded code slices below, keep
shared-state/destructive operations inline, and personally re-run every named
gate before each commit. Work only on `main` in this canonical checkout.

### Phase 1 — Deterministic raw identity checker (3 pts)

**Delegation: subagent — checker and regression owner.** Assume the locked
policy and exit-code contract in this ticket. Work only in the new
`scripts/check-git-identity.sh`, new `tests/git-identity-enforcement.bats`, and
small fixture helpers in `tests/helpers.bash` when strictly required. First
create the test `git identity: existing pre-push accepts a wrong author` and
record its expected success against pre-change code as the captured defect;
then add tests that must fail until the checker exists. Implement current,
explicit-range, complete-history, and pre-push-stdin modes without mailmap
normalization. Return in at most 40 lines: files changed; commands and exit
codes; captured-defect line; final focused test count; representative redacted
diagnostic; blockers. Converge honestly or report the precise blocker with the
actual evidence — NEVER fake green, weaken a check, or hand-wave "should work".
Run the real command, read the real file, curl the real port, and report exact
output (exit codes, JSONL lines, HTTP codes), not adjectives.

The checker reads the canonical public name from
`[git_identity].name` in `.shipyard-git-identity.toml` and the canonical email
from the repository-local `shipyard.identityEmail` Git key. `enforce = true`
requires both. Its modes are:

- `--current --project <path>`: compare `git var GIT_AUTHOR_IDENT` and
  `GIT_COMMITTER_IDENT`;
- `--range <rev-range> --project <path>`: validate every commit produced by
  `git rev-list <rev-range>`; the flag may repeat and commits are de-duplicated;
- `--all <rev> --project <path>`: validate every commit reachable from `<rev>`;
- `--pre-push <remote-name> <remote-url> --project <path>`: consume standard
  four-field pre-push lines on stdin, ignore deletes, union every update, and
  fail closed on malformed/missing objects. Existing refs inspect
  `remote-sha..local-sha`; a new ref inspects the local tip excluding commits
  reachable from locally advertised tracking refs for that remote, and audits
  all reachable commits when no such refs exist.

All four raw fields are compared exactly. Exit `0` means every inspected value
matches, `1` means mismatch, and `2` means invocation/config/range failure.
Diagnostics name the hash and field but redact email values; tests assert that
neither fixture address appears in stdout/stderr.

#### Verification surface

Before implementation, use the hermetic fixture to run the real old hook and
record the defect:

```bash
bats --filter 'git identity: existing pre-push accepts a wrong author' \
  tests/git-identity-enforcement.bats
```

After implementation, the same file must cover author name/email and committer
name/email separately, combinations, mixed ranges, merge commits, repeated
ranges, multiple ref lines, new refs with/without tracking refs, deletes,
missing/shallow endpoints, missing/malformed policy, empty input, exact exit
codes, and redaction. Run:

```bash
git add -N scripts/check-git-identity.sh \
  tests/git-identity-enforcement.bats
bash -n scripts/check-git-identity.sh
bats tests/git-identity-enforcement.bats
set +e
bash scripts/check-git-identity.sh --all HEAD --project .
test "$?" -eq 2
set -e
bats tests/
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bash scripts/check-deck-complete.sh
node scripts/check-deck-render.mjs
bash -n install.sh agents/lib/*.sh agents/*/runner.sh \
  agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit \
  .githooks/pre-push
python3 -m py_compile scripts/gen-deck-data.py
bash scripts/ticket-lifecycle.sh --project . --check
python3 scripts/delegation-report.py
git diff --check
```

Deck render exit `3` is the documented Playwright skip; every other command
must exit `0`. The phase DoD is the focused Bats file green, a policy-configured
fixture naming its intended offending hashes with email values redacted, the
live repository returning fail-closed exit `2` because Phase 2 has not yet
enabled tracked policy, and every remaining applicable gate green. Commit only
the checker/tests/ticket Ledger as one canonical-identity commit.

### Phase 2 — Local, CI, and install/doctor enforcement (3 pts)

**Delegation: subagent — hook/CI/installer owner.** Begin from the committed
Phase 1 checker. Own `.githooks/pre-commit`, `.githooks/pre-push`,
`.github/workflows/checks.yml`, `install.sh`, the new tracked
`.shipyard-git-identity.toml`, focused tests, and only the existing setup
documentation that must describe the external policy. Do not touch GitHub
state, history, the named stash, or Aurora-phase files. Preserve the pre-push
deck cascade as non-blocking after identity succeeds. Prove a project without
the tracked policy has pre-change installer behavior. Return in at most 40
lines: files changed; commands with exit codes; focused/full Bats counts;
dry-run/doctor observations; workflow assertions; blockers. Converge honestly
or report the precise blocker with the actual evidence — NEVER fake green,
weaken a check, or hand-wave "should work". Run the real command, read the real
file, curl the real port, and report exact output (exit codes, JSONL lines, HTTP
codes), not adjectives.

Add `.shipyard-git-identity.toml` with `[git_identity] enforce = true` and
`name = "wabbazzar"` for this project. Add:

```text
install.sh --configure-git-identity --project <path>
```

It reads the effective `user.name`/`user.email`, rejects a name different from
`project_owner`, writes both `user.*` and `shipyard.identityEmail` to the
target repository's local config, sets `core.hooksPath=.githooks`, invokes the
current-identity check, and logs only the name plus a redacted-email marker.
`--doctor` audits those keys/hook path only when the tracked policy exists with
`[git_identity].enforce=true`; an absent policy file is exactly the prior
behavior.

Pre-commit calls `--current` before content/deck gates. Pre-push calls
`--pre-push "$1" "$2"` with its stdin before the best-effort mirror. CI uses
`actions/checkout` with `fetch-depth: 0`; a dedicated job checks
`base-sha..head-sha` on pull requests and `--all HEAD` on `main`, sourcing only
the GitHub Actions variable `SHIPYARD_IDENTITY_EMAIL` into a temporary local Git
key. Missing event SHAs, full history, variable, or policy must fail.

#### Verification surface

Add focused hermetic cases named for pending author/committer rejection,
pre-push multi-ref/new-ref rejection, deck-cascade ordering, configure success
and redaction, doctor missing/mismatch/success, unset-project invariance, and
full-depth/workflow event ranges. New-file leak checks are staged/add-intent
before execution; prose assertions fit on one source line; every guard case is
shown passing against the pre-change file before edits.

```bash
bash -n install.sh scripts/check-git-identity.sh \
  .githooks/pre-commit .githooks/pre-push
bats tests/git-identity-enforcement.bats
bats tests/install.bats
bash install.sh --dry-run --project .
bash install.sh --configure-git-identity --project .
bash install.sh --doctor --project .
bash .githooks/pre-commit
printf '' | bash .githooks/pre-push origin \
  "$(git remote get-url origin)"
bats tests/
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bash scripts/check-deck-complete.sh
node scripts/check-deck-render.mjs
bash -n install.sh agents/lib/*.sh agents/*/runner.sh \
  agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit \
  .githooks/pre-push
python3 -m py_compile scripts/gen-deck-data.py
bash scripts/ticket-lifecycle.sh --project . --check
python3 scripts/delegation-report.py
git diff --check
```

Deck render exit `3` alone is an allowed skip. The phase DoD is that a fresh
opted-in fixture fails doctor before configuration and passes after; wrong
pending and pushed metadata are blocked before downstream hook behavior; the
unset fixture is byte-identical; workflow tests prove full checkout and exact
event ranges; real local configure/doctor pass without exposing the address;
and all repository gates are green. Commit the wiring/tests/docs/ticket Ledger
as one canonical-identity commit.

### Phase 3 — Rewrite, server enforcement, and handback (2 pts)

**Delegation: inline (the orchestrator alone must perform destructive shared
history, live GitHub governance, secret configuration, and cross-session tree
restoration).** Before every mutation, inspect `git status`, the current
`ar-codex` tmux acknowledgement, the named stash object, and remote `main`.
Never ask a subagent to operate the shared index/ref namespace. Converge
honestly or report the precise blocker with the actual evidence — NEVER fake
green, weaken a check, or hand-wave "should work". Run the real command, read
the real file, curl the real port, and report exact output (exit codes, JSONL
lines, HTTP codes), not adjectives.

Create immutable refs under `refs/backup/identity-rewrite-20260730/` for local
pre-rewrite `main`, remote pre-rewrite `main`, and the named stash commit.
Record the six offending old hashes and use a deterministic parent-order walk
to recreate commits: only those six receive the canonical author and committer
name/email; every tree, message bytes, author/committer timestamp, parent order,
and all other raw headers remain unchanged except the `gpgsig` headers on the
two GitHub-signed merge commits whose committer bytes are being corrected.
Those signatures cannot remain cryptographically valid after the rewrite and
must be removed rather than retained as misleading invalid signatures. Move
`main` only after the complete candidate graph passes comparison. Record the
full old→new map in the Ledger, without email values.

Restore the named stash with `apply`, do not pop/drop it, reset the two
new-file index entries and return them to intent-to-add, then compare these
pre-recorded SHA-256 values:

```text
805f95c6b01faa608c7a84324d7a66a67517d2095b315fa4802164b785b6515f  agents/release/critic-codex-feedback.sh
96292d73d356f2976979fc88a7fca020a095b671c1b194f30f21e2b811fe5517  agents/release/critic-note.sh
8f48c8f5adec2c186a4cf8492f4aa9fd814ca75545be4138c25063eeb7e2de66  agents/release/critic-queue-lib.sh
8e2b313f770f178753ff66dd1a3747d67d40db737a22021a2ddc380e92d31269  agents/release/critic-watch.sh
e0abba89a9f0fd69c52f985768c2e96472cc18db0fb83afc28d7bd037a00410b  docs/tickets/pending/codex-critic-in-band-delivery.md
3e3e354e049171ed3edd193a157ec075d3a1fe4c995796fe5156ab391685ebac  tests/codex-feedback-delivery.bats
fb4c54cd31b0cf616fece649765167834e80e2f0c2c014376ea00f5928d0d0b0  tests/shoulder-mode-harness.bats
6118485eb291e14b0dd8daac693d7f2016dad823c476f087735ccbac90915fe5  tests/shoulder-mode.bats
```

#### Verification and publication surface

With the priority tree still safely stashed, prove the old/new lists have equal
length and, pairwise, equal tree ID, exact message bytes, author/committer
timestamps, and ordered parent-map topology. Prove the identity fields differ
only on the six recorded objects and every new commit passes:

```bash
bash scripts/check-git-identity.sh --all main --project .
git fsck --full
bats tests/
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bash scripts/check-deck-complete.sh
node scripts/check-deck-render.mjs
bash -n install.sh agents/lib/*.sh agents/*/runner.sh \
  agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit \
  .githooks/pre-push
python3 -m py_compile scripts/gen-deck-data.py
bash install.sh --doctor --project .
bash scripts/ticket-lifecycle.sh --project . --check
python3 scripts/delegation-report.py
git diff --check
```

Record `git ls-remote origin refs/heads/main` immediately before publication
and require it to equal the saved lease. Push once:

```bash
git push --force-with-lease=refs/heads/main:<saved-remote-hash> origin \
  main:refs/heads/main
```

Then verify `git ls-remote`, GitHub's commit API raw author/committer fields,
and terminal success for the exact `checks` and Pages workflow run IDs.
Configure `SHIPYARD_IDENTITY_EMAIL` without printing its value. Use the GitHub
API to create active `main` governance requiring PRs and the exact identity
status context, with empty bypass actors and exact author/committer email
metadata restrictions; re-read and archive the returned JSON shape in the
Ledger with sensitive values redacted.

Create a disposable bad-identity branch/PR and a disposable canonical
branch/PR using only temporary refs. The bad web/no-reply final metadata must be
rejected server-side, while the locally constructed canonical PR-associated
merge path must be accepted without a bypass. Delete temporary remote refs
only after recording results. If the plan/API cannot express both behaviors,
restore the prior non-deadlocking governance shape, retain the local/CI guard
and rewritten history, and stop with the exact HTTP status/message. Never
enable bypass or widen the allowlist.

Only after remote identity, CI, governance, and both disposable probes pass:
apply the named stash, restore its original index shape, verify all eight
checksums and `git status`, send the exact `AUTHOR_REWRITE_RELEASED` handback to
`ar-codex`, and keep the stash/backup refs until owner acceptance. Phase DoD is
the rewritten remote and API audit green, both governance probes behaving as
specified, all checks green, and the priority tree restored byte-for-byte. A
server-capability failure is an honest blocked terminal condition, not a
partial-green completion.

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
- [ ] Each phase is one verified canonical-identity commit; the ticket is
      graduated deterministically; the final shared worktree is either the
      exactly restored `ar-codex` tree or clean after that work is committed.

## Ledger

Append exact evidence during execution. Never record the canonical or rejected
email value in tracked text.

### Phase 1

- `builder: subagent (1 agent)`
- `plan:` add the raw checker and hermetic red-first coverage only; the
  orchestrator will re-run every Phase 1 gate and commit the slice.
- `commit:` `c41dde89e74e60029999710c3cbd5cf1a4fb2146`
- `red-first:` unchanged pre-push accepted a wrong author (`1/1`, exit `0`).
- `focused/full gates:` checker Bats `25/25`; repository Bats `548/548`;
  syntax, leak, deck freshness/completeness/render, lifecycle, delegation,
  Python bytecode, and diff checks exit `0`.
- `notes/blockers:` the live repository audit correctly exits `2` before the
  Phase 2 tracked policy exists; policy-configured fixtures cover all raw
  fields/ranges and redact both allowed and rejected addresses.

### Phase 2

- `builder: subagent (1 agent)`
- `plan:` wire the committed checker through config, installer/doctor, hooks,
  CI, and focused documentation/tests; the orchestrator will re-run all gates.
- `commit:` pending
- `focused/full gates:` identity Bats `37/37`; repository Bats `560/560`;
  installer/hook regression subset `47/47`; syntax, leak, YAML parse, deck,
  lifecycle, delegation, Python bytecode, and diff checks exit `0`.
- `configure/doctor evidence:` live configure printed
  `name=wabbazzar email=<redacted>`; doctor, pending hook, and empty pre-push
  hook exit `0`; full history audit exits `1` with six unique hashes and no
  address value in diagnostics.
- `notes/blockers:` the ignored, machine-specific `.agents/config.toml` cannot
  be a CI policy source; policy moved to tracked, non-sensitive
  `.shipyard-git-identity.toml`. Projects without that file remain unchanged.

### Phase 3

- `builder: inline (destructive shared history, GitHub governance, secret
  state, and priority-tree restoration)`
- `plan:` commit Phase 2; create immutable backup refs; recreate and compare the
  graph; publish under the recorded lease; verify remote CI/API/governance
  probes; then restore and release the paused priority tree.
- `commit/map:` pending
- `old/new equivalence:` pending
- `force-with-lease and remote:` pending
- `GitHub rules/probes/workflows:` pending
- `stash/index/checksums/handback:` pending
- `notes/blockers:` pending

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

## Handoff

Run this ticket end-to-end with `execute-ticket`. With no open decision, the
polish auto-gate proceeds immediately; execution stops only on a proven
user-decision/server-capability blocker and otherwise graduates this ticket
with `bash scripts/ticket-lifecycle.sh --project . --graduate
docs/tickets/pending/git-identity-enforcement.md`.
