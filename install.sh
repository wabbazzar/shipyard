#!/bin/bash
# install-quartet.sh — idempotent installer for guardian/augur/medic/scribe.
#
# Usage:
#   scripts/install-quartet.sh --project <project_dir> [--dry-run] [--agents LIST]
#
#   --project   Path to the target project (must contain .agents/config.toml).
#   --dry-run   Print every change without writing anything.
#   --agents    Comma list of agents to install. Default: guardian,augur,medic,scribe.
#
# What it does (idempotent — re-running is safe):
#
#   1. Writes ~/.config/systemd/user/<project_name>-<agent>.{service,timer}
#      for each agent. Schedules come from config.toml's [install.timers]
#      table, falling back to baked-in defaults (guardian 06:00, medic
#      every 10 min, augur 03:30, scribe 01:00).
#
#   2. `systemctl --user daemon-reload` + `enable --now` each timer.
#
#   3. Removes ANY crontab line that invokes
#      <project_dir>/scripts/<project_name>-{guardian,augur,medic,scribe}.sh
#      — those are pre-quartet legacy launchers, kept around historically
#      and notorious for racing the new timers. Backs the crontab up first.
#
#   4. Deletes (via `git rm`, or `rm` if not tracked) any pre-quartet
#      launcher script at <project_dir>/scripts/<project_name>-<agent>.sh
#      and its companion <agent>-prompt.md / <agent>-checklist.md. Skips
#      files that are already thin shims (those route to this repo's
#      generic runner so they're harmless and we keep them).
#
#   5. Verifies each requested timer is enabled and reports the next
#      scheduled fire time.
#
# Why removal, not shimming: shims preserve a working call path but also
# preserve the surface area people forget to update. After install, the
# canonical entry point is `agents/<name>/runner.sh --project <dir> --mode X`
# — the same path systemd, the post-push hook, and medic→augur all use.

set -uo pipefail

QUARTET_DIR="${QUARTET_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
SYSTEMD_DIR="$HOME/.config/systemd/user"

usage() {
  sed -n '2,38p' "$0"
  exit "${1:-2}"
}

# ---------- argv ------------------------------------------------------------
PROJECT_DIR=""
DRY_RUN=0
AGENTS="guardian,augur,medic,scribe"
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --agents)  AGENTS="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done
[ -z "$PROJECT_DIR" ] && { echo "--project required" >&2; usage; }
PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd)" || \
  { echo "project_dir not found: $PROJECT_DIR" >&2; exit 2; }

CFG="$PROJECT_DIR/.agents/config.toml"
[ -f "$CFG" ] || { echo "config not found: $CFG" >&2; exit 2; }

# ---------- load config -----------------------------------------------------
# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/load-config.sh"
CFG_JSON="$(load_config_json "$CFG")" || { echo "failed to parse $CFG" >&2; exit 2; }

PROJECT_NAME="$(jq -r '.project_name // empty' <<<"$CFG_JSON")"
[ -z "$PROJECT_NAME" ] && { echo "config missing project_name" >&2; exit 2; }

# ---------- defaults --------------------------------------------------------
default_schedule() {
  case "$1" in
    guardian) echo "*-*-* 06:00:00" ;;
    medic)    echo "*-*-* *:0/10:00" ;;
    augur)    echo "*-*-* 03:30:00" ;;
    scribe)   echo "*-*-* 01:00:00" ;;
  esac
}
default_mode() {
  case "$1" in
    guardian) echo "daily" ;;
    medic)    echo "scan" ;;
    augur)    echo "live" ;;
    scribe)   echo "daily" ;;
  esac
}
description() {
  local cap="$(tr '[:lower:]' '[:upper:]' <<<"${PROJECT_NAME:0:1}")${PROJECT_NAME:1}"
  case "$1" in
    guardian) echo "$cap Guardian — daily tests + typecheck + data audit + build" ;;
    medic)    echo "$cap Medic — failure-triggered triage agent (scan tick)" ;;
    augur)    echo "$cap Augur — nightly user-feedback triage + autonomous fixer" ;;
    scribe)   echo "$cap Scribe — daily doc-as-code refresh" ;;
  esac
}

# ---------- helpers ---------------------------------------------------------
write_or_show() {
  local path="$1" content="$2"
  local tmp; tmp="$(mktemp)"
  printf '%s' "$content" > "$tmp"
  if [ -f "$path" ] && cmp -s "$path" "$tmp"; then
    rm -f "$tmp"
    echo "  unchanged: $path"
    return
  fi
  if [ "$DRY_RUN" = "1" ]; then
    rm -f "$tmp"
    echo "  would write: $path"
  else
    mv "$tmp" "$path"
    echo "  wrote:     $path"
  fi
}

# ---------- step 1+2: systemd units ----------------------------------------
echo "==> systemd units (project=$PROJECT_NAME dir=$PROJECT_DIR)"
[ "$DRY_RUN" = "1" ] || mkdir -p "$SYSTEMD_DIR"

for agent in ${AGENTS//,/ }; do
  schedule="$(jq -r --arg a "$agent" '.install.timers[$a] // empty' <<<"$CFG_JSON")"
  [ -z "$schedule" ] && schedule="$(default_schedule "$agent")"
  [ -z "$schedule" ] && { echo "  skip $agent: no schedule"; continue; }
  mode="$(default_mode "$agent")"
  desc="$(description "$agent")"

  service_path="$SYSTEMD_DIR/${PROJECT_NAME}-${agent}.service"
  timer_path="$SYSTEMD_DIR/${PROJECT_NAME}-${agent}.timer"

  # Guardian wants network; the others don't.
  unit_extras=""
  [ "$agent" = "guardian" ] && unit_extras=$'Wants=network-online.target\nAfter=network-online.target\n'

  service_content="[Unit]
Description=$desc
${unit_extras}
[Service]
Type=oneshot
WorkingDirectory=$PROJECT_DIR
ExecStart=/bin/bash $QUARTET_DIR/agents/$agent/runner.sh --project $PROJECT_DIR --mode $mode
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
Environment=HOME=$HOME
TimeoutStartSec=3900
"
  timer_content="[Unit]
Description=$desc (timer)

[Timer]
OnCalendar=$schedule
Persistent=true

[Install]
WantedBy=timers.target
"
  write_or_show "$service_path" "$service_content"
  write_or_show "$timer_path"   "$timer_content"
done

if [ "$DRY_RUN" = "1" ]; then
  echo "  would: systemctl --user daemon-reload + enable --now each timer"
else
  systemctl --user daemon-reload
  for agent in ${AGENTS//,/ }; do
    systemctl --user enable --now "${PROJECT_NAME}-${agent}.timer" 2>&1 | sed 's/^/  /'
  done
fi

# ---------- step 3: crontab conflict removal --------------------------------
echo ""
echo "==> crontab cleanup"
# Match any line invoking <project_dir>/scripts/<project_name>-<agent>.sh.
CRON_PATTERN="$PROJECT_DIR/scripts/${PROJECT_NAME}-(guardian|augur|medic|scribe)\.sh"

# Box-drawing section-header comments (e.g. `# ── Project Guardian ──`)
# we leave behind when removing their entries. Match: starts with `# ─`,
# mentions the project name (case-insensitive) and one of the agent words.
PROJECT_CAP="$(tr '[:lower:]' '[:upper:]' <<<"${PROJECT_NAME:0:1}")${PROJECT_NAME:1}"
COMMENT_PATTERN="^# ─.*(${PROJECT_NAME}|${PROJECT_CAP}).*(Guardian|Augur|Medic|Scribe).*─"

current_crontab="$(crontab -l 2>/dev/null || true)"
conflicting_lines="$(echo "$current_crontab" | grep -E "$CRON_PATTERN" || true)"
orphan_headers="$(echo "$current_crontab" | grep -E "$COMMENT_PATTERN" || true)"
if [ -z "$conflicting_lines" ] && [ -z "$orphan_headers" ]; then
  echo "  no conflicting cron entries"
else
  if [ -n "$conflicting_lines" ]; then
    echo "  removing entries:"
    echo "$conflicting_lines" | sed 's/^/    /'
  fi
  if [ -n "$orphan_headers" ]; then
    echo "  removing section headers:"
    echo "$orphan_headers" | sed 's/^/    /'
  fi
  if [ "$DRY_RUN" = "0" ]; then
    backup="$HOME/.crontab.backup.$(date +%Y%m%d-%H%M%S)"
    echo "$current_crontab" > "$backup"
    echo "$current_crontab" | grep -vE "$CRON_PATTERN" | grep -vE "$COMMENT_PATTERN" | crontab -
    echo "  crontab backup: $backup"
  fi
fi

# ---------- step 4: legacy launcher script removal --------------------------
echo ""
echo "==> legacy launcher scripts in $PROJECT_DIR/scripts/"
for agent in ${AGENTS//,/ }; do
  legacy="$PROJECT_DIR/scripts/${PROJECT_NAME}-${agent}.sh"
  [ -f "$legacy" ] || continue
  if grep -q "$QUARTET_DIR/agents/$agent/runner.sh" "$legacy" 2>/dev/null; then
    echo "  ok (already a shim): $legacy"
    continue
  fi
  echo "  removing legacy:    $legacy"
  companions=()
  for ext in -prompt.md -checklist.md; do
    f="$PROJECT_DIR/scripts/${PROJECT_NAME}-${agent}${ext}"
    [ -f "$f" ] && companions+=("$f")
  done
  if [ "$DRY_RUN" = "0" ]; then
    ( cd "$PROJECT_DIR" && git rm -q -f "$legacy" 2>/dev/null ) || rm -f "$legacy"
    for c in "${companions[@]}"; do
      echo "  removing companion: $c"
      ( cd "$PROJECT_DIR" && git rm -q -f "$c" 2>/dev/null ) || rm -f "$c"
    done
  else
    for c in "${companions[@]}"; do
      echo "  would remove companion: $c"
    done
  fi
done

# ---------- step 5: verification --------------------------------------------
echo ""
echo "==> verification"
all_ok=1
for agent in ${AGENTS//,/ }; do
  unit="${PROJECT_NAME}-${agent}.timer"
  if systemctl --user is-enabled "$unit" >/dev/null 2>&1; then
    next="$(systemctl --user list-timers "$unit" --no-pager 2>/dev/null | awk 'NR==2 {print $1, $2, $3, $4}')"
    echo "  $unit: enabled, next=$next"
  else
    echo "  $unit: NOT ENABLED"
    all_ok=0
  fi
done

remaining="$(crontab -l 2>/dev/null | grep -E "$CRON_PATTERN" || true)"
if [ -n "$remaining" ]; then
  echo "  WARNING: crontab still contains:"
  echo "$remaining" | sed 's/^/    /'
  all_ok=0
fi

echo ""
if [ "$all_ok" = "1" ]; then
  echo "install-quartet: OK"
  exit 0
else
  echo "install-quartet: incomplete (see warnings above)"
  exit 1
fi
