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
  [ "$(events_json | jq -r 'select(.event=="notification.decision") | .class')" = "actionable" ]
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

@test "the judge's git context carries ISO commit dates + co-author trailers (temporal correlation)" {
  # Regression: the overseer once handed the judge a bare `git log --oneline`
  # (no dates, no author attribution). The judge then could not line a result
  # file's timestamp up against the commit that corroborates it, and fired
  # false "out of sync with git" findings (overseer 2026-07-26: caladan
  # chronicler-result flagged as unsupported when a co-authored scribe commit
  # 47s later actually corroborated it). The context must give dates + trailers.
  P="$(make_repo alpha true)"
  # a chronicler result whose ts a real scribe commit will corroborate
  printf '{"pass":true,"mode":"daily","timestamp":"2026-07-23T20:43:42Z","slugs_changed":["alpha"]}\n' \
    >"$P/tmp/alpha-scribe-result.json"
  git -C "$P" init -q
  git -C "$P" config user.email dev@example.com
  git -C "$P" config user.name dev
  git -C "$P" add -A
  TZ=UTC GIT_AUTHOR_DATE="2026-07-23T20:44:29 +0000" \
    GIT_COMMITTER_DATE="2026-07-23T20:44:29 +0000" \
    git -C "$P" commit -q --no-gpg-sign -m "scribe: nightly refresh (1 file(s))

Co-authored-by: alpha-chronicler <noreply@anthropic.com>"
  stub_judge '{"healthy":true,"summary":"ok","findings":[]}'
  run run_overseer --project "$P"
  [ "$status" -eq 0 ]
  # the prompt handed to the judge (claude's last argv) must carry the UTC ISO
  # commit date so a result ts can be correlated to its commit...
  stub_argv claude | grep -q "2026-07-23T20:44:29Z"
  # ...in a git-version-STABLE spelling. `--date=iso-strict-local` is not one:
  # git <=2.43 renders a zero offset as "+00:00" and git >=2.54 renders it as
  # "Z", so this assertion passed locally and failed in CI for days. The runner
  # pins an explicit strftime format instead; keep it that way.
  ! grep -q 'iso-strict-local' "$QUARTET_ROOT/agents/overseer/runner.sh"
  # ...and the Co-authored-by trailer so a scribe/build commit ties to its role.
  stub_argv claude | grep -q "alpha-chronicler"
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
