#!/usr/bin/env bash
# ticket-lifecycle.sh — the deterministic engine for ticket lifecycle folders.
#
# A project that sets [write_ticket] lifecycle_dirs = true files its tickets in
# three folders, and THE FOLDER IS THE STATUS:
#
#   ticket_dir  = pending   (not finished)
#   archive_dir = complete  (built + verified)
#   backlog_dir = freezer   (parked by the owner)
#
# Modes:
#   --check              report every ticket whose folder disagrees with its
#                        `Status:` line. Exit 1 on drift, 0 when clean. This is
#                        what CI and `install.sh --doctor` call.
#   --sort               print the `git mv` plan. DRY RUN — changes nothing.
#   --sort --apply       actually perform each move.
#   --graduate <file>    move one finished ticket into archive_dir.
#
# Exit codes are load-bearing: 0 ok · 1 drift found (--check only) ·
# 2 bad invocation/config/missing file · 3 deliberate no-op (the project has no
# lifecycle layout configured, so flat projects are left completely untouched).
#
# Status→folder mapping (case-insensitive, freezer words win over complete
# words so "superseded by the built X" parks rather than graduates). Anything
# else — including no Status line at all — is pending. Never guess a ticket
# into complete/.

set -uo pipefail

_src="${BASH_SOURCE[0]}"
_src="$(readlink -f "$_src" 2>/dev/null || echo "$_src")"
QUARTET_DIR="${QUARTET_DIR:-$(cd "$(dirname "$_src")/.." && pwd)}"

PROJECT_DIR=""
MODE=""
APPLY=0
GRADUATE_FILE=""

usage() {
  cat <<'EOF'
ticket-lifecycle — keep tickets in the folder their Status implies.

  ticket-lifecycle.sh --project <dir> --check
  ticket-lifecycle.sh --project <dir> --sort [--apply]
  ticket-lifecycle.sh --project <dir> --graduate <ticket-file>

  --check            report misfiled tickets; exit 1 if any, 0 if clean
  --sort             print the `git mv` plan (dry run; --apply performs it)
  --graduate <file>  move one finished ticket into the archive dir
  --help             this text

Exit: 0 ok · 1 drift (--check) · 2 bad invocation/config · 3 no-op
      (project has no [write_ticket] lifecycle_dirs = true).
EOF
}

set_mode() {
  if [ -n "$MODE" ] && [ "$MODE" != "$1" ]; then
    echo "ticket-lifecycle: conflicting modes: --$MODE and --$1" >&2
    exit 2
  fi
  MODE="$1"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project)   PROJECT_DIR="${2:-}"; shift 2 ;;
    --check)     set_mode check; shift ;;
    --sort)      set_mode sort; shift ;;
    --apply)     APPLY=1; shift ;;
    --graduate)  set_mode graduate; GRADUATE_FILE="${2:-}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "ticket-lifecycle: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$PROJECT_DIR" ] || { echo "ticket-lifecycle: --project <dir> is required" >&2; exit 2; }
[ -d "$PROJECT_DIR" ] || { echo "ticket-lifecycle: not a directory: $PROJECT_DIR" >&2; exit 2; }
[ -n "$MODE" ] || { echo "ticket-lifecycle: one of --check/--sort/--graduate is required" >&2; exit 2; }
if [ "$MODE" = "graduate" ] && [ -z "$GRADUATE_FILE" ]; then
  echo "ticket-lifecycle: --graduate needs a ticket file" >&2; exit 2
fi

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# ---- config ---------------------------------------------------------------
CONFIG_FILE="$PROJECT_DIR/.agents/config.toml"
noop() { echo "ticket-lifecycle: no lifecycle layout configured — nothing to do"; exit 3; }

[ -f "$CONFIG_FILE" ] || noop
# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/load-config.sh"
CFG_JSON="$(load_config_json "$CONFIG_FILE" 2>/dev/null)" || noop
[ -n "$CFG_JSON" ] || noop

LIFECYCLE="$(jq -r '(.write_ticket.lifecycle_dirs // false) | tostring' <<<"$CFG_JSON" 2>/dev/null)"
[ "$LIFECYCLE" = "true" ] || noop

strip_slash() { printf '%s\n' "${1%/}"; }

PENDING_DIR="$(jq -r '.write_ticket.ticket_dir // "docs/tickets/pending"' <<<"$CFG_JSON")"
PENDING_DIR="$(strip_slash "$PENDING_DIR")"
BASE_DIR="$(dirname "$PENDING_DIR")"
COMPLETE_DIR="$(jq -r --arg b "$BASE_DIR" '.write_ticket.archive_dir // ($b + "/complete")' <<<"$CFG_JSON")"
COMPLETE_DIR="$(strip_slash "$COMPLETE_DIR")"
FREEZER_DIR="$(jq -r --arg b "$BASE_DIR" '.write_ticket.backlog_dir // ($b + "/freezer")' <<<"$CFG_JSON")"
FREEZER_DIR="$(strip_slash "$FREEZER_DIR")"

# ---- status parsing -------------------------------------------------------

# ticket_status <abs-file> — the text after a `Status:` label in the opening
# metadata, or "".  Existing tickets use both a standalone metadata line and
# an inline header (`**Created:** … · **Status:** …`); only inspect the first
# twelve lines so a status field mentioned later in prose or code is not state.
ticket_status() {
  local line
  line="$(sed -n '1,12p' "$1" | grep -m1 -iE '(^[[:space:]]*([-*+][[:space:]]*)?\**[[:space:]]*|[[:space:]·]+\**[[:space:]]*)status[[:space:]]*\**[[:space:]]*:' 2>/dev/null)"
  [ -n "$line" ] || return 0
  line="${line#*[:]}"
  line="${line#"${line%%[![:space:]]*}"}"   # ltrim
  line="${line%"${line##*[![:space:]]}"}"   # rtrim
  printf '%s\n' "$line"
}

# expected_dir <status-text> — the folder that status implies. Freezer words are
# tested FIRST: "superseded by the built X" parks, it never graduates.
expected_dir() {
  local s
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  if printf '%s' "$s" | grep -qE "parked|deferred|superseded|won'?t|abandoned"; then
    printf '%s\n' "$FREEZER_DIR"
  elif printf '%s' "$s" | grep -qE 'built|complete|verified|shipped|done'; then
    printf '%s\n' "$COMPLETE_DIR"
  else
    printf '%s\n' "$PENDING_DIR"
  fi
}

# ---- moves ----------------------------------------------------------------

# do_move <rel-from> <rel-to> — git mv, falling back to plain mv for a file git
# does not track yet (then staged, so the change is visible either way).
do_move() {
  local from="$1" to="$2"
  mkdir -p "$PROJECT_DIR/$(dirname "$to")"
  if git -C "$PROJECT_DIR" mv "$from" "$to" 2>/dev/null; then
    return 0
  fi
  mv "$PROJECT_DIR/$from" "$PROJECT_DIR/$to" || return 1
  git -C "$PROJECT_DIR" add -A -- "$from" "$to" >/dev/null 2>&1 || true
}

# ---- graduate -------------------------------------------------------------
if [ "$MODE" = "graduate" ]; then
  src="$GRADUATE_FILE"
  case "$src" in
    /*) : ;;
    *)  src="$PROJECT_DIR/$src" ;;
  esac
  if [ ! -f "$src" ]; then
    echo "ticket-lifecycle: no such ticket: $GRADUATE_FILE" >&2
    exit 2
  fi
  src="$(cd "$(dirname "$src")" && pwd)/$(basename "$src")"
  rel="${src#"$PROJECT_DIR"/}"
  dest_rel="$COMPLETE_DIR/$(basename "$src")"
  if [ "$rel" = "$dest_rel" ]; then
    echo "already complete: $rel"
    exit 0
  fi
  if do_move "$rel" "$dest_rel"; then
    echo "graduated: $rel -> $dest_rel"
    exit 0
  fi
  echo "ticket-lifecycle: move failed: $rel -> $dest_rel" >&2
  exit 2
fi

# ---- scan -----------------------------------------------------------------
# Emits one "rel<TAB>expected<TAB>status" line per misfiled ticket.
scan() {
  local d f rel status want
  for d in "$PENDING_DIR" "$COMPLETE_DIR" "$FREEZER_DIR"; do
    [ -d "$PROJECT_DIR/$d" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      rel="${f#"$PROJECT_DIR"/}"
      status="$(ticket_status "$f")"
      want="$(expected_dir "$status")"
      [ "$want" = "$d" ] && continue
      printf '%s\t%s\t%s\n' "$rel" "$want" "$status"
    done < <(find "$PROJECT_DIR/$d" -maxdepth 1 -type f -name '*.md' | sort)
  done
}

MISFILED="$(scan)"

if [ "$MODE" = "check" ]; then
  [ -n "$MISFILED" ] || exit 0
  while IFS=$'\t' read -r rel want status; do
    [ -n "$rel" ] || continue
    printf 'MISFILED: %s — status "%s" implies %s\n' "$rel" "$status" "$want"
  done <<<"$MISFILED"
  exit 1
fi

# ---- sort -----------------------------------------------------------------
if [ -z "$MISFILED" ]; then
  echo "ticket-lifecycle: every ticket is already in the right folder"
  exit 0
fi

rc=0
while IFS=$'\t' read -r rel want status; do
  [ -n "$rel" ] || continue
  dest="$want/$(basename "$rel")"
  if [ "$APPLY" = "1" ]; then
    if do_move "$rel" "$dest"; then
      printf 'git mv %s %s\n' "$rel" "$dest"
    else
      printf 'FAILED: git mv %s %s\n' "$rel" "$dest" >&2
      rc=2
    fi
  else
    printf 'git mv %s %s\n' "$rel" "$dest"
  fi
done <<<"$MISFILED"

if [ "$APPLY" != "1" ]; then
  echo "(dry run — nothing moved; re-run with --apply)"
fi
exit "$rc"
