#!/bin/bash
# Durable, private Codex release-critic mailbox.
#
# Hook mode (default) reads a PostToolUse payload and emits at most one
# additionalContext object. Hook-side failures are fail-open: exit 0, no
# stdout. Writer/admin modes are deliberately nonzero on failure.

set -uo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROCESS_IDENTITY_HELPER="$SCRIPT_DIR/critic-process-identity.py"

MAX_BYTES=8192
MAX_LINES=50
HOOK_MAX_BYTES=131072
GC_SEC=604800
CLAIM_LEASE_SEC=30
LOCK_WAIT_STEPS=200
LOCK_SLEEP_SEC=0.025
RUNTIME_CONFIG_VALID=1
LOCK_DIR=""
LOCK_TOKEN=""
EXISTING_ITEM=""

feedback_error() {
  printf 'critic-codex-feedback: %s\n' "$*" >&2
}

valid_hash() {
  [[ "${1:-}" =~ ^[0-9a-f]{64}$ ]]
}

clamp_integer() {
  local raw="$1" minimum="$2" maximum="$3" normalized
  [[ "$raw" =~ ^[0-9]+$ ]] || return 1
  normalized="${raw#"${raw%%[!0]*}"}"
  [ -n "$normalized" ] || normalized=0
  if [ "${#normalized}" -gt "${#maximum}" ] ||
     { [ "${#normalized}" -eq "${#maximum}" ] &&
       [[ "$normalized" > "$maximum" ]]; }; then
    normalized="$maximum"
  elif [ "${#normalized}" -lt "${#minimum}" ] ||
       { [ "${#normalized}" -eq "${#minimum}" ] &&
         [[ "$normalized" < "$minimum" ]]; }; then
    normalized="$minimum"
  fi
  printf '%s\n' "$normalized"
}

validate_runtime_config() {
  local sleep_raw="${CRITIC_LOCK_SLEEP_SEC:-0.025}" sleep_value
  CLAIM_LEASE_SEC="$(clamp_integer "${CRITIC_CLAIM_LEASE_SEC:-30}" 1 86400)" ||
    return 1
  LOCK_WAIT_STEPS="$(clamp_integer "${CRITIC_LOCK_WAIT_STEPS:-200}" 1 10000)" ||
    return 1
  [[ "$sleep_raw" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] || return 1
  sleep_value="$(awk -v value="$sleep_raw" 'BEGIN {
    if (value < 0.001) value = 0.001
    if (value > 1) value = 1
    printf "%.3f", value
  }')" || return 1
  [[ "$sleep_value" =~ ^(0[.][0-9]{3}|1[.]000)$ ]] || return 1
  LOCK_SLEEP_SEC="$sleep_value"
}

validate_runtime_config || RUNTIME_CONFIG_VALID=0

checked_sha256() {
  local result hash rest
  if command -v sha256sum >/dev/null 2>&1; then
    result="$(sha256sum)" || return 1
  elif command -v shasum >/dev/null 2>&1; then
    result="$(shasum -a 256)" || return 1
  else
    return 1
  fi
  hash="${result%%[[:space:]]*}"
  rest="${result#"$hash"}"
  valid_hash "$hash" && [[ "$rest" =~ ^[[:space:]]+(-|/dev/stdin)?[[:space:]]*$ ]] ||
    return 1
  printf '%s\n' "$hash"
}

hash_text() {
  printf '%s' "$1" | checked_sha256
}

mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

uid_of() {
  stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1" 2>/dev/null
}

mtime_epoch() {
  stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null
}

safe_dir() {
  local path="$1"
  [ -d "$path" ] && [ ! -L "$path" ] &&
    [ "$(uid_of "$path")" = "$(id -u)" ] &&
    [ "$(mode_of "$path")" = "700" ]
}

safe_file() {
  local path="$1"
  [ -f "$path" ] && [ ! -L "$path" ] &&
    [ "$(uid_of "$path")" = "$(id -u)" ] &&
    [ "$(mode_of "$path")" = "600" ]
}

make_private_dir() {
  local path="$1"
  if [ -e "$path" ] || [ -L "$path" ]; then
    safe_dir "$path"
    return
  fi
  if ! mkdir "$path" 2>/dev/null; then
    safe_dir "$path"
    return
  fi
  chmod 700 "$path" 2>/dev/null || return 1
  safe_dir "$path"
}

state_root_path() {
  local xdg
  xdg="${XDG_STATE_HOME:-${HOME:-}/.local/state}"
  case "$xdg" in
    /*) ;;
    *) return 1 ;;
  esac
  [[ "$xdg" != *$'\n'* && "$xdg" != *$'\r'* ]] || return 1
  printf '%s/shipyard/critic-feedback\n' "${xdg%/}"
}

no_symlink_components() {
  local path="$1" rest component current=""
  case "$path" in /*) ;; *) return 1 ;; esac
  rest="${path#/}"
  while [ -n "$rest" ]; do
    component="${rest%%/*}"
    if [ "$rest" = "$component" ]; then rest=""; else rest="${rest#*/}"; fi
    [ -n "$component" ] || continue
    current="$current/$component"
    [ ! -L "$current" ] || return 1
  done
}

non_writable_owned_dir() {
  local path="$1" mode permissions group_digit world_digit
  [ -d "$path" ] && [ ! -L "$path" ] &&
    [ "$(uid_of "$path")" = "$(id -u)" ] || return 1
  mode="$(mode_of "$path")"
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  permissions="${mode: -3}"
  group_digit="${permissions:1:1}"
  world_digit="${permissions:2:1}"
  [ $((group_digit & 2)) -eq 0 ] && [ $((world_digit & 2)) -eq 0 ]
}

validate_state_parent() {
  local root="$1" xdg anchor current rest component
  xdg="${root%/shipyard/critic-feedback}"
  if [ -n "${XDG_STATE_HOME:-}" ]; then
    anchor="$xdg"
  else
    anchor="${HOME:-}"
  fi
  case "$anchor" in /*) ;; *) return 1 ;; esac

  # Trust starts at explicit XDG_STATE_HOME, or HOME when XDG is defaulted.
  # System ancestors such as /tmp may be root-owned/sticky, but every path
  # component is still lstat-checked so an intermediate symlink cannot redirect
  # state. From the boundary down, directories must be ours and not writable
  # by group/other; Shipyard-managed children are stricter 0700 directories.
  no_symlink_components "$xdg" || return 1
  current="${anchor%/}"
  rest="${xdg#"$current"}"
  rest="${rest#/}"
  non_writable_owned_dir "$current" || return 1
  while [ -n "$rest" ]; do
    component="${rest%%/*}"
    if [ "$rest" = "$component" ]; then rest=""; else rest="${rest#*/}"; fi
    [ -n "$component" ] || continue
    current="$current/$component"
    non_writable_owned_dir "$current" || return 1
  done
}

ensure_state_root_admin() {
  local root="$1" xdg shipyard
  xdg="${root%/shipyard/critic-feedback}"
  shipyard="$xdg/shipyard"
  no_symlink_components "$xdg" || return 1
  mkdir -p "$xdg" 2>/dev/null || return 1
  validate_state_parent "$root" || return 1
  make_private_dir "$shipyard" || return 1
  make_private_dir "$root" || return 1
  make_private_dir "$root/projects" || return 1
  make_private_dir "$root/mailboxes" || return 1
}

validate_state_root() {
  local root="$1" xdg shipyard
  xdg="${root%/shipyard/critic-feedback}"
  shipyard="$xdg/shipyard"
  validate_state_parent "$root" &&
    safe_dir "$shipyard" &&
    safe_dir "$root" &&
    safe_dir "$root/projects" &&
    safe_dir "$root/mailboxes"
}

resolve_project() {
  local candidate="${1:-}"
  [ -n "$candidate" ] && [ -d "$candidate" ] || return 1
  (cd "$candidate" 2>/dev/null && pwd -P)
}

valid_session() {
  local session="${1:-}"
  [ -n "$session" ] &&
    [ "${#session}" -le 4096 ] &&
    [[ "$session" != *$'\n'* ]] &&
    [[ "$session" != *$'\r'* ]]
}

project_hash() {
  hash_text "shipyard-project-v1:$1"
}

session_hash() {
  hash_text "shipyard-session-v1:$1"
}

allow_project() {
  local project root hash record tmp
  [ "${CRITIC_FEEDBACK_ADMIN:-0}" = "1" ] || {
    feedback_error "project authorization requires CRITIC_FEEDBACK_ADMIN=1"
    return 2
  }
  project="$(resolve_project "${1:-}")" || {
    feedback_error "project authorization requires an existing directory"
    return 2
  }
  root="$(state_root_path)" || return 75
  ensure_state_root_admin "$root" || {
    feedback_error "cannot establish private XDG state root"
    return 75
  }
  hash="$(project_hash "$project")" || return 75
  record="$root/projects/$hash.json"
  if [ -e "$record" ] || [ -L "$record" ]; then
    safe_file "$record" || return 75
    jq -e --arg project "$project" --arg hash "$hash" '
      keys == ["canonical_project","project_hash","schema_version"]
      and .schema_version == 1
      and .canonical_project == $project
      and .project_hash == $hash
    ' "$record" >/dev/null 2>&1 || return 75
    return 0
  fi
  tmp="$root/projects/.tmp.$$.$RANDOM"
  jq -cn --arg project "$project" --arg hash "$hash" \
    '{schema_version:1,canonical_project:$project,project_hash:$hash}' >"$tmp" ||
    return 75
  chmod 600 "$tmp" || {
    rm -f -- "$tmp"
    return 75
  }
  mv "$tmp" "$record" || {
    rm -f -- "$tmp"
    return 75
  }
}

authorized_project() {
  local project="$1" root hash record
  root="$(state_root_path)" || return 1
  validate_state_root "$root" || return 1
  hash="$(project_hash "$project")" || return 1
  record="$root/projects/$hash.json"
  safe_file "$record" || return 1
  jq -e --arg project "$project" --arg hash "$hash" '
    keys == ["canonical_project","project_hash","schema_version"]
    and .schema_version == 1
    and .canonical_project == $project
    and .project_hash == $hash
  ' "$record" >/dev/null 2>&1 || return 1
  printf '%s\n' "$hash"
}

prepare_mailbox() {
  local project="$1" session="$2" root project_key session_key project_box box d
  root="$(state_root_path)" || return 75
  project_key="$(authorized_project "$project")" || return 75
  session_key="$(session_hash "$session")" || return 75
  project_box="$root/mailboxes/$project_key"
  box="$project_box/$session_key"
  make_private_dir "$project_box" || return 75
  make_private_dir "$box" || return 75
  for d in pending claims emitted quarantine; do
    make_private_dir "$box/$d" || return 75
  done
  printf '%s\n' "$box"
}

existing_mailbox() {
  local project="$1" session="$2" root project_key session_key box d
  root="$(state_root_path)" || return 1
  project_key="$(authorized_project "$project")" || return 1
  session_key="$(session_hash "$session")" || return 1
  box="$root/mailboxes/$project_key/$session_key"
  [ -e "$box" ] || [ -L "$box" ] || return 2
  safe_dir "$root/mailboxes/$project_key" && safe_dir "$box" || return 1
  for d in pending claims emitted quarantine; do
    safe_dir "$box/$d" || return 1
  done
  printf '%s\n' "$box"
}

random_token() {
  local token
  token="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')" || return 1
  [[ "$token" =~ ^[0-9a-f]{32}$ ]] || return 1
  printf '%s\n' "$token"
}

process_identity() {
  [ -f "$PROCESS_IDENTITY_HELPER" ] || return 1
  python3 "$PROCESS_IDENTITY_HELPER" "$1"
}

read_lock_owner() {
  local owner="$1" third fourth extra
  LOCK_OWNER_PID=""
  LOCK_OWNER_TOKEN=""
  LOCK_OWNER_IDENTITY=""
  LOCK_OWNER_CREATED=""
  safe_file "$owner" || return 1
  IFS=' ' read -r LOCK_OWNER_PID LOCK_OWNER_TOKEN third fourth extra \
    <"$owner" || return 1
  [[ "$LOCK_OWNER_PID" =~ ^[1-9][0-9]*$ ]] &&
    [[ "$LOCK_OWNER_TOKEN" =~ ^[0-9a-f]{32}$ ]] &&
    [ -z "$extra" ] || return 1
  if [ -n "$fourth" ]; then
    # Current record: pid token process-start-identity created_epoch.
    LOCK_OWNER_IDENTITY="$third"
    LOCK_OWNER_CREATED="$fourth"
  else
    # Legacy record: pid token created_epoch. A live legacy PID remains
    # conservatively live because its original process identity is unknowable.
    LOCK_OWNER_CREATED="$third"
  fi
  [[ "$LOCK_OWNER_CREATED" =~ ^[0-9]+$ ]]
}

lock_generation() {
  local generation
  generation="$(stat -c '%d:%i' "$1" 2>/dev/null ||
    stat -f '%d:%i' "$1" 2>/dev/null)" || return 1
  [[ "$generation" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  printf '%s\n' "$generation"
}

file_size_of() {
  stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null
}

read_exact_reaper_owner() {
  local marker="$1" owner="$1/owner" size marker_name record expected
  local third fourth extra bytes
  safe_dir "$marker" && safe_file "$owner" || return 1
  size="$(file_size_of "$owner" || true)"
  [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ] && [ "$size" -le 256 ] ||
    return 1
  # Bounded read even after the size check: concurrent poison cannot grow the
  # owner between stat and read into an unbounded shell variable.
  record="$(dd if="$owner" bs=257 count=1 2>/dev/null)" || return 1
  LOCK_OWNER_PID=""
  LOCK_OWNER_TOKEN=""
  LOCK_OWNER_IDENTITY=""
  LOCK_OWNER_CREATED=""
  IFS=' ' read -r LOCK_OWNER_PID LOCK_OWNER_TOKEN third fourth extra \
    <<<"$record" || return 1
  [ -z "$extra" ] || return 1
  LOCK_OWNER_IDENTITY="$third"
  LOCK_OWNER_CREATED="$fourth"
  [[ "$LOCK_OWNER_PID" =~ ^[1-9][0-9]*$ ]] &&
    [[ "$LOCK_OWNER_TOKEN" =~ ^[0-9a-f]{32}$ ]] &&
    [[ "$LOCK_OWNER_CREATED" =~ ^[0-9]+$ ]] || return 1
  [[ "$LOCK_OWNER_IDENTITY" =~ ^[0-9]+-[0-9]+$ ]] || return 1
  [ "${#LOCK_OWNER_CREATED}" -le 20 ] || return 1
  marker_name="$(basename "$marker")"
  [ "$marker_name" = ".reaper-$LOCK_OWNER_TOKEN" ] || return 1
  expected="$LOCK_OWNER_PID $LOCK_OWNER_TOKEN $LOCK_OWNER_IDENTITY $LOCK_OWNER_CREATED"
  [ "$record" = "$expected" ] || return 1
  bytes="$(LC_ALL=C printf '%s' "$expected" | wc -c | tr -d ' ')"
  [[ "$bytes" =~ ^[0-9]+$ ]] && [ "$size" -eq $((bytes + 1)) ] || return 1
  REAPER_OWNER_RECORD="$record"
}

quarantine_reaper_marker() {
  local lock="$1" expected_lock_generation="$2" marker="$3" marker_kind="$4"
  local expected_marker_identity="$5" box target
  [ "$(lock_generation "$lock" || true)" = "$expected_lock_generation" ] ||
    return 1
  case "$marker_kind" in
    symlink)
      [ -L "$marker" ] &&
        [ "$(readlink "$marker" 2>/dev/null || true)" = \
          "$expected_marker_identity" ] || return 1
      ;;
    inode)
      [ ! -L "$marker" ] &&
        [ "$(lock_generation "$marker" || true)" = \
          "$expected_marker_identity" ] || return 1
      ;;
    *) return 1 ;;
  esac
  box="${lock%/.lock}"
  safe_dir "$box/quarantine" || return 1
  target="$box/quarantine/lock-marker-$(date +%s)-$$-$RANDOM"
  mv "$marker" "$target" || return 1
  # Special files and symlinks need no forensic body and are unlinked without
  # opening/following. Plain files and directories remain privately quarantined.
  if [ -L "$target" ] || [ -p "$target" ] || [ -S "$target" ] ||
     [ -b "$target" ] || [ -c "$target" ]; then
    rm -f -- "$target" || return 1
  fi
}

cleanup_partial_reaper_marker() {
  local marker="$1" expected_generation="$2" owner="$marker/owner"
  safe_dir "$marker" || return 1
  [ "$(lock_generation "$marker" || true)" = "$expected_generation" ] || return 1
  if [ -e "$owner" ] || [ -L "$owner" ]; then
    if [ -L "$owner" ] ||
       { [ -f "$owner" ] && [ "$(uid_of "$owner")" = "$(id -u)" ]; }; then
      rm -f -- "$owner" || return 1
    else
      return 1
    fi
  fi
  rmdir "$marker"
}

cleanup_owned_reaper_marker() {
  local marker="$1" expected_generation="$2" expected_record="$3"
  read_exact_reaper_owner "$marker" || return 1
  [ "$(lock_generation "$marker" || true)" = "$expected_generation" ] ||
    return 1
  [ "$REAPER_OWNER_RECORD" = "$expected_record" ] || return 1
  rm -f -- "$marker/owner" || return 1
  rmdir "$marker"
}

publish_reaper_marker() {
  local lock="$1" token identity created record
  REAPER_MARKER=""
  REAPER_GENERATION=""
  REAPER_RECORD=""
  token="$(random_token)" || return 1
  identity="$(process_identity "$$")" || return 1
  created="$(date +%s)"
  [[ "$created" =~ ^[0-9]+$ ]] || return 1
  REAPER_MARKER="$lock/.reaper-$token"
  mkdir "$REAPER_MARKER" 2>/dev/null || return 1
  REAPER_GENERATION="$(lock_generation "$REAPER_MARKER" || true)"
  [ -n "$REAPER_GENERATION" ] || {
    rmdir "$REAPER_MARKER" 2>/dev/null || true
    return 1
  }
  if ! chmod 700 "$REAPER_MARKER"; then
    cleanup_partial_reaper_marker "$REAPER_MARKER" "$REAPER_GENERATION" || true
    return 1
  fi
  record="$$ $token $identity $created"
  if ! printf '%s\n' "$record" >"$REAPER_MARKER/owner" ||
     ! chmod 600 "$REAPER_MARKER/owner"; then
    cleanup_partial_reaper_marker "$REAPER_MARKER" "$REAPER_GENERATION" || true
    return 1
  fi
  REAPER_RECORD="$record"
  if [ -n "${CRITIC_REAPER_PUBLISHED_TEST_HOOK:-}" ] &&
     ! "$CRITIC_REAPER_PUBLISHED_TEST_HOOK" "$REAPER_MARKER"; then
    cleanup_owned_reaper_marker "$REAPER_MARKER" "$REAPER_GENERATION" \
      "$REAPER_RECORD" || true
    return 1
  fi
}

recover_reaper_markers() {
  local lock="$1" expected_lock_generation="$2" marker marker_generation
  local owner owner_before created now target_before current_identity mtime
  local owner_live
  now="$(date +%s)"
  for marker in "$lock/.reaper" "$lock/.reaper-"*; do
    [ -e "$marker" ] || [ -L "$marker" ] || continue
    [ "$(lock_generation "$lock" || true)" = "$expected_lock_generation" ] ||
      return 1
    if [ -L "$marker" ]; then
      target_before="$(readlink "$marker" 2>/dev/null || true)"
      quarantine_reaper_marker "$lock" "$expected_lock_generation" "$marker" \
        symlink "$target_before" || return 1
      continue
    fi
    marker_generation="$(lock_generation "$marker" || true)"
    [ -n "$marker_generation" ] || return 1
    mtime="$(mtime_epoch "$marker" || true)"
    [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
    if [ ! -d "$marker" ]; then
      if [ "$mtime" -gt "$now" ] ||
         [ $((now - mtime)) -ge "$CLAIM_LEASE_SEC" ]; then
        quarantine_reaper_marker "$lock" "$expected_lock_generation" "$marker" \
          inode "$marker_generation" || return 1
      fi
      continue
    fi
    owner="$marker/owner"
    owner_before=""
    if read_exact_reaper_owner "$marker"; then
      owner_before="$REAPER_OWNER_RECORD"
      owner_live=0
      if kill -0 "$LOCK_OWNER_PID" 2>/dev/null; then
        current_identity="$(process_identity "$LOCK_OWNER_PID" || true)"
        if [ -z "$current_identity" ] ||
           [ "$current_identity" = "$LOCK_OWNER_IDENTITY" ]; then
          owner_live=1
        fi
      fi
      if [ "$owner_live" -eq 1 ]; then
        read_exact_reaper_owner "$marker" &&
          [ "$REAPER_OWNER_RECORD" = "$owner_before" ] || return 1
        continue
      fi
      # A dead or PID-reused exact owner ages from marker publication, never
      # from its attacker/corruption-controlled created_epoch field.
      created="$mtime"
      if [ "$created" -le "$now" ] &&
         [ $((now - created)) -lt "$CLAIM_LEASE_SEC" ]; then
        continue
      fi
      cleanup_owned_reaper_marker "$marker" "$marker_generation" \
        "$owner_before" || return 1
      continue
    fi

    # Every non-exact directory shape (ownerless, malformed, oversized,
    # wrong-mode, symlink/special owner, or wrong marker mode) is opaque poison.
    # After grace, move the entire generation out without inspecting children.
    if [ "$mtime" -le "$now" ] &&
       [ $((now - mtime)) -lt "$CLAIM_LEASE_SEC" ]; then
      continue
    fi
    quarantine_reaper_marker "$lock" "$expected_lock_generation" "$marker" \
      inode "$marker_generation" || return 1
  done
}

retire_stale_lock_generation() {
  local lock="$1" expected_generation="$2" owner_kind="$3"
  local expected_owner="$4" generation
  publish_reaper_marker "$lock" || return 1

  # The generation-unique child marker pins this exact lock: standard release
  # cannot rmdir it. Revalidate inode and owner only after publication; a
  # successor installed before publication is never mistaken for stale state.
  generation="$(lock_generation "$lock" || true)"
  if [ "$generation" != "$expected_generation" ]; then
    cleanup_owned_reaper_marker "$REAPER_MARKER" "$REAPER_GENERATION" \
      "$REAPER_RECORD" || true
    return 1
  fi
  case "$owner_kind" in
    record)
      if ! safe_file "$lock/owner" ||
         [ "$(<"$lock/owner")" != "$expected_owner" ]; then
        cleanup_owned_reaper_marker "$REAPER_MARKER" "$REAPER_GENERATION" \
          "$REAPER_RECORD" || true
        return 1
      fi
      if ! rm -f -- "$lock/owner"; then
        cleanup_owned_reaper_marker "$REAPER_MARKER" "$REAPER_GENERATION" \
          "$REAPER_RECORD" || true
        return 1
      fi
      ;;
    missing)
      if [ -e "$lock/owner" ] || [ -L "$lock/owner" ]; then
        cleanup_owned_reaper_marker "$REAPER_MARKER" "$REAPER_GENERATION" \
          "$REAPER_RECORD" || true
        return 1
      fi
      ;;
    *)
      cleanup_owned_reaper_marker "$REAPER_MARKER" "$REAPER_GENERATION" \
        "$REAPER_RECORD" || true
      return 1
      ;;
  esac
  cleanup_owned_reaper_marker "$REAPER_MARKER" "$REAPER_GENERATION" \
    "$REAPER_RECORD" || return 1
  rmdir "$lock" 2>/dev/null
}

run_lock_recovery_test_hook() {
  [ -n "${CRITIC_LOCK_RECOVERY_TEST_HOOK:-}" ] || return 0
  "$CRITIC_LOCK_RECOVERY_TEST_HOOK" "$LOCK_DIR"
}

unlock_mailbox() {
  local owner
  [ -n "$LOCK_DIR" ] && [ -n "$LOCK_TOKEN" ] || return 0
  owner="$LOCK_DIR/owner"
  if safe_dir "$LOCK_DIR" && read_lock_owner "$owner"; then
    if [ "$LOCK_OWNER_PID" = "$$" ] &&
       [ "$LOCK_OWNER_TOKEN" = "$LOCK_TOKEN" ]; then
      rm -f -- "$LOCK_DIR/owner" 2>/dev/null || true
      rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
  fi
  LOCK_DIR=""
  LOCK_TOKEN=""
}
trap unlock_mailbox EXIT
trap 'unlock_mailbox; exit 130' HUP INT TERM

lock_mailbox() {
  local box="$1" attempt now identity owner owner_before current_identity
  local owner_live generation owner_kind mtime
  LOCK_TOKEN="$(random_token)" || return 75
  identity="$(process_identity "$$")" || return 75
  LOCK_DIR="$box/.lock"
  for ((attempt=0; attempt<LOCK_WAIT_STEPS; attempt++)); do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      if ! chmod 700 "$LOCK_DIR" ||
         ! printf '%s %s %s %s\n' "$$" "$LOCK_TOKEN" "$identity" \
           "$(date +%s)" >"$LOCK_DIR/owner" ||
         ! chmod 600 "$LOCK_DIR/owner"; then
        rm -f -- "$LOCK_DIR/owner" 2>/dev/null || true
        rmdir "$LOCK_DIR" 2>/dev/null || true
        LOCK_DIR=""
        LOCK_TOKEN=""
        return 75
      fi
      return 0
    fi
    if ! safe_dir "$LOCK_DIR"; then
      # The prior owner may have removed the lock between failed mkdir and
      # the lstat/mode checks. That normal handoff race is a retry, not mailbox
      # corruption. Symlinks and non-directory replacements remain fatal.
      if [ -L "$LOCK_DIR" ] ||
          { [ -e "$LOCK_DIR" ] && [ ! -d "$LOCK_DIR" ]; }; then
        return 75
      fi
      sleep "$LOCK_SLEEP_SEC"
      continue
    fi
    generation="$(lock_generation "$LOCK_DIR" || true)"
    [ -n "$generation" ] || return 75
    recover_reaper_markers "$LOCK_DIR" "$generation" || return 75
    # Recovery may have removed only child markers; the lock generation itself
    # remains until a fully validated retirement below.
    safe_dir "$LOCK_DIR" || {
      sleep "$LOCK_SLEEP_SEC"
      continue
    }
    owner="$LOCK_DIR/owner"
    if read_lock_owner "$owner"; then
      owner_before="$(<"$owner")"
      owner_live=0
      if kill -0 "$LOCK_OWNER_PID" 2>/dev/null; then
        if [ -z "$LOCK_OWNER_IDENTITY" ]; then
          owner_live=1
        else
          current_identity="$(process_identity "$LOCK_OWNER_PID" || true)"
          # Failure to identify a live process is conservative; a definite
          # identity mismatch is a reused PID and therefore a stale owner.
          if [ -z "$current_identity" ] ||
             [ "$current_identity" = "$LOCK_OWNER_IDENTITY" ]; then
            owner_live=1
          fi
        fi
      fi
      [ "$owner_live" -eq 0 ] || {
        sleep "$LOCK_SLEEP_SEC"
        continue
      }
      # A complete owner whose PID is dead or whose start identity mismatches is
      # conclusively stale. Its self-reported epoch is not trusted: a forged
      # future value must not pin feedback behind an unrelated process.
      if [ "$(<"$owner")" = "$owner_before" ]; then
        generation="$(lock_generation "$LOCK_DIR" || true)"
        [ -n "$generation" ] || return 75
        run_lock_recovery_test_hook || return 75
        retire_stale_lock_generation "$LOCK_DIR" "$generation" record \
          "$owner_before" || true
      fi
    else
      # A crash before publishing a complete owner record retains the existing
      # lease-based recovery path. Unsafe owner inodes still cannot be opened.
      now="$(date +%s)"
      mtime="$(mtime_epoch "$LOCK_DIR" || true)"
      if safe_file "$owner"; then
        owner_kind=record
        owner_before="$(<"$owner")"
      elif [ ! -e "$owner" ] && [ ! -L "$owner" ]; then
        owner_kind=missing
        owner_before=""
      else
        return 75
      fi
      if [[ "$mtime" =~ ^[0-9]+$ ]] &&
         { [ "$mtime" -gt "$now" ] ||
           [ $((now - mtime)) -ge "$CLAIM_LEASE_SEC" ]; }; then
        generation="$(lock_generation "$LOCK_DIR" || true)"
        [ -n "$generation" ] || return 75
        run_lock_recovery_test_hook || return 75
        retire_stale_lock_generation "$LOCK_DIR" "$generation" "$owner_kind" \
          "$owner_before" || true
      fi
    fi
    sleep "$LOCK_SLEEP_SEC"
  done
  LOCK_DIR=""
  LOCK_TOKEN=""
  feedback_error "mailbox lock unavailable"
  return 75
}

quarantine_item() {
  local box="$1" item="$2" reason="$3" name target marker
  name="$(basename "$item")"
  target="$box/quarantine/poison-$(date +%s)-$$-$RANDOM-$name"
  marker="$box/quarantine/error-$(date +%s)-$$-$RANDOM.json"
  if [ -e "$item" ] || [ -L "$item" ]; then
    # Rename first: this atomically removes any inode type from the active
    # queue without opening or following it. Symlinks and non-directory special
    # files are then unlinked inside private quarantine; directories remain
    # quarantined and are never traversed.
    mv "$item" "$target" || return 1
    if [ -L "$target" ] || [ -p "$target" ] || [ -S "$target" ] ||
       [ -b "$target" ] || [ -c "$target" ]; then
      rm -f -- "$target" || return 1
    fi
  fi
  jq -cn --arg item "$name" --arg reason "$reason" \
    '{schema_version:1,item:$item,reason:$reason}' >"$marker" || return 1
  chmod 600 "$marker" || return 1
}

recover_claims() {
  local box="$1" now f mtime target
  now="$(date +%s)"
  for f in "$box/claims/"*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    if ! safe_file "$f"; then
      quarantine_item "$box" "$f" "unsafe claim" || return 75
      continue
    fi
    mtime="$(mtime_epoch "$f" || true)"
    [[ "$mtime" =~ ^[0-9]+$ ]] || {
      quarantine_item "$box" "$f" "claim timestamp unavailable" || return 75
      continue
    }
    # A future mtime is implausible publication state, not a reason to defer
    # forever. Replay the immutable claim exactly as for an expired lease.
    if [ "$mtime" -le "$now" ] &&
       [ $((now - mtime)) -lt "$CLAIM_LEASE_SEC" ]; then
      continue
    fi
    target="$box/pending/$(basename "$f")"
    if [ -e "$target" ] || [ -L "$target" ]; then
      quarantine_item "$box" "$f" "claim recovery collision" || return 75
      continue
    fi
    mv "$f" "$target" || return 75
  done
}

garbage_collect() {
  local box="$1" now f mtime
  now="$(date +%s)"
  for f in "$box/emitted/"* "$box/pending/".tmp.* "$box/claims/".tmp.*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    if ! safe_file "$f"; then
      quarantine_item "$box" "$f" "unsafe state mode" || return 75
      continue
    fi
    mtime="$(mtime_epoch "$f" || true)"
    [[ "$mtime" =~ ^[0-9]+$ ]] || continue
    [ $((now - mtime)) -gt "$GC_SEC" ] && rm -f -- "$f"
  done
  for f in "$box/quarantine/"*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    if [ -L "$f" ]; then
      rm -f -- "$f" || return 75
      continue
    fi
    mtime="$(mtime_epoch "$f" || true)"
    [[ "$mtime" =~ ^[0-9]+$ ]] || continue
    [ $((now - mtime)) -gt "$GC_SEC" ] || continue
    if [ -d "$f" ]; then
      rmdir "$f" 2>/dev/null || true
    else
      rm -f -- "$f" || return 75
    fi
  done
}

id_exists() {
  local box="$1" critique_id="$2" state f
  EXISTING_ITEM=""
  for state in pending claims emitted; do
    for f in "$box/$state/"*-"$critique_id".json; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      safe_file "$f" || return 2
      EXISTING_ITEM="$f"
      return 0
    done
  done
  return 1
}

bounded_summary() {
  python3 -c '
import sys
left = 8192
parts = []
for _ in range(50):
    if left <= 0:
        break
    chunk = sys.stdin.buffer.readline(left + 1)
    if not chunk:
        break
    chunk = chunk[:left]
    parts.append(chunk)
    left -= len(chunk)
    if not chunk.endswith(b"\n") and left:
        break
# Drain without retaining the remainder so a capped reader never SIGPIPEs its
# producer and memory remains bounded independently of input size.
while sys.stdin.buffer.read(65536):
    pass
sys.stdout.buffer.write(b"".join(parts).decode("utf-8", "ignore").encode())
'
}

bounded_hook_input() {
  python3 -c '
import sys

limit = int(sys.argv[1])
payload = sys.stdin.buffer.read(limit + 1)
if len(payload) > limit:
    raise SystemExit(2)
sys.stdout.buffer.write(payload)
' "$HOOK_MAX_BYTES"
}

sync_committed_item() {
  python3 - "$1" "$2" <<'PY'
import os
import stat
import sys

item, directory = sys.argv[1:]
file_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
file_flags |= getattr(os, "O_NOFOLLOW", 0)
item_fd = os.open(item, file_flags)
try:
    if not stat.S_ISREG(os.fstat(item_fd).st_mode):
        raise OSError("committed mailbox item is not a regular file")
    os.fsync(item_fd)
    if sys.platform == "darwin":
        import fcntl
        full_fsync = getattr(fcntl, "F_FULLFSYNC", None)
        if full_fsync is not None:
            fcntl.fcntl(item_fd, full_fsync)
finally:
    os.close(item_fd)

directory_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
directory_flags |= getattr(os, "O_DIRECTORY", 0)
directory_flags |= getattr(os, "O_NOFOLLOW", 0)
directory_fd = os.open(directory, directory_flags)
try:
    if not stat.S_ISDIR(os.fstat(directory_fd).st_mode):
        raise OSError("mailbox pending path is not a directory")
    os.fsync(directory_fd)
finally:
    os.close(directory_fd)
PY
}

sync_directory() {
  python3 - "$1" <<'PY'
import os
import stat
import sys

directory_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
directory_flags |= getattr(os, "O_DIRECTORY", 0)
directory_flags |= getattr(os, "O_NOFOLLOW", 0)
directory_fd = os.open(sys.argv[1], directory_flags)
try:
    if not stat.S_ISDIR(os.fstat(directory_fd).st_mode):
        raise OSError("mailbox path is not a directory")
    os.fsync(directory_fd)
finally:
    os.close(directory_fd)
PY
}

deposit_item() {
  local project session summary bounded marker critique_id box created_ns stamp
  local target tmp hash exists_rc
  [ "$RUNTIME_CONFIG_VALID" -eq 1 ] || {
    feedback_error "invalid critic mailbox timing configuration"
    return 75
  }
  project="$(resolve_project "${CRITIC_PROJECT_DIR:-}")" || {
    feedback_error "CRITIC_PROJECT_DIR must name an existing project"
    return 75
  }
  session="${1:-}"
  summary="${2:-}"
  valid_session "$session" || return 2
  marker=$'\036'
  bounded="$(
    printf '%s' "$summary" | bounded_summary || exit 75
    printf '\036'
  )" || return 75
  [[ "$bounded" == *"$marker" ]] || return 75
  summary="${bounded%"$marker"}"
  critique_id="${CRITIC_NOTE_ID:-}"
  if [ -z "$critique_id" ]; then
    critique_id="$(printf '%s\037%s' "$session" "$summary" | checked_sha256)" ||
      return 75
  fi
  valid_hash "$critique_id" || return 2
  hash="$(session_hash "$session")" || return 75
  box="$(prepare_mailbox "$project" "$session")" || {
    feedback_error "project is not authorized for private Codex feedback"
    return 75
  }
  lock_mailbox "$box" || return $?
  recover_claims "$box" || return $?
  garbage_collect "$box" || return $?
  id_exists "$box" "$critique_id"
  exists_rc=$?
  [ "$exists_rc" -ne 2 ] || return 75
  if [ "$exists_rc" -eq 0 ]; then
    sync_committed_item "$EXISTING_ITEM" "$(dirname "$EXISTING_ITEM")" ||
      return 75
    unlock_mailbox
    return 0
  fi
  created_ns="$(python3 -c 'import time; print(time.time_ns())')" || return 75
  [[ "$created_ns" =~ ^[0-9]+$ ]] || return 75
  stamp="$(printf '%020d' "$created_ns")"
  target="$box/pending/$stamp-$critique_id.json"
  tmp="$box/pending/.tmp.$$.$RANDOM"
  jq -cn --arg critique_id "$critique_id" --arg session_hash "$hash" \
    --argjson created_ns "$created_ns" --arg summary "$summary" \
    '{schema_version:1,critique_id:$critique_id,session_hash:$session_hash,
      created_ns:$created_ns,summary:$summary}' >"$tmp" || return 75
  chmod 600 "$tmp" || {
    rm -f -- "$tmp"
    return 75
  }
  mv "$tmp" "$target" || {
    rm -f -- "$tmp"
    return 75
  }
  if ! sync_committed_item "$target" "$box/pending"; then
    # The source queue/findings remain unacknowledged when deposit returns
    # failure. Remove the uncertain copy so a retry cannot deduplicate against
    # an item whose rename was never proven durable.
    rm -f -- "$target" || return 75
    sync_directory "$box/pending" || true
    return 75
  fi
  unlock_mailbox
}

validate_item() {
  local item="$1" expected_hash="$2"
  safe_file "$item" || return 1
  jq -e --arg session_hash "$expected_hash" --argjson max "$MAX_BYTES" '
    type == "object"
    and keys == ["created_ns","critique_id","schema_version","session_hash","summary"]
    and .schema_version == 1
    and (.critique_id | type == "string" and test("^[0-9a-f]{64}$"))
    and .session_hash == $session_hash
    and (.created_ns | type == "number")
    and (.summary | type == "string")
    and ((.summary | utf8bytelength) <= $max)
    and ((.summary | split("\n")
      | if length > 0 and .[-1] == "" then length - 1 else length end) <= 50)
  ' "$item" >/dev/null 2>&1
}

oldest_pending() {
  local box="$1" f
  for f in "$box/pending/"*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    printf '%s\n' "$f"
  done | LC_ALL=C sort | head -1
}

drain_item() {
  local input project session hash box box_rc pending claim critique_id output
  [ "$RUNTIME_CONFIG_VALID" -eq 1 ] || return 1
  input="$(bounded_hook_input)" || return 1
  jq -e 'type == "object"' <<<"$input" >/dev/null 2>&1 || return 1
  [ "$(jq -r '.hook_event_name // empty' <<<"$input")" = "PostToolUse" ] ||
    return 1
  session="$(jq -r '.session_id // empty' <<<"$input")"
  valid_session "$session" || return 1
  project="$(resolve_project "$(jq -r '.cwd // empty' <<<"$input")")" || return 1
  hash="$(session_hash "$session")" || return 1
  box="$(existing_mailbox "$project" "$session")"
  box_rc=$?
  [ "$box_rc" -ne 2 ] || return 0
  [ "$box_rc" -eq 0 ] || return 1
  lock_mailbox "$box" || return 1
  recover_claims "$box" || return 1
  garbage_collect "$box" || return 1
  while :; do
    pending="$(oldest_pending "$box")"
    [ -n "$pending" ] || {
      unlock_mailbox
      return 0
    }
    if ! safe_file "$pending"; then
      quarantine_item "$box" "$pending" "unsafe pending item" || return 1
      continue
    fi
    claim="$box/claims/$(basename "$pending")"
    mv "$pending" "$claim" || return 1
    if validate_item "$claim" "$hash"; then
      break
    fi
    quarantine_item "$box" "$claim" "malformed mailbox item" || return 1
    feedback_error "malformed mailbox item quarantined"
  done
  critique_id="$(jq -r '.critique_id' "$claim")" || return 1
  output="$(jq -cn --arg critique_id "$critique_id" --slurpfile item "$claim" '
    {hookSpecificOutput:{
      hookEventName:"PostToolUse",
      additionalContext:("Release critic [" + $critique_id + "]: " + $item[0].summary)
    }}
  ')" ||
    return 1
  printf '%s\n' "$output" || return 1
  mv "$claim" "$box/emitted/$(basename "$claim")" || return 1
  unlock_mailbox
}

valid_claim_token() {
  [[ "${1:-}" =~ ^[0-9]{20}-[0-9a-f]{64}[.]json$ ]]
}

# Stop cannot reuse drain_item directly: that path marks an item emitted before
# a wrapping process can transform PostToolUse JSON into Stop JSON. These three
# operations keep the immutable item in claims until the Stop response itself
# has been written. An abandoned pre-emission claim is recovered by the same
# bounded lease path as any other ambiguous hook-side crash.
stop_claim_item() {
  local project session hash box box_rc pending claim token output
  [ "$RUNTIME_CONFIG_VALID" -eq 1 ] || return 75
  project="$(resolve_project "${1:-}")" || return 2
  session="${2:-}"
  valid_session "$session" || return 2
  hash="$(session_hash "$session")" || return 75
  box="$(existing_mailbox "$project" "$session")"
  box_rc=$?
  [ "$box_rc" -ne 2 ] || return 3
  [ "$box_rc" -eq 0 ] || return 75
  lock_mailbox "$box" || return $?
  recover_claims "$box" || return $?
  garbage_collect "$box" || return $?
  while :; do
    pending="$(oldest_pending "$box")"
    [ -n "$pending" ] || {
      unlock_mailbox
      return 3
    }
    if ! safe_file "$pending"; then
      quarantine_item "$box" "$pending" "unsafe pending item" || return 75
      continue
    fi
    token="$(basename "$pending")"
    valid_claim_token "$token" || {
      quarantine_item "$box" "$pending" "invalid pending item name" || return 75
      continue
    }
    claim="$box/claims/$token"
    mv "$pending" "$claim" || return 75
    # The claim lease starts at the claim, not at an arbitrarily old deposit.
    touch "$claim" || return 75
    if validate_item "$claim" "$hash"; then
      break
    fi
    quarantine_item "$box" "$claim" "malformed mailbox item" || return 75
    feedback_error "malformed mailbox item quarantined"
  done
  output="$(jq -cn --arg token "$token" --slurpfile item "$claim" '
    {schema_version:1,claim_token:$token,
      critique_id:$item[0].critique_id,summary:$item[0].summary}
  ')" || return 75
  printf '%s\n' "$output" || return 75
  unlock_mailbox
}

stop_finish_claim() {
  local operation="$1" project session token hash box box_rc claim target
  project="$(resolve_project "${2:-}")" || return 2
  session="${3:-}"
  token="${4:-}"
  valid_session "$session" && valid_claim_token "$token" || return 2
  hash="$(session_hash "$session")" || return 75
  box="$(existing_mailbox "$project" "$session")"
  box_rc=$?
  [ "$box_rc" -eq 0 ] || return 75
  lock_mailbox "$box" || return $?
  claim="$box/claims/$token"
  case "$operation" in
    commit)
      target="$box/emitted/$token"
      if [ -e "$target" ] || [ -L "$target" ]; then
        safe_file "$target" && validate_item "$target" "$hash" || return 75
        [ ! -e "$claim" ] && [ ! -L "$claim" ] || return 75
        unlock_mailbox
        return 0
      fi ;;
    rollback)
      target="$box/pending/$token"
      if [ -e "$target" ] || [ -L "$target" ]; then
        safe_file "$target" && validate_item "$target" "$hash" || return 75
        [ ! -e "$claim" ] && [ ! -L "$claim" ] || return 75
        unlock_mailbox
        return 0
      fi
      if [ -e "$box/emitted/$token" ] || [ -L "$box/emitted/$token" ]; then
        safe_file "$box/emitted/$token" &&
          validate_item "$box/emitted/$token" "$hash" || return 75
        [ ! -e "$claim" ] && [ ! -L "$claim" ] || return 75
        unlock_mailbox
        return 0
      fi ;;
    *) return 2 ;;
  esac
  safe_file "$claim" && validate_item "$claim" "$hash" || return 75
  mv "$claim" "$target" || return 75
  sync_directory "$(dirname "$target")" || return 75
  sync_directory "$box/claims" || return 75
  unlock_mailbox
}

case "${1:-}" in
  --admin-allow-project)
    shift
    allow_project "${1:-}"
    ;;
  --deposit)
    shift
    deposit_item "${1:-}" "${2:-}"
    ;;
  --stop-claim)
    shift
    stop_claim_item "${1:-}" "${2:-}"
    ;;
  --stop-commit)
    shift
    stop_finish_claim commit "${1:-}" "${2:-}" "${3:-}"
    ;;
  --stop-rollback)
    shift
    stop_finish_claim rollback "${1:-}" "${2:-}" "${3:-}"
    ;;
  -*)
    feedback_error "unknown argument: $1"
    exit 2
    ;;
  *)
    if ! drain_item; then
      feedback_error "hook input or private feedback state rejected; failing open"
    fi
    exit 0
    ;;
esac
