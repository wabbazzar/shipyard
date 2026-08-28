#!/usr/bin/env bats
# tests/shipyard-status.bats — the /shipyard skill skeleton + `status`.
# status is read-only and keys "installed" off the systemd user *unit files*
# (HOME is redirected to BATS_TEST_TMPDIR in quartet_setup, so this is
# hermetic — no real systemctl, no real units). Exit 3 = nothing installed,
# 0 = installed, 2 = bad invocation.

setup() {
  load helpers
  quartet_setup
}

SH="skills/shipyard/shipyard.sh"

run_shipyard() {
  QUARTET_DIR="$QUARTET_ROOT" bash "$QUARTET_ROOT/$SH" "$@"
}

# mark_installed <project-dir> — drop a fake timer unit for the project so the
# unit-file scan sees an install, without touching real systemd.
mark_installed() {
  local dir="$1" name
  name="$(basename "$dir")"
  mkdir -p "$HOME/.config/systemd/user"
  printf '[Unit]\n' > "$HOME/.config/systemd/user/$name-release.timer"
}

enable_memory() {
  local project="$1"
  printf '\n[memory]\nmode = "advisory"\nledger = ".agents/rules-ledger.jsonl"\n' \
    >>"$project/.agents/config.toml"
  : >"$project/.agents/rules-ledger.jsonl"
}

@test "shipyard is registered in GENERIC_SKILLS" {
  run grep -E 'GENERIC_SKILLS="[^"]*\bshipyard\b' "$QUARTET_ROOT/install.sh"
  [ "$status" -eq 0 ]
}

@test "shipyard SKILL.md exists with roles + kind frontmatter" {
  [ -f "$QUARTET_ROOT/skills/shipyard/SKILL.md" ]
  run grep -E '^roles:' "$QUARTET_ROOT/skills/shipyard/SKILL.md"
  [ "$status" -eq 0 ]
  run grep -E '^kind:' "$QUARTET_ROOT/skills/shipyard/SKILL.md"
  [ "$status" -eq 0 ]
  # Source-line-safe pre-change guard: inspect remains additive to status.
  grep -Fxq '### `status` (default)' "$QUARTET_ROOT/skills/shipyard/SKILL.md"
}

@test "shipyard inspect public contract is bounded and non-certifying" {
  skill="$QUARTET_ROOT/skills/shipyard/SKILL.md"
  readme="$QUARTET_ROOT/README.md"
  editorial="$QUARTET_ROOT/docs/deck-editorial.json"

  grep -Fq '"/shipyard inspect"' "$skill"
  grep -Fq 'Six subcommands:' "$skill"
  grep -Fq 'matching current-user manifests into this Shipyard core' "$skill"
  grep -Fq 'strictly read-only' "$skill"
  grep -Fq 'does not certify fleet health' "$skill"
  grep -Fq 'stable schema-v1 JSON' "$skill"
  grep -Fq 'bounded by evidence and reported limitations' "$skill"

  grep -Fq 'six independently enforced daily consumers' "$readme"
  grep -Fq 'matching current-user manifests into the current Shipyard core' \
    "$readme"
  grep -Fq 'never infers an unknown shoulder root' "$readme"

  jq -e '
    .glossary["/shipyard"].def
    | contains("matching current-user manifests")
      and contains("strictly read-only")
      and contains("does not certify fleet health")
      and contains("stable schema-v1 JSON")
      and contains("evidence and limitations")
  ' "$editorial"
}

@test "status exits 3 on a project with nothing installed" {
  P="$(make_fixture_project bare)"
  run run_shipyard status --project "$P"
  [ "$status" -eq 3 ]
  echo "$output" | grep -qi "no crew installed"
}

@test "status preserves unconfigured output and reports configured memory even without crew units" {
  P="$(make_fixture_project memory-console)"
  run run_shipyard status --project "$P"
  [ "$status" -eq 3 ]
  [[ "$output" != *"memory:"* ]]

  enable_memory "$P"
  run run_shipyard status --project "$P"
  [ "$status" -eq 3 ]
  [[ "$output" == *"memory:"* ]]
  [[ "$output" == *"policy: mode=advisory state=ready"* ]]
  [[ "$output" == *"ledger: records=0 active=0 superseded=0 digest="* ]]
  [[ "$output" == *"index: state=not_applicable"* ]]
  [[ "$output" == *"receipt: state=absent"* ]]
}

@test "unconfigured status never invokes the memory helper" {
  P="$(make_fixture_project memory-console-no-spawn)"
  real_python="$(python3 -c 'import sys; print(sys.executable)')"
  make_stub_script python3 "exec \"$real_python\" \"\$@\""

  run run_shipyard status --project "$P"
  [ "$status" -eq 3 ]
  ! grep -Fq 'agents/lib/rules-memory.py status' "$SHIM_LOG/python3.argv"

  enable_memory "$P"
  run run_shipyard status --project "$P"
  [ "$status" -eq 3 ]
  grep -Fq 'agents/lib/rules-memory.py status' "$SHIM_LOG/python3.argv"
}

@test "installed status surfaces only bounded memory error codes" {
  P="$(make_fixture_project memory-console-invalid)"
  mark_installed "$P"; enable_memory "$P"
  printf '{"summary":"PRIVATE-LEDGER-PROSE"}\n' >"$P/.agents/rules-ledger.jsonl"
  run run_shipyard status --project "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *"memory:"* ]]
  [[ "$output" == *"error: missing_key"* ]]
  [[ "$output" != *"PRIVATE-LEDGER-PROSE"* ]]
}

@test "status exits 0 and lists timers on an installed project" {
  P="$(make_fixture_project wired)"
  mark_installed "$P"
  run run_shipyard status --project "$P"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "wired-release"
  echo "$output" | grep -qi "project blocks"
}

@test "status lists native launchd jobs on macOS installs" {
  P="$(make_fixture_project macwired)"
  export SHIPYARD_SCHEDULER=launchd
  mkdir -p "$HOME/Library/LaunchAgents"
  printf '<plist><dict/></plist>\n' >"$HOME/Library/LaunchAgents/macwired-release.plist"
  run run_shipyard status --project "$P"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "macwired-release"
  echo "$output" | grep -qF "via launchd"
}

@test "status is the default subcommand (no arg)" {
  P="$(make_fixture_project deflt)"
  run run_shipyard --project "$P"
  [ "$status" -eq 3 ]
}

@test "unknown subcommand exits 2" {
  run run_shipyard bogus --project /tmp
  [ "$status" -eq 2 ]
}
