#!/usr/bin/env bats

setup() {
  load helpers
  quartet_setup

  OLD_PRE_PUSH="$QUARTET_ROOT/.githooks/pre-push"
  CHECKER="$QUARTET_ROOT/scripts/check-git-identity.sh"
  CANONICAL_NAME="canonical-owner"
  CANONICAL_EMAIL="canonical-owner@example.invalid"
  BAD_AUTHOR_EMAIL="wrong-author@example.invalid"
  BAD_COMMITTER_EMAIL="wrong-committer@example.invalid"
}

write_policy() {
  local project="$1"
  mkdir -p "$project/.agents"
  printf '[git_identity]\nenforce = true\nname = "%s"\n' \
    "$CANONICAL_NAME" >"$project/.agents/config.toml"
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
  git -C "$project" add .agents/config.toml root.txt
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

assert_addresses_redacted() {
  [[ "$output" != *"$CANONICAL_EMAIL"* ]]
  [[ "$output" != *"$BAD_AUTHOR_EMAIL"* ]]
  [[ "$output" != *"$BAD_COMMITTER_EMAIL"* ]]
}

@test "git identity: existing pre-push accepts a wrong author" {
  local project remote_sha local_sha zero
  project="$(make_git_topology "$BATS_TEST_TMPDIR/old-hook")"
  remote_sha="$(git -C "$project" rev-parse refs/remotes/origin/main)"

  printf 'bad author\n' >"$project/bad-author.txt"
  git -C "$project" add bad-author.txt
  GIT_AUTHOR_NAME="wrong-author" \
    GIT_AUTHOR_EMAIL="wrong-author@example.invalid" \
    git -C "$project" commit -q -m "bad author"
  local_sha="$(git -C "$project" rev-parse HEAD)"

  mkdir -p "$project/scripts"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$project/scripts/sync-deck-mirror.sh"
  chmod +x "$project/scripts/sync-deck-mirror.sh"

  zero=0000000000000000000000000000000000000000
  run bash -c \
    "printf 'refs/heads/main %s refs/heads/main %s\\n' '$local_sha' '$remote_sha' |
       env QUARTET_DIR='$project' bash '$OLD_PRE_PUSH' origin '$BATS_TEST_TMPDIR/old-hook/origin.git'"

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$remote_sha" != "$local_sha" ]
  [ "$remote_sha" != "$zero" ]
  [ "$(git -C "$project" show -s --format=%an "$local_sha")" = "wrong-author" ]
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
  printf '[other]\nenabled = true\n' >"$missing/.agents/config.toml"

  run bash "$CHECKER" --all HEAD --project "$missing"
  [ "$status" -eq 2 ]
  [[ "$output" == *"identity policy is missing or malformed"* ]]

  malformed="$(make_identity_repo policy-malformed)"
  printf '[git_identity\nenforce = true\n' >"$malformed/.agents/config.toml"

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
