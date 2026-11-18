#!/usr/bin/env bats
#
# mentat-proposal-dedup.bats -- incident-repair proposals dedup on dedup_key
# (one per failing unit) while undecided; a decided one lets a new one open.

setup() {
  load helpers
  quartet_setup
  # shellcheck disable=SC1091
  source "$QUARTET_ROOT/agents/lib/mentat-proposal.sh"
  RES="$BATS_TEST_TMPDIR/mentat-result.json"
  DEC="$BATS_TEST_TMPDIR/decisions.jsonl"
}

prop() { jq -cn --arg t "$1" '{type:"incident-repair",title:$t,dedup_key:"incident-repair:proj-proctor"}'; }

@test "same dedup_key with different title is a duplicate while undecided" {
  id1="$(mentat_merge_proposal "$RES" proj 2026-01-01T00:00:00Z "$(prop 'gate failed A')" "$DEC")"
  [ -n "$id1" ]
  id2="$(mentat_merge_proposal "$RES" proj 2026-01-02T00:00:00Z "$(prop 'gate failed B (reworded)')" "$DEC")"
  [ -z "$id2" ]
  [ "$(jq '.proposals|length' "$RES")" = "1" ]
}

@test "a decided proposal no longer blocks a new one with the same key" {
  id1="$(mentat_merge_proposal "$RES" proj 2026-01-01T00:00:00Z "$(prop 'gate failed A')" "$DEC")"
  jq -cn --arg i "$id1" '{proposal_id:$i,decision:"approve"}' >"$DEC"
  id2="$(mentat_merge_proposal "$RES" proj 2026-01-02T00:00:00Z "$(prop 'gate failed B')" "$DEC")"
  [ -n "$id2" ]
  [ "$(jq '.proposals|length' "$RES")" = "2" ]
}

@test "no dedup_key keeps legacy title-only behaviour" {
  p='{"type":"bug","title":"x"}'
  mentat_merge_proposal "$RES" proj 2026-01-01T00:00:00Z "$p" >/dev/null
  id2="$(mentat_merge_proposal "$RES" proj 2026-01-02T00:00:00Z '{"type":"bug","title":"y"}')"
  [ -n "$id2" ]
}
