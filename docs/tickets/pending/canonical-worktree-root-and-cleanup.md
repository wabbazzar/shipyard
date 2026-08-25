# Canonical shared worktree root and safe routine cleanup

- **Created:** 2026-08-25
- **Owner:** wabbazzar
- **Status:** Draft — triaged; no implementation started
- **Priority:** high
- **Type:** chore
- **Estimated Points:** 10 across 3 phases (each ≤5)
- **Origin:** Aurora Ticket 060 master-agent intake

## Summary

Require project worktrees to live under one sibling `code/worktrees/<project>/` root instead of cluttering `code/` or nesting inside repositories, and add conservative routine cleanup that removes only worktrees proven safe to remove. Shipyard's fleet-live checkout remains the documented no-worktree exception.

## Problem / Background

Aurora currently configures `.agents/config.toml:35` with `worktree_dir = ".worktrees"`, while manually created ticket worktrees are scattered directly under the parent `code/` directory. Shipyard resolves the configured value as `$PROJECT_DIR/$WORKTREE_DIR_REL` in `agents/build/runner.sh:77-109`, and its crash cleanup only recognizes literal `/.worktrees/build-*` or `/.worktrees/medic-incident-*` paths at `agents/build/runner.sh:276-287`. Changing configuration alone would therefore move new crew worktrees but silently break cleanup.

The generic role tells agents to work at `$WORKTREE_DIR/build-<id>` and expects the runner to remove that worktree (`agents/build/role.md:77-87`), but there is no fleet policy for interactive/ticket worktrees, no canonical parent-root validation, and no safe stale-worktree audit. The live machine currently demonstrates both failure modes: many Aurora worktrees clutter the parent `code/` directory and two older ones remain nested under the repo.

Owner policy captured 2026-08-25: all ordinary project worktrees go under `code/worktrees`; cleanup runs routinely. Cleanup must not destroy dirty, locked, active, or unmerged work.

## Technical Requirements

- Add an optional configured shared-root contract whose unset value preserves today's behavior exactly. A project can resolve a parent-relative value such as `../worktrees/<project>` without any owner-specific absolute path in this public repository.
- Validate the resolved worktree root before creation: it must be an explicit dedicated directory, must not equal a home directory, repository root, filesystem root, or broad parent, and must be namespaced by project.
- Update build/incident worktree creation and cleanup to use the resolved configured root rather than matching the literal `/.worktrees/` segment.
- Add a read-only hygiene inventory plus an explicit/apply cleanup mode. Routine apply may remove only a worktree that is registered, inside the validated root, not current/locked/active, clean, and whose work is safely retained (merged/reachable or runner-owned branch pushed/result recorded). Every other worktree is reported, never force-removed.
- Run `git worktree prune` only after exact-path removals and report its effects. Never use a recursive filesystem deletion as worktree cleanup.
- Installer/docs/skills must direct interactive ticket agents to `code/worktrees/<project>/<ticket>` and reserve paths during triage. Project configs opt in explicitly; the current installed fleet is migrated deliberately after dry-run evidence.
- Existing out-of-root worktrees are inventoried and moved with `git worktree move` only when inactive and path-safe. Dirty or active worktrees are deferred with their exact reason; Ticket 060 must not move while running.
- Shipyard itself remains the explicit exception in `CLAUDE.md:102-130`: its checkout is fleet-live and does not use branches/worktrees.

## Implementation Plan

### Phase 1 — resolved-root contract and runner behavior (4 pts)

Introduce the config-gated root resolver, path-safety validation, and runner-owned cleanup based on the resolved root. Add hermetic fixtures for default behavior, parent-relative roots, unsafe roots, crashes, dirty worktrees, and nonmatching projects.

**Files:** `agents/build/runner.sh`, shared path helper if warranted, `agents/build/role.md`, `tests/`.

**Gate classes:** shell scripts; bats suite; config-gated additivity; public-repo hygiene.

**Delegation: subagent — runner reviewer attacks unsafe path resolution and cleanup ownership with hermetic git topologies.**

### Phase 2 — routine hygiene command and installer guidance (4 pts)

Add read-only inventory and conservative apply modes, wire the canonical root through installer/config documentation and shared workflow instructions, and emit actionable findings for unsafe leftovers rather than deleting them.

**Files:** `install.sh`, a script under `scripts/` or shared helper under `agents/lib/`, relevant skills/docs/tests; generated deck only if coupling requires it.

**Gate classes:** shell scripts; bats suite; config-gated additivity; deck coupling if applicable; public-repo hygiene.

**Delegation: subagent — independent safety reviewer proves dirty, locked, active, unmerged, and out-of-root worktrees survive apply mode.**

### Phase 3 — fleet rollout and measured cleanup (2 pts)

Dry-run every installed project, opt each project into its `../worktrees/<project>` namespace, create the shared root, then move/remove only worktrees passing the safety contract. Record before/after inventories and retain explicit exceptions. Do not use a Shipyard worktree.

**Files:** installed project `.agents/config.toml` files and operational evidence; Shipyard core stays on its canonical main checkout.

**Gate classes:** shell scripts; bats suite; systemd user units if installer output changes; public-repo hygiene.

**Delegation: inline (fleet rollout mutates owner-local installs and requires one coordinating operator after the hermetic implementation is proven).**

## Testing Strategy

- `bats tests/` with red-first cases using `make_git_topology`; no test reaches a real owner repository, network, or model.
- Assert unset configuration retains project-local `.worktrees` behavior byte-for-byte.
- Assert configured roots resolve into a project namespace under a dedicated sibling root and reject broad/escaping/symlinked targets.
- Assert cleanup removes only safe exact paths and reports every dirty/locked/active/unmerged/out-of-root case without mutation.
- Run syntax, leak firewall, deck freshness/completeness, installer dry-run/doctor, and final real `git worktree list --porcelain` inventories.

## Definition of Done

- [ ] Every opted-in project creates new worktrees only under `code/worktrees/<project>/`.
- [ ] Build/incident crash cleanup works from the configured root without literal `.worktrees` assumptions.
- [ ] Routine hygiene inventory is read-only by default; apply removes only exact paths proven safe.
- [ ] Dirty, locked, active, unmerged, and unsafe-path worktrees are preserved and reported.
- [ ] Existing Aurora worktrees are either safely migrated/removed or listed with a specific defer reason; Ticket 060 is never interrupted.
- [ ] Shipyard's live checkout remains the explicit no-worktree exception.
- [ ] Unset configuration reproduces current behavior; full Shipyard gates and fleet doctor checks pass.

## Dependencies

- Ticket 060 must finish before its worktree can be considered for migration or cleanup.
- No dependency on Aurora application tickets 057, 058, 061, or 062.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Cleanup destroys unfinished work | Default read-only; require clean + inactive + retained-work proof; never recursively delete |
| A relative path escapes to a broad directory | Resolve/canonicalize and enforce a dedicated project namespace before any create/remove |
| Runner leaves worktrees because literal pattern changed | Match only descendants of the resolved configured root plus owned prefixes |
| Fleet rollout disrupts an active agent | Inventory processes/locks first; move only inactive worktrees; defer Ticket 060 |
| Public repo leaks a machine-specific home path | Use relative/config placeholders and run the leak firewall on the staged ticket/change |

## Out of scope

- Removing dirty or unmerged worktrees automatically.
- Changing Shipyard's fleet-live main-checkout rule.
- Moving Ticket 060 before it is complete.
- General repository cleanup unrelated to registered git worktrees.
