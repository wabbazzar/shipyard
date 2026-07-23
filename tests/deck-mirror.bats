#!/usr/bin/env bats
#
# deck-mirror.bats — scripts/sync-deck-mirror.sh + .githooks/pre-push.
#
# Cascade the shipyard deck (docs/) into the wabbazzar.com "writing" mirror.
# Hermetic: a synth SOURCE repo (mini-shipyard with docs/ + the real script/hook)
# and a MIRROR repo with a LOCAL bare origin. No network, no real repo, no LLM.
#
# Asserts: verbatim data/styles copy + exactly-2-hunk index transform; scoped,
# attribution-free mirror commit; idempotency; unset = no-op; cascade-from-sha
# (not the worktree); determinism guard; not-on-main + dirty-deck refusals; and
# the hook fires ONLY on a main push and never blocks.

setup() {
  load helpers
  quartet_setup

  SCRIPT="$QUARTET_ROOT/scripts/sync-deck-mirror.sh"
  HOOK="$QUARTET_ROOT/.githooks/pre-push"

  # --- synth SOURCE: a mini-shipyard repo whose docs/ carries the 2 targets ---
  SRC="$BATS_TEST_TMPDIR/src"
  mkdir -p "$SRC/docs" "$SRC/scripts" "$SRC/.githooks"
  cat >"$SRC/docs/index.html" <<'HTML'
<html><body>
  <a class="back-to-writing" href="https://github.com/wabbazzar/shipyard">&larr; Repo</a>
  <script>
      const SOURCES = ['./shipyard-data.json'];
  </script>
</body></html>
HTML
  printf 'body{color:red}\n' >"$SRC/docs/styles.css"
  printf '{"deck":true}\n' >"$SRC/docs/shipyard-data.json"
  # the real script + hook, so the hook's $QUARTET_DIR/scripts path resolves
  cp "$SCRIPT" "$SRC/scripts/sync-deck-mirror.sh"; chmod +x "$SRC/scripts/sync-deck-mirror.sh"
  cp "$HOOK" "$SRC/.githooks/pre-push"; chmod +x "$SRC/.githooks/pre-push"
  git -C "$SRC" init -q -b main
  git -C "$SRC" add -A
  git -C "$SRC" commit -q -m "src deck"
  SRC_SHA="$(git -C "$SRC" rev-parse HEAD)"

  # --- MIRROR: clone of a local bare origin, seeded stale, on main ---
  MORIGIN="$BATS_TEST_TMPDIR/mirror-origin.git"
  MIRROR="$BATS_TEST_TMPDIR/mirror"
  git init -q --bare -b main "$MORIGIN"
  git clone -q "$MORIGIN" "$MIRROR" 2>/dev/null
  git -C "$MIRROR" symbolic-ref HEAD refs/heads/main
  mkdir -p "$MIRROR/writing/the-shipyard"
  printf 'STALE\n' >"$MIRROR/writing/the-shipyard/index.html"
  printf 'STALE\n' >"$MIRROR/writing/the-shipyard/styles.css"
  printf 'STALE\n' >"$MIRROR/writing/the-shipyard/shipyard-data.json"
  git -C "$MIRROR" add -A
  git -C "$MIRROR" commit -q -m seed
  git -C "$MIRROR" push -q -u origin main
}

origin_count() { git -C "$MORIGIN" rev-list --count main; }
sync() { env DECK_MIRROR_DIR="$MIRROR" QUARTET_DIR="$SRC" bash "$SCRIPT" "${1:-$SRC_SHA}"; }

@test "cascade copies data/styles verbatim and transforms index to exactly 2 hunks" {
  run sync
  [ "$status" -eq 0 ]
  diff <(git -C "$SRC" show "$SRC_SHA:docs/shipyard-data.json") "$MIRROR/writing/the-shipyard/shipyard-data.json"
  diff <(git -C "$SRC" show "$SRC_SHA:docs/styles.css") "$MIRROR/writing/the-shipyard/styles.css"
  run bash -c "diff <(git -C '$SRC' show '$SRC_SHA:docs/index.html') '$MIRROR/writing/the-shipyard/index.html' | grep -cE '^[<>]'"
  [ "$output" -eq 4 ]
  grep -q 'href="/writing/">&larr; Writing' "$MIRROR/writing/the-shipyard/index.html"
  grep -qF "SOURCES = ['/shipyard/shipyard-data.json', './shipyard-data.json'];" "$MIRROR/writing/the-shipyard/index.html"
}

@test "mirror commit is scoped to the 3 deck paths with no attribution" {
  sync
  run git -C "$MIRROR" show --name-only --format= HEAD
  [ "$(printf '%s\n' "$output" | grep -c 'writing/the-shipyard/')" -eq 3 ]
  run bash -c "git -C '$MIRROR' show --name-only --format= HEAD | grep -v -e '^writing/the-shipyard/' -e '^\$' | wc -l"
  [ "$output" -eq 0 ]
  run git -C "$MIRROR" log -1 --format=%B
  ! printf '%s' "$output" | grep -qiE 'co-authored-by|claude|generated with'
}

@test "idempotent: a second cascade makes no new commit (exit 3)" {
  sync
  before="$(origin_count)"
  run sync
  [ "$status" -eq 3 ]
  [ "$(origin_count)" = "$before" ]
}

@test "no mirror configured is a clean no-op (exit 3)" {
  run env -u DECK_MIRROR_DIR QUARTET_DIR="$SRC" bash "$SCRIPT" "$SRC_SHA"
  [ "$status" -eq 3 ]
}

@test "cascades the committed sha, not a dirty working tree (D-8)" {
  printf '\nDIRTY-WORKTREE\n' >>"$SRC/docs/index.html"
  run sync
  [ "$status" -eq 0 ]
  ! grep -q DIRTY-WORKTREE "$MIRROR/writing/the-shipyard/index.html"
}

@test "determinism guard: a missing transform target aborts (exit 2)" {
  sed -i "s#const SOURCES = \['./shipyard-data.json'\];#const SOURCES = [];#" "$SRC/docs/index.html"
  git -C "$SRC" commit -q -am "break the transform target"
  bad="$(git -C "$SRC" rev-parse HEAD)"
  run sync "$bad"
  [ "$status" -eq 2 ]
}

@test "refuses when the mirror is not on main (exit 2)" {
  git -C "$MIRROR" checkout -q -b side
  run sync
  [ "$status" -eq 2 ]
}

@test "refuses when the mirror deck dir has uncommitted edits (exit 2)" {
  printf 'human-edit\n' >>"$MIRROR/writing/the-shipyard/index.html"
  run sync
  [ "$status" -eq 2 ]
}

@test "pre-push cascades ONLY on a main push, and never blocks" {
  z=0000000000000000000000000000000000000000
  before="$(origin_count)"
  # a non-main ref → no cascade
  run bash -c "printf 'refs/heads/wip %s refs/heads/wip %s\n' '$SRC_SHA' '$z' | env DECK_MIRROR_DIR='$MIRROR' QUARTET_DIR='$SRC' bash '$HOOK'"
  [ "$status" -eq 0 ]
  [ "$(origin_count)" = "$before" ]
  # a main ref → cascade fires
  run bash -c "printf 'refs/heads/main %s refs/heads/main %s\n' '$SRC_SHA' '$z' | env DECK_MIRROR_DIR='$MIRROR' QUARTET_DIR='$SRC' bash '$HOOK'"
  [ "$status" -eq 0 ]
  [ "$(origin_count)" -gt "$before" ]
}

@test "pre-push never blocks even when the cascade fails" {
  # point at a non-git mirror so the cascade errors; hook must still exit 0
  run bash -c "printf 'refs/heads/main %s refs/heads/main %s\n' '$SRC_SHA' '0000000000000000000000000000000000000000' | env DECK_MIRROR_DIR='$BATS_TEST_TMPDIR/nope' QUARTET_DIR='$SRC' bash '$HOOK'"
  [ "$status" -eq 0 ]
}
