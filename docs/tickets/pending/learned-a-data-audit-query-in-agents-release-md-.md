# Learned (generic → core change): A data audit query in .agents/release.md must share its uniqueness key with the application's own dedup routine; shredly's audit omitted sub_exercise_index and reported phantom duplicates daily for two weeks.

- **Captured:** 2026-10-10
- **Route:** generic — a portable lesson that belongs in a core `agents/<role>/role.md` (or a shared skill), leak-checked and fleet-live on merge.
- **Status:** Draft stub for human review — do NOT edit a core role file directly from this; polish into a real ticket first.

## Lesson

A data audit query in .agents/release.md must share its uniqueness key with the application's own dedup routine; shredly's audit omitted sub_exercise_index and reported phantom duplicates daily for two weeks.

## Proposed core change

_Describe the role-file / skill edit and the config flag that gates it (unset = today)._
