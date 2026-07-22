#!/usr/bin/env bash
# check-deck-fresh.sh — the deck-coupling gate.
#
# docs/shipyard-data.json is GENERATED from the skill files' frontmatter
# (structure) merged with docs/deck-editorial.json (prose) by
# scripts/gen-deck-data.py. This gate regenerates it and fails if the tracked
# file drifted — i.e. someone changed a skill's `roles:`/`kind:`, added/removed
# a skill in GENERIC_SKILLS, or hand-edited the deck without regenerating.
#
# Exit 0 = deck is in sync. Nonzero = stale (regenerate to fix).

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

python3 scripts/gen-deck-data.py || {
    echo "check-deck-fresh: generator failed" >&2
    exit 2
}

if ! git diff --exit-code docs/shipyard-data.json; then
    cat >&2 <<'EOF'

deck is stale — regenerate with gen-deck-data.py

docs/shipyard-data.json is generated from skill frontmatter + docs/deck-editorial.json.
Run:  python3 scripts/gen-deck-data.py
then commit docs/shipyard-data.json alongside your skill/editorial change.
EOF
    exit 1
fi

echo "check-deck-fresh: deck is in sync"
