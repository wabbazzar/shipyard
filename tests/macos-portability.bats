#!/usr/bin/env bats
# Native macOS runtime contracts selected by the launchd installer.

setup() {
  load helpers
  quartet_setup
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
  [ "$status" -ne 2 ]
  [[ "$output" == *"self-test OK:"* || "$output" == *"self-test FAIL:"* ]]
}
