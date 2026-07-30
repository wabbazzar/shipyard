#!/usr/bin/env bats

setup() {
  load helpers
  quartet_setup

  OLD_PRE_PUSH="$QUARTET_ROOT/.githooks/pre-push"
  PRE_COMMIT="$QUARTET_ROOT/.githooks/pre-commit"
  INSTALLER="$QUARTET_ROOT/install.sh"
  CHECKER="$QUARTET_ROOT/scripts/check-git-identity.sh"
  WORKFLOW="$QUARTET_ROOT/.github/workflows/checks.yml"
  CANONICAL_NAME="canonical-owner"
  CANONICAL_EMAIL="canonical-owner@example.invalid"
  BAD_AUTHOR_EMAIL="wrong-author@example.invalid"
  BAD_COMMITTER_EMAIL="wrong-committer@example.invalid"
}

write_policy() {
  local project="$1"
  printf '[git_identity]\nenforce = true\nname = "%s"\n' \
    "$CANONICAL_NAME" >"$project/.shipyard-git-identity.toml"
}

commit_with_identity() {
  local project="$1" message="$2"
  local author_name="$3" author_email="$4"
  local committer_name="$5" committer_email="$6"
  GIT_AUTHOR_NAME="$author_name" \
    GIT_AUTHOR_EMAIL="$author_email" \
    GIT_COMMITTER_NAME="$committer_name" \
    GIT_COMMITTER_EMAIL="$committer_email" \
    git -C "$project" commit -q --no-gpg-sign -m "$message"
}

make_identity_repo() {
  local name="$1" project
  project="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$project"
  git -C "$project" init -q -b main
  write_policy "$project"
  git -C "$project" config --local shipyard.identityEmail "$CANONICAL_EMAIL"
  printf 'root\n' >"$project/root.txt"
  git -C "$project" add .shipyard-git-identity.toml root.txt
  commit_with_identity "$project" root \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL" \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL"
  printf '%s\n' "$project"
}

add_identity_commit() {
  local project="$1" label="$2"
  local author_name="$3" author_email="$4"
  local committer_name="$5" committer_email="$6"
  local count
  count="$(git -C "$project" rev-list --count HEAD)"
  printf '%s\n' "$label" >"$project/$label-$count.txt"
  git -C "$project" add "$label-$count.txt"
  commit_with_identity "$project" "$label" \
    "$author_name" "$author_email" "$committer_name" "$committer_email"
  git -C "$project" rev-parse HEAD
}

install_identity_hooks() {
  local project="$1"
  mkdir -p "$project/.githooks" "$project/scripts"
  cp "$PRE_COMMIT" "$project/.githooks/pre-commit"
  cp "$OLD_PRE_PUSH" "$project/.githooks/pre-push"
  cp "$CHECKER" "$project/scripts/check-git-identity.sh"
  chmod +x "$project/.githooks/pre-commit" \
    "$project/.githooks/pre-push" "$project/scripts/check-git-identity.sh"
}

stub_install_dependencies() {
  make_stub systemctl 0
  make_stub crontab 0 ""
  make_stub gh 0
  make_stub claude 0
}

make_install_identity_fixture() {
  local name="$1" project
  project="$(make_fixture_project "$name" clean-install.toml)"
  printf '[git_identity]\nenforce = true\nname = "fixture-owner"\n' \
    >"$project/.shipyard-git-identity.toml"
  git -C "$project" config --local user.name "fixture-owner"
  git -C "$project" config --local user.email "$CANONICAL_EMAIL"
  stub_install_dependencies
  QUARTET_DIR="$QUARTET_ROOT" \
  QUARTET_EVENTS_DIR="$EVENTS_DIR" \
  QUARTET_NOTIFY_CMD="$NOTIFY_CMD" \
    bash "$INSTALLER" --project "$project" >/dev/null
  printf '%s\n' "$project"
}

configure_identity_fixture() {
  local project="$1"
  env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL \
    -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
    QUARTET_DIR="$QUARTET_ROOT" \
    bash "$INSTALLER" --configure-git-identity --project "$project"
}

run_identity_doctor() {
  local project="$1"
  env QUARTET_DIR="$QUARTET_ROOT" \
    bash "$INSTALLER" --doctor --project "$project"
}

assert_addresses_redacted() {
  [[ "$output" != *"$CANONICAL_EMAIL"* ]]
  [[ "$output" != *"$BAD_AUTHOR_EMAIL"* ]]
  [[ "$output" != *"$BAD_COMMITTER_EMAIL"* ]]
}

@test "git identity: pre-push blocks the wrong author captured by the pre-change repro" {
  local project remote_sha local_sha marker
  project="$(make_identity_repo captured-prepush-defect)"
  remote_sha="$(git -C "$project" rev-parse HEAD)"
  git -C "$project" update-ref refs/remotes/origin/main "$remote_sha"
  local_sha="$(add_identity_commit "$project" bad-author \
    wrong-author "$BAD_AUTHOR_EMAIL" \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL")"
  install_identity_hooks "$project"
  marker="$BATS_TEST_TMPDIR/prechange-deck-marker"
  printf '#!/usr/bin/env bash\nprintf "mirror\\n" >>"$HOOK_MARKER"\n' \
    >"$project/scripts/sync-deck-mirror.sh"
  chmod +x "$project/scripts/sync-deck-mirror.sh"

  run bash -c \
    "printf 'refs/heads/main %s refs/heads/main %s\\n' '$local_sha' '$remote_sha' |
       env HOOK_MARKER='$marker' QUARTET_DIR='$project' \
       bash '$project/.githooks/pre-push' origin local"

  [ "$status" -eq 1 ]
  [[ "$output" == *"$local_sha: author.name mismatch"* ]]
  [ ! -e "$marker" ]
  [ "$remote_sha" != "$local_sha" ]
  [ "$(git -C "$project" show -s --format=%an "$local_sha")" = "wrong-author" ]
  assert_addresses_redacted
}

@test "git identity: current accepts the exact canonical identity" {
  local project
  project="$(make_identity_repo current-good)"

  run env \
    GIT_AUTHOR_NAME="$CANONICAL_NAME" \
    GIT_AUTHOR_EMAIL="$CANONICAL_EMAIL" \
    GIT_COMMITTER_NAME="$CANONICAL_NAME" \
    GIT_COMMITTER_EMAIL="$CANONICAL_EMAIL" \
    bash "$CHECKER" --current --project "$project"

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "git identity: current rejects only a wrong author name" {
  local project
  project="$(make_identity_repo current-author-name)"

  run env \
    GIT_AUTHOR_NAME="wrong-author" \
    GIT_AUTHOR_EMAIL="$CANONICAL_EMAIL" \
    GIT_COMMITTER_NAME="$CANONICAL_NAME" \
    GIT_COMMITTER_EMAIL="$CANONICAL_EMAIL" \
    bash "$CHECKER" --current --project "$project"

  [ "$status" -eq 1 ]
  [[ "$output" == *"pending: author.name mismatch"* ]]
  [[ "$output" != *"author.email mismatch"* ]]
  [[ "$output" != *"committer."* ]]
  assert_addresses_redacted
}

@test "git identity: current rejects only a wrong author email" {
  local project
  project="$(make_identity_repo current-author-email)"

  run env \
    GIT_AUTHOR_NAME="$CANONICAL_NAME" \
    GIT_AUTHOR_EMAIL="$BAD_AUTHOR_EMAIL" \
    GIT_COMMITTER_NAME="$CANONICAL_NAME" \
    GIT_COMMITTER_EMAIL="$CANONICAL_EMAIL" \
    bash "$CHECKER" --current --project "$project"

  [ "$status" -eq 1 ]
  [[ "$output" == *"pending: author.email mismatch"* ]]
  [[ "$output" != *"author.name mismatch"* ]]
  [[ "$output" != *"committer."* ]]
  assert_addresses_redacted
}

@test "git identity: current rejects only a wrong committer name" {
  local project
  project="$(make_identity_repo current-committer-name)"

  run env \
    GIT_AUTHOR_NAME="$CANONICAL_NAME" \
    GIT_AUTHOR_EMAIL="$CANONICAL_EMAIL" \
    GIT_COMMITTER_NAME="wrong-committer" \
    GIT_COMMITTER_EMAIL="$CANONICAL_EMAIL" \
    bash "$CHECKER" --current --project "$project"

  [ "$status" -eq 1 ]
  [[ "$output" == *"pending: committer.name mismatch"* ]]
  [[ "$output" != *"committer.email mismatch"* ]]
  [[ "$output" != *"author."* ]]
  assert_addresses_redacted
}

@test "git identity: current rejects only a wrong committer email" {
  local project
  project="$(make_identity_repo current-committer-email)"

  run env \
    GIT_AUTHOR_NAME="$CANONICAL_NAME" \
    GIT_AUTHOR_EMAIL="$CANONICAL_EMAIL" \
    GIT_COMMITTER_NAME="$CANONICAL_NAME" \
    GIT_COMMITTER_EMAIL="$BAD_COMMITTER_EMAIL" \
    bash "$CHECKER" --current --project "$project"

  [ "$status" -eq 1 ]
  [[ "$output" == *"pending: committer.email mismatch"* ]]
  [[ "$output" != *"committer.name mismatch"* ]]
  [[ "$output" != *"author."* ]]
  assert_addresses_redacted
}

@test "git identity: range reports all four raw fields and redacts addresses" {
  local project base bad_sha
  project="$(make_identity_repo range-all-fields)"
  base="$(git -C "$project" rev-parse HEAD)"
  bad_sha="$(add_identity_commit "$project" all-wrong \
    wrong-author "$BAD_AUTHOR_EMAIL" \
    wrong-committer "$BAD_COMMITTER_EMAIL")"

  run bash "$CHECKER" --range "$base..$bad_sha" --project "$project"

  [ "$status" -eq 1 ]
  [[ "$output" == *"$bad_sha: author.name mismatch"* ]]
  [[ "$output" == *"$bad_sha: author.email mismatch"* ]]
  [[ "$output" == *"$bad_sha: committer.name mismatch"* ]]
  [[ "$output" == *"$bad_sha: committer.email mismatch"* ]]
  assert_addresses_redacted
}

@test "git identity: mixed range names only the bad commit" {
  local project base bad_sha good_sha
  project="$(make_identity_repo range-mixed)"
  base="$(git -C "$project" rev-parse HEAD)"
  bad_sha="$(add_identity_commit "$project" bad-middle \
    wrong-author "$CANONICAL_EMAIL" \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL")"
  good_sha="$(add_identity_commit "$project" good-tip \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL" \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL")"

  run bash "$CHECKER" --range "$base..$good_sha" --project "$project"

  [ "$status" -eq 1 ]
  [[ "$output" == *"$bad_sha: author.name mismatch"* ]]
  [[ "$output" != *"$good_sha:"* ]]
}

@test "git identity: range inspects merge commit metadata" {
  local project base merge_sha
  project="$(make_identity_repo range-merge)"
  base="$(git -C "$project" rev-parse HEAD)"
  git -C "$project" switch -q -c topic
  add_identity_commit "$project" topic \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL" \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL" >/dev/null
  git -C "$project" switch -q main
  add_identity_commit "$project" main \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL" \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL" >/dev/null
  GIT_AUTHOR_NAME="$CANONICAL_NAME" \
    GIT_AUTHOR_EMAIL="$CANONICAL_EMAIL" \
    GIT_COMMITTER_NAME="$CANONICAL_NAME" \
    GIT_COMMITTER_EMAIL="$BAD_COMMITTER_EMAIL" \
    git -C "$project" merge -q --no-ff -m merge-topic topic
  merge_sha="$(git -C "$project" rev-parse HEAD)"

  run bash "$CHECKER" --range "$base..$merge_sha" --project "$project"

  [ "$status" -eq 1 ]
  [[ "$output" == *"$merge_sha: committer.email mismatch"* ]]
  assert_addresses_redacted
}

@test "git identity: repeated ranges de-duplicate commits" {
  local project base bad_sha count
  project="$(make_identity_repo range-repeat)"
  base="$(git -C "$project" rev-parse HEAD)"
  bad_sha="$(add_identity_commit "$project" repeated \
    wrong-author "$CANONICAL_EMAIL" \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL")"

  run bash "$CHECKER" \
    --range "$base..$bad_sha" --range "$base..$bad_sha" \
    --project "$project"

  [ "$status" -eq 1 ]
  count="$(grep -c "$bad_sha: author.name mismatch" <<<"$output")"
  [ "$count" -eq 1 ]
}

@test "git identity: mailmap cannot normalize a raw mismatch" {
  local project base bad_sha tip
  project="$(make_identity_repo range-mailmap)"
  base="$(git -C "$project" rev-parse HEAD)"
  bad_sha="$(add_identity_commit "$project" mailmapped \
    wrong-author "$BAD_AUTHOR_EMAIL" \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL")"
  printf '%s <%s> wrong-author <%s>\n' \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL" "$BAD_AUTHOR_EMAIL" \
    >"$project/.mailmap"
  git -C "$project" add .mailmap
  commit_with_identity "$project" mailmap \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL" \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL"
  tip="$(git -C "$project" rev-parse HEAD)"

  run bash "$CHECKER" --range "$base..$tip" --project "$project"

  [ "$status" -eq 1 ]
  [[ "$output" == *"$bad_sha: author.name mismatch"* ]]
  [[ "$output" == *"$bad_sha: author.email mismatch"* ]]
  assert_addresses_redacted
}

@test "git identity: all audits complete reachable history" {
  local project bad_sha
  project="$(make_identity_repo all-history)"
  bad_sha="$(add_identity_commit "$project" historical \
    "$CANONICAL_NAME" "$BAD_AUTHOR_EMAIL" \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL")"
  add_identity_commit "$project" canonical-tip \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL" \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL" >/dev/null

  run bash "$CHECKER" --all HEAD --project "$project"

  [ "$status" -eq 1 ]
  [[ "$output" == *"$bad_sha: author.email mismatch"* ]]
  assert_addresses_redacted
}

@test "git identity: empty explicit range is valid" {
  local project
  project="$(make_identity_repo empty-range)"

  run bash "$CHECKER" --range HEAD..HEAD --project "$project"

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "git identity: pre-push unions multiple existing-ref updates" {
  local project base one_sha two_sha input
  project="$(make_identity_repo prepush-multi)"
  base="$(git -C "$project" rev-parse HEAD)"
  git -C "$project" switch -q -c one
  one_sha="$(add_identity_commit "$project" one \
    wrong-author "$CANONICAL_EMAIL" \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL")"
  git -C "$project" switch -q main
  git -C "$project" switch -q -c two
  two_sha="$(add_identity_commit "$project" two \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL" \
    wrong-committer "$CANONICAL_EMAIL")"
  input="refs/heads/one $one_sha refs/heads/one $base
refs/heads/two $two_sha refs/heads/two $base"

  run bash -c \
    "printf '%s\\n' \"\$1\" | bash \"\$2\" --pre-push origin local --project \"\$3\"" \
    _ "$input" "$CHECKER" "$project"

  [ "$status" -eq 1 ]
  [[ "$output" == *"$one_sha: author.name mismatch"* ]]
  [[ "$output" == *"$two_sha: committer.name mismatch"* ]]
}

@test "git identity: new ref excludes remote-tracking history" {
  local project remote_tip local_tip zero input
  project="$(make_identity_repo prepush-new-tracked)"
  remote_tip="$(add_identity_commit "$project" existing-remote-bad \
    wrong-author "$CANONICAL_EMAIL" \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL")"
  git -C "$project" update-ref refs/remotes/origin/main "$remote_tip"
  local_tip="$(add_identity_commit "$project" new-canonical \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL" \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL")"
  zero=0000000000000000000000000000000000000000
  input="refs/heads/new $local_tip refs/heads/new $zero"

  run bash -c \
    "printf '%s\\n' \"\$1\" | bash \"\$2\" --pre-push origin local --project \"\$3\"" \
    _ "$input" "$CHECKER" "$project"

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "git identity: new ref without tracking refs audits all reachable commits" {
  local project bad_sha local_tip zero input
  project="$(make_identity_repo prepush-new-untracked)"
  bad_sha="$(add_identity_commit "$project" reachable-bad \
    wrong-author "$CANONICAL_EMAIL" \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL")"
  local_tip="$(add_identity_commit "$project" new-canonical \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL" \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL")"
  zero=0000000000000000000000000000000000000000
  input="refs/heads/new $local_tip refs/heads/new $zero"

  run bash -c \
    "printf '%s\\n' \"\$1\" | bash \"\$2\" --pre-push origin local --project \"\$3\"" \
    _ "$input" "$CHECKER" "$project"

  [ "$status" -eq 1 ]
  [[ "$output" == *"$bad_sha: author.name mismatch"* ]]
}

@test "git identity: pre-push ignores deletes" {
  local project remote_sha zero input
  project="$(make_identity_repo prepush-delete)"
  remote_sha="$(git -C "$project" rev-parse HEAD)"
  zero=0000000000000000000000000000000000000000
  input="(delete) $zero refs/heads/old $remote_sha"

  run bash -c \
    "printf '%s\\n' \"\$1\" | bash \"\$2\" --pre-push origin local --project \"\$3\"" \
    _ "$input" "$CHECKER" "$project"

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "git identity: empty pre-push input is valid" {
  local project
  project="$(make_identity_repo prepush-empty)"

  run bash -c \
    "printf '' | bash \"\$1\" --pre-push origin local --project \"\$2\"" \
    _ "$CHECKER" "$project"

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "git identity: malformed pre-push input exits 2" {
  local project
  project="$(make_identity_repo prepush-malformed)"

  run bash -c \
    "printf 'only three fields\\n' | bash \"\$1\" --pre-push origin local --project \"\$2\"" \
    _ "$CHECKER" "$project"

  [ "$status" -eq 2 ]
  [[ "$output" == *"malformed pre-push ref update"* ]]
}

@test "git identity: missing range endpoints exit 2" {
  local project local_sha missing input
  project="$(make_identity_repo missing-endpoints)"
  local_sha="$(git -C "$project" rev-parse HEAD)"
  missing=1111111111111111111111111111111111111111

  run bash "$CHECKER" --range "$missing..$local_sha" --project "$project"
  [ "$status" -eq 2 ]
  [[ "$output" == *"revision range is missing or invalid"* ]]

  input="refs/heads/main $local_sha refs/heads/main $missing"
  run bash -c \
    "printf '%s\\n' \"\$1\" | bash \"\$2\" --pre-push origin local --project \"\$3\"" \
    _ "$input" "$CHECKER" "$project"
  [ "$status" -eq 2 ]
  [[ "$output" == *"revision range is missing or invalid"* ]]
}

@test "git identity: shallow history exits 2" {
  local source shallow
  source="$(make_identity_repo shallow-source)"
  add_identity_commit "$source" second \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL" \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL" >/dev/null
  shallow="$BATS_TEST_TMPDIR/shallow-clone"
  git clone -q --depth 1 "file://$source" "$shallow"
  git -C "$shallow" config --local shipyard.identityEmail "$CANONICAL_EMAIL"
  [ "$(git -C "$shallow" rev-parse --is-shallow-repository)" = "true" ]

  run bash "$CHECKER" --all HEAD --project "$shallow"

  [ "$status" -eq 2 ]
  [[ "$output" == *"repository history is shallow"* ]]
}

@test "git identity: missing and malformed policies exit 2" {
  local missing malformed
  missing="$(make_identity_repo policy-missing)"
  printf '[other]\nenabled = true\n' >"$missing/.shipyard-git-identity.toml"

  run bash "$CHECKER" --all HEAD --project "$missing"
  [ "$status" -eq 2 ]
  [[ "$output" == *"identity policy is missing or malformed"* ]]

  malformed="$(make_identity_repo policy-malformed)"
  printf '[git_identity\nenforce = true\n' >"$malformed/.shipyard-git-identity.toml"

  run bash "$CHECKER" --all HEAD --project "$malformed"
  [ "$status" -eq 2 ]
  [[ "$output" == *"identity policy is missing or malformed"* ]]
}

@test "git identity: missing or duplicate local email exits 2 without disclosure" {
  local project
  project="$(make_identity_repo email-policy)"
  git -C "$project" config --local --unset-all shipyard.identityEmail

  run bash "$CHECKER" --all HEAD --project "$project"
  [ "$status" -eq 2 ]
  [[ "$output" == *"local canonical email is missing"* ]]
  assert_addresses_redacted

  git -C "$project" config --local --add shipyard.identityEmail "$CANONICAL_EMAIL"
  git -C "$project" config --local --add shipyard.identityEmail "$BAD_AUTHOR_EMAIL"
  run bash "$CHECKER" --all HEAD --project "$project"
  [ "$status" -eq 2 ]
  [[ "$output" == *"local canonical email is malformed"* ]]
  assert_addresses_redacted
}

@test "git identity: malformed pending identity exits 2 without disclosure" {
  local project
  project="$(make_identity_repo current-malformed)"

  run env \
    GIT_AUTHOR_NAME="" \
    GIT_AUTHOR_EMAIL="$BAD_AUTHOR_EMAIL" \
    GIT_COMMITTER_NAME="$CANONICAL_NAME" \
    GIT_COMMITTER_EMAIL="$CANONICAL_EMAIL" \
    bash "$CHECKER" --current --project "$project"

  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot resolve pending author identity"* ]]
  assert_addresses_redacted
}

@test "git identity: bad invocation exits 2" {
  local project
  project="$(make_identity_repo bad-invocation)"

  run bash "$CHECKER" --current --all HEAD --project "$project"
  [ "$status" -eq 2 ]
  [[ "$output" == usage:* ]]

  run bash "$CHECKER" --range --project "$project"
  [ "$status" -eq 2 ]
  [[ "$output" == usage:* ]]
}

@test "git identity: pre-commit rejects a wrong pending author before downstream gates" {
  local project marker
  project="$(make_identity_repo hook-current-author)"
  install_identity_hooks "$project"
  marker="$BATS_TEST_TMPDIR/pre-commit-downstream"
  printf '#!/usr/bin/env bash\nprintf "leak\\n" >>"$HOOK_MARKER"\n' \
    >"$project/scripts/leak-check.sh"
  printf '#!/usr/bin/env bash\nprintf "deck\\n" >>"$HOOK_MARKER"\n' \
    >"$project/scripts/check-deck-complete.sh"
  chmod +x "$project/scripts/leak-check.sh" \
    "$project/scripts/check-deck-complete.sh"

  run bash -c \
    'cd "$1" && env HOOK_MARKER="$2" GIT_AUTHOR_NAME=wrong-author
      GIT_AUTHOR_EMAIL="$3" GIT_COMMITTER_NAME="$4"
      GIT_COMMITTER_EMAIL="$3" bash .githooks/pre-commit' \
    _ "$project" "$marker" "$CANONICAL_EMAIL" "$CANONICAL_NAME"

  [ "$status" -eq 1 ]
  [[ "$output" == *"pending: author.name mismatch"* ]]
  [ ! -e "$marker" ]
  assert_addresses_redacted
}

@test "git identity: pre-commit rejects a wrong pending committer before downstream gates" {
  local project marker
  project="$(make_identity_repo hook-current-committer)"
  install_identity_hooks "$project"
  marker="$BATS_TEST_TMPDIR/pre-commit-downstream"
  printf '#!/usr/bin/env bash\nprintf "leak\\n" >>"$HOOK_MARKER"\n' \
    >"$project/scripts/leak-check.sh"
  chmod +x "$project/scripts/leak-check.sh"

  run bash -c \
    'cd "$1" && env HOOK_MARKER="$2" GIT_AUTHOR_NAME="$3"
      GIT_AUTHOR_EMAIL="$4" GIT_COMMITTER_NAME=wrong-committer
      GIT_COMMITTER_EMAIL="$4" bash .githooks/pre-commit' \
    _ "$project" "$marker" "$CANONICAL_NAME" "$CANONICAL_EMAIL"

  [ "$status" -eq 1 ]
  [[ "$output" == *"pending: committer.name mismatch"* ]]
  [ ! -e "$marker" ]
  assert_addresses_redacted
}

@test "git identity: pre-push rejects multi-ref and new-ref metadata before deck cascade" {
  local project base existing_sha new_sha zero input marker
  project="$(make_identity_repo hook-prepush-multi)"
  install_identity_hooks "$project"
  base="$(git -C "$project" rev-parse HEAD)"
  git -C "$project" update-ref refs/remotes/origin/main "$base"

  git -C "$project" switch -q -c existing
  existing_sha="$(add_identity_commit "$project" existing-bad \
    wrong-author "$CANONICAL_EMAIL" \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL")"
  git -C "$project" switch -q main
  git -C "$project" switch -q -c new-ref
  new_sha="$(add_identity_commit "$project" new-bad \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL" \
    wrong-committer "$CANONICAL_EMAIL")"

  marker="$BATS_TEST_TMPDIR/deck-cascade"
  printf '#!/usr/bin/env bash\nprintf "mirror\\n" >>"$HOOK_MARKER"\n' \
    >"$project/scripts/sync-deck-mirror.sh"
  chmod +x "$project/scripts/sync-deck-mirror.sh"
  zero=0000000000000000000000000000000000000000
  input="refs/heads/existing $existing_sha refs/heads/existing $base
refs/heads/new-ref $new_sha refs/heads/new-ref $zero"

  run bash -c \
    'printf "%s\n" "$1" | env HOOK_MARKER="$2" QUARTET_DIR="$3" \
      bash "$3/.githooks/pre-push" origin local' \
    _ "$input" "$marker" "$project"

  [ "$status" -eq 1 ]
  [[ "$output" == *"$existing_sha: author.name mismatch"* ]]
  [[ "$output" == *"$new_sha: committer.name mismatch"* ]]
  [ ! -e "$marker" ]
}

@test "git identity: pre-push runs non-blocking deck cascade only after identity success" {
  local project base tip input marker
  project="$(make_identity_repo hook-prepush-deck)"
  install_identity_hooks "$project"
  base="$(git -C "$project" rev-parse HEAD)"
  git -C "$project" update-ref refs/remotes/origin/main "$base"
  tip="$(add_identity_commit "$project" canonical \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL" \
    "$CANONICAL_NAME" "$CANONICAL_EMAIL")"
  marker="$BATS_TEST_TMPDIR/deck-cascade"
  printf '#!/usr/bin/env bash\nprintf "mirror\\n" >>"$HOOK_MARKER"\nexit 9\n' \
    >"$project/scripts/sync-deck-mirror.sh"
  chmod +x "$project/scripts/sync-deck-mirror.sh"
  input="refs/heads/main $tip refs/heads/main $base"

  run bash -c \
    'printf "%s\n" "$1" | env HOOK_MARKER="$2" QUARTET_DIR="$3" \
      bash "$3/.githooks/pre-push" origin local' \
    _ "$input" "$marker" "$project"

  [ "$status" -eq 0 ]
  [ "$(cat "$marker")" = "mirror" ]
  [[ "$output" == *"deck mirror cascade did not complete (non-blocking)"* ]]
}

@test "git identity: configure writes local policy and redacts its log" {
  local project
  project="$(make_install_identity_fixture configure-success)"

  run configure_identity_fixture "$project"

  [ "$status" -eq 0 ]
  [ "$(git -C "$project" config --local user.name)" = "fixture-owner" ]
  [ "$(git -C "$project" config --local user.email)" = "$CANONICAL_EMAIL" ]
  [ "$(git -C "$project" config --local shipyard.identityEmail)" = "$CANONICAL_EMAIL" ]
  [ "$(git -C "$project" config --local core.hooksPath)" = ".githooks" ]
  [[ "$output" == *"name=fixture-owner"* ]]
  [[ "$output" == *"email=<redacted>"* ]]
  assert_addresses_redacted
}

@test "git identity: configure rejects a name different from project_owner without writes" {
  local project
  project="$(make_install_identity_fixture configure-name-mismatch)"
  git -C "$project" config --local user.name wrong-owner

  run configure_identity_fixture "$project"

  [ "$status" -eq 2 ]
  [[ "$output" == *"effective user.name does not match project_owner"* ]]
  ! git -C "$project" config --local shipyard.identityEmail >/dev/null
  ! git -C "$project" config --local core.hooksPath >/dev/null
  assert_addresses_redacted
}

@test "git identity: doctor reports missing opted-in local policy" {
  local project
  project="$(make_install_identity_fixture doctor-identity-missing)"

  run run_identity_doctor "$project"

  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR identity: local canonical email is missing"* ]]
  [[ "$output" == *"DOCTOR identity: core.hooksPath must be .githooks"* ]]
  assert_addresses_redacted
}

@test "git identity: doctor reports mismatched opted-in local policy without disclosure" {
  local project
  project="$(make_install_identity_fixture doctor-identity-mismatch)"
  configure_identity_fixture "$project" >/dev/null
  git -C "$project" config --local user.email "$BAD_AUTHOR_EMAIL"
  git -C "$project" config --local core.hooksPath other-hooks

  run run_identity_doctor "$project"

  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR identity: local user.email does not match canonical email"* ]]
  [[ "$output" == *"DOCTOR identity: core.hooksPath must be .githooks"* ]]
  assert_addresses_redacted
}

@test "git identity: doctor passes after configuring a fresh opted-in install" {
  local project
  project="$(make_install_identity_fixture doctor-identity-success)"
  configure_identity_fixture "$project" >/dev/null

  run run_identity_doctor "$project"

  [ "$status" -eq 0 ]
  [[ "$output" == *"crew install clean"* ]]
  [[ "$output" != *"DOCTOR identity:"* ]]
  assert_addresses_redacted
}

@test "git identity: normal install leaves an unset project's local config byte-identical" {
  local project before after
  project="$(make_fixture_project identity-unset clean-install.toml)"
  stub_install_dependencies
  before="$(sha256sum "$project/.git/config")"

  run env QUARTET_DIR="$QUARTET_ROOT" \
    QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    QUARTET_NOTIFY_CMD="$NOTIFY_CMD" \
    bash "$INSTALLER" --project "$project"

  [ "$status" -eq 0 ]
  after="$(sha256sum "$project/.git/config")"
  [ "$before" = "$after" ]
  ! git -C "$project" config --local shipyard.identityEmail >/dev/null
  ! git -C "$project" config --local core.hooksPath >/dev/null
  [[ "$output" != *"git identity"* ]]
}

@test "git identity: workflow uses full-depth checkout and exact event ranges" {
  [ "$(grep -Fc 'fetch-depth: 0' "$WORKFLOW")" -eq 1 ]
  grep -Fq 'BASE_SHA: ${{ github.event.pull_request.base.sha }}' "$WORKFLOW"
  grep -Fq 'PR_HEAD_SHA: ${{ github.event.pull_request.head.sha }}' "$WORKFLOW"
  grep -Fq 'TARGET_REF: ${{ github.ref }}' "$WORKFLOW"
  ! grep -Fq 'GITHUB_REF_NAME:' "$WORKFLOW"
  grep -Fq -- '--range "$BASE_SHA..$PR_HEAD_SHA" --project .' "$WORKFLOW"
  grep -Fq -- '--all "$HEAD_SHA" --project .' "$WORKFLOW"
}

@test "git identity: workflow fails closed on missing variable event SHA history or policy" {
  grep -Fq 'SHIPYARD_IDENTITY_EMAIL: ${{ secrets.SHIPYARD_IDENTITY_EMAIL }}' "$WORKFLOW"
  ! grep -Fq 'vars.SHIPYARD_IDENTITY_EMAIL' "$WORKFLOW"
  grep -Fq 'identity email variable is missing' "$WORKFLOW"
  grep -Fq 'pull request identity range is missing' "$WORKFLOW"
  grep -Fq 'main identity revision is missing' "$WORKFLOW"
  grep -Fq 'repository history is shallow' "$WORKFLOW"
  grep -Fq 'git config --local shipyard.identityEmail "$SHIPYARD_IDENTITY_EMAIL"' "$WORKFLOW"
  grep -Fq 'bash scripts/check-git-identity.sh' "$WORKFLOW"
}
