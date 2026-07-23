#!/usr/bin/env bats
#
# harness-install.bats — install.sh bakes the per-role harness/model/provider
# knobs into the generated unit env (config -> Environment=), and bakes NOTHING
# when the config is silent (unset == today's claude/sonnet default, so the
# fleet's behavior is byte-identical). No secret is ever baked.

setup() {
  load helpers
  quartet_setup
  make_stub systemctl 0
  make_stub crontab 0 ""
  make_stub gh 0
  make_stub claude 0
}

_install() {
  QUARTET_DIR="$QUARTET_ROOT" \
  QUARTET_EVENTS_DIR="$EVENTS_DIR" \
  QUARTET_NOTIFY_CMD="$NOTIFY_CMD" \
    bash "$QUARTET_ROOT/install.sh" --project "$1" "${@:2}"
}

@test "install: per-role override + global-default fallback baked into unit env" {
  p="$(make_fixture_project harnesscfg harness-config.toml)"
  _install "$p" --agents build,design >/dev/null

  svc="$HOME/.config/systemd/user/harnesscfg-build.service"
  [ -f "$svc" ]
  grep -Fxq 'Environment=BUILD_HARNESS=codex'      "$svc"
  grep -Fxq 'Environment=BUILD_MODEL=gpt-5.4'      "$svc"
  grep -Fxq 'Environment=BUILD_PROVIDER=openrouter' "$svc"

  # design has no [design] table -> inherits [harness].default/model; no provider
  # set anywhere -> DESIGN_PROVIDER not baked.
  dsvc="$HOME/.config/systemd/user/harnesscfg-design.service"
  [ -f "$dsvc" ]
  grep -Fxq 'Environment=DESIGN_HARNESS=claude' "$dsvc"
  grep -Fxq 'Environment=DESIGN_MODEL=sonnet'   "$dsvc"
  run grep -q 'DESIGN_PROVIDER' "$dsvc"
  [ "$status" -ne 0 ]
}

@test "install: no [harness] config bakes NO harness env (unset == today)" {
  p="$(make_fixture_project harnessnone can-merge-true.toml)"
  _install "$p" --agents build,release,medic,scribe >/dev/null
  for svc in "$HOME"/.config/systemd/user/harnessnone-*.service; do
    run grep -qE '_(HARNESS|MODEL|PROVIDER)=' "$svc"
    echo "checked $svc: $output"
    [ "$status" -ne 0 ]
  done
}

# NB: the installer's --dry-run prints "would write: <path>" only, never the
# unit body, so the baked Environment lines are verified by real-install unit
# inspection above (stronger evidence than dry-run text).
