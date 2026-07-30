#!/bin/bash
# agents/lib/shoulder-wire.sh — additive, idempotent wiring of the shoulder-mode
# capture hook into each harness's NATIVE config. Sourced by install.sh behind
# the opt-in `--wire-shoulder` / `[shoulder] auto_wire`; with the opt-in unset,
# install NEVER sources or calls any of this, so a default install is
# byte-identical to today (install.sh has always refused to own these files).
#
# Contract:
#   sw_wire  <harness> <config_file> <command>  — ensure the capture hook is
#     present, ADDITIVELY (never clobbers existing hooks) and IDEMPOTENTLY
#     (re-running is a no-op). Prints one action line. Returns:
#       0 = wired now or already wired
#       2 = present config can't be merged safely without a YAML/TOML parser
#           (surfaced, not corrupted — operator merges by hand)
#   sw_wired <harness> <config_file> <command>  — 0 iff already wired (for doctor)
#
# Every path comes from the caller; nothing machine-specific is baked here.

# ---- claude: .claude/settings.json (JSON, merged with jq) ------------------
_sw_is_claude() {
  jq -e --arg c "$2" 'any(.hooks.PostToolUse[]?.hooks[]?; .command==$c)' \
    "$1" >/dev/null 2>&1
}
_sw_wire_claude() {
  local f="$1" cmd="$2" tmp
  [ -f "$f" ] || { mkdir -p "$(dirname "$f")" 2>/dev/null; printf '{}\n' >"$f"; }
  if _sw_is_claude "$f" "$cmd"; then echo "shoulder: claude already wired"; return 0; fi
  tmp="$(mktemp)" || return 2
  if jq --arg c "$cmd" '
        .hooks = (.hooks // {})
      | .hooks.PostToolUse = ((.hooks.PostToolUse // [])
          + [{matcher:"Edit|Write|MultiEdit",hooks:[{type:"command",command:$c}]}])
     ' "$f" >"$tmp" 2>/dev/null && mv "$tmp" "$f"; then
    echo "shoulder: wired claude PostToolUse -> $cmd"; return 0
  fi
  rm -f "$tmp"; echo "shoulder: FAILED to merge claude settings $f"; return 2
}

# ---- codex: config.toml (additive PostToolUse + Stop definitions) ----------
_sw_is_codex() { grep -qF -- "command = \"$2\"" "$1" 2>/dev/null; }
_sw_wire_codex() {
  local f="$1" cmd="$2"
  [ -f "$f" ] || { mkdir -p "$(dirname "$f")" 2>/dev/null; : >"$f"; }
  if _sw_is_codex "$f" "$cmd"; then echo "shoulder: codex already wired"; return 0; fi
  cat >>"$f" <<EOF

# shipyard shoulder-mode capture (install.sh --wire-shoulder)
[[hooks.PostToolUse]]
matcher = "apply_patch"
[[hooks.PostToolUse.hooks]]
type = "command"
command = "$cmd"
EOF
  echo "shoulder: wired codex [[hooks.PostToolUse]] -> $cmd"; return 0
}

_sw_codex_hook_wired() {
  local f="$1" event="$2" matcher="$3" cmd="$4"
  [ -f "$f" ] || return 1
  python3 - "$f" "$event" "$matcher" "$cmd" <<'PY' >/dev/null 2>&1
import sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib

path, event, matcher, command = sys.argv[1:]
with open(path, "rb") as handle:
    rows = tomllib.load(handle).get("hooks", {}).get(event, [])
for row in rows:
    if row.get("matcher") != matcher:
        continue
    if any(
        hook.get("type") == "command" and hook.get("command") == command
        for hook in row.get("hooks", [])
    ):
        raise SystemExit(0)
raise SystemExit(1)
PY
}

_sw_codex_config_valid() {
  [ -f "$1" ] || return 0
  python3 - "$1" <<'PY' >/dev/null 2>&1
import sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib
with open(sys.argv[1], "rb") as handle:
    tomllib.load(handle)
PY
}

_sw_append_codex_hook() {
  local f="$1" event="$2" matcher="$3" cmd="$4" encoded
  [ -f "$f" ] || { mkdir -p "$(dirname "$f")" 2>/dev/null; : >"$f"; }
  _sw_codex_hook_wired "$f" "$event" "$matcher" "$cmd" && return 0
  encoded="$(printf '%s' "$cmd" | jq -Rs .)" || return 2
  {
    printf '\n# shipyard shoulder-mode %s (install.sh --wire-shoulder)\n' \
      "$event"
    printf '[[hooks.%s]]\n' "$event"
    printf 'matcher = "%s"\n' "$matcher"
    printf '[[hooks.%s.hooks]]\n' "$event"
    printf 'type = "command"\n'
    printf 'command = %s\n' "$encoded"
  } >>"$f" || return 2
}

sw_codex_definition_hash() {
  local project="$1" capture="$2" feedback="$3" stop="$4" marker
  project="$(cd "$project" 2>/dev/null && pwd -P)" || return 2
  marker="$(sw_codex_runtime_marker "$project")" || return 2
  python3 - "$project" "$capture" "$feedback" "$stop" "$marker" <<'PY'
from hashlib import sha256
import sys

payload = "\x1f".join(("codex-three-hook-v1", *sys.argv[1:]))
print(sha256(payload.encode()).hexdigest())
PY
}

sw_codex_runtime_command() {
  local project="$1" target="$2" definition="$3" wire marker
  project="$(cd "$project" 2>/dev/null && pwd -P)" || return 2
  wire="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
  marker="$(sw_codex_runtime_marker "$project")" || return 2
  printf '%q %q %q %q %q %q %q\n' \
    /bin/bash "$wire" --codex-runtime-hook \
    "$project" "$target" "$definition" "$marker"
}

sw_wire_codex_bundle() {
  local f="$1" project="$2" capture="$3" feedback="$4" stop="$5"
  local definition capture_cmd feedback_cmd stop_cmd tmp
  if sw_codex_bundle_wired \
       "$f" "$project" "$capture" "$feedback" "$stop" 2>/dev/null; then
    echo "shoulder: codex capture, feedback, and Stop already wired"
    return 0
  fi
  _sw_codex_config_valid "$f" || {
    echo "shoulder: refusing to modify malformed Codex config $f" >&2
    return 2
  }
  definition="$(sw_codex_definition_hash \
    "$project" "$capture" "$feedback" "$stop")" || return 2
  capture_cmd="$capture"
  feedback_cmd="$(sw_codex_runtime_command "$project" "$feedback" "$definition")" ||
    return 2
  stop_cmd="$(sw_codex_runtime_command "$project" "$stop" "$definition")" ||
    return 2
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 2
  tmp="$(mktemp "$(dirname "$f")/.shoulder-config.XXXXXX")" || return 2
  if [ -f "$f" ]; then
    cp -p "$f" "$tmp" || {
      rm -f "$tmp"
      return 2
    }
  fi
  _sw_append_codex_hook "$tmp" PostToolUse apply_patch "$capture_cmd" &&
    _sw_append_codex_hook "$tmp" PostToolUse "*" "$feedback_cmd" &&
    _sw_append_codex_hook "$tmp" Stop "*" "$stop_cmd" &&
    _sw_codex_config_valid "$tmp" &&
    mv "$tmp" "$f" || {
      rm -f "$tmp"
      return 2
    }
  echo "shoulder: wired codex capture, feedback, and Stop definitions"
}

sw_codex_bundle_wired() {
  local f="$1" project="$2" capture="$3" feedback="$4" stop="$5"
  local definition capture_cmd feedback_cmd stop_cmd
  definition="$(sw_codex_definition_hash \
    "$project" "$capture" "$feedback" "$stop")" || return 2
  capture_cmd="$capture"
  feedback_cmd="$(sw_codex_runtime_command "$project" "$feedback" "$definition")" ||
    return 2
  stop_cmd="$(sw_codex_runtime_command "$project" "$stop" "$definition")" ||
    return 2
  _sw_codex_hook_wired "$f" PostToolUse apply_patch "$capture_cmd" &&
    _sw_codex_hook_wired "$f" PostToolUse "*" "$feedback_cmd" &&
    _sw_codex_hook_wired "$f" Stop "*" "$stop_cmd"
}

sw_codex_runtime_marker() {
  local project="$1" xdg hash
  project="$(cd "$project" 2>/dev/null && pwd -P)" || return 2
  xdg="${XDG_STATE_HOME:-${HOME:-}/.local/state}"
  case "$xdg" in /*) ;; *) return 2 ;; esac
  hash="$(python3 - "$project" <<'PY'
from hashlib import sha256
import sys
print(sha256(("shipyard-project-v1:" + sys.argv[1]).encode()).hexdigest())
PY
  )" || return 2
  printf '%s/shipyard/critic-feedback/runtime-seen/%s.json\n' \
    "${xdg%/}" "$hash"
}

_sw_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

_sw_uid() {
  stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1" 2>/dev/null
}

_sw_nlink() {
  stat -c '%h' "$1" 2>/dev/null || stat -f '%l' "$1" 2>/dev/null
}

_sw_private_dir() {
  [ -d "$1" ] && [ ! -L "$1" ] &&
    [ "$(_sw_uid "$1")" = "$(id -u)" ] &&
    [ "$(_sw_mode "$1")" = "700" ]
}

_sw_private_file() {
  [ -f "$1" ] && [ ! -L "$1" ] &&
    [ "$(_sw_uid "$1")" = "$(id -u)" ] &&
    [ "$(_sw_mode "$1")" = "600" ] &&
    [ "$(_sw_nlink "$1")" = "1" ]
}

sw_prepare_codex_runtime_marker() {
  local marker dir
  marker="$(sw_codex_runtime_marker "$1")" || return 2
  dir="$(dirname "$marker")"
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    _sw_private_dir "$dir" || return 2
  else
    (umask 077; mkdir "$dir") 2>/dev/null || return 2
    _sw_private_dir "$dir" || return 2
  fi
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    _sw_private_file "$marker" || return 2
    rm -f -- "$marker" || return 2
  fi
}

sw_codex_runtime_verified() {
  local project="$1" definition="$2" marker
  marker="$(sw_codex_runtime_marker "$project")" || return 1
  _sw_private_dir "$(dirname "$marker")" &&
    _sw_private_file "$marker" &&
    jq -e --arg definition "$definition" '
      keys == [
        "definition_sha256",
        "definition_version",
        "invocation_epoch",
        "schema_version"
      ]
      and .schema_version == 1
      and .definition_version == "codex-three-hook-v1"
      and .definition_sha256 == $definition
      and (.invocation_epoch | type == "number")
    ' "$marker" >/dev/null 2>&1
}

_sw_codex_runtime_hook() {
  local project="$1" target="$2" definition="$3" marker="$4"
  local input cwd canonical tmp rc epoch
  input="$(umask 077; mktemp "${TMPDIR:-/tmp}/shipyard-codex-hook.XXXXXX")" ||
    return 0
  if ! python3 -c '
import sys

path = sys.argv[1]
limit = 131072
payload = sys.stdin.buffer.read(limit + 1)
if len(payload) > limit:
    raise SystemExit(2)
with open(path, "wb") as handle:
    handle.write(payload)
' "$input"; then
    rm -f "$input"
    return 0
  fi
  cwd="$(jq -r '.cwd // empty' "$input" 2>/dev/null || true)"
  canonical="$(cd "$cwd" 2>/dev/null && pwd -P || true)"
  if [ "$canonical" != "$project" ]; then
    rm -f "$input"
    return 0
  fi

  /bin/bash "$target" <"$input"
  rc=$?
  rm -f "$input"

  _sw_private_dir "$(dirname "$marker")" || return "$rc"
  [ ! -e "$marker" ] && [ ! -L "$marker" ] ||
    _sw_private_file "$marker" || return "$rc"
  tmp="$marker.tmp.$$.$RANDOM"
  epoch="$(date +%s)"
  if (umask 077; jq -cn --arg definition "$definition" --argjson epoch "$epoch" '
      {
        schema_version: 1,
        definition_version: "codex-three-hook-v1",
        definition_sha256: $definition,
        invocation_epoch: $epoch
      }
    ' >"$tmp" 2>/dev/null); then
    mv "$tmp" "$marker" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
  return "$rc"
}

# ---- hermes: config.yaml (hooks: post_tool_call:, appended) ----------------
_sw_is_hermes() { grep -qF -- "command: \"$2\"" "$1" 2>/dev/null; }
_sw_wire_hermes() {
  local f="$1" cmd="$2"
  [ -f "$f" ] || { mkdir -p "$(dirname "$f")" 2>/dev/null; : >"$f"; }
  if _sw_is_hermes "$f" "$cmd"; then echo "shoulder: hermes already wired"; return 0; fi
  # A top-level `hooks:` mapping already exists: appending a second one is
  # invalid YAML and we have no stdlib YAML writer, so surface it rather than
  # corrupt the file.
  if grep -qE '^hooks:' "$f" 2>/dev/null; then
    echo "shoulder: hermes $f already has a hooks: block — add manually:"
    echo "           post_tool_call:"
    echo "             - matcher: \"write_file|patch|edit_file\""
    echo "               command: \"$cmd\""
    return 2
  fi
  cat >>"$f" <<EOF

# shipyard shoulder-mode capture (install.sh --wire-shoulder)
hooks:
  post_tool_call:
    - matcher: "write_file|patch|edit_file"
      command: "$cmd"
EOF
  echo "shoulder: wired hermes post_tool_call -> $cmd"; return 0
}

# ---- dispatch --------------------------------------------------------------
sw_wire() {
  case "$1" in
    claude) _sw_wire_claude "$2" "$3" ;;
    codex)  _sw_wire_codex  "$2" "$3" ;;
    hermes) _sw_wire_hermes "$2" "$3" ;;
    *) echo "shoulder: unknown harness '$1'" >&2; return 2 ;;
  esac
}
sw_wired() {
  case "$1" in
    claude) _sw_is_claude "$2" "$3" ;;
    codex)  _sw_is_codex  "$2" "$3" ;;
    hermes) _sw_is_hermes "$2" "$3" ;;
    *) return 2 ;;
  esac
}

# sw_config_path <harness> <project_dir> — the native config file for a harness.
sw_config_path() {
  case "$1" in
    claude) printf '%s/.claude/settings.json\n' "$2" ;;
    codex)  printf '%s/config.toml\n' "${CODEX_HOME:-$HOME/.codex}" ;;
    hermes) printf '%s/config.yaml\n' "${HERMES_HOME:-$HOME/.hermes}" ;;
    *) return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --codex-runtime-hook)
      [ "$#" -eq 5 ] || exit 0
      _sw_codex_runtime_hook "$2" "$3" "$4" "$5"
      exit $?
      ;;
    *)
      echo "usage: shoulder-wire.sh --codex-runtime-hook PROJECT TARGET DEFINITION MARKER" >&2
      exit 2
      ;;
  esac
fi
