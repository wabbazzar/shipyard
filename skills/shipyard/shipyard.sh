#!/usr/bin/env bash
# shipyard.sh — the /shipyard command's deterministic core.
#
# Subcommands (the SKILL.md is the human-facing surface; this script is what it
# runs so the behavior is testable with load-bearing exit codes):
#
#   status                     what's installed here (units, project blocks,
#                              --doctor). Read-only. Exit 3 if nothing installed.
#   add-specialist <subsystem> scaffold + wire the domain-specialist archetype.
#   learn "<lesson>"           route a lesson through the ADAPTING.md taxonomy.
#
# Exit codes (load-bearing, per .agents/gates.md): 0 ok, 2 bad invocation/config,
# 3 deliberate no-op (nothing installed). The skill is symlinked into a project's
# .claude/skills/, so QUARTET_DIR is resolved through the symlink.

set -uo pipefail

_src="${BASH_SOURCE[0]}"
_src="$(readlink -f "$_src" 2>/dev/null || echo "$_src")"
QUARTET_DIR="${QUARTET_DIR:-$(cd "$(dirname "$_src")/../.." && pwd)}"

SUBCMD=""
PROJECT_DIR="$PWD"
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT_DIR="$2"; shift 2 ;;
    -h|--help) SUBCMD="help"; shift ;;
    -*) echo "shipyard: unknown flag '$1'" >&2; exit 2 ;;
    *)
      if [ -z "$SUBCMD" ]; then SUBCMD="$1"; else ARGS+=("$1"); fi
      shift ;;
  esac
done
[ -n "$SUBCMD" ] || SUBCMD="status"

# ---- config (optional — status works on a bare dir too) --------------------
# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/load-config.sh"
CFG_JSON="{}"
if [ -f "$PROJECT_DIR/.agents/config.toml" ]; then
  CFG_JSON="$(load_config_json "$PROJECT_DIR/.agents/config.toml" 2>/dev/null)" || CFG_JSON="{}"
fi
PROJECT_NAME="$(jq -r '.project_name // empty' <<<"$CFG_JSON" 2>/dev/null)"
[ -n "$PROJECT_NAME" ] || PROJECT_NAME="$(basename "$PROJECT_DIR")"

_have_all_deps() {
  local d
  for d in jq python3 git gh systemctl claude; do
    command -v "$d" >/dev/null 2>&1 || return 1
  done
}

usage() {
  cat <<EOF
shipyard — inspect and extend an installed crew.

  shipyard status                  what's installed here (default)
  shipyard add-specialist <sub>    scaffold a domain-specialist for <sub>
  shipyard learn "<lesson>"        route a lesson to the adaptation taxonomy

Exit: 0 ok · 2 bad invocation · 3 nothing installed.
EOF
}

# ---- status ----------------------------------------------------------------
cmd_status() {
  local unit_dir="$HOME/.config/systemd/user"
  local timers=() t
  if [ -d "$unit_dir" ]; then
    while IFS= read -r t; do [ -n "$t" ] && timers+=("$t"); done \
      < <(find "$unit_dir" -maxdepth 1 -name "$PROJECT_NAME-*.timer" 2>/dev/null | sort)
  fi

  if [ "${#timers[@]}" -eq 0 ]; then
    echo "shipyard: no crew installed for '$PROJECT_NAME'"
    echo "  (no $unit_dir/$PROJECT_NAME-*.timer)"
    echo "  install with: $QUARTET_DIR/install.sh --project $PROJECT_DIR"
    return 3
  fi

  echo "shipyard: crew installed for '$PROJECT_NAME' — ${#timers[@]} timer(s):"
  for t in "${timers[@]}"; do echo "  - $(basename "$t" .timer)"; done

  echo "project blocks (.agents/<role>.md):"
  local r
  for r in design build release medic scribe; do
    [ -f "$PROJECT_DIR/.agents/$r.md" ] && echo "  - $r: $PROJECT_DIR/.agents/$r.md"
  done

  # Read-only drift audit — only when the full toolchain is present (skipped in
  # the hermetic test env, where gh/claude are not stubbed).
  if [ -f "$PROJECT_DIR/.agents/config.toml" ] && _have_all_deps; then
    echo "doctor:"
    "$QUARTET_DIR/install.sh" --doctor --project "$PROJECT_DIR" 2>&1 | sed 's/^/  /' || true
  fi
  return 0
}

case "$SUBCMD" in
  help)   usage; exit 0 ;;
  status) cmd_status; exit $? ;;
  add-specialist|learn)
    echo "shipyard: '$SUBCMD' is not available in this build" >&2
    exit 2 ;;
  *)
    echo "shipyard: unknown subcommand '$SUBCMD'" >&2
    usage >&2
    exit 2 ;;
esac
