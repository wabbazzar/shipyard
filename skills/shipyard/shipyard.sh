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
OPT_TO=""       # learn: explicit route (project|generic|install)
OPT_ROLE=""     # learn --to project: which .agents/<role>.md
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT_DIR="$2"; shift 2 ;;
    --to)      OPT_TO="$2";      shift 2 ;;
    --role)    OPT_ROLE="$2";    shift 2 ;;
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
    [--to project|generic|install] explicit route (else keyword heuristic)
    [--role <role>]                 project route target (default release)

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
      mkdir -p "$dir/docs/tickets"
      local f="$dir/docs/tickets/learned-$slug.md"
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
      mkdir -p "$dir/docs/tickets"
      local f="$dir/docs/tickets/installer-question-$slug.md"
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
  add-specialist) cmd_add_specialist; exit $? ;;
  learn) cmd_learn; exit $? ;;
  *)
    echo "shipyard: unknown subcommand '$SUBCMD'" >&2
    usage >&2
    exit 2 ;;
esac
