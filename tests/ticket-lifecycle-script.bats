#!/usr/bin/env bats
#
# ticket-lifecycle-script.bats — behavioral cases for scripts/ticket-lifecycle.sh,
# the deterministic lifecycle-folder engine
# (docs/tickets/ticket-lifecycle-folders.md, revised Phase 3).
#
# The folder IS the status: ticket_dir = pending, archive_dir = complete,
# backlog_dir = freezer. The script never guesses a ticket into complete/ —
# an unparseable or missing Status line means pending.
#
# Hermetic: every fixture repo is built inside $BATS_TEST_TMPDIR, git identity
# comes from quartet_setup, and nothing here touches the network, GitHub, a
# model, or any repo outside the tmpdir.

setup() {
  load helpers
  quartet_setup
  SCRIPT="$QUARTET_ROOT/scripts/ticket-lifecycle.sh"
}

# lc <project> <args...> — run the engine against a fixture project.
lc() {
  local p="$1"; shift
  QUARTET_DIR="$QUARTET_ROOT" bash "$SCRIPT" --project "$p" "$@"
}

# make_lifecycle_project [lifecycle_on] — a git repo with a [write_ticket]
# block. lifecycle_on=1 sets lifecycle_dirs = true and the three folders;
# lifecycle_on=0 writes a flat config with no lifecycle_dirs key at all.
# Echoes the project dir.
make_lifecycle_project() {
  local on="${1:-1}"
  local dir="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$dir/.agents"
  if [ "$on" = "1" ]; then
    mkdir -p "$dir/docs/tickets/pending" "$dir/docs/tickets/complete" \
             "$dir/docs/tickets/freezer"
    cat >"$dir/.agents/config.toml" <<'TOML'
project_name = "fixture"

[write_ticket]
lifecycle_dirs = true
ticket_dir  = "docs/tickets/pending"
archive_dir = "docs/tickets/complete"
backlog_dir = "docs/tickets/freezer"
TOML
  else
    mkdir -p "$dir/docs/tickets"
    cat >"$dir/.agents/config.toml" <<'TOML'
project_name = "fixture"

[write_ticket]
ticket_dir = "docs/tickets"
TOML
  fi
  git -C "$dir" init -q -b main
  printf '# fixture\n' >"$dir/README.md"
  printf '%s\n' "$dir"
}

# ticket <project> <relpath> <status-line-or-empty> [body]
ticket() {
  local p="$1" rel="$2" status="$3" body="${4:-Some body text.}"
  mkdir -p "$(dirname "$p/$rel")"
  {
    printf '# Ticket\n\n'
    [ -n "$status" ] && printf -- '- **Status:** %s\n' "$status"
    printf '\n%s\n' "$body"
  } >"$p/$rel"
}

commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -q -m "fixture tickets"
}

# ---------------------------------------------------------------------------
# The backward-compat guarantee: no lifecycle config → deliberate no-op
# ---------------------------------------------------------------------------

@test "no lifecycle_dirs: exits 3 and moves nothing" {
  p="$(make_lifecycle_project 0)"
  ticket "$p" "docs/tickets/001_feature_thing.md" "built and verified"
  commit_all "$p"

  run lc "$p" --sort --apply
  [ "$status" -eq 3 ]
  [ -f "$p/docs/tickets/001_feature_thing.md" ]
  # and --check is a no-op too, not a failure
  run lc "$p" --check
  [ "$status" -eq 3 ]
}

@test "no config file at all: exits 3" {
  p="$(make_lifecycle_project 0)"
  rm -f "$p/.agents/config.toml"
  run lc "$p" --check
  [ "$status" -eq 3 ]
}

# ---------------------------------------------------------------------------
# --check
# ---------------------------------------------------------------------------

@test "--check: clean tree exits 0" {
  p="$(make_lifecycle_project 1)"
  ticket "$p" "docs/tickets/pending/001_feature_a.md" "in progress"
  ticket "$p" "docs/tickets/complete/002_feature_b.md" "built + verified"
  ticket "$p" "docs/tickets/freezer/003_feature_c.md" "parked by owner"
  commit_all "$p"

  run lc "$p" --check
  [ "$status" -eq 0 ]
}

@test "--check: a built ticket sitting in pending is MISFILED (exit 1, names it)" {
  p="$(make_lifecycle_project 1)"
  ticket "$p" "docs/tickets/pending/004_feature_done.md" "built + verified (abc1234)"
  commit_all "$p"

  run lc "$p" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISFILED"* ]]
  [[ "$output" == *"004_feature_done.md"* ]]
  [[ "$output" == *"docs/tickets/complete"* ]]
}

@test "--check: a ticket with NO Status line belongs in pending, never complete" {
  p="$(make_lifecycle_project 1)"
  ticket "$p" "docs/tickets/pending/005_feature_nostatus.md" ""
  ticket "$p" "docs/tickets/complete/006_feature_nostatus.md" ""
  commit_all "$p"

  run lc "$p" --check
  [ "$status" -eq 1 ]
  # the pending one is fine; the complete one must be flagged back to pending
  [[ "$output" != *"005_feature_nostatus.md"* ]]
  [[ "$output" == *"006_feature_nostatus.md"* ]]
  [[ "$output" == *"docs/tickets/pending"* ]]
}

@test "--check: superseded goes to freezer even when the body says built" {
  p="$(make_lifecycle_project 1)"
  ticket "$p" "docs/tickets/pending/007_feature_old.md" \
    "superseded by the built replacement in 012" \
    "This was superseded; the built successor shipped instead."
  commit_all "$p"

  run lc "$p" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"docs/tickets/freezer"* ]]
  [[ "$output" != *"docs/tickets/complete"* ]]
}

# ---------------------------------------------------------------------------
# --sort
# ---------------------------------------------------------------------------

@test "--sort: dry-run prints the plan and moves nothing" {
  p="$(make_lifecycle_project 1)"
  ticket "$p" "docs/tickets/pending/008_feature_shipped.md" "shipped"
  commit_all "$p"

  run lc "$p" --sort
  [ "$status" -eq 0 ]
  [[ "$output" == *"git mv"* ]]
  [[ "$output" == *"008_feature_shipped.md"* ]]
  # nothing moved
  [ -f "$p/docs/tickets/pending/008_feature_shipped.md" ]
  [ ! -f "$p/docs/tickets/complete/008_feature_shipped.md" ]
  [ -z "$(git -C "$p" status --porcelain)" ]
}

@test "--sort --apply: performs the git mv and stages the rename" {
  p="$(make_lifecycle_project 1)"
  ticket "$p" "docs/tickets/pending/009_feature_done.md" "complete"
  commit_all "$p"

  run lc "$p" --apply --sort
  [ "$status" -eq 0 ]
  [ ! -f "$p/docs/tickets/pending/009_feature_done.md" ]
  [ -f "$p/docs/tickets/complete/009_feature_done.md" ]
  run git -C "$p" status --porcelain
  [[ "$output" == *"R "* ]]
  [[ "$output" == *"009_feature_done.md"* ]]
}

# ---------------------------------------------------------------------------
# --graduate
# ---------------------------------------------------------------------------

@test "--graduate: moves the named ticket to complete" {
  p="$(make_lifecycle_project 1)"
  ticket "$p" "docs/tickets/pending/010_feature_x.md" "in progress"
  commit_all "$p"

  run lc "$p" --graduate docs/tickets/pending/010_feature_x.md
  [ "$status" -eq 0 ]
  [ ! -f "$p/docs/tickets/pending/010_feature_x.md" ]
  [ -f "$p/docs/tickets/complete/010_feature_x.md" ]
}

@test "--graduate: missing file exits 2" {
  p="$(make_lifecycle_project 1)"
  commit_all "$p"
  run lc "$p" --graduate docs/tickets/pending/999_nope.md
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Invocation contract
# ---------------------------------------------------------------------------

@test "unknown argument exits 2" {
  p="$(make_lifecycle_project 1)"
  run lc "$p" --frobnicate
  [ "$status" -eq 2 ]
}

@test "missing --project exits 2" {
  run env QUARTET_DIR="$QUARTET_ROOT" bash "$SCRIPT" --check
  [ "$status" -eq 2 ]
}

@test "no mode exits 2" {
  p="$(make_lifecycle_project 1)"
  run lc "$p"
  [ "$status" -eq 2 ]
}

@test "--help prints usage and exits 0" {
  run env QUARTET_DIR="$QUARTET_ROOT" bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"ticket-lifecycle"* ]]
}
