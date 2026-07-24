#!/usr/bin/env bash
# reconcile-skills.sh — make an installed project's skill symlinks match the
# current GENERIC_SKILLS, WITHOUT re-running the full installer.
#
# Why this exists: adding a skill to install.sh's GENERIC_SKILLS makes every
# installed project's `--doctor` report "skill symlink missing" until it is
# reinstalled — a notify-only crew-install-drift incident on every project. A
# full reinstall is the wrong tool: it defaults --agents (would change a
# scribe-only or design-bearing project's unit set) and re-bakes units. This
# does ONLY the additive, safe part: create any missing generic-skill symlink,
# refresh a stale one. It never removes a symlink, never clobbers a real
# dir/file, and never touches units, config, or gates.md.
#
# Usage:
#   reconcile-skills.sh --project <dir> [--dry-run]
#   reconcile-skills.sh --all           [--dry-run]   # every installed project
#
# --all discovers projects from the systemd user units' ExecStart `--project`
# argument. Exit 0 = reconciled (or nothing to do), 2 = bad invocation.

set -uo pipefail

QUARTET_DIR="${QUARTET_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

DRY_RUN=0
ALL=0
PROJECT_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT_DIR="$2"; shift 2 ;;
    --all)     ALL=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "reconcile-skills: unknown arg '$1'" >&2; exit 2 ;;
  esac
done
if [ "$ALL" = "0" ] && [ -z "$PROJECT_DIR" ]; then
  echo "reconcile-skills: need --project <dir> or --all" >&2; exit 2
fi

# GENERIC_SKILLS is the single source of truth in install.sh.
GENERIC_SKILLS="$(grep -m1 -oE 'GENERIC_SKILLS="[^"]*"' "$QUARTET_DIR/install.sh" \
  | sed 's/^GENERIC_SKILLS="//;s/"$//')"
[ -n "$GENERIC_SKILLS" ] || { echo "reconcile-skills: GENERIC_SKILLS not found" >&2; exit 2; }

# discover_projects — unique --project dirs from the installed crew units.
discover_projects() {
  local unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  [ -d "$unit_dir" ] || return 0
  grep -hoE -- '--project[ =][^ ]+' "$unit_dir"/*.service 2>/dev/null \
    | sed -E 's/^--project[ =]//' | sort -u
}

# reconcile_one <project-dir> — mirror install.sh's create/refresh symlink rules
# for exactly the missing/stale entries. Echoes a per-project summary.
reconcile_one() {
  local dir="$1"
  [ -d "$dir" ] || { echo "  skip (no such dir): $dir"; return 0; }
  # only touch projects that look installed (have a crew config or skills dir)
  if [ ! -d "$dir/.agents" ] && [ ! -d "$dir/.claude/skills" ]; then
    echo "  skip (not a crew project): $dir"; return 0
  fi
  local dest_root="$dir/.claude/skills"
  [ "$DRY_RUN" = "1" ] || mkdir -p "$dest_root"

  local skill src dest cur changed=0
  for skill in $GENERIC_SKILLS; do
    src="$QUARTET_DIR/skills/$skill"
    dest="$dest_root/$skill"
    [ -d "$src" ] || { echo "  skip $skill: source missing"; continue; }
    if [ -L "$dest" ]; then
      cur="$(readlink -f "$dest" 2>/dev/null || true)"
      if [ "$cur" = "$(readlink -f "$src")" ]; then
        continue                                   # already correct
      elif [ "$DRY_RUN" = "1" ]; then
        echo "  would relink: $dest -> $src"; changed=1
      else
        ln -sfn "$src" "$dest"; echo "  relinked: $skill"; changed=1
      fi
    elif [ -e "$dest" ]; then
      echo "  SKIP (real dir/file, not clobbering): $dest"   # operator owns it
    elif [ "$DRY_RUN" = "1" ]; then
      echo "  would symlink: $dest -> $src"; changed=1
    else
      ln -s "$src" "$dest"; echo "  symlinked: $skill"; changed=1
    fi
  done
  [ "$changed" = "0" ] && echo "  up-to-date"
  return 0
}

rc=0
if [ "$ALL" = "1" ]; then
  found=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    found=1
    echo "project: $p"
    reconcile_one "$p"
  done < <(discover_projects)
  [ "$found" = "1" ] || echo "reconcile-skills: no installed crew units found"
else
  echo "project: $PROJECT_DIR"
  reconcile_one "$PROJECT_DIR"
fi
exit $rc
