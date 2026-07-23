#!/bin/bash
# agents/lib/naming.sh — canonical role IDs → display names + agent dirs.
#
# Source me from a runner or the installer. Dependency-light (jq only).
#
# Canonical role IDs are the stable identity used for the agent directory,
# the config section, the event `role:` field, and the event-name prefix:
#
#     design  build  release  medic  scribe
#
# DISPLAY names (systemd unit / svc string, notification voice) resolve
# through role_display, which reads an optional [names] block from the
# project's config JSON. When no [names] block is present the display
# falls back to the role id itself (the pre-rename legacy display map is
# retired; every install is post-rename).

# Space-separated canonical role list, in install order.
QUARTET_ROLES="design build release medic scribe"

# role_display <role> <cfg-json>
#
# Echo the DISPLAY name for <role>: cfg.names.<role> if the [names] block has
# it, else the role id itself. <cfg-json> may be empty or "{}".
role_display() {
  local role="$1" cfg="${2:-}"
  local name=""
  if [ -n "$cfg" ]; then
    name="$(jq -r --arg r "$role" '.names[$r] // empty' <<<"$cfg" 2>/dev/null)"
  fi
  if [ -n "$name" ]; then
    printf '%s\n' "$name"
    return 0
  fi
  # No [names] block -> the role id IS the display.
  printf '%s\n' "$role"
}

# dir_for_role <role> — the agent directory for a role: an identity map
# (the legacy display-name dir aliases are retired).
dir_for_role() {
  case "$1" in
    design)  printf 'design\n' ;;
    build)   printf 'build\n' ;;
    release) printf 'release\n' ;;
    medic)   printf 'medic\n' ;;
    scribe)  printf 'scribe\n' ;;
    *)       printf '%s\n' "$1" ;;
  esac
}
