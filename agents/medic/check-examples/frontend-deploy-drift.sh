#!/usr/bin/env bash
# EXAMPLE medic drift check — copy into your project (e.g.
# scripts/medic-checks/), edit the CONFIG block, then register it.
# Setting restart_unit lets medic bounce a wedged auto-deployer
# (classify `restart` when tests are green; notify-only when red):
#
#   [[medic.checks]]
#   name         = "frontend-deploy-drift"
#   cmd          = "scripts/medic-checks/frontend-deploy-drift.sh"
#   timeout_sec  = 30
#   restart_unit = "myproject-frontend-deploy.timer"
#
# Convention this check depends on: your deploy script stamps the
# deployed commit into a publicly served version.json, e.g.
#
#   jq -n --arg c "$(git rev-parse HEAD)" '{commit: $c}' \
#     > "$WEBROOT/version.json"
#
# The check compares that stamp to origin/<branch> HEAD once HEAD is
# older than the grace window (auto-deployer poll interval + test-suite
# runtime). Catches both a silently-skipped deploy (e.g. deployer
# refuses on dirty tree) and a red test suite stalling the pipeline
# past the grace window.
#
# Exit 0 = deployed or within grace. Exit 1 = drift; stdout names both
# SHAs and becomes the incident evidence medic quotes verbatim.
set -euo pipefail

# ---- CONFIG (edit after copying; env vars override) -------------------
VERSION_URL="${DRIFT_VERSION_URL:-https://example.com/version.json}"
BRANCH="${DRIFT_BRANCH:-main}"
GRACE_SEC="${DRIFT_GRACE_SEC:-600}"   # deployer poll + test runtime
# -----------------------------------------------------------------------

git fetch -q origin "$BRANCH"

HEAD_SHA="$(git rev-parse "origin/$BRANCH")"
HEAD_EPOCH="$(git log -1 --format=%ct "origin/$BRANCH")"

AGE=$(( $(date +%s) - HEAD_EPOCH ))
[ "$AGE" -lt "$GRACE_SEC" ] && { echo "within deploy grace window (${AGE}s)"; exit 0; }

DEPLOYED="$(curl -fsS --max-time 10 "$VERSION_URL" \
  | jq -r '.commit' 2>/dev/null || echo "")"

if [ "$DEPLOYED" != "$HEAD_SHA" ]; then
  echo "FRONTEND DEPLOY DRIFT: $BRANCH HEAD $HEAD_SHA not deployed (live=$DEPLOYED, HEAD age $((AGE/60))m)"
  exit 1
fi

echo "frontend deployed commit matches $BRANCH HEAD"
