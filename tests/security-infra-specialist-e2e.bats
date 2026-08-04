#!/usr/bin/env bats
# Regression fixture for the review miss behind datavant/infrastructure#6726.
# Every external command that could reach a model, vendor, cloud, or GitHub is
# stubbed: this exercises Shipyard's real hunk selection and evidence plumbing
# without model or network access.

setup() {
  load helpers
  quartet_setup
}

WATCH="agents/release/critic-watch.sh"
SHIPYARD="skills/shipyard/shipyard.sh"

run_watch() {
  QUARTET_DIR="$QUARTET_ROOT" QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    CRITIC_IDLE_SEC=1 CLAUDE_NOTE_CMD="$SHIM_BIN/claude-note" \
    bash "$QUARTET_ROOT/$WATCH" --project "$1" --session s1 --once
}

queue_paths() {
  local project="$1"
  shift
  : >"$project/tmp/critic-queue-s1"
  local path
  for path in "$@"; do
    printf '%s %s\n' "$path" "$(date +%s)" \
      >>"$project/tmp/critic-queue-s1"
  done
  fixture_set_mtime_ago 120 "$project/tmp/critic-queue-s1"
}

configure_security_specialist() {
  local project="$1"
  QUARTET_DIR="$QUARTET_ROOT" bash "$QUARTET_ROOT/$SHIPYARD" \
    add-specialist security-infra-platform --project "$project" >/dev/null

  local manifest="$project/.agents/specialists/security-infra-platform.toml"
  fixture_replace_in_place "$manifest" \
    '^hunk_path_patterns = \[\]$' \
    'hunk_path_patterns = ["src/judgify/ec2.py", "src/judgify/iam.py"]'
  fixture_replace_in_place "$manifest" \
    '^external_repository_triggers = \[\]$' \
    'external_repository_triggers = ["datavant/infrastructure"]'
  fixture_replace_in_place "$manifest" '^live_docs = \[\]$' ''
  printf '\n[[live_docs]]\nlabel = "AWS EC2 AMI encryption"\nurl = "https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/AMIEncryption.html"\nauthority = "AWS"\naccess_mode = "public"\n' \
    >>"$manifest"
  printf '\n[[live_docs]]\nlabel = "Wiz live finding"\nurl = "https://app.wiz.io/"\nauthority = "Wiz"\naccess_mode = "authenticated"\n' \
    >>"$manifest"

  cat >"$project/.agents/specialists/security-infra-platform.md" <<'EOF'
# security-infra-platform specialist

Block an external infrastructure PR until current primary docs, live read-only
state, existing internal patterns, local IAM/resource behavior, and narrower
local fixes are all evidenced. For shared encrypted AMIs, distinguish the
source key's ReEncryptFrom permission from the destination key's ReEncryptTo
permission and require an explicit destination KmsKeyId.
EOF
}

stub_hermetic_reviews() {
  ORDER_FILE="$BATS_TEST_TMPDIR/review-order"
  SPECIALIST_PROMPT="$BATS_TEST_TMPDIR/security-specialist-prompt"
  export ORDER_FILE SPECIALIST_PROMPT

  make_stub_script claude '
case "$*" in
  *"Specialist — generic subsystem-steward role"*)
    printf "specialist\n" >>"$ORDER_FILE"
    printf "%s" "$*" >"$SPECIALIST_PROMPT"
    jq -nc --arg result "block|docs/tickets/pending/t48.md|External infrastructure escalation lacks the required local source/destination KMS launch matrix.
block|src/judgify/ec2.py|The shared encrypted AMI root mapping omits the reviewed destination KmsKeyId, so AWS selects the destination default EBS key.
block|src/judgify/iam.py|The exact source KMS key statement lacks kms:ReEncryptFrom.
source|https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/AMIEncryption.html|2026-08-04T18:00:00Z|success|A non-owned encrypted snapshot without KmsKeyId restores using the destination account default key." \
      "{type:\"result\",result:\$result,usage:{input_tokens:20,output_tokens:10}}"
    ;;
  *)
    printf "generic\n" >>"$ORDER_FILE"
    jq -nc --arg result "warn|docs/tickets/pending/t48.md|External change needs evidence." \
      "{type:\"result\",result:\$result,usage:{input_tokens:10,output_tokens:5}}"
    ;;
esac'
  make_stub claude-note 0

  # A regression must fail visibly if the deterministic runner starts doing
  # its own live retrieval or cloud/GitHub probing.
  make_stub curl 97
  make_stub wget 97
  make_stub aws 97
  make_stub gh 97
}

@test "6726-like escalation is blocked on local source and destination KMS defects" {
  P="$(make_fixture_project security-infra-6726)"
  configure_security_specialist "$P"
  stub_hermetic_reviews

  mkdir -p "$P/docs/tickets/pending" "$P/src/judgify"
  cat >"$P/docs/tickets/pending/t48.md" <<'EOF'
Open a PR in datavant/infrastructure to add the destination account to the
central AMI KMS key policy before trying a narrower Judgify-owned fix.
EOF
  cat >"$P/src/judgify/ec2.py" <<'EOF'
root_ebs = {"Encrypted": True}
run_instances(BlockDeviceMappings=[{"DeviceName": "/dev/xvda", "Ebs": root_ebs}])
EOF
  cat >"$P/src/judgify/iam.py" <<'EOF'
source_key_statement = {
    "Action": ["kms:Decrypt", "kms:DescribeKey"],
    "Resource": "arn:aws:kms:us-east-1:111122223333:key/source-key",
}
destination_key_statement = {
    "Action": ["kms:Encrypt", "kms:GenerateDataKey*", "kms:ReEncryptTo"],
    "Resource": "arn:aws:kms:us-east-1:444455556666:key/destination-key",
}
EOF
  # This is deliberately outside the queue and must not leak into the bounded
  # exact-hunk specialist input.
  printf 'UNRELATED_PLATFORM_POLICY_CHANGE\n' >"$P/src/judgify/unrelated.py"

  queue_paths "$P" \
    docs/tickets/pending/t48.md \
    src/judgify/ec2.py \
    src/judgify/iam.py

  run run_watch "$P"
  [ "$status" -eq 0 ]
  [ "$(cat "$ORDER_FILE")" = $'generic\nspecialist' ]

  grep -qF 'docs/tickets/pending/t48.md' "$SPECIALIST_PROMPT"
  grep -qF 'src/judgify/ec2.py' "$SPECIALIST_PROMPT"
  grep -qF 'root_ebs = {"Encrypted": True}' "$SPECIALIST_PROMPT"
  grep -qF 'src/judgify/iam.py' "$SPECIALIST_PROMPT"
  grep -qF '"kms:Decrypt", "kms:DescribeKey"' "$SPECIALIST_PROMPT"
  ! grep -qF 'UNRELATED_PLATFORM_POLICY_CHANGE' "$SPECIALIST_PROMPT"

  findings="$P/tmp/critic-findings-s1"
  grep -qF 'block|docs/tickets/pending/t48.md|External infrastructure escalation lacks the required local source/destination KMS launch matrix.' "$findings"
  grep -qF 'block|src/judgify/ec2.py|The shared encrypted AMI root mapping omits the reviewed destination KmsKeyId' "$findings"
  grep -qF 'block|src/judgify/iam.py|The exact source KMS key statement lacks kms:ReEncryptFrom.' "$findings"

  evidence="$P/tmp/critic-specialist-sources-s1"
  grep -qF 'source|https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/AMIEncryption.html|2026-08-04T18:00:00Z|success|' "$evidence"
  grep -Eq '^source\|https://app\.wiz\.io/\|[^|]+\|unverified\|specialist returned no retrieval evidence$' "$evidence"

  [ "$(stub_calls curl)" = "0" ]
  [ "$(stub_calls wget)" = "0" ]
  [ "$(stub_calls aws)" = "0" ]
  [ "$(stub_calls gh)" = "0" ]
}

@test "a queued matching path with no real hunk cannot invoke the security specialist" {
  P="$(make_fixture_project security-infra-no-hunk)"
  configure_security_specialist "$P"
  stub_hermetic_reviews

  mkdir -p "$P/src/judgify" "$P/src/app"
  printf 'original\n' >"$P/src/judgify/ec2.py"
  git -C "$P" add src/judgify/ec2.py
  git -C "$P" commit -q -m 'fixture: tracked EC2 path'
  printf 'temporary change\n' >"$P/src/judgify/ec2.py"
  printf 'original\n' >"$P/src/judgify/ec2.py"
  printf 'real application change\n' >"$P/src/app/service.py"
  queue_paths "$P" src/judgify/ec2.py src/app/service.py

  run run_watch "$P"
  [ "$status" -eq 0 ]
  [ "$(cat "$ORDER_FILE")" = "generic" ]
  [ ! -e "$SPECIALIST_PROMPT" ]
  [ ! -e "$P/tmp/critic-specialist-sources-s1" ]
  [ "$(stub_calls curl)" = "0" ]
  [ "$(stub_calls wget)" = "0" ]
  [ "$(stub_calls aws)" = "0" ]
  [ "$(stub_calls gh)" = "0" ]
}
