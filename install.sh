#!/bin/bash
# install.sh — idempotent installer for the shipyard crew.
#
# Usage:
#   install.sh --project <project_dir> [--dry-run] [--agents LIST] [--theme T]
#
#   --project   Path to the target project (must contain .agents/config.toml).
#   --dry-run   Print every change without writing anything.
#   --agents    Comma list of roles to install. Default: build,release,medic,scribe
#               (design is opt-in). Legacy names accepted and mapped:
#               guardian→release, augur→build.
#   --theme     Display-name theme baked into the project's [names] block:
#                 plain      role IDs verbatim (default): build/release/medic/scribe
#                 spacetime  mentat/helldiver/proctor/suk/chronicler
#                 custom:d,b,r,m,s  five names in role order design,build,release,medic,scribe
#               Unit/svc names come from [names]; the canonical role drives the
#               agent dir + config section. Existing installs (no [names]) are a
#               no-op until re-baked with a theme.
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
#   4. Deletes (via `git rm`, or `rm` if not tracked) any legacy
#      launcher script at <project_dir>/scripts/<project_name>-<agent>.sh
#      and its companion <agent>-prompt.md / <agent>-checklist.md. Skips
#      files that are already thin shims (those route to this repo's
#      generic runner so they're harmless and we keep them).
#
#   4.5 Symlinks the shared skills (polish-ticket, execute-ticket,
#      coverage-audit) from this repo's skills/ into
#      <project_dir>/.claude/skills/ — so headless agents and in-session
#      humans load the identical files — and drops skills/gates.md.template
#      into <project_dir>/.agents/gates.md if that gate file does not already
#      exist (an existing gate file is NEVER clobbered). It does NOT symlink
#      into any hub's own .claude/skills — the hub owns that itself.
#
#   5. Verifies each requested timer is enabled and reports the next
#      scheduled fire time.
#
# Why removal, not shimming: shims preserve a working call path but also
# preserve the surface area people forget to update. After install, the
# canonical entry point is `agents/<name>/runner.sh --project <dir> --mode X`
# — the same path systemd, the post-push hook, and medic→augur all use.

set -uo pipefail

# Dependency preflight — fail fast with a clear message.
for dep in jq python3 git gh systemctl claude; do
  command -v "$dep" >/dev/null 2>&1 || {
    echo "missing dependency: $dep (see README Requirements)" >&2; exit 2; }
done

QUARTET_DIR="${QUARTET_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
SYSTEMD_DIR="$HOME/.config/systemd/user"

# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/naming.sh"

usage() {
  sed -n '2,54p' "$0"
  exit "${1:-2}"
}

# ---------- argv ------------------------------------------------------------
PROJECT_DIR=""
DRY_RUN=0
AGENTS="build,release,medic,scribe"
THEME="plain"
THEME_EXPLICIT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --agents)  AGENTS="$2"; shift 2 ;;
    --theme)   THEME="$2"; THEME_EXPLICIT=1; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done
[ -z "$PROJECT_DIR" ] && { echo "--project required" >&2; usage; }

# Normalize the --agents list to canonical role IDs (accept legacy names).
map_agent_token() {
  case "$1" in
    guardian) echo release ;;
    augur)    echo build ;;
    *)        echo "$1" ;;
  esac
}
ROLES_LIST=""
for tok in ${AGENTS//,/ }; do
  ROLES_LIST+="$(map_agent_token "$tok") "
done
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

# ---------- theme → [names] block -------------------------------------------
# Resolve the theme into a display name per role (order: design build release
# medic scribe), then bake a [names] block into the project's config.toml so
# the runners + this installer resolve the same svc/unit names.
declare -A THEME_NAMES
# No explicit --theme on a re-run: an existing [names] block in the project's
# config is the operator's prior choice — honor it. Defaulting to plain here
# once wrote a DUPLICATE role-id unit set alongside a live themed fleet.
if [ "$THEME_EXPLICIT" = "0" ]; then
  cfg_design="$(jq -r '.names.design // empty' <<<"$CFG_JSON")"
  if [ -n "$cfg_design" ]; then
    THEME="custom:$(jq -r '[.names.design, .names.build, .names.release, .names.medic, .names.scribe] | map(. // "") | join(",")' <<<"$CFG_JSON")"
    echo "==> no --theme given; honoring existing [names] block ($THEME)"
  fi
fi
case "$THEME" in
  plain)
    THEME_NAMES=( [design]=design [build]=build [release]=release [medic]=medic [scribe]=scribe ) ;;
  spacetime)
    THEME_NAMES=( [design]=mentat [build]=helldiver [release]=proctor [medic]=suk [scribe]=chronicler ) ;;
  custom:*)
    IFS=',' read -r c_d c_b c_r c_m c_s <<<"${THEME#custom:}"
    if [ -z "$c_d" ] || [ -z "$c_b" ] || [ -z "$c_r" ] || [ -z "$c_m" ] || [ -z "$c_s" ]; then
      echo "bad --theme custom: need 5 names (design,build,release,medic,scribe)" >&2; exit 2
    fi
    THEME_NAMES=( [design]="$c_d" [build]="$c_b" [release]="$c_r" [medic]="$c_m" [scribe]="$c_s" ) ;;
  *)
    echo "unknown --theme: $THEME (want plain|spacetime|custom:d,b,r,m,s)" >&2; exit 2 ;;
esac

# Build the [names] TOML block (canonical role order).
names_block="[names]"$'\n'
for role in $QUARTET_ROLES; do
  names_block+="$role = \"${THEME_NAMES[$role]}\""$'\n'
done

echo "==> theme '$THEME' → [names] block in $CFG"
# Resolve the effective names into CFG_JSON in-memory NOW, so unit-name
# resolution (role_display) sees the theme in BOTH dry-run and real runs —
# a dry-run must show the same unit names the real run will write.
names_json="$(for role in $QUARTET_ROLES; do
    printf '%s\t%s\n' "$role" "${THEME_NAMES[$role]}"
  done | jq -R 'split("\t") | {(.[0]): .[1]}' | jq -s 'add')"
CFG_JSON="$(jq --argjson n "$names_json" '.names = $n' <<<"$CFG_JSON")"
if [ "$DRY_RUN" = "1" ]; then
  echo "  would write:"; printf '%s' "$names_block" | sed 's/^/    /'
else
  # Idempotent: strip any existing [names] block, then append the new one.
  tmp_cfg="$(mktemp)"
  awk '
    /^[[:space:]]*\[names\]/ { skip=1; next }
    skip && /^[[:space:]]*\[/ { skip=0 }
    !skip { print }
  ' "$CFG" > "$tmp_cfg"
  # Drop a trailing blank line to keep spacing tidy, then append the block.
  printf '\n%s' "$names_block" >> "$tmp_cfg"
  mv "$tmp_cfg" "$CFG"
  echo "  wrote [names] ($THEME)"
fi

# ---------- defaults (keyed by canonical role) ------------------------------
default_schedule() {
  case "$1" in
    design)  echo "*-*-* 05:00:00" ;;
    release) echo "*-*-* 06:00:00" ;;
    medic)   echo "*-*-* *:0/10:00" ;;
    build)   echo "*-*-* 03:30:00" ;;
    scribe)  echo "*-*-* 01:00:00" ;;
  esac
}
default_mode() {
  case "$1" in
    design)  echo "design" ;;
    release) echo "daily" ;;
    medic)   echo "scan" ;;
    build)   echo "live" ;;
    scribe)  echo "daily" ;;
  esac
}
description() {
  local cap="$(tr '[:lower:]' '[:upper:]' <<<"${PROJECT_NAME:0:1}")${PROJECT_NAME:1}"
  case "$1" in
    design)  echo "$cap Design — pre-build design/architecture pass" ;;
    release) echo "$cap Release — daily tests + typecheck + data audit + build" ;;
    medic)   echo "$cap Medic — failure-triggered triage agent (scan tick)" ;;
    build)   echo "$cap Build — nightly user-feedback triage + autonomous fixer" ;;
    scribe)  echo "$cap Scribe — daily doc-as-code refresh" ;;
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

for role in $ROLES_LIST; do
  # Timer schedule: config's [install.timers] wins (accept role id OR the
  # legacy display key), else the baked-in default.
  legacy_key="$(role_display "$role" '{}')"
  schedule="$(jq -r --arg r "$role" --arg l "$legacy_key" \
    '.install.timers[$r] // .install.timers[$l] // empty' <<<"$CFG_JSON")"
  [ -z "$schedule" ] && schedule="$(default_schedule "$role")"
  [ -z "$schedule" ] && { echo "  skip $role: no schedule"; continue; }
  mode="$(default_mode "$role")"
  desc="$(description "$role")"

  dir="$(dir_for_role "$role")"
  display="$(role_display "$role" "$CFG_JSON")"

  service_path="$SYSTEMD_DIR/${PROJECT_NAME}-${display}.service"
  timer_path="$SYSTEMD_DIR/${PROJECT_NAME}-${display}.timer"

  # Propagate quartet runtime knobs set at install time into the unit —
  # systemd user services get a near-empty environment otherwise, which
  # silently mutes notifications and disables medic's ops scan.
  quartet_env=""
  for var in QUARTET_NOTIFY_CMD QUARTET_OPS_JSON QUARTET_EVENTS_DIR; do
    val="${!var:-}"
    [ -n "$val" ] && quartet_env+="Environment=$var=$val"$'\n'
  done

  # The release role (tests + build) wants network; the others don't.
  unit_extras=""
  [ "$role" = "release" ] && unit_extras=$'Wants=network-online.target\nAfter=network-online.target\n'

  service_content="[Unit]
Description=$desc
${unit_extras}
[Service]
Type=oneshot
WorkingDirectory=$PROJECT_DIR
ExecStart=/bin/bash $QUARTET_DIR/agents/$dir/runner.sh --project $PROJECT_DIR --mode $mode
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
Environment=HOME=$HOME
${quartet_env}TimeoutStartSec=3900
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
  for role in $ROLES_LIST; do
    display="$(role_display "$role" "$CFG_JSON")"
    systemctl --user enable --now "${PROJECT_NAME}-${display}.timer" 2>&1 | sed 's/^/  /'
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
for role in $ROLES_LIST; do
  dir="$(dir_for_role "$role")"
  # Pre-quartet launchers are named by the legacy display (guardian/augur/…).
  legacy_name="$(role_display "$role" '{}')"
  legacy="$PROJECT_DIR/scripts/${PROJECT_NAME}-${legacy_name}.sh"
  [ -f "$legacy" ] || continue
  if grep -q "$QUARTET_DIR/agents/$dir/runner.sh" "$legacy" 2>/dev/null; then
    echo "  ok (already a shim): $legacy"
    continue
  fi
  echo "  removing legacy:    $legacy"
  companions=()
  for ext in -prompt.md -checklist.md; do
    f="$PROJECT_DIR/scripts/${PROJECT_NAME}-${legacy_name}${ext}"
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

# ---------- step 4.5: symlink shared skills + drop the gate file ------------
# The generic skills live in $QUARTET_DIR/skills and are symlinked into the
# project's .claude/skills/ so agents (headless) and humans (in-session) load
# the identical files. A core upgrade to a skill flows to every project at
# once. We NEVER touch a hub's .claude/skills here — the orchestrator owns the
# hub's own symlinking.
echo ""
echo "==> shared skills → $PROJECT_DIR/.claude/skills/"
GENERIC_SKILLS="polish-ticket execute-ticket coverage-audit write-ticket bugfix feature"
SKILLS_DEST="$PROJECT_DIR/.claude/skills"
[ "$DRY_RUN" = "1" ] || mkdir -p "$SKILLS_DEST"
for skill in $GENERIC_SKILLS; do
  src="$QUARTET_DIR/skills/$skill"
  dest="$SKILLS_DEST/$skill"
  if [ ! -d "$src" ]; then
    echo "  skip $skill: source missing ($src)"
    continue
  fi
  if [ -L "$dest" ]; then
    # Existing symlink: refresh it (cheap, idempotent).
    cur="$(readlink -f "$dest" 2>/dev/null || true)"
    if [ "$cur" = "$(readlink -f "$src")" ]; then
      echo "  unchanged: $dest -> $src"
    elif [ "$DRY_RUN" = "1" ]; then
      echo "  would relink: $dest -> $src"
    else
      ln -sfn "$src" "$dest"; echo "  relinked:  $dest -> $src"
    fi
  elif [ -e "$dest" ]; then
    # A real dir/file is there — do NOT clobber; the operator put it there.
    echo "  SKIP (exists, not a symlink — not clobbering): $dest"
  elif [ "$DRY_RUN" = "1" ]; then
    echo "  would symlink: $dest -> $src"
  else
    ln -s "$src" "$dest"; echo "  symlinked: $dest -> $src"
  fi
done

# Drop the gate file template into .agents/gates.md — but NEVER clobber an
# existing gate file (it accumulates this project's filled-in commands + the
# Traps appendix).
GATES_SRC="$QUARTET_DIR/skills/gates.md.template"
GATES_DEST="$PROJECT_DIR/.agents/gates.md"
if [ ! -f "$GATES_SRC" ]; then
  echo "  skip gates.md: template missing ($GATES_SRC)"
elif [ -f "$GATES_DEST" ]; then
  echo "  gates.md: exists — leaving as-is (never clobbered)"
elif [ "$DRY_RUN" = "1" ]; then
  echo "  would drop: $GATES_DEST (from gates.md.template)"
else
  sed "s/<PROJECT_NAME>/$PROJECT_NAME/g" "$GATES_SRC" > "$GATES_DEST"
  echo "  wrote:     $GATES_DEST (fill in the commands + gate classes)"
fi

# ---------- step 5: verification --------------------------------------------
echo ""
echo "==> verification"
all_ok=1
for role in $ROLES_LIST; do
  display="$(role_display "$role" "$CFG_JSON")"
  unit="${PROJECT_NAME}-${display}.timer"
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
  echo "install: OK"
  exit 0
else
  echo "install: incomplete (see warnings above)"
  exit 1
fi
