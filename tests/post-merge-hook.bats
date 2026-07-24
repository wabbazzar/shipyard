#!/usr/bin/env bats
# tests/post-merge-hook.bats — the .githooks/post-merge hook heals skill-symlink
# drift after a merge by invoking reconcile-skills.sh --all, and NEVER breaks a
# merge (non-fatal). Hermetic: the hook is run from a throwaway git repo whose
# scripts/reconcile-skills.sh is a recording stub — the real fleet is untouched.

setup() {
  load helpers
  quartet_setup
  HOOK="$QUARTET_ROOT/.githooks/post-merge"
}

@test "hook exists, is executable, and parses" {
  [ -x "$HOOK" ]
  run bash -n "$HOOK"
  [ "$status" -eq 0 ]
}

@test "hook invokes reconcile-skills.sh --all from the repo root" {
  local repo="$BATS_TEST_TMPDIR/fakerepo"
  mkdir -p "$repo/scripts"
  git -C "$repo" init -q
  # recording stub in the fake repo's scripts/
  cat > "$repo/scripts/reconcile-skills.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$repo/reconcile.called"
STUB
  chmod +x "$repo/scripts/reconcile-skills.sh"
  ( cd "$repo" && bash "$HOOK" )
  [ -f "$repo/reconcile.called" ]
  grep -qF -- "--all" "$repo/reconcile.called"
}

@test "hook is non-fatal when reconcile-skills.sh is absent" {
  local repo="$BATS_TEST_TMPDIR/norepo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  run bash -c "cd '$repo' && bash '$HOOK'"
  [ "$status" -eq 0 ]
}
