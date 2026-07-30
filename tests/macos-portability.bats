#!/usr/bin/env bats
# Native macOS runtime contracts selected by the launchd installer.

setup() {
  load helpers
  quartet_setup
}

source_checksums() {
  python3 - "$@" <<'PY'
import hashlib
from pathlib import Path
import sys

for raw_path in sys.argv[1:]:
    path = Path(raw_path)
    print(f"{path.name}:{hashlib.sha256(path.read_bytes()).hexdigest()}")
PY
}

@test "launchd interpreter parses every shipped shell entrypoint" {
  local entrypoint
  local entrypoints=(
    install.sh
    agents/lib/*.sh
    agents/*/runner.sh
    agents/release/critic-*.sh
    scripts/*.sh
    .githooks/pre-commit
  )

  for entrypoint in "${entrypoints[@]}"; do
    run /bin/bash -n "$QUARTET_ROOT/$entrypoint"
    if [ "$status" -ne 0 ]; then
      echo "$entrypoint: $output" >&3
      return 1
    fi
  done

  run env QUARTET_DIR="$QUARTET_ROOT" \
    /bin/bash "$QUARTET_ROOT/agents/design/runner.sh" --self-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"self-test OK:"* ]]
  [[ "$output" == *"stale incident excluded"* ]]
}

@test "design collector reads exactly seven UTC days without mutating sources" {
  local offset day event_file
  P="$(make_fixture_project mentutc names-spacetime.toml)"
  mkdir -p "$P/tmp"

  for offset in 0 1 2 3 4 5 6 7; do
    day="$(python3 - "$offset" <<'PY'
from datetime import datetime, timedelta, timezone
import sys
print(datetime.now(timezone.utc).date() - timedelta(days=int(sys.argv[1])))
PY
)"
    event_file="$EVENTS_DIR/$day.jsonl"
    printf '{"ts":"%sT01:00:00Z","svc":"mentutc-release","event":"job.end","status":"fail"}\n' \
      "$day" >"$event_file"
  done

  printf '%s\n' '{"incident_id":"fresh","reason":"new"}' >"$P/tmp/medic-incident-fresh.json"
  printf '%s\n' '{"incident_id":"stale","reason":"old"}' >"$P/tmp/medic-incident-stale.json"
  python3 - "$P/tmp/medic-incident-stale.json" <<'PY'
from datetime import datetime, timedelta, timezone
import os
import sys
timestamp = (datetime.now(timezone.utc) - timedelta(days=40)).timestamp()
os.utime(sys.argv[1], (timestamp, timestamp))
PY

  SOURCES_BEFORE="$(source_checksums "$EVENTS_DIR"/*.jsonl "$P"/tmp/*incident*.json)"
  run env QUARTET_DIR="$QUARTET_ROOT" QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    /bin/bash "$QUARTET_ROOT/agents/design/collectors.sh" \
      --project "$P" --days 7 --json
  [ "$status" -eq 0 ]
  SOURCES_AFTER="$(source_checksums "$EVENTS_DIR"/*.jsonl "$P"/tmp/*incident*.json)"
  [ "$SOURCES_AFTER" = "$SOURCES_BEFORE" ]
  [ "$(echo "$output" | jq -r '.sources.events.job_fail')" = "7" ]
  [ "$(echo "$output" | jq -r '.sources.medic_incidents.count')" = "1" ]
  [ "$(echo "$output" | jq -r '.sources.medic_incidents.examples[0].file')" = \
    "medic-incident-fresh.json" ]
}
