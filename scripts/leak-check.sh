#!/usr/bin/env bash
# leak-check.sh — refuse to commit/publish machine- or owner-specific data.
#
# This repo is public. Everything in it must work on a stranger's machine,
# so hard-coded personal defaults are treated as leaks, not conveniences.
#
# Usage:
#   scripts/leak-check.sh           # scan all tracked files
#   scripts/leak-check.sh --staged  # scan staged changes (pre-commit hook)
#
# A line can opt out with the marker: leak-allow (use sparingly, e.g. for
# documenting the placeholder patterns themselves).

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

MODE="${1:-all}"

# Each entry: <name>|<extended regex>
# Placeholders that are ALLOWED: +1555… numbers, /home/user, example.com,
# user@example.com.
PATTERNS=(
    'real-phone-number|\+1(?!555)[0-9]{9}'
    'home-path|/home/(?!user\b|\.local)[a-z][a-z0-9_-]+'
    'private-email|[a-zA-Z0-9._%+-]+@(gmail|yahoo|outlook|icloud|proton|hotmail)\.[a-z]+'
    'tailnet-host|[a-z0-9-]+\.ts\.net'
    'anthropic-key|sk-ant-[A-Za-z0-9_-]{8,}'
    'openai-key|sk-[A-Za-z0-9]{32,}'
    'github-token|gh[pousr]_[A-Za-z0-9]{20,}'
    'aws-key|AKIA[0-9A-Z]{16}'
    'slack-token|xox[baprs]-[A-Za-z0-9-]{10,}'
    'private-key|-----BEGIN[ A-Z]*PRIVATE KEY-----'
    'signal-uuid-pair|sourceUuid.{0,40}[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
)

if [[ "$MODE" == "--staged" ]]; then
    FILES=$(git diff --cached --name-only --diff-filter=ACM)
else
    FILES=$(git ls-files)
fi
[[ -n "$FILES" ]] || exit 0

FAIL=0
while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    # skip binaries
    file --mime "$f" 2>/dev/null | grep -q "charset=binary" && continue
    for entry in "${PATTERNS[@]}"; do
        name="${entry%%|*}"
        regex="${entry#*|}"
        hits=$(grep -nP "$regex" "$f" 2>/dev/null | grep -v "leak-allow" || true)
        if [[ -n "$hits" ]]; then
            FAIL=1
            while IFS= read -r h; do
                printf '\033[31mLEAK\033[0m [%s] %s:%s\n' "$name" "$f" "$h"
            done <<<"$hits"
        fi
    done
done <<<"$FILES"

if (( FAIL )); then
    cat >&2 <<'EOF'

Leak check FAILED. This repo is public: no real phone numbers, home paths,
personal emails, tailnet hostnames, or credentials may be committed.
Use placeholders (+1555…, /home/user, user@example.com) or move the value
to ~/.bopbop/env. To allowlist a documentation line, append: leak-allow
EOF
    exit 1
fi
echo "leak-check: clean"
