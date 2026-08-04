#!/bin/bash
# install.sh — idempotent installer for the shipyard crew.
#
# Usage:
#   install.sh --project <project_dir> [--dry-run] [--agents LIST] [--theme T]
#   install.sh --doctor    --project <project_dir>
#   install.sh --configure-git-identity --project <project_dir>
#   install.sh --relink    --project <project_dir> [--dry-run]
#   install.sh --uninstall --project <project_dir> [--dry-run]
#
#   --project    Path to the target project (must contain .agents/config.toml).
#   --dry-run    Print every change without writing anything.
#   --agents     Comma list of roles to install. Without it, reuse configured
#                or enabled roles; a fresh project defaults to
#                build,release,medic,scribe (design is opt-in).
#   --doctor     Read-only conformance audit of this project's crew install.
#                Prints `DOCTOR <class>: <detail>` one line per finding; exit 0
#                clean / 1 on drift. Never writes, never touches the scheduler.
#                Fast
#                enough to run as a [[medic.checks]] entry every scan.
#   --configure-git-identity
#                For a project with `.shipyard-git-identity.toml` enforcement,
#                copy the effective Git name/email into repository-local
#                policy, enable `.githooks`, and verify the pending identity.
#                Email is never printed.
#   --relink     Repair mode: recreate the skill symlinks and missing skill
#                bridge --doctor flags as drift. Deterministic filesystem op —
#                touches nothing else (no scheduler/config/gate), never clobbers
#                a real file/dir. Honors --dry-run. Exit 0.
#   --uninstall  Remove exactly the installer-owned surface (scheduler jobs
#                + shared-skill symlinks resolving into $QUARTET_DIR/skills),
#                then print the deliberate leave-behind (.agents/, data/, tmp/).
#                Honors --dry-run. uninstall+install == fresh install.
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
#   1. Writes scheduler definitions for each selected agent:
#        Linux: ~/.config/systemd/user/<project>-<agent>.{service,timer}
#        macOS: ~/Library/LaunchAgents/<project>-<agent>.plist
#      Without --agents, selection preserves configured or enabled canonical
#      roles; only a fresh/undeclared project uses the four-role default.
#      Schedules come from config.toml's [install.timers] table, falling back
#      to baked-in defaults (release 06:00, medic every 10 min, build 03:30,
#      scribe 01:00). Required project prompts are validated before any write.
#
#   2. Enables each timer with systemd (Linux) or launchd (macOS).
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
#   4.5 Symlinks the shared skills from this repo's skills/ into both
#      <project_dir>/.claude/skills/ (Claude/Hermes compatibility) and
#      <project_dir>/.agents/skills/ (Codex's native repository discovery
#      root), then drops skills/gates.md.template into
#      <project_dir>/.agents/gates.md if that gate file does not already
#      exist (an existing gate file is NEVER clobbered).
#
#   4.6 Creates a root AGENTS.md skill bridge for Codex and Hermes when absent.
#       This is universal rather than tied to the current scheduled harness:
#       an operator can open either harness in every installed project.
#
#   5. Verifies each requested timer is enabled and reports the next
#      scheduled fire time.
#
# Why removal, not shimming: shims preserve a working call path but also
# preserve the surface area people forget to update. After install, the
# canonical entry point is `agents/<name>/runner.sh --project <dir> --mode X`
# — the same path the scheduler, the post-push hook, and medic→build all use.

set -uo pipefail

QUARTET_DIR="${QUARTET_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
SYSTEMD_DIR="${SHIPYARD_SYSTEMD_DIR:-$HOME/.config/systemd/user}"
LAUNCHD_DIR="${SHIPYARD_LAUNCHD_DIR:-$HOME/Library/LaunchAgents}"
LAUNCHD_LOG_DIR="${SHIPYARD_LAUNCHD_LOG_DIR:-$HOME/Library/Logs/Shipyard}"
LAUNCHD_DOMAIN="gui/$(id -u)"

detect_scheduler() {
  case "${SHIPYARD_SCHEDULER:-auto}" in
    systemd|launchd) printf '%s\n' "$SHIPYARD_SCHEDULER" ;;
    auto)
      case "$(uname -s)" in
        Darwin) printf 'launchd\n' ;;
        Linux)  printf 'systemd\n' ;;
        *) echo "unsupported platform: $(uname -s) (want Linux/systemd or macOS/launchd)" >&2; return 2 ;;
      esac
      ;;
    *) echo "bad SHIPYARD_SCHEDULER: $SHIPYARD_SCHEDULER (want auto|systemd|launchd)" >&2; return 2 ;;
  esac
}
SCHEDULER="$(detect_scheduler)" || exit $?

scheduler_dependency() {
  case "$SCHEDULER" in
    systemd) printf 'systemctl\n' ;;
    launchd) printf 'launchctl\n' ;;
  esac
}

scheduler_manifest_dir() {
  case "$SCHEDULER" in
    systemd) printf '%s\n' "$SYSTEMD_DIR" ;;
    launchd) printf '%s\n' "$LAUNCHD_DIR" ;;
  esac
}

launchd_label() { printf 'com.shipyard.%s\n' "$1"; }

xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&apos;}"
  printf '%s' "$s"
}

# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/naming.sh"

usage() {
  sed -n '2,63p' "$0"
  exit "${1:-2}"
}

# ---------- argv ------------------------------------------------------------
PROJECT_DIR=""
DRY_RUN=0
AGENTS="build,release,medic,scribe"
AGENTS_EXPLICIT=0
THEME="plain"
THEME_EXPLICIT=0
MODE="install"   # install | doctor | configure-git-identity | relink | uninstall
WIRE_SHOULDER=0  # opt-in: additively wire the shoulder-mode capture hook into
                 # the authoring harness's native config. Unset ⇒ install NEVER
                 # touches .claude/settings.json / ~/.codex / ~/.hermes.
while [ $# -gt 0 ]; do
  case "$1" in
    --project)   PROJECT_DIR="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --agents)    AGENTS="$2"; AGENTS_EXPLICIT=1; shift 2 ;;
    --theme)     THEME="$2"; THEME_EXPLICIT=1; shift 2 ;;
    --doctor)    MODE="doctor"; shift ;;
    --configure-git-identity) MODE="configure-git-identity"; shift ;;
    --relink)    MODE="relink"; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    --wire-shoulder) WIRE_SHOULDER=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done
[ -z "$PROJECT_DIR" ] && { echo "--project required" >&2; usage; }
case "$MODE" in
  doctor|configure-git-identity|uninstall|relink)
    [ "$THEME_EXPLICIT" = "0" ] ||
      { echo "--theme not valid with --$MODE" >&2; usage; }
    ;;
esac
if [ "$MODE" = "configure-git-identity" ]; then
  [ "$DRY_RUN" = "0" ] && [ "$WIRE_SHOULDER" = "0" ] || {
    echo "--dry-run/--wire-shoulder not valid with --configure-git-identity" >&2
    usage
  }
fi

# Dependency preflight — fail fast with a scheduler-specific message.
for dep in jq python3 git gh claude "$(scheduler_dependency)"; do
  command -v "$dep" >/dev/null 2>&1 || {
    echo "missing dependency: $dep (see README Requirements)" >&2; exit 2; }
done
BASH_BIN="/bin/bash"
if [ "$SCHEDULER" = "launchd" ]; then
  for dep in plutil timeout sha256sum; do
    command -v "$dep" >/dev/null 2>&1 || {
      echo "missing macOS dependency: $dep (run: brew install coreutils jq)" >&2; exit 2; }
  done
fi

# The installer-owned shared-skill set: the symlink manifest doctor (e) audits
# and uninstall removes. Single source of truth (referenced again at step 4.5).
GENERIC_SKILLS="polish-ticket execute-ticket coverage-audit write-ticket bugfix feature shipyard ui-design"

ROLES_LIST="${AGENTS//,/ }" 
PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd)" || \
  { echo "project_dir not found: $PROJECT_DIR" >&2; exit 2; }

CFG="$PROJECT_DIR/.agents/config.toml"
[ -f "$CFG" ] || { echo "config not found: $CFG" >&2; exit 2; }

# ---------- load config -----------------------------------------------------
# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/load-config.sh"
CFG_JSON="$(load_config_json "$CFG")" || { echo "failed to parse $CFG" >&2; exit 2; }

PROJECT_NAME="$(jq_from_json "$CFG_JSON" -r '.project_name // empty')"
[ -z "$PROJECT_NAME" ] && { echo "config missing project_name" >&2; exit 2; }
IDENTITY_POLICY_FILE="$PROJECT_DIR/.shipyard-git-identity.toml"

SHOULDER_AUTO="$(jq_from_json "$CFG_JSON" -r '.shoulder.auto_wire // false')"
SHOULDER_MULTI="$(jq_from_json "$CFG_JSON" -r '
  if (.shoulder | type) == "object" and (.shoulder | has("harnesses"))
  then "true" else "false" end')"
if [ "$SHOULDER_MULTI" = "true" ]; then
  jq_from_json "$CFG_JSON" -e '
    (.shoulder.harnesses | type) == "array" and
    (.shoulder.harnesses | length) >= 2 and
    (all(.shoulder.harnesses[]; . == "claude" or . == "codex")) and
    ((.shoulder.harnesses | unique | length) == (.shoulder.harnesses | length)) and
    (.shoulder | has("harness") | not)
  ' >/dev/null || {
    echo "invalid [shoulder] harnesses (want ordered unique [\"claude\",\"codex\"] and no scalar harness)" >&2
    exit 2
  }
  SHOULDER_HARNESSES="$(jq_from_json "$CFG_JSON" -r '.shoulder.harnesses | join(",")')"
  SHOULDER_HARNESS="$(jq_from_json "$CFG_JSON" -r '.shoulder.harnesses[0]')"
else
  SHOULDER_HARNESS="$(
    jq_from_json "$CFG_JSON" -r '.shoulder.harness // .harness.default // "claude"'
  )"
  SHOULDER_HARNESSES="$SHOULDER_HARNESS"
fi
SHOULDER_HAS_CODEX=false
case ",$SHOULDER_HARNESSES," in
  *,codex,*) SHOULDER_HAS_CODEX=true ;;
esac
SHOULDER_CRITIC_HARNESS="$(
  jq_from_json "$CFG_JSON" -r \
    '.shoulder.critic_harness // .shoulder.harnesses[0] // .shoulder.harness // .harness.default // "claude"' \
)"
for shoulder_key in harness critic_harness; do
  case "$shoulder_key" in
    harness) shoulder_value="$SHOULDER_HARNESS" ;;
    critic_harness) shoulder_value="$SHOULDER_CRITIC_HARNESS" ;;
  esac
  case "$shoulder_value" in
    claude|codex|hermes) : ;;
    *)
      echo "invalid [shoulder] $shoulder_key '$shoulder_value' (want claude|codex|hermes)" >&2
      exit 2
      ;;
  esac
done

# Configure the opt-in Git identity policy from effective Git configuration.
# Values are validated before any local key is written, and email is never
# copied into stdout/stderr.
run_configure_git_identity() {
  local owner policy_json policy_enabled policy_name
  local effective_name effective_email root
  owner="$(jq_from_json "$CFG_JSON" -r '.project_owner // empty')"
  [ -f "$IDENTITY_POLICY_FILE" ] || {
    echo "git-identity: tracked policy is missing" >&2
    return 2
  }
  policy_json="$(load_config_json "$IDENTITY_POLICY_FILE" 2>/dev/null)" || {
    echo "git-identity: tracked policy is malformed" >&2
    return 2
  }
  policy_enabled="$(jq_from_json "$policy_json" -r '(.git_identity.enforce // false) == true')"
  policy_name="$(jq_from_json "$policy_json" -r '.git_identity.name // empty')"

  [ "$policy_enabled" = "true" ] || {
    echo "git-identity: tracked policy is not enabled" >&2
    return 2
  }
  [ -n "$policy_name" ] || {
    echo "git-identity: tracked name is missing" >&2
    return 2
  }
  if [ -n "$owner" ] && [ "$policy_name" != "$owner" ]; then
    echo "git-identity: tracked name must match project_owner" >&2
    return 2
  fi
  root="$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "git-identity: project is not a Git worktree" >&2
    return 2
  }
  [ "$(cd "$root" && pwd -P)" = "$(cd "$PROJECT_DIR" && pwd -P)" ] || {
    echo "git-identity: project must be the Git worktree root" >&2
    return 2
  }

  effective_name="$(git -C "$PROJECT_DIR" config --get user.name 2>/dev/null)" || {
    echo "git-identity: effective user.name is missing" >&2
    return 2
  }
  effective_email="$(git -C "$PROJECT_DIR" config --get user.email 2>/dev/null)" || {
    echo "git-identity: effective user.email is missing" >&2
    return 2
  }
  [ "$effective_name" = "$policy_name" ] || {
    if [ -n "$owner" ]; then
      echo "git-identity: effective user.name does not match project_owner" >&2
    else
      echo "git-identity: effective user.name does not match tracked name" >&2
    fi
    return 2
  }
  case "$effective_email" in
    ""|*$'\n'*|*$'\r'*|*" "*|*"<"*|*">"*|*@|@*)
      echo "git-identity: effective user.email is malformed" >&2
      return 2
      ;;
    *@*) ;;
    *)
      echo "git-identity: effective user.email is malformed" >&2
      return 2
      ;;
  esac

  git -C "$PROJECT_DIR" config --local --replace-all user.name "$effective_name" &&
    git -C "$PROJECT_DIR" config --local --replace-all user.email "$effective_email" &&
    git -C "$PROJECT_DIR" config --local --replace-all \
      shipyard.identityEmail "$effective_email" &&
    git -C "$PROJECT_DIR" config --local --replace-all core.hooksPath .githooks || {
      echo "git-identity: could not write repository-local policy" >&2
      return 2
    }

  "$BASH_BIN" "$QUARTET_DIR/scripts/check-git-identity.sh" \
    --current --project "$PROJECT_DIR" || return $?
  printf 'git-identity: configured name=%s email=<redacted>\n' \
    "$effective_name"
}

# ===========================================================================
# doctor / uninstall — a manifest for what an install owns (ticket:
# shipyard-doctor-uninstall). Both modes are pure functions here (no new
# module boundary). They resolve the crew surface the SAME way install does,
# but by ROLE-RUNNER + `--project <realpath>`, never by display filename —
# the fleet is a mix of plain and spacetime unit names, and a project may be
# mid-migration (a plain unit and its spacetime successor coexisting).
# ===========================================================================

# crew_units_for_role <role> — this project's scheduler basenames (without
# .service/.plist) whose command runs agents/<role>/runner.sh for THIS project
# dir. One per line; empty if none. Non-crew jobs never match.
manifest_matches_project() {
  local manifest="$1" claimed claimed_real
  grep -Fq -- "--project $PROJECT_DIR " "$manifest" 2>/dev/null && return 0
  grep -Fq "<string>$PROJECT_DIR</string>" "$manifest" 2>/dev/null && return 0

  while IFS= read -r claimed; do
    [ -d "$claimed" ] || continue
    claimed_real="$(cd "$claimed" 2>/dev/null && pwd -P)" || continue
    [ "$claimed_real" = "$(cd "$PROJECT_DIR" && pwd -P)" ] && return 0
  done < <(
    {
      sed -n 's#.*--project \([^ ]*\) .*#\1#p' "$manifest"
      sed -n 's#.*<string>\([^<]*\)</string>.*#\1#p' "$manifest"
    } 2>/dev/null
  )
  return 1
}

crew_units_for_role() {
  local role="$1" manifest
  case "$SCHEDULER" in
    systemd)
      for manifest in "$SYSTEMD_DIR/${PROJECT_NAME}-"*.service; do
        [ -e "$manifest" ] || continue
        manifest_matches_project "$manifest" || continue
        grep -Fq "agents/$role/runner.sh" "$manifest" 2>/dev/null || continue
        basename "${manifest%.service}"
      done
      ;;
    launchd)
      for manifest in "$LAUNCHD_DIR/${PROJECT_NAME}-"*.plist; do
        [ -e "$manifest" ] || continue
        manifest_matches_project "$manifest" || continue
        grep -Fq "agents/$role/runner.sh" "$manifest" 2>/dev/null || continue
        basename "${manifest%.plist}"
      done
      ;;
  esac
}

# timer_enabled <unit-base> — success if the scheduler job is loaded/enabled.
timer_enabled() {
  case "$SCHEDULER" in
    systemd) systemctl --user is-enabled "$1.timer" >/dev/null 2>&1 ;;
    launchd) launchctl print "$LAUNCHD_DOMAIN/$(launchd_label "$1")" >/dev/null 2>&1 ;;
  esac
}

# resolve_effective_roles — print the role set shared by install and Doctor.
# An explicit --agents list is authoritative and keeps caller order. Otherwise
# use configured timer keys union roles with a currently enabled canonical crew
# job, in canonical order. Only a genuinely fresh/undeclared project gets the
# historical four-role default.
resolve_effective_roles() {
  local role unit requested="${AGENTS//,/ }" timer_roles enabled=0 resolved=""
  if [ "$AGENTS_EXPLICIT" = "1" ]; then
    [ -n "$requested" ] || {
      echo "--agents requires at least one role" >&2
      return 2
    }
    for role in $requested; do
      case " $QUARTET_ROLES " in
        *" $role "*) : ;;
        *)
          echo "unknown role in --agents: $role (want design,build,release,medic,scribe)" >&2
          return 2
          ;;
      esac
    done
    printf '%s\n' "$requested"
    return 0
  fi

  timer_roles="$(
    jq_from_json "$CFG_JSON" -r '(.install.timers // {}) | keys[]' 2>/dev/null
  )"
  for role in $QUARTET_ROLES; do
    if printf '%s\n' "$timer_roles" | grep -Fxq "$role"; then
      resolved="${resolved:+$resolved }$role"
      continue
    fi
    enabled=0
    while IFS= read -r unit; do
      [ -n "$unit" ] || continue
      if timer_enabled "$unit"; then
        enabled=1
        break
      fi
    done <<<"$(crew_units_for_role "$role")"
    [ "$enabled" = "1" ] && resolved="${resolved:+$resolved }$role"
  done
  [ -n "$resolved" ] || resolved="build release medic scribe"
  printf '%s\n' "$resolved"
}

required_prompt_for_role() {
  case "$1" in
    build|release|medic|scribe)
      printf '%s/.agents/%s.md\n' "$PROJECT_DIR" "$1"
      ;;
    design) return 1 ;;
  esac
}

# Explicit prompt preflight is intentionally before any install write or
# scheduler call. Implicit selection may make read-only scheduler queries while
# resolving the enabled-role half of the eligibility union, but still performs
# no mutation before every required prompt is known to exist.
preflight_required_prompts() {
  local role prompt missing=""
  for role in $ROLES_LIST; do
    prompt="$(required_prompt_for_role "$role" || true)"
    [ -z "$prompt" ] || [ -f "$prompt" ] ||
      missing+="${missing:+$'\n'}  $role: $prompt"
  done
  [ -z "$missing" ] && return 0
  printf 'install: missing required project prompts\n%s\n' "$missing" >&2
  return 2
}

crew_manifest_path() {
  case "$SCHEDULER" in
    systemd) printf '%s/%s.service\n' "$SYSTEMD_DIR" "$1" ;;
    launchd) printf '%s/%s.plist\n' "$LAUNCHD_DIR" "$1" ;;
  esac
}

runner_path_from_manifest() {
  local role="$1" unit="$2" manifest
  manifest="$(crew_manifest_path "$unit")"
  case "$SCHEDULER" in
    systemd)
      grep -oE "/bin/bash [^ ]*agents/$role/runner.sh" "$manifest" 2>/dev/null | awk '{print $2}'
      ;;
    launchd)
      sed -n "s#.*<string>\\([^<]*agents/$role/runner.sh\\)</string>.*#\\1#p" "$manifest" | head -1
      ;;
  esac
}

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
  # job; installer default when both are empty. (The installed agent set is
  # not recorded in config, so this is the honest lower bound — extra
  # installed roles are tolerated, a scheduled-but-not-running role is caught.)
  local expected
  expected="$(resolve_effective_roles)" || return $?

  # (a) each expected role: an enabled crew unit whose ExecStart runner lives
  #     under $QUARTET_DIR (realpath-tolerant — the compat symlink path is ok).
  for role in $expected; do
    local prompt
    prompt="$(required_prompt_for_role "$role" || true)"
    if [ -n "$prompt" ] && [ ! -f "$prompt" ]; then
      emit "prompt: expected '$role' project prompt missing: $prompt"
    fi
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
      es="$(runner_path_from_manifest "$role" "$u")"
      es_base="${es%/agents/$role/runner.sh}"       # the claimed QUARTET_DIR
      if [ -d "$es_base" ]; then
        es_dir="$(cd "$es_base" && pwd -P)"          # realpath-tolerant (compat symlink ok)
      else
        es_dir="$es_base"                            # dangling path — compare text
      fi
      [ -n "$es" ] && [ "$es_dir" != "$qd_real" ] && \
        emit "unit: $u runner not under \$QUARTET_DIR (-> $es_dir, want $qd_real)"
    done <<<"$units"
    if [ "$any_enabled" != "1" ]; then
      case "$SCHEDULER" in
        systemd) emit "unit: '$role' present but its timer is not enabled" ;;
        launchd) emit "unit: '$role' present but its scheduler job is not enabled" ;;
      esac
    fi
  done

  # (b) more than one crew unit per role for this project = stale duplicate
  #     (an old display-name unit left beside its successor — the sweep target).
  for role in $QUARTET_ROLES; do
    local list n; list="$(crew_units_for_role "$role")"
    n="$(printf '%s\n' "$list" | sed '/^$/d' | wc -l | tr -d ' ')"
    [ "$n" -gt 1 ] && emit "stale: $n units run the '$role' runner ($(printf '%s\n' "$list" | sed '/^$/d' | paste -sd, -)) — expected 1"
  done

  # (c) foreign systemd drop-in on a crew unit (e.g. a self-written budget
  #     override). launchd has no drop-in mechanism.
  if [ "$SCHEDULER" = "systemd" ]; then
    for role in $QUARTET_ROLES; do
      while IFS= read -r u; do
        [ -z "$u" ] && continue
        [ -d "$SYSTEMD_DIR/$u.service.d" ] && \
          emit "dropin: $u.service.d present (foreign env override) — flag, never auto-removed"
      done <<<"$(crew_units_for_role "$role")"
    done
  fi

  # (d) retired config keys/sections (USD-era caps, retired vocabulary). The
  #     retired words are assembled from split strings so this file never
  #     contains them literally (the conformance grep scans install.sh too).
  local a="au""gur" g="guar""dian" dre hit
  dre="^[[:space:]]*budget[[:space:]]*=[[:space:]]*[0-9]+\.|^[[:space:]]*budget_hook[[:space:]]*=|^[[:space:]]*budget_daily[[:space:]]*=|^[[:space:]]*budget_incident[[:space:]]*=|^[[:space:]]*claude_usd[[:space:]]*=|max-budget-usd|^[[:space:]]*sync_to_${a}[[:space:]]*=|^[[:space:]]*${a}_can_merge[[:space:]]*=|^[[:space:]]*\[${a}\]|^[[:space:]]*\[${g}\]"
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    emit "config: retired key/section — $hit"
  done <<<"$(grep -nE "$dre" "$CFG" 2>/dev/null)"

  # (e) repository-local Git identity policy — strictly opt-in. An absent root
  #     policy file performs no local Git reads and emits no findings.
  local identity_policy_json="" identity_enabled=false
  local identity_name identity_owner
  if [ -f "$IDENTITY_POLICY_FILE" ]; then
    identity_policy_json="$(
      load_config_json "$IDENTITY_POLICY_FILE" 2>/dev/null
    )" || emit "identity: tracked policy is malformed"
    if [ -n "$identity_policy_json" ]; then
      identity_enabled="$(
        jq_from_json "$identity_policy_json" -r \
          '(.git_identity.enforce // false) == true'
      )"
    fi
  fi
  if [ "$identity_enabled" = "true" ]; then
    identity_name="$(jq_from_json "$identity_policy_json" -r '.git_identity.name // empty')"
    identity_owner="$(jq_from_json "$CFG_JSON" -r '.project_owner // empty')"
    if [ -z "$identity_name" ]; then
      emit "identity: tracked name is missing"
    elif [ -n "$identity_owner" ] && [ "$identity_name" != "$identity_owner" ]; then
      emit "identity: tracked name must match project_owner"
    fi

    local identity_local_name identity_local_email identity_canonical_email
    local identity_hooks
    identity_local_name="$(
      git -C "$PROJECT_DIR" config --local --get-all user.name 2>/dev/null || true
    )"
    identity_local_email="$(
      git -C "$PROJECT_DIR" config --local --get-all user.email 2>/dev/null || true
    )"
    identity_canonical_email="$(
      git -C "$PROJECT_DIR" config --local --get-all \
        shipyard.identityEmail 2>/dev/null || true
    )"
    identity_hooks="$(
      git -C "$PROJECT_DIR" config --local --get-all core.hooksPath 2>/dev/null || true
    )"

    [ "$identity_local_name" = "$identity_name" ] ||
      emit "identity: local user.name does not match tracked name"
    case "$identity_canonical_email" in
      "") emit "identity: local canonical email is missing" ;;
      *$'\n'*) emit "identity: local canonical email must have one value" ;;
    esac
    if [ -n "$identity_canonical_email" ] &&
       [[ "$identity_canonical_email" != *$'\n'* ]] &&
       [ "$identity_local_email" != "$identity_canonical_email" ]; then
      emit "identity: local user.email does not match canonical email"
    fi
    [ "$identity_hooks" = ".githooks" ] ||
      emit "identity: core.hooksPath must be .githooks"
  fi

  # (f) each installer-owned skill link resolves (realpath) into
  #     $QUARTET_DIR/skills/. Codex natively discovers the .agents/skills
  #     root; .claude/skills remains the Claude/Hermes compatibility root.
  local qskills; qskills="$(cd "$QUARTET_DIR/skills" 2>/dev/null && pwd -P || true)"
  local skill link tgt skill_root skill_label
  for skill_root in "$PROJECT_DIR/.claude/skills" "$PROJECT_DIR/.agents/skills"; do
    skill_label=""
    [ "$skill_root" = "$PROJECT_DIR/.agents/skills" ] && skill_label="codex "
    for skill in $GENERIC_SKILLS; do
      link="$skill_root/$skill"
      if [ ! -e "$link" ] && [ ! -L "$link" ]; then
        emit "${skill_label}skill: $skill symlink missing"; continue
      fi
      tgt="$(readlink -f "$link" 2>/dev/null || true)"
      case "$tgt" in
        "$qskills"/*) : ;;
        *) emit "${skill_label}skill: $skill does not resolve into \$QUARTET_DIR/skills (-> ${tgt:-broken})" ;;
      esac
    done
  done

  # (f) the cross-harness skill bridge is present. Its content is deliberately
  # not audited: an existing AGENTS.md is project-owned and must never be
  # rewritten by Shipyard.
  if [ ! -e "$PROJECT_DIR/AGENTS.md" ] && [ ! -L "$PROJECT_DIR/AGENTS.md" ]; then
    emit "skill bridge: AGENTS.md missing"
  fi

  # (g) dead hook wiring in the same Claude settings target shoulder wiring
  #     owns. A tracked settings.json is policy, so the local sibling is used.
  # shellcheck source=agents/lib/shoulder-wire.sh
  . "$QUARTET_DIR/agents/lib/shoulder-wire.sh"
  local settings cmd tok path
  settings="$(sw_config_path claude "$PROJECT_DIR")"
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

  # (h) legacy per-project launcher scripts / crontab lines.
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

  # (i) hub-only: the design-loop decision ledger mirror. When this project
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

  # (j) shoulder-mode wiring drift — only when this project OPTED IN (config
  #     auto_wire, a delivery env, or an installed watcher). A project that
  #     never enabled shoulder mode is not drifted for lacking this surface.
  local sh_auto sh_env sh_release_display sh_watch_base sh_watch_unit sh_watch_path
  sh_auto="$SHOULDER_AUTO"
  sh_env="$PROJECT_DIR/.agents/shoulder.env"
  sh_release_display="$(role_display release "$CFG_JSON")"
  sh_watch_base="${PROJECT_NAME}-${sh_release_display}-watch"
  case "$SCHEDULER" in
    systemd)
      sh_watch_unit="$sh_watch_base.service"
      sh_watch_path="$SYSTEMD_DIR/$sh_watch_unit"
      ;;
    launchd)
      sh_watch_unit="$(launchd_label "$sh_watch_base")"
      sh_watch_path="$LAUNCHD_DIR/$sh_watch_base.plist"
      ;;
  esac
  if [ "$sh_auto" = "true" ] || [ -f "$sh_env" ] ||
     [ -f "$sh_watch_path" ]; then
    # shellcheck source=agents/lib/shoulder-wire.sh
    . "$QUARTET_DIR/agents/lib/shoulder-wire.sh"
    local sh_h sh_critic sh_cfg sh_q sh_feedback sh_stop sh_namespace sh_command
    local sh_definition expected sh_loaded sh_old_ifs
    sh_critic="$SHOULDER_CRITIC_HARNESS"
    sh_old_ifs="$IFS"; IFS=,
    for sh_h in $SHOULDER_HARNESSES; do
      IFS="$sh_old_ifs"
      sh_namespace=""
      [ "$SHOULDER_MULTI" != "true" ] || [ "$sh_h" = "$SHOULDER_HARNESS" ] || sh_namespace="$sh_h"
      sh_cfg="$(sw_config_path "$sh_h" "$PROJECT_DIR")"
      sh_q="$QUARTET_DIR/agents/release/critic-queue-${sh_h}.sh"
      [ "$sh_h" = "claude" ] && sh_q="$QUARTET_DIR/agents/release/critic-queue.sh"
      if [ "$sh_h" = "codex" ]; then
        sh_feedback="$QUARTET_DIR/agents/release/critic-codex-feedback.sh"
        sh_stop="$QUARTET_DIR/agents/release/critic-stop-gate-codex.sh"
      if [ "$SHOULDER_MULTI" = "true" ] && [ -n "$sh_namespace" ]; then
        if [ ! -f "$sh_cfg" ] || ! sw_codex_bundle_scoped_wired \
             "$sh_cfg" "$PROJECT_DIR" "$sh_q" "$sh_feedback" "$sh_stop" "$sh_namespace"; then
          emit "shoulder: codex three-hook definition missing in $sh_cfg (run install.sh --wire-shoulder)"
        else
          sh_definition="$(sw_codex_scoped_definition_hash \
            "$PROJECT_DIR" "$sh_q" "$sh_feedback" "$sh_stop" "$sh_namespace")"
          if ! sw_codex_runtime_verified "$PROJECT_DIR" "$sh_definition"; then
            emit "shoulder: codex configured but trust/runtime unverified since install"
          fi
        fi
      elif [ ! -f "$sh_cfg" ] ||
           ! sw_codex_bundle_wired \
             "$sh_cfg" "$PROJECT_DIR" "$sh_q" "$sh_feedback" "$sh_stop"; then
        emit "shoulder: codex three-hook definition missing in $sh_cfg (run install.sh --wire-shoulder)"
      else
        sh_definition="$(sw_codex_definition_hash \
          "$PROJECT_DIR" "$sh_q" "$sh_feedback" "$sh_stop")"
        if ! sw_codex_runtime_verified "$PROJECT_DIR" "$sh_definition"; then
          emit "shoulder: codex configured but trust/runtime unverified since install"
        fi
      fi
      else
        sh_command="$sh_q"
        [ -z "$sh_namespace" ] || sh_command="CRITIC_QUEUE_NAMESPACE=$sh_namespace CRITIC_AUTHOR_HARNESS=$sh_h /bin/bash $sh_q"
        if [ ! -f "$sh_cfg" ] || ! sw_wired "$sh_h" "$sh_cfg" "$sh_command"; then
          emit "shoulder: $sh_h capture hook not wired in $sh_cfg (run install.sh --wire-shoulder)"
        fi
      fi
      IFS=,
    done
    IFS="$sh_old_ifs"

    if [ ! -f "$sh_env" ]; then
      emit "shoulder: delivery env $sh_env missing (run install.sh --wire-shoulder)"
    else
      expected="$(printf 'CRITIC_PROJECT_DIR=%q' "$PROJECT_DIR")"
      grep -Fxq "$expected" "$sh_env" ||
        emit "shoulder: delivery env missing canonical CRITIC_PROJECT_DIR"
      expected="$(printf 'CRITIC_HARNESS=%q' "$sh_critic")"
      grep -Fxq "$expected" "$sh_env" ||
        emit "shoulder: delivery env missing configured CRITIC_HARNESS"
      expected="$(printf 'CRITIC_NOTE_HARNESS=%q' "$SHOULDER_HARNESS")"
      grep -Fxq "$expected" "$sh_env" ||
        emit "shoulder: delivery env missing authoring CRITIC_NOTE_HARNESS"
      if [ "$SHOULDER_MULTI" = "true" ]; then
        grep -Fxq "CRITIC_MULTI_AUTHOR=true" "$sh_env" ||
          emit "shoulder: delivery env missing multi-author mode"
        grep -Fxq "CRITIC_AUTHOR_HARNESSES=$SHOULDER_HARNESSES" "$sh_env" ||
          emit "shoulder: delivery env missing configured author list"
      fi
    fi

    if [ "$SCHEDULER" = "systemd" ]; then
      if [ ! -f "$sh_watch_path" ]; then
        emit "shoulder: watcher unit $sh_watch_unit missing"
      else
        grep -Fxq "WorkingDirectory=$PROJECT_DIR" "$sh_watch_path" ||
          emit "shoulder: watcher WorkingDirectory is not canonical"
        grep -Fxq "EnvironmentFile=-$sh_env" "$sh_watch_path" ||
          emit "shoulder: watcher EnvironmentFile is missing or stale"
        grep -Fxq \
          "ExecStart=/bin/bash $QUARTET_DIR/agents/release/critic-watch.sh --project $PROJECT_DIR" \
          "$sh_watch_path" ||
          emit "shoulder: watcher ExecStart is missing or non-canonical"
        systemctl --user is-active "$sh_watch_unit" >/dev/null 2>&1 ||
          emit "shoulder: watcher unit $sh_watch_unit is not active"
        sh_loaded="$(
          systemctl --user show "$sh_watch_unit" \
            --property=FragmentPath \
            --property=ExecStart \
            --property=EnvironmentFiles 2>/dev/null
        )" || sh_loaded=""
        if [ -z "$sh_loaded" ]; then
          emit "shoulder: loaded watcher definition could not be inspected"
        else
          grep -Fxq "FragmentPath=$sh_watch_path" <<<"$sh_loaded" ||
            emit "shoulder: loaded watcher FragmentPath is stale"
          grep -Fq \
            "$QUARTET_DIR/agents/release/critic-watch.sh --project $PROJECT_DIR" \
            <<<"$sh_loaded" ||
            emit "shoulder: loaded watcher ExecStart is stale"
          grep -Fq "$sh_env" <<<"$sh_loaded" ||
            emit "shoulder: loaded watcher EnvironmentFile is stale"
        fi
      fi
    elif [ "$SCHEDULER" = "launchd" ]; then
      if [ ! -f "$sh_watch_path" ]; then
        emit "shoulder: watcher plist $sh_watch_path missing"
      else
        plutil -lint "$sh_watch_path" >/dev/null 2>&1 ||
          emit "shoulder: watcher plist is malformed"
        grep -Fq "<string>$(xml_escape "$QUARTET_DIR/agents/release/critic-watch.sh")</string>" \
          "$sh_watch_path" || emit "shoulder: watcher program is missing or stale"
        grep -Fq "<string>$(xml_escape "$PROJECT_DIR")</string>" \
          "$sh_watch_path" || emit "shoulder: watcher project is missing or stale"
        grep -Fq "<string>$(xml_escape "$sh_env")</string>" \
          "$sh_watch_path" || emit "shoulder: watcher delivery env is missing or stale"
        grep -Fq '<key>KeepAlive</key><true/>' "$sh_watch_path" ||
          emit "shoulder: watcher KeepAlive is missing"
        sh_loaded="$(launchctl print "$LAUNCHD_DOMAIN/$sh_watch_unit" 2>/dev/null)" ||
          sh_loaded=""
        if [ -z "$sh_loaded" ]; then
          emit "shoulder: watcher $sh_watch_unit is not loaded"
        elif ! grep -Fq 'state = running' <<<"$sh_loaded"; then
          emit "shoulder: watcher $sh_watch_unit is not running"
        fi
      fi
    fi
  fi

  # (j) ticket lifecycle drift — every ticket must sit in the folder its
  #     `Status:` line implies. The deterministic engine is the authority.
  #     Exit 1 = drift (one finding per misfiled ticket — blocking, which is
  #     the point); exit 3 = the project has no lifecycle layout configured, so
  #     a flat project is NOT a finding; exit 2 = the engine could not run.
  local lc_engine="$QUARTET_DIR/scripts/ticket-lifecycle.sh" lc_out lc_rc
  if [ -f "$lc_engine" ]; then
    lc_out="$("$BASH_BIN" "$lc_engine" --project "$PROJECT_DIR" --check 2>/dev/null)"
    lc_rc=$?
    case "$lc_rc" in
      0|3) : ;;
      1)
        while IFS= read -r hit; do
          [ -z "$hit" ] && continue
          emit "lifecycle: ${hit#MISFILED: }"
        done <<<"$lc_out"
        ;;
      *) emit "lifecycle: ticket-lifecycle.sh --check could not run (exit $lc_rc)" ;;
    esac
  fi

  if [ "$findings" -eq 0 ]; then
    echo "doctor: $PROJECT_NAME crew install clean" >&2
    return 0
  fi
  echo "doctor: $PROJECT_NAME — $findings finding(s)" >&2
  return 1
}

# run_uninstall — remove exactly the installer-owned surface for this project:
# its scheduler jobs (any role, enabled or not) and the shared-skill
# symlinks that resolve into $QUARTET_DIR/skills. Everything else (.agents/
# incl. config + prompts + gates.md, data/, tmp/) is deliberately left.
# Honors --dry-run (prints the identical plan, writes nothing). Invariant:
# `--uninstall` then a normal install reproduces a fresh install's unit set.
run_uninstall() {
  echo "==> uninstall crew for $PROJECT_NAME ($PROJECT_DIR)"
  [ "$DRY_RUN" = "1" ] && echo "  (dry-run — no changes will be made)"

  # 1. crew scheduler jobs (dedup across roles).
  local seen=" " u role touched=0
  for role in $QUARTET_ROLES; do
    while IFS= read -r u; do
      [ -z "$u" ] && continue
      case "$seen" in *" $u "*) continue ;; esac
      seen+="$u "
      touched=1
      if [ "$DRY_RUN" = "1" ]; then
        case "$SCHEDULER" in
          systemd) echo "  would disable + remove: $u.{service,timer}" ;;
          launchd) echo "  would bootout + remove: $u.plist" ;;
        esac
      else
        case "$SCHEDULER" in
          systemd)
            systemctl --user disable --now "$u.timer" >/dev/null 2>&1 || true
            rm -f "$SYSTEMD_DIR/$u.service" "$SYSTEMD_DIR/$u.timer"
            echo "  removed: $u.{service,timer}"
            ;;
          launchd)
            launchctl bootout "$LAUNCHD_DOMAIN/$(launchd_label "$u")" >/dev/null 2>&1 || true
            rm -f "$LAUNCHD_DIR/$u.plist"
            echo "  removed: $u.plist"
            ;;
        esac
      fi
    done <<<"$(crew_units_for_role "$role")"
  done
  [ "$touched" = "0" ] && echo "  (no crew units found for $PROJECT_NAME)"
  if [ "$DRY_RUN" = "1" ]; then
    [ "$SCHEDULER" = "systemd" ] && echo "  would: systemctl --user daemon-reload"
  else
    [ "$SCHEDULER" = "systemd" ] && systemctl --user daemon-reload
  fi

  # 2. shared-skill symlinks in both discovery roots — only ones that resolve
  #    into $QUARTET_DIR/skills.
  local qskills; qskills="$(cd "$QUARTET_DIR/skills" 2>/dev/null && pwd -P || true)"
  local skill link tgt skill_root
  for skill_root in "$PROJECT_DIR/.claude/skills" "$PROJECT_DIR/.agents/skills"; do
    for skill in $GENERIC_SKILLS; do
      link="$skill_root/$skill"
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

# write_skill_bridge — create the cross-harness discovery bridge without
# touching a project-owned AGENTS.md. Shared by full install and --relink.
write_skill_bridge() {
  local dest="$PROJECT_DIR/AGENTS.md" skill
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    echo "  AGENTS.md: exists — leaving as-is (never clobbered)"
    return 1
  elif [ "$DRY_RUN" = "1" ]; then
    echo "  would drop: $dest (skill bridge for codex/hermes)"
    return 0
  fi
  {
    printf '# Agent instructions (generated by shipyard install)\n\n'
    printf 'Codex discovers the reusable skills for this project under\n'
    printf '`.agents/skills/<name>/SKILL.md`; `.claude/skills/` is retained for\n'
    printf 'Claude/Hermes compatibility. When a task prompt says "use the\n'
    printf '<name> skill", READ that file and follow it before acting — the\n'
    printf 'SKILL.md is the source of truth for that workflow.\n\n'
    printf 'Available skills:\n'
    for skill in $GENERIC_SKILLS; do
      printf -- '- %s — `.agents/skills/%s/SKILL.md`\n' "$skill" "$skill"
    done
  } > "$dest"
  echo "  wrote:     $dest (skill bridge for codex/hermes)"
  return 0
}

# run_relink — repair installer-owned skill links in both the Claude/Hermes and
# Codex discovery roots that --doctor (check e) flags as drift, then create a
# missing skill bridge (check f). These deterministic, reversible filesystem ops
# touch no systemd, config, or gate file and never clobber a real file/dir an
# operator placed there. Honors --dry-run. Exit 0 even when nothing needed
# fixing; exit 2 only when the source skills dir is gone.
run_relink() {
  local qskills
  qskills="$(cd "$QUARTET_DIR/skills" 2>/dev/null && pwd -P)" \
    || { echo "relink: \$QUARTET_DIR/skills not found ($QUARTET_DIR/skills)" >&2; return 2; }
  echo "==> relink shared skills for $PROJECT_NAME → $PROJECT_DIR/{.claude,.agents}/skills/"
  [ "$DRY_RUN" = "1" ] && echo "  (dry-run — no changes will be made)"
  local skill src dest tgt dest_root fixed=0 kept=0
  for dest_root in "$PROJECT_DIR/.claude/skills" "$PROJECT_DIR/.agents/skills"; do
    [ "$DRY_RUN" = "1" ] || mkdir -p "$dest_root"
    for skill in $GENERIC_SKILLS; do
      src="$QUARTET_DIR/skills/$skill"
      dest="$dest_root/$skill"
      if [ ! -d "$src" ]; then
        echo "  skip $skill: source missing ($src)"; continue
      fi
      # A real (non-symlink) file/dir the operator owns — never clobber.
      if [ -e "$dest" ] && [ ! -L "$dest" ]; then
        echo "  kept (real file/dir, not a symlink): $dest"; kept=$((kept + 1)); continue
      fi
      tgt="$(readlink -f "$dest" 2>/dev/null || true)"
      case "$tgt" in
        "$qskills"/*)
          echo "  ok: $skill"; kept=$((kept + 1)) ;;        # resolves correctly — leave it
        *)                                                   # missing / broken / wrong target
          if [ "$DRY_RUN" = "1" ]; then
            echo "  would relink: $dest -> $src"
          else
            ln -sfn "$src" "$dest"; echo "  relinked: $dest -> $src"
          fi
          fixed=$((fixed + 1)) ;;
      esac
    done
  done
  if write_skill_bridge; then
    fixed=$((fixed + 1))
  else
    kept=$((kept + 1))
  fi
  if [ "$DRY_RUN" = "1" ]; then
    echo "relink: DRY RUN — $fixed would be repaired, $kept already ok"
  else
    echo "relink: $PROJECT_NAME — $fixed repaired, $kept already ok" >&2
  fi
  return 0
}

case "$MODE" in
  doctor)                run_doctor; exit $? ;;
  configure-git-identity) run_configure_git_identity; exit $? ;;
  relink)                run_relink; exit $? ;;
  uninstall)             run_uninstall; exit $? ;;
esac

# Resolve and validate the scheduler role set before install mutates config,
# project files, manifests, crontab, or scheduler state.
ROLES_LIST="$(resolve_effective_roles)" || exit $?
preflight_required_prompts || exit $?

# ---------- theme → [names] block -------------------------------------------
# Resolve the theme into a display name per role (order: design build release
# medic scribe), then bake a [names] block into the project's config.toml so
# the runners + this installer resolve the same svc/unit names. Individual
# variables keep the installer and generated jobs compatible with Apple's
# native Bash 3.2.
# No explicit --theme on a re-run: an existing [names] block in the project's
# config is the operator's prior choice — honor it. Defaulting to plain here
# once wrote a DUPLICATE role-id unit set alongside a live themed fleet.
if [ "$THEME_EXPLICIT" = "0" ]; then
  cfg_design="$(jq_from_json "$CFG_JSON" -r '.names.design // empty')"
  if [ -n "$cfg_design" ]; then
    THEME="custom:$(jq_from_json "$CFG_JSON" -r '[.names.design, .names.build, .names.release, .names.medic, .names.scribe] | map(. // "") | join(",")')"
    echo "==> no --theme given; honoring existing [names] block ($THEME)"
  fi
fi
case "$THEME" in
  plain)
    THEME_DESIGN=design; THEME_BUILD=build; THEME_RELEASE=release
    THEME_MEDIC=medic; THEME_SCRIBE=scribe ;;
  spacetime)
    THEME_DESIGN=mentat; THEME_BUILD=helldiver; THEME_RELEASE=proctor
    THEME_MEDIC=suk; THEME_SCRIBE=chronicler ;;
  custom:*)
    IFS=',' read -r c_d c_b c_r c_m c_s <<<"${THEME#custom:}"
    if [ -z "$c_d" ] || [ -z "$c_b" ] || [ -z "$c_r" ] || [ -z "$c_m" ] || [ -z "$c_s" ]; then
      echo "bad --theme custom: need 5 names (design,build,release,medic,scribe)" >&2; exit 2
    fi
    THEME_DESIGN="$c_d"; THEME_BUILD="$c_b"; THEME_RELEASE="$c_r"
    THEME_MEDIC="$c_m"; THEME_SCRIBE="$c_s" ;;
  *)
    echo "unknown --theme: $THEME (want plain|spacetime|custom:d,b,r,m,s)" >&2; exit 2 ;;
esac

theme_name() {
  case "$1" in
    design) printf '%s\n' "$THEME_DESIGN" ;;
    build) printf '%s\n' "$THEME_BUILD" ;;
    release) printf '%s\n' "$THEME_RELEASE" ;;
    medic) printf '%s\n' "$THEME_MEDIC" ;;
    scribe) printf '%s\n' "$THEME_SCRIBE" ;;
  esac
}

# Build the [names] TOML block (canonical role order).
names_block="[names]"$'\n'
for role in $QUARTET_ROLES; do
  names_block+="$role = \"$(theme_name "$role")\""$'\n'
done

echo "==> theme '$THEME' → [names] block in $CFG"
# Resolve the effective names into CFG_JSON in-memory NOW, so unit-name
# resolution (role_display) sees the theme in BOTH dry-run and real runs —
# a dry-run must show the same unit names the real run will write.
names_json="$(for role in $QUARTET_ROLES; do
    printf '%s\t%s\n' "$role" "$(theme_name "$role")"
  done | jq -R 'split("\t") | {(.[0]): .[1]}' | jq -s 'add')"
names_unchanged="$(jq_from_json "$CFG_JSON" --argjson n "$names_json" '.names == $n')"
CFG_JSON="$(jq_from_json "$CFG_JSON" --argjson n "$names_json" '.names = $n')"
if [ "$names_unchanged" = "true" ]; then
  echo "  [names] unchanged"
elif [ "$DRY_RUN" = "1" ]; then
  echo "  would write:"; printf '%s' "$names_block" | sed 's/^/    /'
else
  # Idempotent: strip any existing [names] block, then append the new one.
  tmp_cfg="$(mktemp)"
  awk '
    /^[[:space:]]*\[names\]/ { skip=1; next }
    skip && /^[[:space:]]*\[/ { skip=0 }
    !skip { print }
  ' "$CFG" | awk '
    { line[NR]=$0 }
    END {
      last=NR
      while (last > 0 && line[last] ~ /^[[:space:]]*$/) last--
      for (i=1; i<=last; i++) print line[i]
    }
  ' > "$tmp_cfg"
  # Drop trailing blank lines to keep spacing stable, then append the block.
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

shoulder_atomic_write() {
  local path="$1" content="$2" mode="$3" dir tmp
  dir="$(dirname "$path")"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 2
  [ ! -L "$path" ] || return 2
  tmp="$(umask 077; mktemp "$dir/.shoulder-write.XXXXXX")" || return 2
  if ! printf '%s' "$content" >"$tmp" || ! chmod "$mode" "$tmp"; then
    rm -f "$tmp"
    return 2
  fi
  if [ -f "$path" ] && cmp -s "$path" "$tmp"; then
    rm -f "$tmp"
    chmod "$mode" "$path" || return 2
    echo "  unchanged: $path"
    return 0
  fi
  mv "$tmp" "$path" || {
    rm -f "$tmp"
    return 2
  }
  echo "  wrote:     $path"
}

shoulder_backup_file() {
  local path="$1" dir tmp
  [ ! -L "$path" ] || return 2
  [ -f "$path" ] || return 0
  dir="$(dirname "$path")"
  tmp="$(umask 077; mktemp "$dir/.shoulder-backup.XXXXXX")" || return 2
  cp -p "$path" "$tmp" || {
    rm -f "$tmp"
    return 2
  }
  printf '%s\n' "$tmp"
}

shoulder_restore_file() {
  local path="$1" backup="$2"
  if [ -n "$backup" ]; then
    mv "$backup" "$path"
  else
    rm -f -- "$path"
  fi
}

shoulder_multi_restore_configs() {
  [ "${sh_multi_tx_active:-0}" = "1" ] || return 0
  shoulder_restore_file "$sh_multi_claude_cfg" "$sh_multi_claude_backup" || true
  shoulder_restore_file "$sh_multi_codex_cfg" "$sh_multi_codex_backup" || true
}

shoulder_multi_discard_backups() {
  rm -f -- "${sh_multi_claude_backup:-}" "${sh_multi_codex_backup:-}"
  sh_multi_tx_active=0
}

shoulder_rollback_watcher() {
  local unit="$1" unit_path="$2" unit_backup="$3"
  local env_path="$4" env_backup="$5" unit_existed="$6"
  if [ "$unit_existed" = "0" ]; then
    systemctl --user disable --now "$unit" >/dev/null 2>&1 || true
  fi
  shoulder_restore_file "$env_path" "$env_backup" || true
  shoulder_restore_file "$unit_path" "$unit_backup" || true
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  if [ "$unit_existed" = "1" ]; then
    systemctl --user restart "$unit" >/dev/null 2>&1 || true
  fi
  rm -f -- "$unit_backup" "$env_backup"
}

shoulder_rollback_launchd_watcher() {
  local label="$1" plist="$2" plist_backup="$3"
  local env_path="$4" env_backup="$5" plist_existed="$6"
  launchctl bootout "$LAUNCHD_DOMAIN/$label" >/dev/null 2>&1 || true
  shoulder_restore_file "$env_path" "$env_backup" || true
  shoulder_restore_file "$plist" "$plist_backup" || true
  if [ "$plist_existed" = "1" ]; then
    launchctl bootstrap "$LAUNCHD_DOMAIN" "$plist" >/dev/null 2>&1 || true
    launchctl enable "$LAUNCHD_DOMAIN/$label" >/dev/null 2>&1 || true
  fi
  rm -f -- "$plist_backup" "$env_backup"
}

# Convert Shipyard's documented systemd-style schedule subset to launchd.
# Daily HH:MM jobs become StartCalendarInterval; */N minute jobs become
# StartInterval. Fail honestly on any expression launchd cannot represent.
launchd_schedule_xml() {
  local schedule="$1" hour minute seconds every
  if [[ "$schedule" =~ ^\*-\*-\*\ ([0-9][0-9]?):([0-9][0-9]):([0-9][0-9])$ ]]; then
    hour="${BASH_REMATCH[1]}"; minute="${BASH_REMATCH[2]}"; seconds="${BASH_REMATCH[3]}"
    [ "$seconds" = "00" ] || {
      echo "launchd does not support seconds in schedule '$schedule'" >&2; return 2; }
    hour=$((10#$hour)); minute=$((10#$minute))
    [ "$hour" -le 23 ] && [ "$minute" -le 59 ] || {
      echo "invalid daily schedule '$schedule'" >&2; return 2; }
    cat <<EOF
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>$hour</integer>
    <key>Minute</key><integer>$minute</integer>
  </dict>
EOF
    return 0
  fi
  if [[ "$schedule" =~ ^\*-\*-\*\ \*:0/([0-9]+):00$ ]]; then
    every="${BASH_REMATCH[1]}"
    [ "$every" -gt 0 ] || { echo "invalid interval schedule '$schedule'" >&2; return 2; }
    printf '  <key>StartInterval</key>\n  <integer>%s</integer>\n' "$((every * 60))"
    return 0
  fi
  echo "launchd cannot translate schedule '$schedule' (use '*-*-* HH:MM:00' or '*-*-* *:0/N:00')" >&2
  return 2
}

# ---------- step 1+2: scheduler jobs ---------------------------------------
echo "==> $SCHEDULER jobs (project=$PROJECT_NAME dir=$PROJECT_DIR)"
manifest_dir="$(scheduler_manifest_dir)"
if [ "$DRY_RUN" = "0" ]; then
  mkdir -p "$manifest_dir"
  [ "$SCHEDULER" = "launchd" ] && mkdir -p "$LAUNCHD_LOG_DIR"
fi

for role in $ROLES_LIST; do
  # Timer schedule: config's [install.timers] wins (accept role id OR the
  # legacy display key), else the baked-in default.
  schedule="$(jq_from_json "$CFG_JSON" -r --arg r "$role" \
    '.install.timers[$r] // empty')"
  [ -z "$schedule" ] && schedule="$(default_schedule "$role")"
  [ -z "$schedule" ] && { echo "  skip $role: no schedule"; continue; }
  mode="$(default_mode "$role")"
  desc="$(description "$role")"

  dir="$(dir_for_role "$role")"
  display="$(role_display "$role" "$CFG_JSON")"

  unit_base="${PROJECT_NAME}-${display}"
  service_path="$SYSTEMD_DIR/$unit_base.service"
  timer_path="$SYSTEMD_DIR/$unit_base.timer"
  plist_path="$LAUNCHD_DIR/$unit_base.plist"

  # A theme change or rename must never leave two jobs for one project+role.
  while IFS= read -r old_base; do
    [ -n "$old_base" ] || continue
    [ "$old_base" = "$unit_base" ] && continue
    if [ "$DRY_RUN" = "1" ]; then
      case "$SCHEDULER" in
        systemd) echo "  would remove stale duplicate: $old_base.{service,timer} (role $role under an old name)" ;;
        launchd) echo "  would remove stale duplicate: $old_base.plist (role $role under an old name)" ;;
      esac
    else
      case "$SCHEDULER" in
        systemd)
          systemctl --user disable --now "$old_base.timer" >/dev/null 2>&1 || true
          rm -f "$SYSTEMD_DIR/$old_base.service" "$SYSTEMD_DIR/$old_base.timer"
          echo "  removed stale duplicate: $old_base.{service,timer} (role $role under an old name)"
          ;;
        launchd)
          launchctl bootout "$LAUNCHD_DOMAIN/$(launchd_label "$old_base")" >/dev/null 2>&1 || true
          rm -f "$LAUNCHD_DIR/$old_base.plist"
          echo "  removed stale duplicate: $old_base.plist (role $role under an old name)"
          ;;
      esac
    fi
  done <<<"$(crew_units_for_role "$role")"

  # Propagate runtime knobs into the scheduler's deliberately small environment.
  quartet_env=""
  # Put Apple's native /bin/bash ahead of an old Intel Homebrew bash; Rosetta
  # shells have exhibited command-substitution hangs on Apple Silicon.
  launchd_env="    <key>PATH</key><string>$(xml_escape "$HOME/.local/bin:$HOME/.pyenv/shims:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin")</string>"$'\n'
  launchd_env+="    <key>HOME</key><string>$(xml_escape "$HOME")</string>"$'\n'
  for var in QUARTET_NOTIFY_CMD QUARTET_OPS_JSON QUARTET_EVENTS_DIR; do
    val="${!var:-}"
    if [ -n "$val" ]; then
      quartet_env+="Environment=$var=$val"$'\n'
      launchd_env+="    <key>$var</key><string>$(xml_escape "$val")</string>"$'\n'
    fi
  done

  # Bake the per-role harness/model/provider knobs into the unit env. Precedence:
  # [<role>].<knob>  >  [harness].<default|knob>  >  (unbaked). Only non-empty
  # values are written, so an unset config leaves the runner on its built-in
  # claude/sonnet default — today's behavior, byte-identical. Secrets
  # (OPENROUTER_API_KEY &c.) are NEVER baked here; they are sourced at runtime.
  role_upper="$(tr '[:lower:]' '[:upper:]' <<<"$role")"
  h_val="$(jq_from_json "$CFG_JSON" -r --arg r "$role" '(.[$r].harness  // .harness.default  // empty)')"
  m_val="$(jq_from_json "$CFG_JSON" -r --arg r "$role" '(.[$r].model     // .harness.model    // empty)')"
  p_val="$(jq_from_json "$CFG_JSON" -r --arg r "$role" '(.[$r].provider  // .harness.provider // empty)')"
  if [ -n "$h_val" ]; then
    quartet_env+="Environment=${role_upper}_HARNESS=$h_val"$'\n'
    launchd_env+="    <key>${role_upper}_HARNESS</key><string>$(xml_escape "$h_val")</string>"$'\n'
  fi
  if [ -n "$m_val" ]; then
    quartet_env+="Environment=${role_upper}_MODEL=$m_val"$'\n'
    launchd_env+="    <key>${role_upper}_MODEL</key><string>$(xml_escape "$m_val")</string>"$'\n'
  fi
  if [ -n "$p_val" ]; then
    quartet_env+="Environment=${role_upper}_PROVIDER=$p_val"$'\n'
    launchd_env+="    <key>${role_upper}_PROVIDER</key><string>$(xml_escape "$p_val")</string>"$'\n'
  fi

  if [ "$SCHEDULER" = "systemd" ]; then
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
    write_or_show "$timer_path" "$timer_content"
  else
    schedule_xml="$(launchd_schedule_xml "$schedule")" || exit $?
    label="$(launchd_label "$unit_base")"
    plist_content="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
  <key>Label</key><string>$(xml_escape "$label")</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "$BASH_BIN")</string>
    <string>$(xml_escape "$QUARTET_DIR/agents/$dir/runner.sh")</string>
    <string>--project</string>
    <string>$(xml_escape "$PROJECT_DIR")</string>
    <string>--mode</string>
    <string>$(xml_escape "$mode")</string>
  </array>
  <key>WorkingDirectory</key><string>$(xml_escape "$PROJECT_DIR")</string>
  <key>EnvironmentVariables</key>
  <dict>
${launchd_env}  </dict>
$schedule_xml
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$(xml_escape "$LAUNCHD_LOG_DIR/$unit_base.log")</string>
  <key>StandardErrorPath</key><string>$(xml_escape "$LAUNCHD_LOG_DIR/$unit_base.err.log")</string>
</dict>
</plist>
"
    write_or_show "$plist_path" "$plist_content"
    if [ "$DRY_RUN" = "0" ]; then
      plutil -lint "$plist_path" >/dev/null || exit 2
    fi
  fi
done

if [ "$DRY_RUN" = "1" ]; then
  case "$SCHEDULER" in
    systemd) echo "  would: systemctl --user daemon-reload + enable --now each timer" ;;
    launchd) echo "  would: launchctl bootstrap each LaunchAgent" ;;
  esac
else
  case "$SCHEDULER" in
    systemd)
      systemctl --user daemon-reload
      for role in $ROLES_LIST; do
        display="$(role_display "$role" "$CFG_JSON")"
        systemctl --user enable --now "${PROJECT_NAME}-${display}.timer" 2>&1 | sed 's/^/  /'
      done
      ;;
    launchd)
      for role in $ROLES_LIST; do
        display="$(role_display "$role" "$CFG_JSON")"
        unit_base="${PROJECT_NAME}-${display}"
        label="$(launchd_label "$unit_base")"
        launchctl bootout "$LAUNCHD_DOMAIN/$label" >/dev/null 2>&1 || true
        launchctl bootstrap "$LAUNCHD_DOMAIN" "$LAUNCHD_DIR/$unit_base.plist"
        launchctl enable "$LAUNCHD_DOMAIN/$label" >/dev/null 2>&1 || true
        echo "  loaded: $label"
      done
      ;;
  esac
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
# The generic skills live in $QUARTET_DIR/skills. Install both the legacy
# Claude/Hermes links and Codex's native .agents/skills discovery links, so a
# core upgrade flows to every installed project at once.
echo ""
echo "==> shared skills → $PROJECT_DIR/{.claude,.agents}/skills/"
# GENERIC_SKILLS is defined once near the top (shared with doctor/uninstall).
SKILLS_DESTS=("$PROJECT_DIR/.claude/skills" "$PROJECT_DIR/.agents/skills")
for SKILLS_DEST in "${SKILLS_DESTS[@]}"; do
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

# ---------- step 4.55: ticket lifecycle folders -----------------------------
# Ticket hygiene is DEFAULT ON at install time: a project gets
# docs/tickets/{pending,complete,freezer} plus the [write_ticket] keys that name
# them, so THE FOLDER IS THE STATUS and scripts/ticket-lifecycle.sh --check can
# enforce it (blocking in --doctor and CI, warning in the pre-commit hook).
#
# Tri-state, by the project's existing config:
#   (a) no ticket_dir configured  -> provision the folders + config (default ON)
#   (b) lifecycle_dirs present    -> already configured; touch nothing
#   (c) ticket_dir but no flag    -> a non-standard layout (several projects use
#       backlog/ + archive/). Enabling the mover would MISFILE those tickets, so
#       print a migration NOTICE and change nothing — no silent enable, no
#       rewrite of the operator's dir keys. Migration is handled separately.
#
# Never clobbers: an existing folder or an existing config value is left as-is,
# same posture as the gates.md drop above.
echo "==> ticket lifecycle folders"
LC_BASE="docs/tickets"
lc_ticket_dir="$(jq_from_json "$CFG_JSON" -r '.write_ticket.ticket_dir // empty')"
lc_flag_set="$(jq_from_json "$CFG_JSON" -r '((.write_ticket // {}) | has("lifecycle_dirs")) | tostring')"

if [ "$lc_flag_set" = "true" ]; then
  echo "  ticket lifecycle: already configured (lifecycle_dirs present) — leaving as-is"
elif [ -n "$lc_ticket_dir" ]; then
  echo "  NOTICE: ticket lifecycle NOT enabled for $PROJECT_NAME."
  echo "  NOTICE: this project keeps tickets in a non-standard layout"
  echo "  NOTICE: (ticket_dir = \"$lc_ticket_dir\") and needs migration first —"
  echo "  NOTICE: switching the mover on now would misfile them."
  echo "  NOTICE: migrate to $LC_BASE/{pending,complete,freezer}, then add"
  echo "  NOTICE: lifecycle_dirs = true to [write_ticket] in $CFG."
else
  for lc_sub in pending complete freezer; do
    lc_dir="$PROJECT_DIR/$LC_BASE/$lc_sub"
    if [ -d "$lc_dir" ]; then
      echo "  $LC_BASE/$lc_sub exists — leaving as-is (never clobbered)"
    elif [ "$DRY_RUN" = "1" ]; then
      echo "  would create: $lc_dir"
    else
      mkdir -p "$lc_dir"
      [ -e "$lc_dir/.gitkeep" ] || : >"$lc_dir/.gitkeep"
      echo "  created:   $lc_dir"
    fi
  done

  lifecycle_keys="ticket_dir     = \"$LC_BASE/pending\""$'\n'
  lifecycle_keys+="archive_dir    = \"$LC_BASE/complete\""$'\n'
  lifecycle_keys+="backlog_dir    = \"$LC_BASE/freezer\""$'\n'
  lifecycle_keys+="scan_dirs      = [ \"$LC_BASE/pending\", \"$LC_BASE/complete\", \"$LC_BASE/freezer\" ]"$'\n'
  lifecycle_keys+="lifecycle_dirs = true"$'\n'

  if [ "$DRY_RUN" = "1" ]; then
    echo "  would write into [write_ticket] in $CFG:"
    printf '%s' "$lifecycle_keys" | sed 's/^/    /'
  elif grep -qE '^[[:space:]]*\[write_ticket\][[:space:]]*$' "$CFG"; then
    # A [write_ticket] section exists with other keys — insert into it rather
    # than appending a second header (duplicate TOML tables are a parse error).
    tmp_cfg="$(mktemp)"
    awk -v keys="$lifecycle_keys" '
      { print }
      !ins && /^[[:space:]]*\[write_ticket\][[:space:]]*$/ { printf "%s", keys; ins=1 }
    ' "$CFG" >"$tmp_cfg"
    mv "$tmp_cfg" "$CFG"
    echo "  wrote lifecycle keys into the existing [write_ticket] in $CFG"
  else
    printf '\n[write_ticket]\n%s' "$lifecycle_keys" >>"$CFG"
    echo "  wrote [write_ticket] (lifecycle_dirs = true) in $CFG"
  fi
fi

# ---------- step 4.6: cross-harness skill-bridge AGENTS.md ------------------
# Claude auto-discovers .claude/skills; Codex and Hermes read this bridge from
# the project root. The helper is intentionally universal and non-clobbering.
write_skill_bridge || true

# ---------- step 4.7: shoulder-mode wiring (opt-in) -------------------------
# OFF unless `--wire-shoulder` or `[shoulder] auto_wire = true`. When off this
# whole block is skipped, so no harness config, feedback authorization, env, or
# watcher is touched. When on, authoring hooks and reviewer harness remain
# independently configured.
sh_auto="$SHOULDER_AUTO"
if [ "$WIRE_SHOULDER" = "1" ] || [ "$sh_auto" = "true" ]; then
  # shellcheck source=agents/lib/shoulder-wire.sh
  . "$QUARTET_DIR/agents/lib/shoulder-wire.sh"
  sh_harness="$SHOULDER_HARNESS"
  sh_critic_harness="$SHOULDER_CRITIC_HARNESS"
  echo ""
  if [ "$SHOULDER_MULTI" = "true" ]; then
    echo "==> shoulder-mode wiring (authors=$SHOULDER_HARNESSES critic=$sh_critic_harness)"
  else
    echo "==> shoulder-mode wiring (author=$sh_harness critic=$sh_critic_harness)"
  fi
  sh_feedback="$QUARTET_DIR/agents/release/critic-codex-feedback.sh"
  sh_stop="$QUARTET_DIR/agents/release/critic-stop-gate-codex.sh"
  if [ "$SHOULDER_MULTI" != "true" ]; then
    sh_queue="$QUARTET_DIR/agents/release/critic-queue-${sh_harness}.sh"
    [ "$sh_harness" = "claude" ] && sh_queue="$QUARTET_DIR/agents/release/critic-queue.sh"
    sh_cfg="$(sw_config_path "$sh_harness" "$PROJECT_DIR")"
    if [ "$DRY_RUN" = "1" ]; then
      if [ "$sh_harness" = "codex" ] &&
       sw_codex_bundle_wired \
         "$sh_cfg" "$PROJECT_DIR" "$sh_queue" "$sh_feedback" "$sh_stop"; then
      echo "  would keep: $sh_cfg already has codex capture, feedback, and Stop"
    elif [ "$sh_harness" = "codex" ]; then
      echo "  would wire: codex apply_patch capture into $sh_cfg"
      echo "  would wire: codex all-local PostToolUse feedback into $sh_cfg"
      echo "  would wire: codex Stop backstop into $sh_cfg"
    elif sw_wired "$sh_harness" "$sh_cfg" "$sh_queue"; then
      echo "  would keep: $sh_cfg already wired -> $sh_queue"
    else
      echo "  would wire: capture hook into $sh_cfg -> $sh_queue"
    fi
    else
      if [ "$sh_harness" = "codex" ]; then
      CRITIC_FEEDBACK_ADMIN=1 \
        "$sh_feedback" --admin-allow-project "$PROJECT_DIR" || {
          echo "shoulder: failed to authorize $PROJECT_DIR for Codex feedback" >&2
          exit 2
        }
      sw_wire_codex_bundle \
        "$sh_cfg" "$PROJECT_DIR" "$sh_queue" "$sh_feedback" "$sh_stop" |
        sed 's/^/  /' || exit 2
      else
        sw_wire "$sh_harness" "$sh_cfg" "$sh_queue" | sed 's/^/  /' || exit 2
      fi
    fi
  else
    sh_multi_claude_cfg="$(sw_config_path claude "$PROJECT_DIR")"
    sh_multi_codex_cfg="$(sw_config_path codex "$PROJECT_DIR")"
    # Fail before touching either author if a native config is malformed.
    if [ -f "$sh_multi_claude_cfg" ] &&
       ! jq -e 'type == "object"' "$sh_multi_claude_cfg" >/dev/null 2>&1; then
      echo "shoulder: refusing to modify malformed Claude config $sh_multi_claude_cfg" >&2
      exit 2
    fi
    if ! _sw_codex_config_valid "$sh_multi_codex_cfg"; then
      echo "shoulder: refusing to modify malformed Codex config $sh_multi_codex_cfg" >&2
      exit 2
    fi
    if [ "$DRY_RUN" != "1" ]; then
      sh_multi_claude_backup="$(shoulder_backup_file "$sh_multi_claude_cfg")" || exit 2
      sh_multi_codex_backup="$(shoulder_backup_file "$sh_multi_codex_cfg")" || {
        rm -f -- "$sh_multi_claude_backup"
        exit 2
      }
      sh_multi_tx_active=1
      trap shoulder_multi_restore_configs EXIT
    fi
    sh_old_ifs="$IFS"; IFS=,
    for sh_author in $SHOULDER_HARNESSES; do
      IFS="$sh_old_ifs"
      sh_namespace=""
      [ "$sh_author" = "$SHOULDER_HARNESS" ] || sh_namespace="$sh_author"
      sh_queue="$QUARTET_DIR/agents/release/critic-queue-${sh_author}.sh"
      [ "$sh_author" = "claude" ] && sh_queue="$QUARTET_DIR/agents/release/critic-queue.sh"
      sh_cfg="$(sw_config_path "$sh_author" "$PROJECT_DIR")"
      if [ "$DRY_RUN" = "1" ]; then
        echo "  would wire: $sh_author capture into $sh_cfg"
      elif [ "$sh_author" = "codex" ] && [ -n "$sh_namespace" ]; then
        CRITIC_FEEDBACK_ADMIN=1 "$sh_feedback" --admin-allow-project "$PROJECT_DIR" || exit 2
        sw_wire_codex_bundle_scoped \
          "$sh_cfg" "$PROJECT_DIR" "$sh_queue" "$sh_feedback" "$sh_stop" "$sh_namespace" |
          sed 's/^/  /' || exit 2
      elif [ "$sh_author" = "codex" ]; then
        CRITIC_FEEDBACK_ADMIN=1 "$sh_feedback" --admin-allow-project "$PROJECT_DIR" || exit 2
        sw_wire_codex_bundle \
          "$sh_cfg" "$PROJECT_DIR" "$sh_queue" "$sh_feedback" "$sh_stop" |
          sed 's/^/  /' || exit 2
      else
        sh_command="$sh_queue"
        [ -z "$sh_namespace" ] ||
          sh_command="CRITIC_QUEUE_NAMESPACE=$sh_namespace CRITIC_AUTHOR_HARNESS=$sh_author /bin/bash $sh_queue"
        sw_wire "$sh_author" "$sh_cfg" "$sh_command" | sed 's/^/  /' || exit 2
      fi
      IFS=,
    done
    IFS="$sh_old_ifs"
  fi

  # Delivery/reviewer env sourced by the persistent watcher. Write the complete
  # fragment atomically before installing or restarting the watcher.
  sh_target="$(jq_from_json "$CFG_JSON" -r '.notify.target // empty')"
  sh_deliver="$(jq_from_json "$CFG_JSON" -r '.notify.cmd // empty')"
  sh_env="$PROJECT_DIR/.agents/shoulder.env"
  sh_release_display="$(role_display release "$CFG_JSON")"
  sh_watch_base="${PROJECT_NAME}-${sh_release_display}-watch"
  if [ "$SCHEDULER" = "systemd" ]; then
    sh_watch_unit="$sh_watch_base.service"
    sh_watch_path="$SYSTEMD_DIR/$sh_watch_unit"
  else
    sh_watch_unit="$(launchd_label "$sh_watch_base")"
    sh_watch_path="$LAUNCHD_DIR/$sh_watch_base.plist"
  fi
  sh_env_content="$(
    printf '# generated by install.sh --wire-shoulder — source before critic-watch.sh\n'
    printf 'CRITIC_PROJECT_DIR=%q\n' "$PROJECT_DIR"
    printf 'CRITIC_HARNESS=%q\n' "$sh_critic_harness"
    printf 'CRITIC_NOTE_HARNESS=%q\n' "$sh_harness"
    printf 'CLAUDE_NOTE_CMD=%q\n' \
      "$QUARTET_DIR/agents/release/critic-note.sh --harness $sh_harness"
    if [ "$SHOULDER_MULTI" = "true" ]; then
      printf 'CRITIC_MULTI_AUTHOR=true\n'
      printf 'CRITIC_PRIMARY_HARNESS=%q\n' "$sh_harness"
      printf 'CRITIC_AUTHOR_HARNESSES=%s\n' "$SHOULDER_HARNESSES"
    fi
    [ -n "$sh_target" ] &&
      printf 'CRITIC_NOTE_TARGET=%q\n' "$sh_target"
    [ -n "$sh_deliver" ] &&
      printf 'CRITIC_NOTE_DELIVER_CMD=%q\n' "$sh_deliver"
  )"$'\n'
  if [ "$DRY_RUN" = "1" ]; then
    echo "  would write: $sh_env"
  elif [ "$SCHEDULER" = "launchd" ]; then
    sh_env_backup="$(shoulder_backup_file "$sh_env")" || {
      echo "shoulder: cannot save prior env for rollback" >&2
      exit 2
    }
    shoulder_atomic_write "$sh_env" "$sh_env_content" 600 || {
      shoulder_restore_file "$sh_env" "$sh_env_backup" || true
      echo "shoulder: failed to atomically write $sh_env" >&2
      exit 2
    }
    if [ "$SHOULDER_HAS_CODEX" = "true" ]; then
      sw_prepare_codex_runtime_marker "$PROJECT_DIR" || {
        shoulder_restore_file "$sh_env" "$sh_env_backup" || true
        echo "shoulder: private Codex runtime marker state is unsafe" >&2
        exit 2
      }
    fi
  fi

  if [ "$SCHEDULER" = "systemd" ]; then
    sh_watch_existed=0
    [ -f "$sh_watch_path" ] && sh_watch_existed=1
    sh_watch_content="[Unit]
Description=$PROJECT_NAME shoulder release critic watcher
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
WorkingDirectory=$PROJECT_DIR
EnvironmentFile=-$sh_env
ExecStart=/bin/bash $QUARTET_DIR/agents/release/critic-watch.sh --project $PROJECT_DIR
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
"
    if [ "$DRY_RUN" = "1" ]; then
      echo "  would write watcher: $sh_watch_path"
      printf '%s' "$sh_watch_content" | sed 's/^/    /'
      echo "  would: systemctl --user daemon-reload"
      if [ "$sh_watch_existed" = "1" ]; then
        echo "  would: systemctl --user enable + try-restart $sh_watch_unit"
      else
        echo "  would: systemctl --user enable --now $sh_watch_unit"
      fi
    else
      sh_env_backup="$(shoulder_backup_file "$sh_env")" || {
        echo "shoulder: cannot save prior env for rollback" >&2
        exit 2
      }
      sh_watch_backup="$(shoulder_backup_file "$sh_watch_path")" || {
        rm -f -- "$sh_env_backup"
        echo "shoulder: cannot save prior watcher for rollback" >&2
        exit 2
      }
      if ! shoulder_atomic_write "$sh_env" "$sh_env_content" 600 ||
         ! shoulder_atomic_write "$sh_watch_path" "$sh_watch_content" 644; then
        shoulder_rollback_watcher \
          "$sh_watch_unit" "$sh_watch_path" "$sh_watch_backup" \
          "$sh_env" "$sh_env_backup" "$sh_watch_existed"
        echo "shoulder: atomic env/unit install failed; prior state restored" >&2
        exit 2
      fi
      # A reinstall invalidates prior runtime proof until one of the exact
      # definitions executes in a fresh normal Codex process. The marker sits
      # beside the installer-owned private authorization state, never in the
      # project workspace.
      if [ "$SHOULDER_HAS_CODEX" = "true" ]; then
        sw_prepare_codex_runtime_marker "$PROJECT_DIR" || {
          shoulder_rollback_watcher \
            "$sh_watch_unit" "$sh_watch_path" "$sh_watch_backup" \
            "$sh_env" "$sh_env_backup" "$sh_watch_existed"
          echo "shoulder: private Codex runtime marker state is unsafe" >&2
          exit 2
        }
      fi
      if ! systemctl --user daemon-reload; then
        shoulder_rollback_watcher \
          "$sh_watch_unit" "$sh_watch_path" "$sh_watch_backup" \
          "$sh_env" "$sh_env_backup" "$sh_watch_existed"
        echo "shoulder: daemon-reload failed; prior state restored" >&2
        exit 2
      fi
      sh_watch_ok=1
      if [ "$sh_watch_existed" = "1" ]; then
        systemctl --user enable "$sh_watch_unit" >/dev/null 2>&1 ||
          sh_watch_ok=0
        [ "$sh_watch_ok" = "0" ] ||
          systemctl --user try-restart "$sh_watch_unit" || sh_watch_ok=0
        if ! systemctl --user is-active "$sh_watch_unit" >/dev/null 2>&1; then
          systemctl --user start "$sh_watch_unit" || sh_watch_ok=0
        fi
      else
        systemctl --user enable --now "$sh_watch_unit" || sh_watch_ok=0
      fi
      if [ "$sh_watch_ok" = "0" ]; then
        shoulder_rollback_watcher \
          "$sh_watch_unit" "$sh_watch_path" "$sh_watch_backup" \
          "$sh_env" "$sh_env_backup" "$sh_watch_existed"
        echo "shoulder: watcher activation failed; prior state restored" >&2
        exit 2
      fi
      rm -f -- "$sh_watch_backup" "$sh_env_backup"
      echo "  watcher active: $sh_watch_unit"
    fi
  elif [ "$SCHEDULER" = "launchd" ]; then
    sh_watch_existed=0
    [ -f "$sh_watch_path" ] && sh_watch_existed=1
    sh_watch_launchd_env="    <key>PATH</key><string>$(xml_escape "$HOME/.local/bin:$HOME/.pyenv/shims:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin")</string>"$'\n'
    sh_watch_launchd_env+="    <key>HOME</key><string>$(xml_escape "$HOME")</string>"$'\n'
    for var in QUARTET_NOTIFY_CMD QUARTET_OPS_JSON QUARTET_EVENTS_DIR; do
      val="${!var:-}"
      [ -z "$val" ] ||
        sh_watch_launchd_env+="    <key>$var</key><string>$(xml_escape "$val")</string>"$'\n'
    done
    sh_watch_content="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
  <key>Label</key><string>$(xml_escape "$sh_watch_unit")</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "$BASH_BIN")</string>
    <string>-c</string>
    <string>set -a; . \"\$1\"; set +a; exec \"\$2\" --project \"\$3\"</string>
    <string>shipyard-critic-watch</string>
    <string>$(xml_escape "$sh_env")</string>
    <string>$(xml_escape "$QUARTET_DIR/agents/release/critic-watch.sh")</string>
    <string>$(xml_escape "$PROJECT_DIR")</string>
  </array>
  <key>WorkingDirectory</key><string>$(xml_escape "$PROJECT_DIR")</string>
  <key>EnvironmentVariables</key>
  <dict>
${sh_watch_launchd_env}  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$(xml_escape "$LAUNCHD_LOG_DIR/$sh_watch_base.log")</string>
  <key>StandardErrorPath</key><string>$(xml_escape "$LAUNCHD_LOG_DIR/$sh_watch_base.err.log")</string>
</dict>
</plist>
"
    if [ "$DRY_RUN" = "1" ]; then
      echo "  would write watcher: $sh_watch_path"
      printf '%s' "$sh_watch_content" | sed 's/^/    /'
      echo "  would: launchctl bootout + bootstrap $sh_watch_unit"
    else
      sh_watch_backup="$(shoulder_backup_file "$sh_watch_path")" || {
        shoulder_restore_file "$sh_env" "$sh_env_backup" || true
        echo "shoulder: cannot save prior watcher for rollback" >&2
        exit 2
      }
      if ! shoulder_atomic_write "$sh_watch_path" "$sh_watch_content" 644 ||
         ! plutil -lint "$sh_watch_path" >/dev/null; then
        shoulder_rollback_launchd_watcher \
          "$sh_watch_unit" "$sh_watch_path" "$sh_watch_backup" \
          "$sh_env" "$sh_env_backup" "$sh_watch_existed"
        echo "shoulder: atomic env/plist install failed; prior state restored" >&2
        exit 2
      fi
      launchctl bootout "$LAUNCHD_DOMAIN/$sh_watch_unit" >/dev/null 2>&1 || true
      if ! launchctl bootstrap "$LAUNCHD_DOMAIN" "$sh_watch_path" ||
         ! launchctl enable "$LAUNCHD_DOMAIN/$sh_watch_unit" >/dev/null 2>&1 ||
         ! launchctl kickstart -k "$LAUNCHD_DOMAIN/$sh_watch_unit" ||
         ! launchctl print "$LAUNCHD_DOMAIN/$sh_watch_unit" >/dev/null 2>&1; then
        shoulder_rollback_launchd_watcher \
          "$sh_watch_unit" "$sh_watch_path" "$sh_watch_backup" \
          "$sh_env" "$sh_env_backup" "$sh_watch_existed"
        echo "shoulder: watcher activation failed; prior state restored" >&2
        exit 2
      fi
      rm -f -- "$sh_watch_backup" "$sh_env_backup"
      echo "  watcher active: $sh_watch_unit"
    fi
  fi
  if [ "$SHOULDER_MULTI" = "true" ] && [ "$DRY_RUN" != "1" ]; then
    shoulder_multi_discard_backups
    trap - EXIT
  fi
fi

# ---------- step 5: verification --------------------------------------------
echo ""
echo "==> verification"
all_ok=1
for role in $ROLES_LIST; do
  display="$(role_display "$role" "$CFG_JSON")"
  unit="${PROJECT_NAME}-${display}"
  case "$SCHEDULER" in
    systemd)
      timer="$unit.timer"
      if systemctl --user is-enabled "$timer" >/dev/null 2>&1; then
        next="$(systemctl --user list-timers "$timer" --no-pager 2>/dev/null | awk 'NR==2 {print $1, $2, $3, $4}')"
        echo "  $timer: enabled, next=$next"
      else
        echo "  $timer: NOT ENABLED"
        all_ok=0
      fi
      ;;
    launchd)
      label="$(launchd_label "$unit")"
      if launchctl print "$LAUNCHD_DOMAIN/$label" >/dev/null 2>&1; then
        echo "  $label: loaded"
      else
        echo "  $label: NOT LOADED"
        all_ok=0
      fi
      ;;
  esac
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
