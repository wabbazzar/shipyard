#!/usr/bin/env bash
# shipyard.sh — the /shipyard command's deterministic core.
#
# Subcommands (the SKILL.md is the human-facing surface; this script is what it
# runs so the behavior is testable with load-bearing exit codes):
#
#   status                     what's installed here (units, project blocks,
#                              --doctor). Read-only. Exit 3 if nothing installed.
#   dashboard [--open]         report the local dashboard URL and health;
#                              open it only when explicitly requested.
#   inspect [--json] [--days N] fleet observation for this Shipyard core.
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
OPT_TO=""       # learn: explicit route (project|generic|install)
OPT_ROLE=""     # learn --to project: which .agents/<role>.md
OPT_JSON=0      # inspect: emit the schema-v1 source document
OPT_DAYS="7"    # inspect: rolling UTC window in days
OPT_OPEN=0      # dashboard: open the loopback URL after reporting health
OPT_PROJECT_SET=0
OPT_TO_SET=0
OPT_ROLE_SET=0
OPT_DAYS_SET=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { echo "shipyard: --project requires a value" >&2; exit 2; }
      PROJECT_DIR="$2"; OPT_PROJECT_SET=1; shift 2 ;;
    --to)
      [ $# -ge 2 ] || { echo "shipyard: --to requires a value" >&2; exit 2; }
      OPT_TO="$2"; OPT_TO_SET=1; shift 2 ;;
    --role)
      [ $# -ge 2 ] || { echo "shipyard: --role requires a value" >&2; exit 2; }
      OPT_ROLE="$2"; OPT_ROLE_SET=1; shift 2 ;;
    --days)
      [ $# -ge 2 ] || { echo "shipyard: --days requires a value" >&2; exit 2; }
      OPT_DAYS="$2"; OPT_DAYS_SET=1; shift 2 ;;
    --json)    OPT_JSON=1; shift ;;
    --open)    OPT_OPEN=1; shift ;;
    -h|--help) SUBCMD="help"; shift ;;
    -*) echo "shipyard: unknown flag '$1'" >&2; exit 2 ;;
    *)
      if [ -z "$SUBCMD" ]; then SUBCMD="$1"; else ARGS+=("$1"); fi
      shift ;;
  esac
done
[ -n "$SUBCMD" ] || SUBCMD="status"

if [ "$SUBCMD" != "inspect" ] \
  && { [ "$OPT_JSON" -eq 1 ] || [ "$OPT_DAYS_SET" -eq 1 ]; }; then
  echo "shipyard $SUBCMD: --json/--days apply only to inspect" >&2
  exit 2
fi
if [ "$SUBCMD" != "dashboard" ] && [ "$OPT_OPEN" -eq 1 ]; then
  echo "shipyard $SUBCMD: --open applies only to dashboard" >&2
  exit 2
fi

# ---- config (optional — status works on a bare dir too) --------------------
# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/load-config.sh"
CFG_JSON="{}"
if [ -f "$PROJECT_DIR/.agents/config.toml" ]; then
  CFG_JSON="$(load_config_json "$PROJECT_DIR/.agents/config.toml" 2>/dev/null)" || CFG_JSON="{}"
fi
PROJECT_NAME="$(jq_from_json "$CFG_JSON" -r '.project_name // empty' 2>/dev/null)"
[ -n "$PROJECT_NAME" ] || PROJECT_NAME="$(basename "$PROJECT_DIR")"

_scheduler() {
  case "${SHIPYARD_SCHEDULER:-auto}" in
    systemd|launchd) printf '%s\n' "$SHIPYARD_SCHEDULER" ;;
    auto) [ "$(uname -s)" = "Darwin" ] && printf 'launchd\n' || printf 'systemd\n' ;;
    *) return 2 ;;
  esac
}

_have_all_deps() {
  local d scheduler_dep
  [ "$(_scheduler)" = "launchd" ] && scheduler_dep="launchctl" || scheduler_dep="systemctl"
  for d in jq python3 git gh "$scheduler_dep" claude; do
    command -v "$d" >/dev/null 2>&1 || return 1
  done
}

usage() {
  cat <<EOF
shipyard — inspect and extend an installed crew.

  shipyard status                  what's installed here (default)
  shipyard dashboard [--open]      report the private local dashboard
  shipyard inspect [--json]        inspect this current-user Shipyard fleet
    [--days N]                     rolling UTC window (default 7)
  shipyard add-specialist <sub>    scaffold a domain-specialist for <sub>
  shipyard learn "<lesson>"        route a lesson to the adaptation taxonomy
    [--to project|generic|install] explicit route (else keyword heuristic)
    [--role <role>]                 project route target (default release)

Exit: 0 ok · 2 bad invocation · 3 nothing installed.
EOF
}

# ---- dashboard -------------------------------------------------------------
_dashboard_manifest_value() {
  python3 -c '
import pathlib, plistlib, re, sys
path, key = pathlib.Path(sys.argv[1]), sys.argv[2]
if not path.is_file() or path.is_symlink(): raise SystemExit(1)
if path.suffix == ".plist":
    with path.open("rb") as source:
        value = plistlib.load(source).get("EnvironmentVariables", {}).get(key, "")
else:
    value, prefix = "", "Environment=\"" + key + "="
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith(prefix) and line.endswith("\""):
            value = re.sub(r"\\(.)", r"\1", line[len(prefix):-1]).replace("%%", "%")
            break
if isinstance(value, str): print(value)
' "$1" "$2"
}

_dashboard_health_record() {
  python3 -c '
import json, sys, urllib.request
host, port_text, expected_events = sys.argv[1:]
port = int(port_text)
request = urllib.request.Request(
    f"http://{host}:{port}/api/health",
    headers={"Accept": "application/json"},
)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
with opener.open(request, timeout=1.5) as response:
    if response.status != 200:
        raise SystemExit(1)
    payload = json.load(response)
if not isinstance(payload, dict):
    raise SystemExit(1)
actual_events = payload.get("event_directory")
latest = payload.get("latest_timestamp")
consistent = (
    payload.get("ready") is True
    and payload.get("host") == host
    and payload.get("port") == port
    and actual_events == expected_events
)
print("ready" if consistent else "drift")
print(actual_events if isinstance(actual_events, str) and actual_events else "unknown")
print(latest if isinstance(latest, str) and latest else "none")
' "$1" "$2" "$3"
}

_dashboard_valid_port() {
  case "$1" in *[!0-9]*|"") return 1 ;; esac
  [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

_dashboard_report() {
  local prefix="${1:-}" scheduler dash_home manifest service port host events
  local loaded="false" running="false" health="absent" latest="unknown"
  local systemctl_cmd launchctl_cmd record="" value=""
  scheduler="$(_scheduler)" || { echo "shipyard: unsupported scheduler" >&2; return 2; }
  dash_home="${SHIPYARD_DASHBOARD_HOME:-$HOME}"
  host="127.0.0.1"
  port="${SHIPYARD_DASHBOARD_PORT:-8765}"
  case "$scheduler" in
    launchd)
      manifest="${SHIPYARD_DASHBOARD_LAUNCHD_DIR:-$dash_home/Library/LaunchAgents}/com.shipyard.dashboard.plist"
      service="com.shipyard.dashboard"
      ;;
    systemd)
      manifest="${SHIPYARD_DASHBOARD_SYSTEMD_DIR:-$dash_home/.config/systemd/user}/shipyard-dashboard.service"
      service="shipyard-dashboard.service"
      ;;
  esac
  DASHBOARD_URL="unavailable"
  DASHBOARD_OPENABLE=0
  if _dashboard_valid_port "$port"; then
    DASHBOARD_URL="http://$host:$port"
    DASHBOARD_OPENABLE=1
  else
    health="invalid-config"
  fi
  events="unknown"

  if [ -f "$manifest" ] && [ ! -L "$manifest" ]; then
    if command -v python3 >/dev/null 2>&1; then
      value="$(_dashboard_manifest_value "$manifest" SHIPYARD_DASHBOARD_HOST 2>/dev/null || true)"
      [ -z "$value" ] || host="$value"
      value="$(_dashboard_manifest_value "$manifest" SHIPYARD_DASHBOARD_PORT 2>/dev/null || true)"
      [ -z "$value" ] || port="$value"
      value="$(_dashboard_manifest_value "$manifest" QUARTET_EVENTS_DIR 2>/dev/null || true)"
      [ -z "$value" ] || events="$value"
    fi
    if [ "$host" = "127.0.0.1" ] && _dashboard_valid_port "$port"; then
      DASHBOARD_URL="http://$host:$port"
      DASHBOARD_OPENABLE=1
    else
      health="invalid-config"
      DASHBOARD_URL="unavailable"
      DASHBOARD_OPENABLE=0
    fi

    if [ "$scheduler" = "launchd" ]; then
      launchctl_cmd="${SHIPYARD_DASHBOARD_LAUNCHCTL:-launchctl}"
      if command -v "$launchctl_cmd" >/dev/null 2>&1; then
        if "$launchctl_cmd" print \
          "gui/${SHIPYARD_DASHBOARD_UID:-$(id -u)}/$service" \
          >/dev/null 2>&1; then
          loaded="true"
          if "$launchctl_cmd" print \
            "gui/${SHIPYARD_DASHBOARD_UID:-$(id -u)}/$service" 2>/dev/null \
            | grep -E 'state = running|pid = [0-9]+' >/dev/null; then
            running="true"
          fi
        fi
      else
        loaded="unknown"; running="unknown"
      fi
    else
      systemctl_cmd="${SHIPYARD_DASHBOARD_SYSTEMCTL:-systemctl}"
      if command -v "$systemctl_cmd" >/dev/null 2>&1; then
        "$systemctl_cmd" --user is-enabled "$service" >/dev/null 2>&1 && loaded="true"
        "$systemctl_cmd" --user is-active "$service" >/dev/null 2>&1 && running="true"
      else
        loaded="unknown"; running="unknown"
      fi
    fi

    if [ "$running" = "true" ] && [ "$health" != "invalid-config" ] \
      && command -v python3 >/dev/null 2>&1; then
      record="$(_dashboard_health_record "$host" "$port" "$events" 2>/dev/null || true)"
      if [ -n "$record" ]; then
        health="$(printf '%s\n' "$record" | sed -n '1p')"
        events="$(printf '%s\n' "$record" | sed -n '2p')"
        latest="$(printf '%s\n' "$record" | sed -n '3p')"
      else
        health="unavailable"
      fi
    elif [ "$health" != "invalid-config" ]; then
      health="unavailable"
    fi
  fi

  printf '%sservice=%s\n' "$prefix" "$service"
  printf '%sloaded=%s\n' "$prefix" "$loaded"
  printf '%srunning=%s\n' "$prefix" "$running"
  printf '%surl=%s\n' "$prefix" "$DASHBOARD_URL"
  printf '%shealth=%s\n' "$prefix" "$health"
  printf '%sevent_path=%s\n' "$prefix" "$events"
  printf '%slatest_event=%s\n' "$prefix" "$latest"
  if [ ! -f "$manifest" ]; then
    printf '%sinstall_command=/bin/bash %s/scripts/install-dashboard.sh --install --port %s\n' \
      "$prefix" "$QUARTET_DIR" "$port"
    return 3
  fi
  return 0
}

cmd_dashboard() {
  [ "$OPT_TO_SET" -eq 0 ] && [ "$OPT_ROLE_SET" -eq 0 ] || {
    echo "shipyard dashboard: --to/--role apply only to learn" >&2
    return 2
  }
  [ "${#ARGS[@]}" -eq 0 ] || {
    echo "shipyard dashboard: unexpected positional argument '${ARGS[0]}'" >&2
    return 2
  }
  local report_rc=0 opener=""
  _dashboard_report "" || report_rc=$?
  if [ "$OPT_OPEN" -eq 1 ] && [ "$report_rc" -eq 0 ]; then
    [ "$DASHBOARD_OPENABLE" -eq 1 ] || {
      echo "shipyard dashboard: installed URL is invalid" >&2
      return 2
    }
    case "$(uname -s)" in
      Darwin) opener="${SHIPYARD_DASHBOARD_OPEN:-open}" ;;
      *) opener="${SHIPYARD_DASHBOARD_OPEN:-xdg-open}" ;;
    esac
    command -v "$opener" >/dev/null 2>&1 || {
      echo "shipyard dashboard: opener is unavailable: $opener" >&2
      return 2
    }
    "$opener" "$DASHBOARD_URL" || {
      echo "shipyard dashboard: opener failed" >&2
      return 2
    }
  fi
  return "$report_rc"
}

# ---- inspect ---------------------------------------------------------------
cmd_inspect() {
  [ "$OPT_PROJECT_SET" -eq 0 ] || {
    echo "shipyard inspect: --project is not valid for fleet inspection" >&2
    return 2
  }
  [ "$OPT_TO_SET" -eq 0 ] && [ "$OPT_ROLE_SET" -eq 0 ] || {
    echo "shipyard inspect: --to/--role apply only to learn" >&2
    return 2
  }
  [ "${#ARGS[@]}" -eq 0 ] || {
    echo "shipyard inspect: unexpected positional argument '${ARGS[0]}'" >&2
    return 2
  }
  local scheduler unit_dir
  scheduler="$(_scheduler)" || {
    echo "shipyard inspect: unsupported scheduler" >&2
    return 2
  }
  case "$scheduler" in
    systemd) unit_dir="${SHIPYARD_SYSTEMD_DIR:-$HOME/.config/systemd/user}" ;;
    launchd) unit_dir="${SHIPYARD_LAUNCHD_DIR:-$HOME/Library/LaunchAgents}" ;;
  esac
  local cmd=(
    python3 "$QUARTET_DIR/skills/shipyard/inspect.py"
    --core-root "$QUARTET_DIR"
    --unit-dir "$unit_dir"
    --scheduler "$scheduler"
    --days "$OPT_DAYS"
  )
  [ "$OPT_JSON" -eq 1 ] && cmd+=(--json)
  "${cmd[@]}"
}

# ---- status ----------------------------------------------------------------
cmd_status() {
  [ "$OPT_JSON" -eq 0 ] && [ "$OPT_DAYS" = "7" ] || {
    echo "shipyard status: --json/--days apply only to inspect" >&2
    return 2
  }
  local scheduler unit_dir pattern suffix
  scheduler="$(_scheduler)" || { echo "shipyard: unsupported scheduler" >&2; return 2; }
  case "$scheduler" in
    systemd)
      unit_dir="$HOME/.config/systemd/user"; pattern="$PROJECT_NAME-*.timer"; suffix=".timer" ;;
    launchd)
      unit_dir="$HOME/Library/LaunchAgents"; pattern="$PROJECT_NAME-*.plist"; suffix=".plist" ;;
  esac
  local timers=() t
  if [ -d "$unit_dir" ]; then
    while IFS= read -r t; do [ -n "$t" ] && timers+=("$t"); done \
      < <(find "$unit_dir" -maxdepth 1 -name "$pattern" 2>/dev/null | sort)
  fi

  if [ "${#timers[@]}" -eq 0 ]; then
    echo "shipyard: no crew installed for '$PROJECT_NAME'"
    echo "  (no $unit_dir/$pattern)"
    echo "  install with: $QUARTET_DIR/install.sh --project $PROJECT_DIR"
    echo "dashboard:"
    _dashboard_report "  " || true
    return 3
  fi

  echo "shipyard: crew installed for '$PROJECT_NAME' — ${#timers[@]} job(s) via $scheduler:"
  for t in "${timers[@]}"; do echo "  - $(basename "$t" "$suffix")"; done

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
  echo "dashboard:"
  _dashboard_report "  " || true
  return 0
}

# ---- add-specialist --------------------------------------------------------
# Scaffold the domain-specialist archetype (agents/specialist/*) for one named
# subsystem into the target project, and wire it into three surfaces. The
# decision log is instantiated from the TEMPLATE (deterministic) — no model call
# is made, so drafting spends nothing and token-caps hold vacuously; the
# specialist role fills the log over time.
cmd_add_specialist() {
  local sub="${ARGS[0]:-}"
  [ -n "$sub" ] || { echo "usage: shipyard add-specialist <subsystem>" >&2; return 2; }
  case "$sub" in
    *[!a-zA-Z0-9_-]*) echo "add-specialist: subsystem must be [A-Za-z0-9_-]" >&2; return 2 ;;
  esac
  local dir="$PROJECT_DIR"
  [ -d "$dir/.agents" ] || {
    echo "add-specialist: $dir has no .agents/ (is the crew installed?)" >&2; return 2; }

  # 1. decision-log doc in the project's docs dir (discovered, not hardcoded)
  local docs_dir="docs"
  [ -d "$dir/doc" ] && [ ! -d "$dir/docs" ] && docs_dir="doc"
  mkdir -p "$dir/$docs_dir"
  local log_rel="$docs_dir/${sub}-decisions.md" log_abs="$dir/$docs_dir/${sub}-decisions.md"
  [ -f "$log_abs" ] || \
    sed "s/<subsystem>/$sub/g" "$QUARTET_DIR/agents/specialist/decision-log.template.md" > "$log_abs"

  # 2. the specialist subagent definition (archetype role + subsystem pointers)
  mkdir -p "$dir/.claude/agents"
  local agent_file="$dir/.claude/agents/${sub}-specialist.md"
  if [ ! -f "$agent_file" ]; then
    {
      printf -- '---\n'
      printf -- 'name: %s-specialist\n' "$sub"
      printf -- 'description: Standing reviewer for the %s subsystem. Reads %s before reviewing; guards settled decisions against fresh-context erosion.\n' "$sub" "$log_rel"
      printf -- '---\n\n'
      printf -- '# %s specialist\n\n' "$sub"
      printf -- 'Subsystem: **%s**. Decision log: `%s` (read it first).\n\n' "$sub" "$log_rel"
      printf -- 'Subsystem files: _list the globs/paths this specialist owns here._\n\n'
      printf -- '---\n\n'
      cat "$QUARTET_DIR/agents/specialist/role.md"
    } > "$agent_file"
  fi

  local marker="<!-- shipyard:specialist:$sub -->"

  # 3a. gates.md — a "consult the specialist" note (creates the file if absent)
  local gates="$dir/.agents/gates.md"
  if ! grep -qsF "$marker" "$gates"; then
    {
      printf '\n%s\n' "$marker"
      printf '### Specialist — %s — APPLIES: on changes to the %s subsystem\n' "$sub" "$sub"
      printf 'Consult the `%s-specialist` subagent and its decision log (`%s`) before landing a change to the %s subsystem; a change that re-introduces a rejected approach or breaks a stated invariant is a block.\n' "$sub" "$log_rel" "$sub"
    } >> "$gates"
  fi

  # 3b. release.md — a HUNK-KEYED file-conditional block (never membership-keyed)
  local rel="$dir/.agents/release.md"
  if ! grep -qsF "$marker" "$rel"; then
    {
      printf '\n%s\n' "$marker"
      printf '## Conventions — %s specialist gate\n\n' "$sub"
      printf -- '- When the DIFF contains real +/- hunks for a %s subsystem file, verify the change cites the relevant `%s` decision-log entry. Key on the presence of hunks in DIFF, NOT on mere membership in the CHANGED FILES list (which is a superset — a listed file with no hunk is at most a note).\n' "$sub" "$log_rel"
    } >> "$rel"
  fi

  # 3c. [write_ticket].context_files += the decision log (idempotent line-edit)
  local cfg="$dir/.agents/config.toml"
  if [ -f "$cfg" ]; then
    if ! QUARTET_LOG_REL="$log_rel" python3 - "$cfg" <<'PY'
import os, sys, re
path = sys.argv[1]; rel = os.environ["QUARTET_LOG_REL"]
txt = open(path, encoding="utf-8").read()
if rel in txt:            # idempotent
    sys.exit(0)
lines = txt.split("\n")
hdr = next((i for i, l in enumerate(lines)
            if re.match(r'\s*\[write_ticket\]\s*$', l)), None)
entry = '"%s"' % rel
if hdr is None:
    if txt and not txt.endswith("\n"):
        txt += "\n"
    txt += '\n[write_ticket]\ncontext_files = [%s]\n' % entry
    open(path, "w", encoding="utf-8").write(txt); sys.exit(0)
cf = None
for i in range(hdr + 1, len(lines)):
    if re.match(r'\s*\[[^\]]+\]\s*$', lines[i]):
        break
    if re.match(r'\s*context_files\s*=', lines[i]):
        cf = i; break
if cf is None:
    lines.insert(hdr + 1, 'context_files = [%s]' % entry)
else:
    j = cf
    while '[' not in lines[j]:
        j += 1
    k = lines[j].index('[')
    lines[j] = lines[j][:k + 1] + entry + ', ' + lines[j][k + 1:]
open(path, "w", encoding="utf-8").write("\n".join(lines))
PY
    then
      echo "add-specialist: failed to wire context_files" >&2; return 2
    fi
    if ! QUARTET_LOG_REL="$log_rel" python3 - "$cfg" <<'PY'
import os, sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
rel = os.environ["QUARTET_LOG_REL"]
assert rel in d.get("write_ticket", {}).get("context_files", []), "context_files missing path"
PY
    then
      echo "add-specialist: config no longer parses after wiring" >&2; return 2
    fi
  fi

  echo "add-specialist: wired '$sub' specialist"
  echo "  agent:   .claude/agents/${sub}-specialist.md"
  echo "  log:     $log_rel"
  echo "  gates:   .agents/gates.md (consult note)"
  echo "  release: .agents/release.md (hunk-keyed gate)"
  echo "  config:  [write_ticket].context_files += $log_rel"
  return 0
}

# ---- learn ------------------------------------------------------------------
# Route a lesson through the docs/ADAPTING.md triage taxonomy
# (project-specific / generic / install-time) to a deterministic destination.
# Classification is by an explicit --to flag, else a keyword heuristic; when
# neither settles it, exit 2 and ask (honest ambiguity beats a mis-route). No
# model is called — the routing, not the free-text judgement, is the value.
_learn_classify() {
  local l; l="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$l" in
    *install*|*installer*|*interview*|*--theme*|*--agents*|*"first-run"*) echo install; return ;;
  esac
  case "$l" in
    *"every project"*|*"all projects"*|*"fleet-wide"*|*"fleet wide"*|*portable*|*"core role"*|*"generic"*) echo generic; return ;;
  esac
  case "$l" in
    *"this project"*|*"this repo"*|*"here we"*|*" here."*|*convention*) echo project; return ;;
  esac
  echo ""
}

# _ticket_dir <dir> — absolute ticket directory for <dir>, read from ITS OWN
# .agents/config.toml [write_ticket] ticket_dir. `learn` can write to a dir
# other than $PROJECT_DIR, so never reuse the top-level CFG_JSON here.
# Falls back to docs/tickets when the key or the config file is absent.
_ticket_dir() {
  local d="$1" cfg="{}" rel=""
  if [ -f "$d/.agents/config.toml" ]; then
    cfg="$(load_config_json "$d/.agents/config.toml" 2>/dev/null)" || cfg="{}"
  fi
  rel="$(jq_from_json "$cfg" -r '.write_ticket.ticket_dir // empty' 2>/dev/null)"
  [ -n "$rel" ] || rel="docs/tickets"
  case "$rel" in /*) printf '%s\n' "$rel" ;; *) printf '%s/%s\n' "$d" "$rel" ;; esac
}

cmd_learn() {
  local lesson; lesson="${ARGS[*]:-}"
  lesson="$(printf '%s' "$lesson" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "$lesson" ] || { echo 'usage: shipyard learn "<lesson>"' >&2; return 2; }

  local class="$OPT_TO"
  case "$class" in
    project|generic|install) ;;
    "") class="$(_learn_classify "$lesson")" ;;
    *) echo "learn: --to must be project|generic|install" >&2; return 2 ;;
  esac
  if [ -z "$class" ]; then
    echo "learn: ambiguous lesson — cannot classify. Re-run with --to project|generic|install" >&2
    return 2
  fi

  local dir="$PROJECT_DIR"
  local slug
  slug="$(printf '%s' "$lesson" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' \
    | sed 's/^-//;s/-$//' | cut -c1-40)"
  [ -n "$slug" ] || slug="lesson"
  local stamp; stamp="$(date -u +%Y-%m-%d)"

  case "$class" in
    project)
      local role="${OPT_ROLE:-release}"
      case "$role" in design|build|release|medic|scribe) ;; *)
        echo "learn: --role must be a role id (design|build|release|medic|scribe)" >&2; return 2 ;;
      esac
      local rf="$dir/.agents/$role.md"
      [ -d "$dir/.agents" ] || { echo "learn: $dir has no .agents/" >&2; return 2; }
      {
        printf '\n<!-- shipyard:learn:%s -->\n' "$stamp"
        printf '> LESSON (%s): %s\n' "$stamp" "$lesson"
      } >> "$rf"
      echo "learn: routed project-specific → .agents/$role.md"
      ;;
    generic)
      local tdir; tdir="$(_ticket_dir "$dir")"
      mkdir -p "$tdir"
      local f="$tdir/learned-$slug.md"
      {
        printf '# Learned (generic → core change): %s\n\n' "$lesson"
        printf -- '- **Captured:** %s\n' "$stamp"
        printf -- '- **Route:** generic — a portable lesson that belongs in a core `agents/<role>/role.md` (or a shared skill), leak-checked and fleet-live on merge.\n'
        printf -- '- **Status:** Draft stub for human review — do NOT edit a core role file directly from this; polish into a real ticket first.\n\n'
        printf '## Lesson\n\n%s\n\n' "$lesson"
        printf '## Proposed core change\n\n_Describe the role-file / skill edit and the config flag that gates it (unset = today)._\n'
      } > "$f"
      echo "learn: routed generic → $f"
      ;;
    install)
      local tdir; tdir="$(_ticket_dir "$dir")"
      mkdir -p "$tdir"
      local f="$tdir/installer-question-$slug.md"
      {
        printf '# Installer question (install-time): %s\n\n' "$lesson"
        printf -- '- **Captured:** %s\n' "$stamp"
        printf -- '- **Route:** install-time — a new question for the installer interview so every future install decides this explicitly.\n'
        printf -- '- **Status:** Draft proposal for human review.\n\n'
        printf '## Lesson\n\n%s\n\n' "$lesson"
        printf '## Proposed interview question\n\n_The prompt, its default, and the config key it sets._\n'
      } > "$f"
      echo "learn: routed install-time → $f"
      ;;
  esac
  return 0
}

case "$SUBCMD" in
  help)   usage; exit 0 ;;
  status) cmd_status; exit $? ;;
  dashboard) cmd_dashboard; exit $? ;;
  inspect) cmd_inspect; exit $? ;;
  add-specialist) cmd_add_specialist; exit $? ;;
  learn) cmd_learn; exit $? ;;
  *)
    echo "shipyard: unknown subcommand '$SUBCMD'" >&2
    usage >&2
    exit 2 ;;
esac
