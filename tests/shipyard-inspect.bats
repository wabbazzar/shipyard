#!/usr/bin/env bats
# shipyard-inspect.bats — hermetic contract for the read-only fleet inspector.

setup() {
  load helpers
  quartet_setup
  UNIT_DIR="$HOME/.config/systemd/user"
  mkdir -p "$UNIT_DIR"
}

run_inspect() {
  SHIPYARD_INSPECT_NOW=2026-07-29T12:00:00Z \
    QUARTET_DIR="$QUARTET_ROOT" \
    bash "$QUARTET_ROOT/skills/shipyard/shipyard.sh" inspect --json "$@"
}

run_shipyard() {
  QUARTET_DIR="$QUARTET_ROOT" \
    bash "$QUARTET_ROOT/skills/shipyard/shipyard.sh" "$@"
}

write_service() {
  local stem="$1" role="$2" project="$3" core="${4:-$QUARTET_ROOT}"
  cat >"$UNIT_DIR/$stem.service" <<EOF
[Unit]
Description=synthetic fixture
[Service]
Type=oneshot
WorkingDirectory=$project
ExecStart=/bin/bash $core/agents/$role/runner.sh --project $project --mode fixture
EOF
}

@test "inspect: discovers only matching current-root manifests and emits schema v1" {
  alpha="$BATS_TEST_TMPDIR/projects/alpha"
  beta="$BATS_TEST_TMPDIR/projects/beta"
  mkdir -p "$alpha" "$beta"
  write_service alpha-helldiver build "$alpha"
  write_service alpha-proctor release "$alpha"
  write_service beta-chronicler scribe "$beta"

  run run_inspect --days 7

  [ "$status" -eq 0 ]
  jq -e '
    .schema_version == 1
    and .meta.inspection_started_at == "2026-07-29T12:00:00Z"
    and .meta.window_start_at == "2026-07-22T12:00:00Z"
    and .meta.window_end_at == .meta.inspection_started_at
    and .meta.window_days == 7
    and .meta.project_count == 2
    and .meta.role_count == 3
    and (.fleet | length) == 2
    and ([.fleet[].roles[]] | sort) == ["build", "release", "scribe"]
  ' <<<"$output"

  calculated_id="$(jq -c '.evidence[0]' <<<"$output" | python3 -c '
import hashlib, json, sys
e = json.load(sys.stdin)
operand = json.dumps(e["fields"], sort_keys=True, separators=(",", ":"),
                     ensure_ascii=False, allow_nan=False)
print(hashlib.sha256(("manifest\0" + e["source_ref"] + "\0" + operand)
      .encode("utf-8")).hexdigest()[:20])
')"
  [ "$calculated_id" = "$(jq -r '.evidence[0].id' <<<"$output")" ]

  run env SHIPYARD_INSPECT_NOW=2026-07-29T12:00:00Z \
    QUARTET_DIR="$QUARTET_ROOT" \
    bash "$QUARTET_ROOT/skills/shipyard/shipyard.sh" inspect --days 7
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet: 2 project(s), 3 role(s)"* ]]
}

@test "inspect: dedupes canonical projects and roles" {
  project="$BATS_TEST_TMPDIR/projects/alpha"
  mkdir -p "$project"
  write_service alpha-proctor release "$project"
  write_service alpha-release release "$project"
  write_service alpha-helldiver build "$project"

  run run_inspect

  [ "$status" -eq 0 ]
  jq -e '
    .meta.project_count == 1
    and .meta.role_count == 2
    and .fleet[0].roles == ["build", "release"]
    and (.fleet[0].units | length) == 2
    and ([.coverage[] | select(.source == "manifest")][0].records_total == 3)
    and ([.evidence[] | select(.kind == "manifest_identity")] | length) == 3
  ' <<<"$output"
}

@test "inspect: excludes unrelated CODE_ROOT and other-root units" {
  project="$BATS_TEST_TMPDIR/projects/eligible"
  uninstalled="$BATS_TEST_TMPDIR/code/uninstalled"
  other_project="$BATS_TEST_TMPDIR/projects/other-core"
  other_core="$BATS_TEST_TMPDIR/other-core"
  mkdir -p "$project" "$uninstalled" "$other_project" \
    "$other_core/agents/release"
  printf '#!/usr/bin/env bash\n' >"$other_core/agents/release/runner.sh"
  write_service eligible-release release "$project"
  write_service other-release release "$other_project" "$other_core"
  cat >"$UNIT_DIR/unrelated.service" <<'EOF'
[Service]
WorkingDirectory=/
ExecStart=/bin/true
EOF

  run run_inspect

  [ "$status" -eq 0 ]
  jq -e --arg project "$(readlink -f "$project")" '
    .meta.project_count == 1
    and .meta.role_count == 1
    and .fleet[0].project_path == $project
    and (.fleet | all(.project_name != "uninstalled"))
    and (.fleet | all(.project_name != "other-core"))
  ' <<<"$output"
}

@test "inspect: excludes WorkingDirectory and project argument mismatch" {
  eligible="$BATS_TEST_TMPDIR/projects/eligible"
  wrong="$BATS_TEST_TMPDIR/projects/wrong"
  mkdir -p "$eligible" "$wrong"
  write_service eligible-release release "$eligible"
  cat >"$UNIT_DIR/missing-working-directory.service" <<EOF
[Service]
ExecStart=/bin/bash $QUARTET_ROOT/agents/release/runner.sh --project $eligible --mode fixture
EOF
  cat >"$UNIT_DIR/mismatched-project.service" <<EOF
[Service]
WorkingDirectory=$eligible
ExecStart=/bin/bash $QUARTET_ROOT/agents/release/runner.sh --project $wrong --mode fixture
EOF

  run run_inspect

  [ "$status" -eq 0 ]
  jq -e '
    .meta.project_count == 1
    and .meta.role_count == 1
    and .fleet[0].project_name == "eligible"
  ' <<<"$output"
}

@test "inspect: documents indistinguishable matching spoof" {
  project="$BATS_TEST_TMPDIR/projects/alpha"
  mkdir -p "$project"
  write_service alpha-release release "$project"
  write_service alpha-release-copy release "$project"

  run run_inspect

  [ "$status" -eq 0 ]
  jq -e '
    .meta.role_count == 1
    and ([.coverage[] | select(.source == "manifest")][0].records_total == 2)
    and (.meta.discovery_limitations
      | index("byte_matching_service_spoof_indistinguishable") != null)
  ' <<<"$output"
}

@test "inspect: no fleet exits 3 and emits no JSON" {
  run run_inspect

  [ "$status" -eq 3 ]
  [[ "$output" != *'"schema_version"'* ]]
  [[ "$output" == *"no eligible Shipyard installation"* ]]
}

@test "inspect: malformed flags clock and days exit 2" {
  run run_inspect --days 0
  [ "$status" -eq 2 ]
  [[ "$output" == *"--days must be a positive integer"* ]]

  run run_inspect --days nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"--days must be a positive integer"* ]]

  run env SHIPYARD_INSPECT_NOW=not-a-clock QUARTET_DIR="$QUARTET_ROOT" \
    bash "$QUARTET_ROOT/skills/shipyard/shipyard.sh" inspect --json
  [ "$status" -eq 2 ]
  [[ "$output" == *"timezone-aware RFC3339"* ]]

  run env SHIPYARD_INSPECT_NOW='2026-07-29 12:00:00+00:00' \
    QUARTET_DIR="$QUARTET_ROOT" \
    bash "$QUARTET_ROOT/skills/shipyard/shipyard.sh" inspect --json
  [ "$status" -eq 2 ]
  [[ "$output" == *"timezone-aware RFC3339"* ]]

  run run_inspect --days 999999999
  [ "$status" -eq 2 ]

  run run_shipyard inspect --days
  [ "$status" -eq 2 ]
  [[ "$output" == *"--days requires a value"* ]]

  run run_shipyard inspect --unknown
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag"* ]]

  run run_shipyard inspect --project "$PWD"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--project is not valid"* ]]

  run run_shipyard inspect unexpected
  [ "$status" -eq 2 ]
  [[ "$output" == *"unexpected positional argument"* ]]

  run run_shipyard status --days 7
  [ "$status" -eq 2 ]
  [[ "$output" == *"--json/--days apply only to inspect"* ]]
}

@test "inspect: default status output is unchanged" {
  project="$(make_fixture_project default-status)"

  run run_shipyard --project "$project"
  default_status="$status"
  default_output="$output"
  run run_shipyard status --project "$project"

  [ "$default_status" -eq 3 ]
  [ "$status" -eq 3 ]
  [ "$default_output" = "$output" ]
  [[ "$output" == *"no crew installed"* ]]
}

@test "inspect: schema v1 golden covers every enum and nullable branch" {
  golden="$FIXTURES_DIR/shipyard-inspect/full-schema-v1.json"

  run python3 -m json.tool "$golden"

  [ "$status" -eq 0 ]
  jq -e '
    (keys == [
      "attention", "coverage", "effectiveness", "evidence", "fleet",
      "meta", "priorities", "schema_version", "summary"
    ])
    and .schema_version == 1
    and (.meta.inspection_started_at | type == "string")
    and .meta.schema_catalog.coverage_state
      == ["available", "partial", "unavailable", "error", "not_applicable"]
    and .meta.schema_catalog.claim_kind == ["fact", "derived", "assessment"]
    and .meta.schema_catalog.fleet_state
      == ["fault_observed", "degraded_observed", "no_fault_observed", "unknown"]
    and .meta.schema_catalog.attention_kind
      == ["open_proposal", "observed_fault", "install_drift", "owner_decision", "coverage_gap"]
    and .meta.schema_catalog.effectiveness_state
      == ["measured", "partial", "unmeasured"]
    and .meta.schema_catalog.priority_category
      == ["confirmed_failure", "human_gate", "recurring_failure",
          "evidenced_opportunity", "instrumentation_gap", "hygiene"]
    and (.meta.schema_catalog.nullable_fields | length) == 46
    and ([paths(type == "null")] | length) > 0
  ' "$golden"

  run python3 -c '
import hashlib, json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
e = d["evidence"][0]
def identity(fields):
    operand = json.dumps(fields, sort_keys=True, separators=(",", ":"),
                         ensure_ascii=False, allow_nan=False)
    return hashlib.sha256(("manifest\0" + e["source_ref"] + "\0" + operand)
                          .encode("utf-8")).hexdigest()[:20]
ordered = dict(reversed(list(e["fields"].items())))
dropped = dict(e["fields"])
dropped.pop("event_root_env")
print(e["id"], identity(e["fields"]), identity(ordered), identity(dropped))
' "$golden"
  [ "$status" -eq 0 ]
  read -r golden_id calculated_id reordered_id dropped_id <<<"$output"
  [ "$golden_id" = "$calculated_id" ]
  [ "$golden_id" = "$reordered_id" ]
  [ "$golden_id" != "$dropped_id" ]

  project="$BATS_TEST_TMPDIR/projects/schema"
  mkdir -p "$project"
  write_service schema-release release "$project"
  run run_inspect
  [ "$status" -eq 0 ]
  jq -e --slurpfile golden "$golden" '
    . as $actual | $golden[0] as $expected
    | ($actual | keys) == ($expected | keys)
    and ($actual.meta | keys) == ($expected.meta | del(.schema_catalog) | keys)
    and ($actual.coverage[0] | keys) == ($expected.coverage[0] | keys)
    and ($actual.evidence[0] | keys) == ($expected.evidence[0] | keys)
    and ($actual.evidence[0].fields | keys) == ($expected.evidence[0].fields | keys)
    and ($actual.fleet[0] | keys) == ($expected.fleet[0] | keys)
    and ($actual.fleet[0].units[0] | keys) == ($expected.fleet[0].units[0] | keys)
    and ($actual.fleet[0].doctor | keys) == ($expected.fleet[0].doctor | keys)
    and ($actual.fleet[0].jobs | keys) == ($expected.fleet[0].jobs | keys)
    and ($actual.fleet[0].critiques | keys) == ($expected.fleet[0].critiques | keys)
    and ($actual.fleet[0].pressure | keys) == ($expected.fleet[0].pressure | keys)
    and ($actual.fleet[0].pressure.daily_budget_consumers[0] | keys)
      == ($expected.fleet[0].pressure.daily_budget_consumers[0] | keys)
    and ($actual.fleet[0].safety | keys) == ($expected.fleet[0].safety | keys)
    and ($actual.fleet[0].overseer | keys) == ($expected.fleet[0].overseer | keys)
    and ($actual.summary | keys) == ($expected.summary | keys)
  ' <<<"$output"
}
