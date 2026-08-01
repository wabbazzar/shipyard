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

  outcome_lineage_validate "$raw" || return 2

  # Canonical shape only: [build]/[release] sections and medic.can_merge.
  # (The legacy section/merge-key normalization from the old display names is retired;
  # configs were migrated fleet-wide 2026-07-22.)
  printf '%s\n' "$raw"
}

# Make the validated opt-in helpers available to every caller that sources the
# config loader, without requiring five runner-specific implementations.
# shellcheck source=agents/lib/outcome-lineage.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/outcome-lineage.sh"

# quartet_notify <title> <body>
# quartet_notify --class <routine|actionable|urgent>
#   [--episode <key>] [--window <seconds>] <title> <body>
#
# Owner notification, transport-agnostic. Classified calls read the already
# loaded $CFG_JSON (`[notify].signal_level` = all|actionable|urgent|off), emit a
# notification.decision event, and optionally dedupe an explicit episode under
# $PROJECT_DIR/tmp. Legacy two-argument calls retain their exact old behavior.
#
# Set QUARTET_NOTIFY_CMD to any command taking (title, body) as two args,
# e.g. a Signal/ntfy/pushover wrapper. Unset → notifications are skipped.
_quartet_notification_decision() {
  local class="$1" episode="$2" outcome="$3" policy="$4" reason="$5"
  local root log_event svc
  root="${QUARTET_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  log_event="$root/agents/lib/log_event.sh"
  svc="${SVC:-${PROJECT_NAME:-notification}}"
  [ -x "$log_event" ] || return 0
  "$log_event" "$svc" notification.decision \
    class="$class" episode="$episode" outcome="$outcome" policy="$policy" \
    reason="$reason" || true
}

_quartet_notify_transport() {
  local title="$1" body="$2"
  [ -n "${QUARTET_NOTIFY_CMD:-}" ] || return 1
  # shellcheck disable=SC2086 — word-splitting QUARTET_NOTIFY_CMD is intentional
  $QUARTET_NOTIFY_CMD "$title" "$body" >/dev/null 2>&1
}

quartet_notify() {
  # Backward compatibility is deliberately a separate, byte-equivalent path:
  # no policy, state, or decision event is introduced for legacy callers.
  if [ "${1:-}" != "--class" ]; then
    [ "$#" -ge 2 ] || return 2
    _quartet_notify_transport "$1" "$2" || true
    return 0
  fi

  shift
  local class="${1:-}" episode="" window=86400
  shift || true
  case "$class" in
    routine|actionable|urgent) ;;
    *) echo "quartet_notify: invalid --class: $class" >&2; return 2 ;;
  esac

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --episode)
        [ "$#" -ge 2 ] || { echo "quartet_notify: --episode requires a key" >&2; return 2; }
        episode="$2"; shift 2 ;;
      --window)
        [ "$#" -ge 2 ] || { echo "quartet_notify: --window requires seconds" >&2; return 2; }
        window="$2"; shift 2 ;;
      --*) echo "quartet_notify: unknown option: $1" >&2; return 2 ;;
      *) break ;;
    esac
  done
  [ "$#" -eq 2 ] || {
    echo "quartet_notify: classified calls require title and body" >&2
    return 2
  }
  [[ "$window" =~ ^[0-9]+$ ]] || {
    echo "quartet_notify: --window must be non-negative seconds" >&2
    return 2
  }
  local title="$1" body="$2"

  local policy invalid_policy=0 threshold class_level cfg_data
  cfg_data="${CFG_JSON:-}"
  [ -n "$cfg_data" ] || cfg_data='{}'
  policy="$(jq -r '.notify.signal_level // "all"' <<<"$cfg_data" 2>/dev/null || echo all)"
  case "$policy" in
    all)        threshold=0 ;;
    actionable) threshold=1 ;;
    urgent)     threshold=2 ;;
    off)        threshold=99 ;;
    *) policy=all; threshold=0; invalid_policy=1 ;;
  esac
  case "$class" in
    routine)    class_level=0 ;;
    actionable) class_level=1 ;;
    urgent)     class_level=2 ;;
  esac

  if [ "$class_level" -lt "$threshold" ]; then
    _quartet_notification_decision "$class" "$episode" suppressed "$policy" policy
    return 0
  fi

  local reason=""
  [ "$invalid_policy" -eq 1 ] && reason="invalid_policy"

  # Calls without an episode are classified and filtered, but not deduped.
  if [ -z "$episode" ]; then
    if _quartet_notify_transport "$title" "$body"; then
      _quartet_notification_decision "$class" "" delivered "$policy" "$reason"
    else
      _quartet_notification_decision "$class" "" suppressed "$policy" transport_failed
    fi
    return 0
  fi

  local project_name project_tmp state_file lock_file key now state last
  project_name="${PROJECT_NAME:-$(jq -r '.project_name // empty' <<<"$cfg_data" 2>/dev/null)}"
  [ -n "$project_name" ] || project_name="unknown"
  project_tmp="${PROJECT_DIR:-}/tmp"
  if [ -z "${PROJECT_DIR:-}" ] || ! mkdir -p "$project_tmp" 2>/dev/null; then
    if _quartet_notify_transport "$title" "$body"; then
      _quartet_notification_decision "$class" "$episode" delivered "$policy" dedup_unavailable
    else
      _quartet_notification_decision "$class" "$episode" suppressed "$policy" transport_failed
    fi
    return 0
  fi

  state_file="$project_tmp/notification-dedup.json"
  lock_file="$project_tmp/notification-dedup.lock"
  key="$(printf '%s' "$project_name|$episode" | sha256sum | awk '{print $1}')"
  now="$(date +%s)"

  local notify_lock_kind="" notify_lock_dir="$lock_file.d"
  local lock_attempt=0
  if command -v flock >/dev/null 2>&1; then
    if exec 9>"$lock_file" && flock -x 9; then
      notify_lock_kind="flock"
    else
      exec 9>&-
    fi
  else
    while [ "$lock_attempt" -lt 100 ]; do
      if mkdir "$notify_lock_dir" 2>/dev/null; then
        notify_lock_kind="mkdir"
        break
      fi
      sleep 0.01
      lock_attempt=$((lock_attempt + 1))
    done
  fi
  if [ -z "$notify_lock_kind" ]; then
    if _quartet_notify_transport "$title" "$body"; then
      _quartet_notification_decision "$class" "$episode" delivered "$policy" dedup_unavailable
    else
      _quartet_notification_decision "$class" "$episode" suppressed "$policy" transport_failed
    fi
    return 0
  fi

  state='{"episodes":{}}'
  if [ -s "$state_file" ]; then
    state="$(jq -c 'if (.episodes | type) == "object" then . else {episodes:{}} end' \
      "$state_file" 2>/dev/null || printf '%s' '{"episodes":{}}')"
  fi
  last="$(jq -r --arg key "$key" '.episodes[$key] // 0' <<<"$state")"
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if [ "$last" -gt 0 ] && [ $((now - last)) -lt "$window" ]; then
    if [ "$notify_lock_kind" = "flock" ]; then
      flock -u 9; exec 9>&-
    else
      rmdir "$notify_lock_dir" 2>/dev/null || true
    fi
    _quartet_notification_decision "$class" "$episode" deduped "$policy" episode_window
    return 0
  fi

  # Hold the episode lock through delivery. Otherwise concurrent callers can
  # both pass the state check and double-page before either records success.
  if _quartet_notify_transport "$title" "$body"; then
    local state_tmp=""
    state_tmp="$(mktemp "$state_file.tmp.XXXXXX" 2>/dev/null || true)"
    if [ -n "$state_tmp" ] && \
       jq -c --arg key "$key" --argjson now "$now" \
         '.episodes[$key] = $now' <<<"$state" >"$state_tmp" 2>/dev/null && \
       mv "$state_tmp" "$state_file"; then
      :
    else
      [ -n "$state_tmp" ] && rm -f "$state_tmp"
      reason="state_write_failed"
    fi
    if [ "$notify_lock_kind" = "flock" ]; then
      flock -u 9; exec 9>&-
    else
      rmdir "$notify_lock_dir" 2>/dev/null || true
    fi
    _quartet_notification_decision "$class" "$episode" delivered "$policy" "$reason"
  else
    # A failed transport never consumes the key; the next call may retry.
    if [ "$notify_lock_kind" = "flock" ]; then
      flock -u 9; exec 9>&-
    else
      rmdir "$notify_lock_dir" 2>/dev/null || true
    fi
    _quartet_notification_decision "$class" "$episode" suppressed "$policy" transport_failed
  fi
  return 0
}
