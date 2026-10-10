# Learned (generic → core change): A new CI gate must be proven green on the base branch before scribe/helldiver publish PRs against it; bopthere's pr-gate shipped red (missing PUBLIC_ env in CI, machine-local e2e-data test) and every nightly docs PR was blocked for two days with no page.

- **Captured:** 2026-10-10
- **Route:** generic — a portable lesson that belongs in a core `agents/<role>/role.md` (or a shared skill), leak-checked and fleet-live on merge.
- **Status:** Draft stub for human review — do NOT edit a core role file directly from this; polish into a real ticket first.

## Lesson

A new CI gate must be proven green on the base branch before scribe/helldiver publish PRs against it; bopthere's pr-gate shipped red (missing PUBLIC_ env in CI, machine-local e2e-data test) and every nightly docs PR was blocked for two days with no page.

## Proposed core change

_Describe the role-file / skill edit and the config flag that gates it (unset = today)._
