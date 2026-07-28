#!/usr/bin/env bats

setup() {
  CHECKER="$BATS_TEST_DIRNAME/../scripts/gen-deck-data.py"
  ROOT="$BATS_TEST_TMPDIR/deck-root"
  mkdir -p "$ROOT/skills" "$ROOT/docs"
}

write_skill() {
  local skill="$1" roles="$2"
  mkdir -p "$ROOT/skills/$skill"
  cat >"$ROOT/skills/$skill/SKILL.md" <<EOF
---
name: $skill
roles: [$roles]
disposition: adapted
kind: shared
---
EOF
}

write_install() {
  printf 'GENERIC_SKILLS="%s"\n' "$1" >"$ROOT/install.sh"
}

write_editorial() {
  cat >"$ROOT/docs/deck-editorial.json"
}

run_checker() {
  run python3 "$CHECKER" --check --root "$ROOT"
}

@test "--check fails for a skill directory missing from GENERIC_SKILLS" {
  write_skill alpha design
  write_skill rogue design
  write_install "alpha"
  write_editorial <<'JSON'
{"crew":[{"id":"design","skills":[{"_file":"alpha"}]}],
 "graph":{"skills":[{"_file":"alpha"}]}}
JSON

  run_checker
  [ "$status" -eq 1 ]
  [[ "$output" == *"rogue: missing from GENERIC_SKILLS"* ]]
}

@test "--check fails when a member crew lacks an authored card" {
  write_skill alpha "design, build"
  write_install "alpha"
  write_editorial <<'JSON'
{"crew":[{"id":"design","skills":[{"_file":"alpha"}]},
         {"id":"build","skills":[]}],
 "graph":{"skills":[{"_file":"alpha"}]}}
JSON

  run_checker
  [ "$status" -eq 1 ]
  [[ "$output" == *"alpha: missing authored crew card for build"* ]]
}

@test "--check fails when a generic skill lacks a graph _file mapping" {
  write_skill alpha design
  write_install "alpha"
  write_editorial <<'JSON'
{"crew":[{"id":"design","skills":[{"_file":"alpha"}]}],
 "graph":{"skills":[]}}
JSON

  run_checker
  [ "$status" -eq 1 ]
  [[ "$output" == *"alpha: missing graph.skills _file mapping"* ]]
}

@test "install is the sole deck-exempt skill directory" {
  write_skill alpha design
  write_skill install human
  write_install "alpha"
  write_editorial <<'JSON'
{"crew":[{"id":"design","skills":[{"_file":"alpha"}]}],
 "graph":{"skills":[{"_file":"alpha"}]}}
JSON

  run_checker
  [ "$status" -eq 0 ]
  [[ "$output" == *"deck-complete: 1 installed skills complete"* ]]
}

@test "--check passes a complete fixture" {
  write_skill alpha design
  write_install "alpha"
  write_editorial <<'JSON'
{"crew":[{"id":"design","skills":[{"_file":"alpha"}]}],
 "graph":{"skills":[{"_file":"alpha"}]}}
JSON

  run_checker
  [ "$status" -eq 0 ]
  [[ "$output" == *"deck-complete: 1 installed skills complete"* ]]
}

@test "--check writes nothing" {
  write_skill alpha design
  write_install "alpha"
  write_editorial <<'JSON'
{"crew":[{"id":"design","skills":[{"_file":"alpha"}]}],
 "graph":{"skills":[{"_file":"alpha"}]}}
JSON
  printf 'sentinel\n' >"$ROOT/docs/shipyard-data.json"
  before="$(sha256sum "$ROOT/docs/shipyard-data.json")"

  run_checker
  [ "$status" -eq 0 ]
  after="$(sha256sum "$ROOT/docs/shipyard-data.json")"
  [ "$after" = "$before" ]
  [ "$(cat "$ROOT/docs/shipyard-data.json")" = "sentinel" ]
}

@test "multiple gaps are reported in deterministic skill order" {
  write_skill alpha design
  write_skill zeta design
  write_install "alpha"
  write_editorial <<'JSON'
{"crew":[{"id":"design","skills":[{"_file":"alpha"}]}],
 "graph":{"skills":[]}}
JSON

  run_checker
  [ "$status" -eq 1 ]
  first="$(printf '%s\n' "$output" | grep -n 'alpha:' | cut -d: -f1)"
  second="$(printf '%s\n' "$output" | grep -n 'zeta:' | cut -d: -f1)"
  [ "$first" -lt "$second" ]
}

@test "thin wrapper runs the real repository check" {
  run bash "$BATS_TEST_DIRNAME/../scripts/check-deck-complete.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"deck-complete: 8 installed skills complete"* ]]
}

@test "real pre-commit hook blocks a fixture commit with an incomplete deck" {
  write_skill alpha design
  write_skill rogue design
  write_install "alpha"
  write_editorial <<'JSON'
{"crew":[{"id":"design","skills":[{"_file":"alpha"}]}],
 "graph":{"skills":[{"_file":"alpha"}]}}
JSON

  mkdir -p "$ROOT/.githooks" "$ROOT/scripts"
  cp "$BATS_TEST_DIRNAME/../.githooks/pre-commit" "$ROOT/.githooks/pre-commit"
  cp "$BATS_TEST_DIRNAME/../scripts/check-deck-complete.sh" "$ROOT/scripts/"
  cp "$BATS_TEST_DIRNAME/../scripts/gen-deck-data.py" "$ROOT/scripts/"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$ROOT/scripts/leak-check.sh"
  chmod +x "$ROOT/.githooks/pre-commit" "$ROOT/scripts/"*.sh
  cmp "$BATS_TEST_DIRNAME/../.githooks/pre-commit" "$ROOT/.githooks/pre-commit"

  git -C "$ROOT" init -q
  git -C "$ROOT" config user.name "Deck Gate Test"
  git -C "$ROOT" config user.email "deck-gate@example.invalid"
  git -C "$ROOT" config core.hooksPath .githooks
  git -C "$ROOT" add .

  run git -C "$ROOT" commit -m "test incomplete deck"
  printf '%s\n' "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"deck-complete: GAP rogue: missing from GENERIC_SKILLS"* ]]
  ! git -C "$ROOT" rev-parse --verify HEAD >/dev/null 2>&1
}
