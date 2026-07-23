#!/usr/bin/env bash
#
# sync-deck-mirror.sh — cascade the shipyard deck (docs/) to the wabbazzar.com
# "writing" mirror in the wabbazzar.github.io repo.
#
# The deck is published in two places:
#   * wabbazzar.com/shipyard/            — this repo, Pages main:/docs (served as-is)
#   * wabbazzar.com/writing/the-shipyard — a copy in wabbazzar.github.io
# This script keeps the second a deterministic copy of the first: it materializes
# docs/{index.html,styles.css,shipyard-data.json} FROM A COMMITTED SHA (default
# HEAD), applies the two destination-specific transforms to index.html, and
# commits+pushes ONLY the mirror's writing/the-shipyard/ paths.
#
# No-op unless a mirror dir is configured ([deck] mirror_dir in .agents/config.toml,
# or $DECK_MIRROR_DIR). See docs/tickets/deck-mirror-cascade.md.
#
# Exit codes:  0 = cascade pushed   2 = bad config/guard/safety   3 = no-op
set -uo pipefail

QUARTET_DIR="${QUARTET_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$QUARTET_DIR" || { echo "sync-deck-mirror: cannot cd to repo root" >&2; exit 2; }

SRC_SHA="${1:-HEAD}"

# --- resolve mirror dir: env override, else [deck] mirror_dir from config ------
MIRROR="${DECK_MIRROR_DIR:-}"
if [ -z "$MIRROR" ] && [ -f "$QUARTET_DIR/.agents/config.toml" ]; then
  # shellcheck source=/dev/null
  . "$QUARTET_DIR/agents/lib/load-config.sh"
  _cfg_json="$(load_config_json "$QUARTET_DIR/.agents/config.toml" 2>/dev/null)" || _cfg_json=""
  MIRROR="$(printf '%s' "$_cfg_json" | jq -r '.deck.mirror_dir // empty' 2>/dev/null)"
fi

# Unset/empty ⇒ deliberate no-op (a stranger cloned shipyard with no mirror).
if [ -z "$MIRROR" ]; then
  echo "sync-deck-mirror: no mirror configured ([deck] mirror_dir / \$DECK_MIRROR_DIR) — nothing to do" >&2
  exit 3
fi

DEST="$MIRROR/writing/the-shipyard"

# --- sanity: mirror is a git repo with the expected layout, on main -----------
if ! git -C "$MIRROR" rev-parse --git-dir >/dev/null 2>&1; then
  echo "sync-deck-mirror: mirror is not a git repo: $MIRROR" >&2; exit 2
fi
if [ ! -d "$DEST" ]; then
  echo "sync-deck-mirror: expected layout missing: $DEST" >&2; exit 2
fi
_mbranch="$(git -C "$MIRROR" branch --show-current 2>/dev/null || true)"
if [ "$_mbranch" != "main" ]; then
  echo "sync-deck-mirror: mirror not on main (on '${_mbranch:-detached}') — refusing to clobber" >&2; exit 2
fi

# --- safety: refuse if the mirror's deck dir already has uncommitted edits -----
# (a human may be mid-edit; we must not clobber their work). Check BEFORE writing.
if ! git -C "$MIRROR" diff --quiet -- writing/the-shipyard/ \
   || ! git -C "$MIRROR" diff --cached --quiet -- writing/the-shipyard/; then
  echo "sync-deck-mirror: mirror writing/the-shipyard/ has uncommitted edits — refusing to clobber" >&2
  exit 2
fi

# --- materialize the deck from the COMMITTED sha (not the working tree) --------
if ! git show "$SRC_SHA:docs/shipyard-data.json" > "$DEST/shipyard-data.json" 2>/dev/null; then
  echo "sync-deck-mirror: cannot read docs/shipyard-data.json at $SRC_SHA" >&2; exit 2
fi
if ! git show "$SRC_SHA:docs/styles.css" > "$DEST/styles.css" 2>/dev/null; then
  echo "sync-deck-mirror: cannot read docs/styles.css at $SRC_SHA" >&2; exit 2
fi

_tmp_index="$(mktemp)"
trap 'rm -f "$_tmp_index"' EXIT
if ! git show "$SRC_SHA:docs/index.html" > "$_tmp_index" 2>/dev/null; then
  echo "sync-deck-mirror: cannot read docs/index.html at $SRC_SHA" >&2; exit 2
fi

# Apply the two destination transforms as EXACT literal replacements (no regex),
# each of which must appear exactly once. A miss => the deck was restructured and
# the transform map is stale (exit 2).
if ! python3 - "$_tmp_index" "$DEST/index.html" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()
TRANSFORMS = [
    ('href="https://github.com/wabbazzar/shipyard">&larr; Repo',
     'href="/writing/">&larr; Writing'),
    ("const SOURCES = ['./shipyard-data.json'];",
     "const SOURCES = ['/shipyard/shipyard-data.json', './shipyard-data.json'];"),
]
for old, new in TRANSFORMS:
    n = s.count(old)
    if n != 1:
        sys.stderr.write("transform target found %d times (want 1): %r\n" % (n, old))
        sys.exit(3)
    s = s.replace(old, new)
open(dst, "w", encoding="utf-8").write(s)
PY
then
  echo "sync-deck-mirror: index.html transform failed (deck restructured? update the transform map)" >&2
  exit 2
fi

# --- determinism guard (D-6): dest index differs from source by EXACTLY 2 hunks
_d="$(diff <(git show "$SRC_SHA:docs/index.html") "$DEST/index.html" || true)"
_nlt="$(printf '%s\n' "$_d" | grep -c '^<')"
_ngt="$(printf '%s\n' "$_d" | grep -c '^>')"
if [ "$_nlt" -ne 2 ] || [ "$_ngt" -ne 2 ]; then
  echo "sync-deck-mirror: determinism guard failed (index diff is $_nlt/$_ngt lines, want 2/2)" >&2
  exit 2
fi

# --- idempotent: nothing changed ⇒ no empty deploy ----------------------------
if git -C "$MIRROR" diff --quiet -- writing/the-shipyard/; then
  echo "sync-deck-mirror: mirror already up to date — no deploy" >&2
  exit 3
fi

# --- commit ONLY the three deck paths (clean message, no attribution) ----------
_short="$(git rev-parse --short "$SRC_SHA")"
_paths=(writing/the-shipyard/index.html writing/the-shipyard/styles.css writing/the-shipyard/shipyard-data.json)
if ! git -C "$MIRROR" commit -m "the-shipyard: sync deck from shipyard@$_short" -- "${_paths[@]}"; then
  echo "sync-deck-mirror: commit FAILED — re-run: scripts/sync-deck-mirror.sh $SRC_SHA" >&2
  exit 2
fi
if ! git -C "$MIRROR" push; then
  echo "sync-deck-mirror: push FAILED (commit landed locally) — re-run push in $MIRROR, or: scripts/sync-deck-mirror.sh $SRC_SHA" >&2
  exit 2
fi

echo "sync-deck-mirror: cascaded deck shipyard@$_short -> $DEST and pushed" >&2
exit 0
