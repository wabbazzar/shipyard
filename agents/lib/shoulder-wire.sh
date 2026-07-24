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

# ---- codex: config.toml ([[hooks.PostToolUse]], appended) ------------------
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
