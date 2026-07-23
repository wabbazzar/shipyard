#!/usr/bin/env bash
# EXAMPLE medic drift check — copy into your project (e.g.
# scripts/medic-checks/), edit the CONFIG block, then register it:
#
#   [[medic.checks]]
#   name        = "server-restart-drift"
#   cmd         = "scripts/medic-checks/server-restart-drift.sh"
#   timeout_sec = 30
#
# Detects the "merged but never restarted" gap on projects whose server
# deploys are manual: the long-running service must have been
# (re)started AFTER the newest commit touching server paths. A merged
# server commit without a restart means production runs old code.
#
# Exit 0 = up to date. Exit 1 = drift; stdout names the SHA + age and
# becomes the incident evidence medic quotes verbatim in the
# notification. Must run on the host where the unit lives (the medic
# host).
#
# Classification cue for your .agents/medic.md: this drift is
# operational (a missed restart), NEVER `regression` — build cannot fix
# it. Map it to `restart` only if the unit is safe to bounce
# unattended; otherwise `infra` (notify hard, freeze 24h).
set -euo pipefail

# ---- CONFIG (edit after copying; env vars override) -------------------
UNIT="${DRIFT_UNIT:-myservice}"          # systemd unit running the server
BRANCH="${DRIFT_BRANCH:-main}"           # deploy branch
SYSTEMCTL="${DRIFT_SYSTEMCTL:-systemctl}"  # "systemctl --user" for user units
# Paths whose commits require a restart (space-separated):
read -r -a SERVER_PATHS <<<"${DRIFT_SERVER_PATHS:-src/server server.js}"
# -----------------------------------------------------------------------

git fetch -q origin "$BRANCH"

PROC_START="$($SYSTEMCTL show "$UNIT" -p ActiveEnterTimestamp --value)"
PROC_EPOCH="$(date -d "$PROC_START" +%s 2>/dev/null || echo 0)"

COMMIT_EPOCH="$(git log -1 --format=%ct "origin/$BRANCH" -- "${SERVER_PATHS[@]}")"
SHA="$(git log -1 --format=%h "origin/$BRANCH" -- "${SERVER_PATHS[@]}")"

if [ "${COMMIT_EPOCH:-0}" -gt "$PROC_EPOCH" ]; then
  AGE_H=$(( (COMMIT_EPOCH - PROC_EPOCH) / 3600 ))
  echo "SERVER RESTART PENDING: server code at $SHA is ${AGE_H}h newer than running $UNIT process"
  exit 1
fi

echo "server up-to-date (process started after newest server-path commit)"
