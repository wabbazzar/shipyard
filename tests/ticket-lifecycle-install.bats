#!/usr/bin/env bats
#
# ticket-lifecycle-install.bats — ticket hygiene is DEFAULT ON at install time.
#
# install.sh provisions docs/tickets/{pending,complete,freezer} and the
# [write_ticket] keys that name them, and --doctor blocks on lifecycle drift.
# The tri-state is the load-bearing part:
#
#   (a) no ticket_dir configured  -> provision folders + config (default ON)
#   (b) lifecycle_dirs present    -> already configured, touch nothing
#   (c) ticket_dir but no flag    -> NOTICE only; never silently enable the
#       mover on a non-standard layout, never rewrite the operator's dir keys
#
# systemctl/crontab/gh/claude are stubbed so the installer never touches the
# host's real user units or crontab.

setup() {
  load helpers
  quartet_setup
  make_stub systemctl 0
  make_stub crontab 0 ""
  make_stub gh 0
  make_stub claude 0
  PROJ="$(make_fixture_project lctest can-merge-true.toml)"
  CFG="$PROJ/.agents/config.toml"
}

run_install() {
  QUARTET_DIR="$QUARTET_ROOT" \
  QUARTET_EVENTS_DIR="$EVENTS_DIR" \
  QUARTET_NOTIFY_CMD="$NOTIFY_CMD" \
    bash "$QUARTET_ROOT/install.sh" --project "$PROJ" "$@"
}

run_doctor_on() {
  run env QUARTET_DIR="$QUARTET_ROOT" \
    bash "$QUARTET_ROOT/install.sh" --doctor --project "$1"
}

# ---------------------------------------------------------------------------
# (a) fresh project — default ON
# ---------------------------------------------------------------------------

@test "dry-run announces the lifecycle folders + config and writes NOTHING" {
  run run_install --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "would create: $PROJ/docs/tickets/pending"
  echo "$output" | grep -q "would create: $PROJ/docs/tickets/complete"
  echo "$output" | grep -q "would create: $PROJ/docs/tickets/freezer"
  echo "$output" | grep -q "lifecycle_dirs = true"
  [ ! -d "$PROJ/docs/tickets" ]
  ! grep -q "write_ticket" "$CFG"
}

@test "real run creates the three folders and writes lifecycle_dirs = true" {
  run run_install
  [ "$status" -eq 0 ]
  [ -d "$PROJ/docs/tickets/pending" ]
  [ -d "$PROJ/docs/tickets/complete" ]
  [ -d "$PROJ/docs/tickets/freezer" ]
  grep -q '^\[write_ticket\]' "$CFG"
  grep -qE '^lifecycle_dirs[[:space:]]*=[[:space:]]*true' "$CFG"
  grep -q 'docs/tickets/pending' "$CFG"
  grep -q 'docs/tickets/complete' "$CFG"
  grep -q 'docs/tickets/freezer' "$CFG"
  # The config still parses through the shared loader.
  run env QUARTET_DIR="$QUARTET_ROOT" bash -c \
    'source "$QUARTET_DIR/agents/lib/load-config.sh"; load_config_json "$1" | jq -e ".write_ticket.lifecycle_dirs == true"' _ "$CFG"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# (b) already lifecycle-configured — idempotent
# ---------------------------------------------------------------------------

@test "re-run on a lifecycle project is idempotent: no duplicate config, folders untouched" {
  run_install >/dev/null
  echo "keep me" > "$PROJ/docs/tickets/pending/NOTES.md"
  run run_install
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ticket lifecycle: already configured"
  [ "$(grep -c '^\[write_ticket\]' "$CFG")" -eq 1 ]
  [ "$(grep -cE '^lifecycle_dirs[[:space:]]*=' "$CFG")" -eq 1 ]
  grep -q "keep me" "$PROJ/docs/tickets/pending/NOTES.md"
}

# ---------------------------------------------------------------------------
# (c) non-standard layout — NOTICE only
# ---------------------------------------------------------------------------

@test "a non-standard ticket layout gets a migration NOTICE, not a silent enable" {
  cat >>"$CFG" <<'TOML'

[write_ticket]
ticket_dir  = "backlog"
archive_dir = "archive"
TOML
  run run_install
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "NOTICE"
  echo "$output" | grep -qi "migration"
  ! grep -q "lifecycle_dirs" "$CFG"
  grep -qE '^ticket_dir[[:space:]]*=[[:space:]]*"backlog"' "$CFG"
  grep -qE '^archive_dir[[:space:]]*=[[:space:]]*"archive"' "$CFG"
  [ ! -d "$PROJ/docs/tickets/pending" ]
}

# ---------------------------------------------------------------------------
# never clobber
# ---------------------------------------------------------------------------

@test "an existing docs/tickets/pending with content is never clobbered" {
  mkdir -p "$PROJ/docs/tickets/pending"
  echo "# mine" > "$PROJ/docs/tickets/pending/001_feature_mine.md"
  run run_install
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "docs/tickets/pending exists — leaving as-is"
  grep -q "# mine" "$PROJ/docs/tickets/pending/001_feature_mine.md"
  [ -d "$PROJ/docs/tickets/complete" ]
}

# ---------------------------------------------------------------------------
# --doctor
# ---------------------------------------------------------------------------

@test "doctor emits a lifecycle finding and exits non-zero on a misfiled ticket" {
  run_install >/dev/null
  # Built + verified, but still sitting in pending/ — the drift this catches.
  printf '# t\n\n- **Status:** built + verified\n' \
    > "$PROJ/docs/tickets/pending/002_feature_late.md"
  run_doctor_on "$PROJ"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "DOCTOR lifecycle:"
  echo "$output" | grep -q "002_feature_late.md"
}

@test "doctor on a flat (non-lifecycle) project emits NO lifecycle finding" {
  cat >>"$CFG" <<'TOML'

[write_ticket]
ticket_dir = "docs/tickets"
TOML
  run_install >/dev/null
  mkdir -p "$PROJ/docs/tickets"
  printf '# t\n\n- **Status:** built + verified\n' > "$PROJ/docs/tickets/flat.md"
  run_doctor_on "$PROJ"
  ! echo "$output" | grep -q "DOCTOR lifecycle:"
}
