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

@test "fixture mutation helpers replace text and set an exact relative mtime" {
  local fixture="$BATS_TEST_TMPDIR/portable-fixture"
  printf 'alpha\nbeta\n' >"$fixture"

  fixture_replace_in_place "$fixture" '^beta$' 'gamma'
  [ "$(cat "$fixture")" = $'alpha\ngamma' ]

  local before after age
  before="$(date +%s)"
  fixture_set_mtime_ago 120 "$fixture"
  after="$(date +%s)"
  age="$(python3 - "$fixture" "$before" "$after" <<'PY'
from pathlib import Path
import sys

mtime = int(Path(sys.argv[1]).stat().st_mtime)
before, after = map(int, sys.argv[2:])
print(before - 121 <= mtime <= after - 119)
PY
)"
  [ "$age" = "True" ]
}

@test "test fixtures contain no non-portable in-place edits or relative touch dates" {
  run python3 - "$QUARTET_ROOT/tests" <<'PY'
from pathlib import Path
import re
import sys

tests = Path(sys.argv[1])
bare_in_place = re.compile(r"(^|[;&|\s])" + r"sed\s+" + r"-i(?:\s|$)")
relative_mtime = re.compile(
    r"touch\s+" + r"-d\s+[\"']\d+\s+(?:minute|day)s?\s+ago"
)
violations = []
for path in sorted(tests.glob("*.bats")):
    text = path.read_text()
    for line_number, line in enumerate(text.splitlines(), 1):
        if bare_in_place.search(line) or relative_mtime.search(line):
            violations.append(f"{path.relative_to(tests.parent)}:{line_number}:{line}")
if violations:
    print("\n".join(violations))
    raise SystemExit(1)
PY
  [ "$status" -eq 0 ]
}

@test "launchd runtime scripts avoid Bash 4 case transforms and GNU date arithmetic" {
  run python3 - "$QUARTET_ROOT" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
paths = [root / "install.sh", root / ".githooks/pre-commit"]
paths.extend((root / "agents/lib").glob("*.sh"))
paths.extend((root / "agents").glob("*/runner.sh"))
paths.extend((root / "agents/release").glob("critic-*.sh"))
paths.extend((root / "scripts").glob("*.sh"))

bash4_case = re.compile(r"\$\{[^}\n]+\^(?:\^)?\}")
gnu_relative_date = re.compile(r"\bdate\b[^\n]*\s-d\s")
violations = []
for path in sorted(paths):
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        if bash4_case.search(line) or gnu_relative_date.search(line):
            violations.append(f"{path.relative_to(root)}:{line_number}:{line}")
if violations:
    print("\n".join(violations))
    raise SystemExit(1)
PY
  [ "$status" -eq 0 ]
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
