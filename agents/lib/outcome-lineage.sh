#!/bin/bash
# Opt-in, content-minimizing outcome lineage shared by every role runner.

outcome_lineage_validate() {
  local cfg="${1:-}"
  [ -n "$cfg" ] || cfg='{}'
  printf '%s\n' "$cfg" | jq -e '
    if has("telemetry") then
      (.telemetry | type) == "object" and
      ((.telemetry | has("outcome_lineage") | not) or
       ((.telemetry.outcome_lineage | type) == "boolean"))
    else true end
  ' >/dev/null 2>&1 || {
    echo "telemetry.outcome_lineage must be boolean" >&2
    return 2
  }
}

outcome_lineage_configure() {
  local cfg="${1:-}"
  [ -n "$cfg" ] || cfg='{}'
  outcome_lineage_validate "$cfg" || return 2
  QUARTET_OUTCOME_LINEAGE="$(
    printf '%s\n' "$cfg" | jq -r '.telemetry.outcome_lineage // false'
  )"
  export QUARTET_OUTCOME_LINEAGE
  unset QUARTET_RUN_ID
  unset SPAWN_PROVIDER SPAWN_MODEL SPAWN_INPUT_TOKENS
  unset SPAWN_CACHE_READ_TOKENS SPAWN_CACHE_WRITE_TOKENS
  unset SPAWN_OUTPUT_TOKENS SPAWN_REASONING_TOKENS
}

outcome_lineage_enabled() {
  [ "${QUARTET_OUTCOME_LINEAGE:-false}" = "true" ]
}

outcome_lineage_start_run() {
  local cfg="${1:-}" run_id
  [ -n "$cfg" ] || cfg='{}'
  outcome_lineage_configure "$cfg" || return 2
  outcome_lineage_enabled || return 0
  run_id="$(python3 -c 'import secrets; print(secrets.token_hex(16))')" || return 1
  [[ "$run_id" =~ ^[0-9a-f]{32}$ ]] || return 1
  QUARTET_RUN_ID="$run_id"
  export QUARTET_RUN_ID
}

outcome_lineage_token_fields() {
  OUTCOME_TOKEN_FIELDS=()
  outcome_lineage_enabled || return 0
  [[ "${SPAWN_PROVIDER:-}" =~ ^[A-Za-z0-9._:@/-]{1,128}$ ]] &&
    OUTCOME_TOKEN_FIELDS+=("provider=$SPAWN_PROVIDER")
  [[ "${SPAWN_MODEL:-}" =~ ^[A-Za-z0-9._:@/-]{1,256}$ ]] &&
    OUTCOME_TOKEN_FIELDS+=("model=$SPAWN_MODEL")
  [[ "${SPAWN_INPUT_TOKENS:-}" =~ ^[0-9]+$ ]] &&
    OUTCOME_TOKEN_FIELDS+=("input_tokens=$SPAWN_INPUT_TOKENS")
  [[ "${SPAWN_CACHE_READ_TOKENS:-}" =~ ^[0-9]+$ ]] &&
    OUTCOME_TOKEN_FIELDS+=("cache_read_tokens=$SPAWN_CACHE_READ_TOKENS")
  [[ "${SPAWN_CACHE_WRITE_TOKENS:-}" =~ ^[0-9]+$ ]] &&
    OUTCOME_TOKEN_FIELDS+=("cache_write_tokens=$SPAWN_CACHE_WRITE_TOKENS")
  [[ "${SPAWN_OUTPUT_TOKENS:-}" =~ ^[0-9]+$ ]] &&
    OUTCOME_TOKEN_FIELDS+=("output_tokens=$SPAWN_OUTPUT_TOKENS")
  [[ "${SPAWN_REASONING_TOKENS:-}" =~ ^[0-9]+$ ]] &&
    OUTCOME_TOKEN_FIELDS+=("reasoning_tokens=$SPAWN_REASONING_TOKENS")
}

outcome_lineage_ticket_id() {
  local project_dir="$1" ticket_file="$2"
  python3 - "$project_dir" "$ticket_file" <<'PY'
import hashlib
from pathlib import Path
import sys

project = Path(sys.argv[1]).resolve(strict=True)
ticket = Path(sys.argv[2]).resolve(strict=True)
try:
    relative = ticket.relative_to(project)
except ValueError:
    raise SystemExit(2)
if not relative.parts or any(part in {"", ".", ".."} for part in relative.parts):
    raise SystemExit(2)
identity = hashlib.sha256(
    b"shipyard-ticket-v1\0" + relative.as_posix().encode("utf-8")
).hexdigest()
print(f"ticket:{identity}")
PY
}

outcome_lineage_emit_build_items() {
  local log_event="$1" svc="$2" result_file="$3"
  outcome_lineage_enabled || return 0
  [ -s "$result_file" ] || return 1
  jq -e '
    type == "object" and (.pass | type) == "boolean" and
    (.items | type) == "array" and all(.items[];
      type == "object" and
      (.id | type == "string" and length > 0 and length <= 256 and
        test("^[A-Za-z0-9._:@-]+$")) and
      (.classification == "ATTEMPT" or .classification == "SKIP" or
        .classification == "SECURITY") and
      ((.outcome //
        (if .classification == "SKIP" then "skipped"
         elif .classification == "SECURITY" then "security"
         else "" end)) as $outcome |
        ($outcome == "pr_opened" or $outcome == "tests_failed" or
         $outcome == "scope_blew" or $outcome == "dry-run" or
         $outcome == "skipped" or $outcome == "security")) and
      ((.pr_url // "") | type == "string" and length <= 512 and
        (. == "" or test("^https://[^[:space:]]+$"))) and
      ((.branch // "") | type == "string" and length <= 255 and
        (. == "" or test("^[A-Za-z0-9._/-]+$"))) and
      ((.commit_sha // "") | type == "string" and
        (. == "" or test("^[0-9a-fA-F]{7,64}$"))) and
      ((.upstream_work_id // "") | type == "string" and length <= 256 and
        (. == "" or test("^[A-Za-z0-9._:@-]+$"))))
  ' "$result_file" >/dev/null 2>&1 || return 1

  while IFS= read -r work_id &&
        IFS= read -r classification &&
        IFS= read -r outcome &&
        IFS= read -r upstream_work_id &&
        IFS= read -r pr_url &&
        IFS= read -r branch &&
        IFS= read -r commit_sha; do
    local fields=("work_id=$work_id" "classification=$classification" "outcome=$outcome")
    [ -n "$upstream_work_id" ] && fields+=("upstream_work_id=$upstream_work_id")
    [ -n "$pr_url" ] && fields+=("pr_url=$pr_url")
    [ -n "$branch" ] && fields+=("branch=$branch")
    [ -n "$commit_sha" ] && fields+=("commit_sha=$commit_sha")
    "$log_event" "$svc" build.work.outcome "${fields[@]}" || true
  done < <(jq -r '.items[] |
    .id, .classification,
    (.outcome // (if .classification == "SKIP" then "skipped"
      elif .classification == "SECURITY" then "security" else "" end)),
    (.upstream_work_id // ""), (.pr_url // ""), (.branch // ""),
    (.commit_sha // "")
  ' "$result_file")
}
