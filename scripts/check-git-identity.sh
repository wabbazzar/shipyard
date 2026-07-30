#!/usr/bin/env bash
# Validate Shipyard's pending or committed Git identities against its local
# canonical policy. Email values are deliberately never printed.

set -uo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  check-git-identity.sh --current --project <path>
  check-git-identity.sh --range <rev-range> [--range <rev-range> ...] --project <path>
  check-git-identity.sh --all <rev> --project <path>
  check-git-identity.sh --pre-push <remote-name> <remote-url> --project <path>
EOF
  exit 2
}

config_error() {
  printf 'git-identity: configuration error: %s\n' "$1" >&2
  exit 2
}

input_error() {
  printf 'git-identity: input error: %s\n' "$1" >&2
  exit 2
}

MODE=""
PROJECT=""
ALL_REV=""
REMOTE_NAME=""
REMOTE_URL=""
RANGES=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --current)
      [ -z "$MODE" ] || usage
      MODE="current"
      shift
      ;;
    --range)
      [ "$#" -ge 2 ] || usage
      if [ -z "$MODE" ]; then
        MODE="range"
      elif [ "$MODE" != "range" ]; then
        usage
      fi
      case "$2" in ""|-*) usage ;; esac
      RANGES+=("$2")
      shift 2
      ;;
    --all)
      [ -z "$MODE" ] && [ "$#" -ge 2 ] || usage
      case "$2" in ""|-*) usage ;; esac
      MODE="all"
      ALL_REV="$2"
      shift 2
      ;;
    --pre-push)
      [ -z "$MODE" ] && [ "$#" -ge 3 ] || usage
      [ -n "$2" ] && [ -n "$3" ] || usage
      MODE="pre-push"
      REMOTE_NAME="$2"
      REMOTE_URL="$3"
      shift 3
      ;;
    --project)
      [ -z "$PROJECT" ] && [ "$#" -ge 2 ] || usage
      [ -n "$2" ] || usage
      PROJECT="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[ -n "$MODE" ] && [ -n "$PROJECT" ] || usage
[ "$MODE" != "range" ] || [ "${#RANGES[@]}" -gt 0 ] || usage

ROOT="$(git -C "$PROJECT" rev-parse --show-toplevel 2>/dev/null)" ||
  config_error "project is not a Git worktree"
POLICY_FILE="$ROOT/.shipyard-git-identity.toml"
[ -f "$POLICY_FILE" ] || config_error "identity policy is missing"

CANONICAL_NAME="$(
  python3 - "$POLICY_FILE" 2>/dev/null <<'PY'
import sys

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib

try:
    with open(sys.argv[1], "rb") as handle:
        data = tomllib.load(handle)
    policy = data.get("git_identity")
    if not isinstance(policy, dict) or policy.get("enforce") is not True:
        raise ValueError
    name = policy.get("name")
    if (
        not isinstance(name, str)
        or not name
        or any(ch in name for ch in "\r\n\0<>")
    ):
        raise ValueError
except Exception:
    raise SystemExit(2)

sys.stdout.write(name)
PY
)" || config_error "identity policy is missing or malformed"

EMAIL_VALUES="$(git -C "$ROOT" config --local --get-all shipyard.identityEmail 2>/dev/null)" ||
  config_error "local canonical email is missing"
case "$EMAIL_VALUES" in
  ""|*$'\n'*|*$'\r'*|*" "*|*"<"*|*">"*|*@|@*)
    config_error "local canonical email is malformed"
    ;;
esac
case "$EMAIL_VALUES" in
  *@*) ;;
  *) config_error "local canonical email is malformed" ;;
esac
CANONICAL_EMAIL="$EMAIL_VALUES"

MISMATCH=0

report_mismatch() {
  local object="$1" field="$2"
  printf 'git-identity: %s: %s mismatch (value=<redacted>)\n' \
    "$object" "$field" >&2
  MISMATCH=1
}

check_fields() {
  local object="$1"
  local author_name="$2" author_email="$3"
  local committer_name="$4" committer_email="$5"

  [ "$author_name" = "$CANONICAL_NAME" ] ||
    report_mismatch "$object" "author.name"
  [ "$author_email" = "$CANONICAL_EMAIL" ] ||
    report_mismatch "$object" "author.email"
  [ "$committer_name" = "$CANONICAL_NAME" ] ||
    report_mismatch "$object" "committer.name"
  [ "$committer_email" = "$CANONICAL_EMAIL" ] ||
    report_mismatch "$object" "committer.email"
}

parse_current_ident() {
  local kind="$1" label ident name email
  case "$kind" in
    AUTHOR) label="author" ;;
    COMMITTER) label="committer" ;;
    *) input_error "unknown pending identity kind" ;;
  esac
  ident="$(git -C "$ROOT" var "GIT_${kind}_IDENT" 2>/dev/null)" ||
    input_error "cannot resolve pending $label identity"
  if [[ "$ident" =~ ^(.*)\ \<([^[:space:]\<\>]+)\>\ [0-9]+\ [+-][0-9]{4}$ ]]; then
    name="${BASH_REMATCH[1]}"
    email="${BASH_REMATCH[2]}"
  else
    input_error "pending $label identity is malformed"
  fi
  printf '%s\n%s\n' "$name" "$email"
}

if [ "$MODE" = "current" ]; then
  author_ident="$(parse_current_ident AUTHOR)" || exit $?
  committer_ident="$(parse_current_ident COMMITTER)" || exit $?
  author_name="${author_ident%%$'\n'*}"
  author_email="${author_ident#*$'\n'}"
  committer_name="${committer_ident%%$'\n'*}"
  committer_email="${committer_ident#*$'\n'}"
  check_fields "pending" \
    "$author_name" "$author_email" "$committer_name" "$committer_email"
  [ "$MISMATCH" -eq 0 ] && exit 0
  exit 1
fi

SHALLOW="$(git -C "$ROOT" rev-parse --is-shallow-repository 2>/dev/null)" ||
  input_error "cannot determine repository history depth"
[ "$SHALLOW" = "false" ] ||
  input_error "repository history is shallow"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/git-identity.XXXXXX")" ||
  input_error "cannot create temporary workspace"
trap 'rm -rf "$SCRATCH"' EXIT
COMMITS="$SCRATCH/commits"
UNIQUE_COMMITS="$SCRATCH/commits.unique"
: >"$COMMITS" || input_error "cannot initialize temporary workspace"

append_range() {
  local revision="$1" part="$SCRATCH/range"
  if ! git -C "$ROOT" rev-list --end-of-options "$revision" >"$part" 2>/dev/null; then
    input_error "revision range is missing or invalid"
  fi
  while IFS= read -r commit; do
    if [ -n "$commit" ]; then
      printf '%s\n' "$commit" >>"$COMMITS" ||
        input_error "cannot write temporary commit set"
    fi
  done <"$part"
}

append_new_ref() {
  local local_sha="$1" tips="$SCRATCH/tracking-tips" part="$SCRATCH/range"
  local tip
  local rev_args=("$local_sha")

  if ! git -C "$ROOT" for-each-ref --format='%(objectname)' -- \
      "refs/remotes/$REMOTE_NAME/" >"$tips" 2>/dev/null; then
    input_error "cannot enumerate remote-tracking refs"
  fi

  if [ -s "$tips" ]; then
    rev_args+=("--not")
    while IFS= read -r tip; do
      [ -n "$tip" ] && rev_args+=("$tip")
    done <"$tips"
  fi

  if ! git -C "$ROOT" rev-list "${rev_args[@]}" >"$part" 2>/dev/null; then
    input_error "new-ref history is missing or invalid"
  fi
  while IFS= read -r commit; do
    if [ -n "$commit" ]; then
      printf '%s\n' "$commit" >>"$COMMITS" ||
        input_error "cannot write temporary commit set"
    fi
  done <"$part"
}

is_zero_oid() {
  [[ "$1" =~ ^0+$ ]]
}

case "$MODE" in
  range)
    for revision in "${RANGES[@]}"; do
      append_range "$revision"
    done
    ;;
  all)
    append_range "$ALL_REV"
    ;;
  pre-push)
    while IFS= read -r line || [ -n "$line" ]; do
      local_ref=""
      local_sha=""
      remote_ref=""
      remote_sha=""
      extra=""
      read -r local_ref local_sha remote_ref remote_sha extra <<<"$line"
      if [ -z "$local_ref" ] || [ -z "$local_sha" ] ||
         [ -z "$remote_ref" ] || [ -z "$remote_sha" ] ||
         [ -n "$extra" ]; then
        input_error "malformed pre-push ref update"
      fi

      if is_zero_oid "$local_sha"; then
        continue
      fi
      if is_zero_oid "$remote_sha"; then
        append_new_ref "$local_sha"
      else
        append_range "$remote_sha..$local_sha"
      fi
    done
    ;;
esac

if ! LC_ALL=C sort -u "$COMMITS" >"$UNIQUE_COMMITS"; then
  input_error "cannot de-duplicate commit set"
fi

RECORD="$SCRATCH/record"
while IFS= read -r commit; do
  [ -n "$commit" ] || continue
  if ! git -C "$ROOT" show -s \
      --format='format:%H%x00%an%x00%ae%x00%cn%x00%ce%x00' \
      "$commit" >"$RECORD" 2>/dev/null; then
    input_error "commit metadata is missing or malformed"
  fi

  exec 3<"$RECORD"
  hash=""
  author_name=""
  author_email=""
  committer_name=""
  committer_email=""
  IFS= read -r -d '' hash <&3 ||
    input_error "commit metadata is malformed"
  IFS= read -r -d '' author_name <&3 ||
    input_error "commit metadata is malformed"
  IFS= read -r -d '' author_email <&3 ||
    input_error "commit metadata is malformed"
  IFS= read -r -d '' committer_name <&3 ||
    input_error "commit metadata is malformed"
  IFS= read -r -d '' committer_email <&3 ||
    input_error "commit metadata is malformed"
  if IFS= read -r -n 1 trailing <&3; then
    input_error "commit metadata is malformed"
  fi
  exec 3<&-

  [ "$hash" = "$commit" ] ||
    input_error "commit metadata hash does not match requested object"
  [ -n "$author_name" ] && [ -n "$author_email" ] &&
    [ -n "$committer_name" ] && [ -n "$committer_email" ] ||
    input_error "commit metadata is malformed"
  check_fields "$hash" \
    "$author_name" "$author_email" "$committer_name" "$committer_email"
done <"$UNIQUE_COMMITS"

[ "$MISMATCH" -eq 0 ] && exit 0
exit 1
