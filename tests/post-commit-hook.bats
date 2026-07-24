#!/usr/bin/env bats
# tests/post-commit-hook.bats — the .githooks/post-commit hook relinks skills
# fleet-wide ONLY when the commit changed the skill set (install.sh or skills/),
# covering the direct-commit-to-main path. Hermetic: run from a throwaway git
# repo whose scripts/reconcile-skills.sh is a recording stub.

setup() {
  load helpers
  quartet_setup
  HOOK="$QUARTET_ROOT/.githooks/post-commit"
}

# fake_repo — a throwaway git repo with a recording reconcile stub on disk.
fake_repo() {
  local repo="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$repo/scripts"
  git -C "$repo" init -q
  cat > "$repo/scripts/reconcile-skills.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$repo/reconcile.called"
STUB
  chmod +x "$repo/scripts/reconcile-skills.sh"
  printf '%s\n' "$repo"
}

@test "hook exists, is executable, and parses" {
  [ -x "$HOOK" ]
  run bash -n "$HOOK"
  [ "$status" -eq 0 ]
}

@test "relinks when the commit touched skills/" {
  repo="$(fake_repo r1)"
  mkdir -p "$repo/skills/newskill"
  printf 'x\n' > "$repo/skills/newskill/SKILL.md"
  git -C "$repo" add skills
  git -C "$repo" commit -q -m "add a skill"
  ( cd "$repo" && bash "$HOOK" )
  [ -f "$repo/reconcile.called" ]
  grep -qF -- "--all" "$repo/reconcile.called"
}

@test "relinks when the commit touched install.sh" {
  repo="$(fake_repo r2)"
  printf 'GENERIC_SKILLS="a b"\n' > "$repo/install.sh"
  git -C "$repo" add install.sh
  git -C "$repo" commit -q -m "edit install.sh"
  ( cd "$repo" && bash "$HOOK" )
  [ -f "$repo/reconcile.called" ]
}

@test "does NOT relink for an unrelated commit" {
  repo="$(fake_repo r3)"
  printf 'hi\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m "docs only"
  ( cd "$repo" && bash "$HOOK" )
  [ ! -f "$repo/reconcile.called" ]
}

@test "is non-fatal when reconcile-skills.sh is absent" {
  repo="$BATS_TEST_TMPDIR/r4"
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf 'GENERIC_SKILLS="a"\n' > "$repo/install.sh"
  git -C "$repo" add install.sh
  git -C "$repo" commit -q -m "x"
  run bash -c "cd '$repo' && bash '$HOOK'"
  [ "$status" -eq 0 ]
}
