#!/bin/bash
# agents/lib/load-config.sh — shared TOML loader for the agent runners.
#
# Source me from a runner. I provide one function:
#
#   load_config_json <path/to/config.toml>
#
# which echoes the parsed TOML as compact JSON to stdout. Caller does
# whatever it likes with that — typically:
#
#   CFG_JSON="$(load_config_json "$CONFIG_FILE")" || exit 2
#   PROJECT_NAME="$(jq -r '.project_name' <<<"$CFG_JSON")"
#
# Uses Python's stdlib tomllib (3.11+) with a tomli fallback for older
# Pythons. Returns non-zero on missing file or parse failure so callers
# can exit cleanly.

load_config_json() {
  local cfg_file="${1:-}"
  if [ -z "$cfg_file" ] || [ ! -f "$cfg_file" ]; then
    echo "load_config_json: file not found: $cfg_file" >&2
    return 2
  fi
  local raw
  raw="$(python3 - "$cfg_file" <<'PY' 2>/dev/null
import json, sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib  # py < 3.11
with open(sys.argv[1], 'rb') as f:
    print(json.dumps(tomllib.load(f)))
PY
)" || return 1
  [ -n "$raw" ] || return 1

  # Canonical shape only: [build]/[release] sections and medic.can_merge.
  # (The legacy section/merge-key normalization from the old display names is retired;
  # configs were migrated fleet-wide 2026-07-22.)
  printf '%s\n' "$raw"
}

# quartet_notify <title> <body> — owner notification, transport-agnostic.
# Set QUARTET_NOTIFY_CMD to any command taking (title, body) as two args,
# e.g. a Signal/ntfy/pushover wrapper. Unset → events are still logged,
# notifications are silently skipped. Never fails the caller.
quartet_notify() {
  [ -n "${QUARTET_NOTIFY_CMD:-}" ] || return 0
  # shellcheck disable=SC2086 — word-splitting QUARTET_NOTIFY_CMD is intentional
  $QUARTET_NOTIFY_CMD "$1" "$2" >/dev/null 2>&1 || true
}
