#!/usr/bin/env bash
# check-deck-complete.sh — stable shell entry point for the read-only deck gate.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

exec python3 "$SCRIPT_DIR/gen-deck-data.py" --check --root "$REPO_ROOT"
