#!/usr/bin/env bash
# incident-classification.sh — deterministic, model-independent incident tags.
#
# Source this file. Functions communicate through load-bearing shell status:
# 0 = matched, 1 = not matched.

incident_is_weekly_claude_limit() {
  local LC_ALL=C
  local bounded_text="${*:-}" normalized token
  [ -n "$bounded_text" ] || return 1

  normalized="$(printf '%s' "$bounded_text" |
    tr '[:upper:]' '[:lower:]' |
    tr -cs '[:alnum:]' '\n')"
  for token in claude weekly limit; do
    grep -Fqx "$token" <<<"$normalized" || return 1
  done
  return 0
}
