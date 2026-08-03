#!/usr/bin/env bash
# Dispatch the raw Git identity gate for a GitHub Actions event. Identity
# values are deliberately never printed.

set -uo pipefail

usage() {
  printf 'usage: check-git-identity-ci.sh --project <path>\n' >&2
  exit 2
}

fail() {
  printf 'git-identity CI: %s\n' "$1" >&2
  exit 2
}

PROJECT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)
      [ -z "$PROJECT" ] && [ "$#" -ge 2 ] && [ -n "$2" ] || usage
      PROJECT="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done
[ -n "$PROJECT" ] || usage

ROOT="$(git -C "$PROJECT" rev-parse --show-toplevel 2>/dev/null)" ||
  fail "project is not a Git worktree"
[ -n "${SHIPYARD_IDENTITY_EMAIL:-}" ] ||
  fail "identity email variable is missing"
[ "$(git -C "$ROOT" rev-parse --is-shallow-repository 2>/dev/null)" = "false" ] ||
  fail "repository history is shallow"

git -C "$ROOT" config --local shipyard.identityEmail \
  "$SHIPYARD_IDENTITY_EMAIL" || fail "cannot configure identity email"
trap 'git -C "$ROOT" config --local --unset-all shipyard.identityEmail >/dev/null 2>&1 || true' EXIT

case "${EVENT_NAME:-}" in
  pull_request)
    [ -n "${BASE_SHA:-}" ] && [ -n "${PR_HEAD_SHA:-}" ] ||
      fail "pull request identity range is missing"
    bash "$ROOT/scripts/check-git-identity.sh" \
      --range "$BASE_SHA..$PR_HEAD_SHA" --project "$ROOT"
    ;;
  push)
    [ "${TARGET_REF:-}" = "refs/heads/main" ] && [ -n "${HEAD_SHA:-}" ] ||
      fail "main identity revision is missing"
    bash "$ROOT/scripts/check-git-identity.sh" \
      --all "$HEAD_SHA" --project "$ROOT"
    ;;
  *) fail "unsupported workflow event" ;;
esac
