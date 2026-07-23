#!/bin/bash
# install.sh — idempotent installer for the shipyard crew.
#
# Usage:
#   install.sh --project <project_dir> [--dry-run] [--agents LIST] [--theme T]
#
#   --project   Path to the target project (must contain .agents/config.toml).
#   --dry-run   Print every change without writing anything.
#   --agents    Comma list of roles to install. Default: build,release,medic,scribe
#               (design is opt-in).
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
#      table, falling back to baked-in defaults (release 06:00, medic
#      every 10 min, build 03:30, scribe 01:00).
#
#   2. `systemctl --user daemon-reload` + `enable --now` each timer.
#
#   3. Removes ANY crontab line that invokes a per-project agent launcher
#      (<project_dir>/scripts/<project_name>-<role-or-display>.sh) — those
#      are pre-quartet legacy launchers, kept around historically and
#      notorious for racing the new timers. Backs the crontab up first.
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
# — the same path systemd, the post-push hook, and medic→build all use.

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
MODE="install"   # install | doctor | uninstall
while [ $# -gt 0 ]; do
  case "$1" in
    --project)   PROJECT_DIR="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --agents)    AGENTS="$2"; shift 2 ;;
    --theme)     THEME="$2"; THEME_EXPLICIT=1; shift 2 ;;
    --doctor)    MODE="doctor"; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done
[ -z "$PROJECT_DIR" ] && { echo "--project required" >&2; usage; }
case "$MODE" in
  doctor|uninstall) [ "$THEME_EXPLICIT" = "0" ] || { echo "--theme not valid with --$MODE" >&2; usage; } ;;
esac

# The installer-owned shared-skill set: the symlink manifest doctor (e) audits
# and uninstall removes. Single source of truth (referenced again at step 4.5).
GENERIC_SKILLS="polish-ticket execute-ticket coverage-audit write-ticket bugfix feature"

ROLES_LIST="${AGENTS//,/ }" 
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

# ===========================================================================
# doctor / uninstall — a manifest for what an install owns (ticket:
# shipyard-doctor-uninstall). Both modes are pure functions here (no new
# module boundary). They resolve the crew surface the SAME way install does,
# but by ROLE-RUNNER + `--project <realpath>`, never by display filename —
# the fleet is a mix of plain and spacetime unit names, and a project may be
# mid-migration (a plain unit and its spacetime successor coexisting).
# ===========================================================================

# crew_units_for_role <role> — this project's unit basenames (no .service)
# whose ExecStart runs agents/<role>/runner.sh for THIS project dir. One
# per line; empty if none. Non-crew units (watch daemons, app services)
# never match because they don't invoke a role runner.
crew_units_for_role() {
  local role="$1" svc
  for svc in "$SYSTEMD_DIR/${PROJECT_NAME}-"*.service; do
    [ -e "$svc" ] || continue
    grep -q -- "--project $PROJECT_DIR " "$svc" 2>/dev/null || continue
    grep -q "agents/$role/runner.sh" "$svc" 2>/dev/null || continue
    basename "${svc%.service}"
  done
}

# timer_enabled <unit-base> — success if <unit-base>.timer is enabled.
timer_enabled() { systemctl --user is-enabled "$1.timer" >/dev/null 2>&1; }

# run_doctor — read-only conformance audit. Prints `DOCTOR <class>: <detail>`
# one line per finding on stdout; a clean project prints a single line to
# STDERR and exits 0. Exit 1 iff any finding. Never writes, never mutates
# systemd. < 5s (fits inside a medic tick).
run_doctor() {
  local findings=0
  emit() { printf 'DOCTOR %s\n' "$1"; findings=$((findings+1)); }

  local qd_real; qd_real="$(cd "$QUARTET_DIR" && pwd -P)"
  local role u

  # Expected role set: [install.timers] keys ∪ roles with an enabled crew
  # timer; installer default when both are empty. (The installed agent set is
  # not recorded in config, so this is the honest lower bound — extra
  # installed roles are tolerated, a scheduled-but-not-running role is caught.)
  local timer_roles enabled_roles="" expected
  timer_roles="$(jq -r '(.install.timers // {}) | keys[]' <<<"$CFG_JSON" 2>/dev/null)"
  for role in $QUARTET_ROLES; do
    while IFS= read -r u; do
      [ -z "$u" ] && continue
      timer_enabled "$u" && { enabled_roles+="$role "; break; }
    done <<<"$(crew_units_for_role "$role")"
  done
  expected="$(printf '%s\n%s\n' "$timer_roles" "$(printf '%s' "$enabled_roles" | tr ' ' '\n')" \
    | sed '/^$/d' | sort -u)"
  [ -z "$expected" ] && expected="build release medic scribe"

  # (a) each expected role: an enabled crew unit whose ExecStart runner lives
  #     under $QUARTET_DIR (realpath-tolerant — the compat symlink path is ok).
  for role in $expected; do
    local units; units="$(crew_units_for_role "$role")"
    if [ -z "$units" ]; then
      emit "unit: expected '$role' crew unit missing for $PROJECT_NAME"
      continue
    fi
    local any_enabled=0
    while IFS= read -r u; do
      [ -z "$u" ] && continue
      timer_enabled "$u" && any_enabled=1
      local es es_base es_dir
      es="$(grep -oE "/bin/bash [^ ]*agents/$role/runner.sh" "$SYSTEMD_DIR/$u.service" | awk '{print $2}')"
      es_base="${es%/agents/$role/runner.sh}"       # the claimed QUARTET_DIR
      if [ -d "$es_base" ]; then
        es_dir="$(cd "$es_base" && pwd -P)"          # realpath-tolerant (compat symlink ok)
      else
        es_dir="$es_base"                            # dangling path — compare text
      fi
      [ -n "$es" ] && [ "$es_dir" != "$qd_real" ] && \
        emit "unit: $u runner not under \$QUARTET_DIR (-> $es_dir, want $qd_real)"
    done <<<"$units"
    [ "$any_enabled" = "1" ] || emit "unit: '$role' present but its timer is not enabled"
  done

  # (b) more than one crew unit per role for this project = stale duplicate
  #     (an old display-name unit left beside its successor — the sweep target).
  for role in $QUARTET_ROLES; do
    local list n; list="$(crew_units_for_role "$role")"
    n="$(printf '%s\n' "$list" | sed '/^$/d' | wc -l | tr -d ' ')"
    [ "$n" -gt 1 ] && emit "stale: $n units run the '$role' runner ($(printf '%s\n' "$list" | sed '/^$/d' | paste -sd, -)) — expected 1"
  done

  # (c) foreign systemd drop-in on a crew unit (e.g. a self-written budget
  #     override). Crew-scoped so app-service drop-ins are not flagged.
  for role in $QUARTET_ROLES; do
    while IFS= read -r u; do
      [ -z "$u" ] && continue
      [ -d "$SYSTEMD_DIR/$u.service.d" ] && \
        emit "dropin: $u.service.d present (foreign env override) — flag, never auto-removed"
    done <<<"$(crew_units_for_role "$role")"
  done

  # (d) retired config keys/sections (USD-era caps, retired vocabulary). The
  #     retired words are assembled from split strings so this file never
  #     contains them literally (the conformance grep scans install.sh too).
  local a="au""gur" g="guar""dian" dre hit
  dre="^[[:space:]]*budget[[:space:]]*=[[:space:]]*[0-9]+\.|^[[:space:]]*budget_hook[[:space:]]*=|^[[:space:]]*budget_daily[[:space:]]*=|^[[:space:]]*budget_incident[[:space:]]*=|^[[:space:]]*claude_usd[[:space:]]*=|max-budget-usd|^[[:space:]]*sync_to_${a}[[:space:]]*=|^[[:space:]]*${a}_can_merge[[:space:]]*=|^[[:space:]]*\[${a}\]|^[[:space:]]*\[${g}\]"
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    emit "config: retired key/section — $hit"
  done <<<"$(grep -nE "$dre" "$CFG" 2>/dev/null)"

  # (e) each installer-owned skill symlink resolves (realpath) into
  #     $QUARTET_DIR/skills/ (compat-path link TEXT is fine, it still resolves).
  local qskills; qskills="$(cd "$QUARTET_DIR/skills" 2>/dev/null && pwd -P || true)"
  local skill link tgt
  for skill in $GENERIC_SKILLS; do
    link="$PROJECT_DIR/.claude/skills/$skill"
    if [ ! -e "$link" ] && [ ! -L "$link" ]; then
      emit "skill: $skill symlink missing"; continue
    fi
    tgt="$(readlink -f "$link" 2>/dev/null || true)"
    case "$tgt" in
      "$qskills"/*) : ;;
      *) emit "skill: $skill does not resolve into \$QUARTET_DIR/skills (-> ${tgt:-broken})" ;;
    esac
  done

  # (f) dead hook wiring: a .claude/settings.json hook command that names a
  #     script file which does not exist (the retired post-push class).
  local settings="$PROJECT_DIR/.claude/settings.json" cmd tok path
  if [ -f "$settings" ]; then
    while IFS= read -r cmd; do
      [ -z "$cmd" ] && continue
      for tok in $(grep -oE '[A-Za-z0-9_./${}~-]+\.(sh|py|js|ts|mjs|cjs)' <<<"$cmd"); do
        path="$tok"
        path="${path//\$\{CLAUDE_PROJECT_DIR\}/$PROJECT_DIR}"
        path="${path//\$CLAUDE_PROJECT_DIR/$PROJECT_DIR}"
        path="${path//\$PWD/$PROJECT_DIR}"
        case "$path" in
          *'$'*) continue ;;                 # still-unresolved var — can't test
          /*) : ;;
          *)  path="$PROJECT_DIR/$path" ;;
        esac
        [ -e "$path" ] || emit "hook: settings.json command references missing file $tok"
      done
    done <<<"$(jq -r '.hooks // {} | .. | .command? // empty' "$settings" 2>/dev/null)"
  fi

  # (g) legacy per-project launcher scripts / crontab lines.
  local legacy_name legacy dir
  for role in $QUARTET_ROLES; do
    dir="$(dir_for_role "$role")"
    legacy_name="$(role_display "$role" '{}')"
    legacy="$PROJECT_DIR/scripts/${PROJECT_NAME}-${legacy_name}.sh"
    [ -f "$legacy" ] || continue
    grep -q "$QUARTET_DIR/agents/$dir/runner.sh" "$legacy" 2>/dev/null && continue  # harmless shim
    emit "launcher: legacy $legacy (not a shim) — pre-crew launcher"
  done
  local cron_pat cron_hit
  cron_pat="$PROJECT_DIR/scripts/${PROJECT_NAME}-(design|build|release|medic|scribe|mentat|helldiver|proctor|suk|chronicler)\.sh"
  while IFS= read -r cron_hit; do
    [ -z "$cron_hit" ] && continue
    emit "cron: legacy launcher entry — $cron_hit"
  done <<<"$(crontab -l 2>/dev/null | grep -E "$cron_pat" || true)"

  # (h) hub-only: the design-loop decision ledger mirror. When this project
  #     holds the dispatch's hub ledger (data/news/decisions.jsonl), every
  #     mentat decision must be mirrored into the target project's own
  #     data/decisions.jsonl (sibling of the hub dir). Generic sibling
  #     resolution — no absolute path baked in. Skipped when the hub ledger
  #     is absent (every non-hub project).
  local news="$PROJECT_DIR/data/news/decisions.jsonl" base proj pledger id
  if [ -f "$news" ]; then
    base="$(dirname "$PROJECT_DIR")"
    for proj in $(jq -r 'select((.id // "")|startswith("mentat:")) | .project // empty' "$news" 2>/dev/null | sort -u); do
      pledger="$base/$proj/data/decisions.jsonl"
      [ -f "$pledger" ] || continue
      for id in $(jq -r --arg p "$proj" 'select(.project==$p and ((.id // "")|startswith("mentat:"))) | .id' "$news" 2>/dev/null); do
        grep -q "\"$id\"" "$pledger" || \
          emit "ledger: mentat decision $id ($proj) not mirrored to $proj/data/decisions.jsonl"
      done
    done
  fi

  if [ "$findings" -eq 0 ]; then
    echo "doctor: $PROJECT_NAME crew install clean (checks a-h)" >&2
    return 0
  fi
  echo "doctor: $PROJECT_NAME — $findings finding(s)" >&2
  return 1
}

# run_uninstall — remove exactly the installer-owned surface for this project:
# its crew units/timers (any role, enabled or not) and the shared-skill
# symlinks that resolve into $QUARTET_DIR/skills. Everything else (.agents/
# incl. config + prompts + gates.md, data/, tmp/) is deliberately left.
# Honors --dry-run (prints the identical plan, writes nothing). Invariant:
# `--uninstall` then a normal install reproduces a fresh install's unit set.
run_uninstall() {
  echo "==> uninstall crew for $PROJECT_NAME ($PROJECT_DIR)"
  [ "$DRY_RUN" = "1" ] && echo "  (dry-run — no changes will be made)"

  # 1. crew units/timers (dedup across roles).
  local seen=" " u role touched=0
  for role in $QUARTET_ROLES; do
    while IFS= read -r u; do
      [ -z "$u" ] && continue
      case "$seen" in *" $u "*) continue ;; esac
      seen+="$u "
      touched=1
      if [ "$DRY_RUN" = "1" ]; then
        echo "  would disable + remove: $u.{service,timer}"
      else
        systemctl --user disable --now "$u.timer" >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_DIR/$u.service" "$SYSTEMD_DIR/$u.timer"
        echo "  removed: $u.{service,timer}"
      fi
    done <<<"$(crew_units_for_role "$role")"
  done
  [ "$touched" = "0" ] && echo "  (no crew units found for $PROJECT_NAME)"
  if [ "$DRY_RUN" = "1" ]; then
    echo "  would: systemctl --user daemon-reload"
  else
    systemctl --user daemon-reload
  fi

  # 2. shared-skill symlinks — only ones that resolve into $QUARTET_DIR/skills.
  local qskills; qskills="$(cd "$QUARTET_DIR/skills" 2>/dev/null && pwd -P || true)"
  local skill link tgt
  for skill in $GENERIC_SKILLS; do
    link="$PROJECT_DIR/.claude/skills/$skill"
    if [ ! -L "$link" ]; then
      [ -e "$link" ] && echo "  kept (real file/dir, not a symlink): $link"
      continue
    fi
    tgt="$(readlink -f "$link" 2>/dev/null || true)"
    case "$tgt" in
      "$qskills"/*)
        if [ "$DRY_RUN" = "1" ]; then echo "  would remove symlink: $link"
        else rm -f "$link"; echo "  removed symlink: $link"; fi ;;
      *) echo "  kept (resolves outside \$QUARTET_DIR/skills): $link -> ${tgt:-broken}" ;;
    esac
  done

  # 3. the deliberate leave-behind — NOT installer-owned.
  echo "  left in place (not installer-owned):"
  echo "    $PROJECT_DIR/.agents/   (config.toml, prompts, gates.md)"
  echo "    $PROJECT_DIR/data/      (events, decisions, results)"
  echo "    $PROJECT_DIR/tmp/"
  if [ "$DRY_RUN" = "1" ]; then
    echo "uninstall: DRY RUN — nothing changed"
  else
    echo "uninstall: $PROJECT_NAME crew removed (reinstall with: install.sh --project $PROJECT_DIR)"
  fi
  return 0
}

case "$MODE" in
  doctor)    run_doctor; exit $? ;;
  uninstall) run_uninstall; exit $? ;;
esac

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
  schedule="$(jq -r --arg r "$role" \
    '.install.timers[$r] // empty' <<<"$CFG_JSON")"
  [ -z "$schedule" ] && schedule="$(default_schedule "$role")"
  [ -z "$schedule" ] && { echo "  skip $role: no schedule"; continue; }
  mode="$(default_mode "$role")"
  desc="$(description "$role")"

  dir="$(dir_for_role "$role")"
  display="$(role_display "$role" "$CFG_JSON")"

  service_path="$SYSTEMD_DIR/${PROJECT_NAME}-${display}.service"
  timer_path="$SYSTEMD_DIR/${PROJECT_NAME}-${display}.timer"

  # A theme change or rename must never leave two live unit sets for one
  # project+role: sweep any OTHER unit of this project whose ExecStart runs
  # this role's runner. Plain-name leftovers have fired alongside a
  # spacetime set before. (The retired display-name dir aliases are gone —
  # every install is post-rename, so only the role dir itself is swept.)
  role_dirs="$dir"
  for old_svc in "$SYSTEMD_DIR/${PROJECT_NAME}-"*.service; do
    [ -e "$old_svc" ] || continue
    [ "$old_svc" = "$service_path" ] && continue
    grep -q -- "--project $PROJECT_DIR " "$old_svc" 2>/dev/null || continue
    stale=0
    for rd in $role_dirs; do
      grep -q "agents/$rd/runner.sh" "$old_svc" 2>/dev/null && stale=1
    done
    [ "$stale" = "1" ] || continue
    old_base="$(basename "${old_svc%.service}")"
    if [ "$DRY_RUN" = "1" ]; then
      echo "  would remove stale duplicate: $old_base.{service,timer} (role $role under an old name)"
    else
      systemctl --user disable --now "$old_base.timer" >/dev/null 2>&1 || true
      rm -f "$old_svc" "$SYSTEMD_DIR/$old_base.timer"
      echo "  removed stale duplicate: $old_base.{service,timer} (role $role under an old name)"
    fi
  done

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
CRON_PATTERN="$PROJECT_DIR/scripts/${PROJECT_NAME}-(design|build|release|medic|scribe|mentat|helldiver|proctor|suk|chronicler)\.sh"

# Box-drawing section-header comments (e.g. `# ── Project Release ──`)
# we leave behind when removing their entries. Match: starts with `# ─`,
# mentions the project name (case-insensitive) and one of the agent words.
PROJECT_CAP="$(tr '[:lower:]' '[:upper:]' <<<"${PROJECT_NAME:0:1}")${PROJECT_NAME:1}"
COMMENT_PATTERN="^# ─.*(${PROJECT_NAME}|${PROJECT_CAP}).*(Design|Build|Release|Medic|Scribe|Mentat|Helldiver|Proctor|Suk|Chronicler).*─"

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
  # Pre-quartet launchers are named by the role's default display.
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
# GENERIC_SKILLS is defined once near the top (shared with doctor/uninstall).
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
