#!/usr/bin/env bats
#
# overseer.bats — the fleet dogfood overseer (agents/overseer/runner.sh).
#
# For each autonomous repo (config `autonomous = true`) the overseer hands the
# crew's outputs to an LLM judge and NOTIFIES the owner only when the verdict is
# unhealthy; a healthy verdict is silent (an overseer.assessed status=ok event
# only). The harness (claude) is a PATH stub whose verdict is driven per test —
# no network, no model.

setup() {
  load helpers
  quartet_setup
  ROOT="$BATS_TEST_TMPDIR/code"   # a fake CODE_ROOT
  mkdir -p "$ROOT"
}

# make_repo <name> <autonomous:true|false> — a fixture project with one crew
# result file + a feedback signal. Echoes the absolute dir.
make_repo() {
  local name="$1" auto="$2" d="$ROOT/$1"
  mkdir -p "$d/.agents" "$d/tmp" "$d/data"
  {
    printf 'project_name = "%s"\n' "$name"
    [ "$auto" = "true" ] && printf 'autonomous = true\n'
    printf '[design]\nnorth_star = "a well-tested thing"\n'
  } >"$d/.agents/config.toml"
  printf '{"ts":"2026-07-24T00:00:00Z","project":"%s","proposals":[{"id":"mentat:%s:aa","title":"x","status":"open"}]}\n' \
    "$name" "$name" >"$d/tmp/$name-mentat-result.json"
  printf '{"ts":"2026-07-24T00:00:00Z","id":"fyi_1","text":"please add X"}\n' >"$d/data/fyi-requests.jsonl"
  printf '%s\n' "$d"
}

# stub_judge <verdict-json> — claude --json stub whose .result IS the verdict
# the model "returns" (spawn.sh normalizes .result into SPAWN_TEXT).
stub_judge() {
  local env
  env="$(jq -cn --arg v "$1" '{result:$v, usage:{input_tokens:5, output_tokens:5}}')"
  make_stub claude 0 "$env"
}

run_overseer() {
  CODE_ROOT="$ROOT" OVERSEER_WALL_CLOCK=5 \
  QUARTET_DIR="$QUARTET_ROOT" QUARTET_EVENTS_DIR="$EVENTS_DIR" QUARTET_NOTIFY_CMD="$NOTIFY_CMD" \
    bash "$QUARTET_ROOT/agents/overseer/runner.sh" "$@"
}

assessed_status() { events_json | jq -r 'select(.event=="overseer.assessed") | .status' | tail -1; }
n_assessed() { events_json | jq -c 'select(.event=="overseer.assessed")' | wc -l | tr -d ' '; }

@test "--check-config lists only autonomous repos" {
  make_repo alpha true >/dev/null; make_repo beta false >/dev/null; make_repo gamma true >/dev/null
  run run_overseer --check-config
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "/alpha$"
  echo "$output" | grep -q "/gamma$"
  ! echo "$output" | grep -q "/beta$"
}

@test "healthy crew: overseer.assessed status=ok and NO notification" {
  P="$(make_repo alpha true)"
  stub_judge '{"healthy":true,"summary":"all good","findings":[]}'
  run run_overseer --project "$P"
  [ "$status" -eq 0 ]
  [ "$(assessed_status)" = "ok" ]
  [ ! -s "$NOTIFY_LOG" ]                                   # silent when healthy
  [ "$(jq -r '.healthy' "$P/tmp/overseer-result.json")" = "true" ]
}

@test "unhealthy crew: status=problem and the owner IS notified" {
  P="$(make_repo alpha true)"
  stub_judge '{"healthy":false,"summary":"false green in proctor","findings":[{"role":"release","severity":"high","issue":"pass:true but pytest failed"}]}'
  run run_overseer --project "$P"
  [ "$status" -eq 1 ]
  [ "$(assessed_status)" = "problem" ]
  [ -s "$NOTIFY_LOG" ]
  grep -q "needs a look" "$NOTIFY_LOG"
  grep -q "false green" "$NOTIFY_LOG"
}

@test "--project on a NON-autonomous repo is a no-op (exit 3, no assessment)" {
  P="$(make_repo beta false)"
  stub_judge '{"healthy":true,"summary":"x","findings":[]}'
  run run_overseer --project "$P"
  [ "$status" -eq 3 ]
  [ ! -f "$P/tmp/overseer-result.json" ]
  [ -z "$(events_json | jq -c 'select(.event=="overseer.assessed")')" ]
}

@test "fleet sweep assesses every autonomous repo and skips the rest" {
  make_repo alpha true >/dev/null; make_repo beta false >/dev/null; make_repo gamma true >/dev/null
  stub_judge '{"healthy":true,"summary":"ok","findings":[]}'
  run run_overseer
  [ "$status" -eq 0 ]
  [ "$(n_assessed)" -eq 2 ]
  [ -f "$ROOT/alpha/tmp/overseer-result.json" ]
  [ -f "$ROOT/gamma/tmp/overseer-result.json" ]
  [ ! -f "$ROOT/beta/tmp/overseer-result.json" ]
}

@test "judge returns no usable verdict → status=error and the owner is notified" {
  P="$(make_repo alpha true)"
  stub_judge 'not json at all'
  run run_overseer --project "$P"
  [ "$status" -eq 1 ]
  [ "$(assessed_status)" = "error" ]
  [ -s "$NOTIFY_LOG" ]
}

@test "a healthy fleet stays silent (no notification for any repo)" {
  make_repo alpha true >/dev/null; make_repo gamma true >/dev/null
  stub_judge '{"healthy":true,"summary":"ok","findings":[]}'
  run run_overseer
  [ "$status" -eq 0 ]
  [ ! -s "$NOTIFY_LOG" ]
}
