# tests/helpers.bash — shared bats helpers for the guardian-quartet suite.
#
# Load from a .bats file with:
#
#   setup() {
#     load helpers
#     quartet_setup
#   }
#
# What you get:
#   * a PATH shim ($SHIM_BIN, prepended to PATH) where make_stub drops fake
#     executables that record their argv — no network, no GitHub, no LLM;
#   * make_fixture_project — a throwaway project with .agents/{config.toml,
#     guardian,augur,medic,scribe}.md, a tmp/ result dir and a git repo;
#   * make_git_topology — a local bare "origin" plus a clone, with helpers
#     to build BOTH trunk commit shapes (squash merge = one parent, true
#     merge = two parents) so `git revert` semantics can be asserted for real;
#   * run_runner — invoke an agent runner against a fixture with the events
#     dir and notify command captured into the test tmpdir.
#
# Everything lives under $BATS_TEST_TMPDIR, so tests are isolated and bats
# cleans up after itself.

QUARTET_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="$QUARTET_ROOT/tests/fixtures"
export QUARTET_ROOT FIXTURES_DIR

# ---------------------------------------------------------------------------
# quartet_setup — call from setup(). Installs the PATH shim and the captured
# environment (events dir + notify recorder).
# ---------------------------------------------------------------------------
quartet_setup() {
  SHIM_BIN="$BATS_TEST_TMPDIR/bin"
  SHIM_LOG="$BATS_TEST_TMPDIR/shim-log"
  EVENTS_DIR="$BATS_TEST_TMPDIR/events"
  mkdir -p "$SHIM_BIN" "$SHIM_LOG" "$EVENTS_DIR"

  PATH="$SHIM_BIN:$PATH"
  export PATH SHIM_BIN SHIM_LOG EVENTS_DIR

  # Deterministic git identity — fixture repos must commit without touching
  # the developer's global config.
  export GIT_AUTHOR_NAME="quartet-test"
  export GIT_AUTHOR_EMAIL="quartet-test@example.com"
  export GIT_COMMITTER_NAME="quartet-test"
  export GIT_COMMITTER_EMAIL="quartet-test@example.com"
  export GIT_CONFIG_NOSYSTEM=1
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"

  make_notify_stub
}

# ---------------------------------------------------------------------------
# PATH shim
# ---------------------------------------------------------------------------

# make_stub <name> [exit_code] [stdout]
#
# Drops an executable named <name> at the front of PATH. Every invocation
# appends its argv (one line, space-joined) to $SHIM_LOG/<name>.argv, prints
# <stdout> if given, and exits with <exit_code> (default 0).
make_stub() {
  local name="$1" rc="${2:-0}"
  local out_file="$SHIM_LOG/$name.stdout"
  if [ "$#" -ge 3 ]; then printf '%s\n' "$3" >"$out_file"; else : >"$out_file"; fi
  cat >"$SHIM_BIN/$name" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SHIM_LOG/$name.argv"
if [ -s "$out_file" ]; then cat "$out_file"; fi
exit $rc
STUB
  chmod +x "$SHIM_BIN/$name"
}

# make_stub_script <name> <body>
#
# Same recording behaviour, but the caller supplies the body (bash), so a
# stub can branch on its own argv (e.g. a `gh` that answers `pr checks`
# differently from `pr view`). "$@" is available in the body.
make_stub_script() {
  local name="$1" body="$2"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$*" >> "%s/%s.argv"\n' "$SHIM_LOG" "$name"
    printf '%s\n' "$body"
  } >"$SHIM_BIN/$name"
  chmod +x "$SHIM_BIN/$name"
}

# stub_argv <name> — every recorded invocation, one per line ("" if never called).
stub_argv() {
  local f="$SHIM_LOG/$1.argv"
  [ -f "$f" ] && cat "$f" || true
}

# stub_calls <name> — number of recorded invocations.
stub_calls() {
  local f="$SHIM_LOG/$1.argv"
  [ -f "$f" ] && wc -l <"$f" | tr -d ' ' || echo 0
}

# make_notify_stub — a recording QUARTET_NOTIFY_CMD. Each call appends
# "<title>|<body>" to $SHIM_LOG/notify.log.
make_notify_stub() {
  NOTIFY_CMD="$SHIM_BIN/quartet-notify-stub"
  NOTIFY_LOG="$SHIM_LOG/notify.log"
  cat >"$NOTIFY_CMD" <<STUB
#!/usr/bin/env bash
printf '%s|%s\n' "\${1:-}" "\${2:-}" >> "$NOTIFY_LOG"
STUB
  chmod +x "$NOTIFY_CMD"
  export NOTIFY_CMD NOTIFY_LOG
  export QUARTET_NOTIFY_CMD="$NOTIFY_CMD"
}

# notify_log — recorded notifications ("" if none).
notify_log() {
  [ -f "$NOTIFY_LOG" ] && cat "$NOTIFY_LOG" || true
}

# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

# events_file — today's JSONL file in the captured events dir.
events_file() {
  printf '%s/%s.jsonl\n' "$EVENTS_DIR" "$(date -u +%Y-%m-%d)"
}

# events_json — every event emitted during the test, one compact object per
# line (empty if none). Corrupt lines are dropped, matching hub practice.
events_json() {
  local f
  f="$(events_file)"
  [ -f "$f" ] && jq -R 'fromjson?' <"$f" | jq -c '.' || true
}

# ---------------------------------------------------------------------------
# Fixture projects
# ---------------------------------------------------------------------------

_git_init_repo() {
  local dir="$1" trunk="${2:-main}"
  git -C "$dir" init -q -b "$trunk"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "fixture: initial commit"
}

# make_fixture_project <name> [config-fixture] [trunk]
#
# Builds $BATS_TEST_TMPDIR/projects/<name> with .agents/config.toml (from
# tests/fixtures/, with __PROJECT_NAME__ substituted), the four per-agent
# prompt files, a tmp/ result dir, and an initialized git repo. Echoes the
# project dir.
make_fixture_project() {
  local name="$1" cfg="${2:-absent-keys.toml}" trunk="${3:-main}"
  local dir="$BATS_TEST_TMPDIR/projects/$name"
  mkdir -p "$dir/.agents" "$dir/tmp"

  [ -f "$FIXTURES_DIR/$cfg" ] || {
    echo "make_fixture_project: no such fixture: $FIXTURES_DIR/$cfg" >&2
    return 2
  }
  sed "s/__PROJECT_NAME__/$name/g" "$FIXTURES_DIR/$cfg" >"$dir/.agents/config.toml"

  local a
  for a in guardian augur medic scribe; do
    printf '# %s — %s\n\nFixture prompt. No project-specific instructions.\n' \
      "$name" "$a" >"$dir/.agents/$a.md"
  done
  printf 'tmp/\n' >"$dir/.gitignore"
  printf '# %s\n' "$name" >"$dir/README.md"

  _git_init_repo "$dir" "$trunk"
  printf '%s\n' "$dir"
}

# ---------------------------------------------------------------------------
# Git topology: bare origin + clone, both trunk commit shapes
# ---------------------------------------------------------------------------

# make_git_topology <root> [trunk]
#
# Creates <root>/origin.git (bare) and <root>/project (a clone with one base
# commit pushed to trunk). Echoes the project dir.
make_git_topology() {
  local root="$1" trunk="${2:-main}"
  mkdir -p "$root"
  git init -q --bare -b "$trunk" "$root/origin.git"
  git clone -q "$root/origin.git" "$root/project" 2>/dev/null
  local p="$root/project"
  # A clone of an empty repo leaves HEAD unborn on the remote's default
  # branch; make sure it is the trunk we asked for.
  git -C "$p" symbolic-ref HEAD "refs/heads/$trunk"
  printf 'base\n' >"$p/README.md"
  git -C "$p" add -A
  git -C "$p" commit -q -m "base"
  git -C "$p" push -q -u origin "$trunk"
  printf '%s\n' "$p"
}

# _topo_branch <project> <branch> <file> <content> — create a feature branch
# off trunk with one commit adding <file>, then return to trunk.
_topo_branch() {
  local p="$1" br="$2" f="$3" content="$4" trunk
  trunk="$(git -C "$p" rev-parse --abbrev-ref HEAD)"
  git -C "$p" checkout -q -b "$br"
  printf '%s\n' "$content" >"$p/$f"
  git -C "$p" add -A
  git -C "$p" commit -q -m "$br: add $f"
  git -C "$p" checkout -q "$trunk"
}

# topo_squash_merge <project> <branch> <file> [content]
#
# Lands <branch> on trunk as a SQUASH merge — a single-parent commit, the
# shape GitHub's "Squash and merge" produces. `git revert -m 1 <sha>` is
# invalid against it. Echoes the trunk commit sha.
topo_squash_merge() {
  local p="$1" br="$2" f="$3" content="${4:-squashed change}"
  _topo_branch "$p" "$br" "$f" "$content"
  # --squash chatters on stdout ("Squash commit -- not updating HEAD"), which
  # would pollute the sha we echo.
  git -C "$p" merge --squash "$br" >/dev/null 2>&1
  git -C "$p" commit -q -m "$br (#1)

Squash-merged $br."
  git -C "$p" rev-parse HEAD
}

# topo_true_merge <project> <branch> <file> [content]
#
# Lands <branch> on trunk as a TRUE merge commit — two parents, the shape
# `git revert -m 1 <sha>` requires. Echoes the merge commit sha.
topo_true_merge() {
  local p="$1" br="$2" f="$3" content="${4:-merged change}"
  _topo_branch "$p" "$br" "$f" "$content"
  git -C "$p" merge -q --no-ff -m "Merge branch '$br'" "$br"
  git -C "$p" rev-parse HEAD
}

# commit_parent_count <project> <sha>
commit_parent_count() {
  git -C "$1" rev-list --parents -n 1 "$2" | awk '{print NF-1}'
}

# ---------------------------------------------------------------------------
# Runner invocation
# ---------------------------------------------------------------------------

# run_runner <agent> <project-dir> [args...]
#
# Invokes agents/<agent>/runner.sh with --project <project-dir> and the
# captured environment: QUARTET_DIR pinned to this checkout,
# QUARTET_EVENTS_DIR pointed at the per-test events dir, QUARTET_NOTIFY_CMD
# pointed at the recording stub. Wrap with bats `run` to capture status.
run_runner() {
  local agent="$1" project="$2"
  shift 2
  QUARTET_DIR="$QUARTET_ROOT" \
  QUARTET_EVENTS_DIR="$EVENTS_DIR" \
  QUARTET_NOTIFY_CMD="$NOTIFY_CMD" \
  QUARTET_SOURCE="test" \
    bash "$QUARTET_ROOT/agents/$agent/runner.sh" --project "$project" "$@"
}

# load_fixture_config <fixture> — echo a fixture config.toml as JSON via the
# shared loader (the exact path every runner takes).
load_fixture_config() {
  # shellcheck disable=SC1091
  source "$QUARTET_ROOT/agents/lib/load-config.sh"
  load_config_json "$FIXTURES_DIR/$1"
}
