#!/bin/bash
# agents/release/critic-note.sh — the crew's GENERIC, shipped shoulder-mode
# delivery command. critic-watch.sh calls "$CLAUDE_NOTE_CMD <session> <summary>";
# install.sh bakes CLAUDE_NOTE_CMD to point here (per harness) so no operator
# has to hand-write a note command.
#
# It reads every path/target from ENV — NEVER a baked path (this repo is
# public; leak-check enforces it). Unset config ⇒ the watcher never calls us
# (CLAUDE_NOTE_CMD stays unset ⇒ log-and-skip), so being called at all means
# some delivery is configured.
#
# Usage:  critic-note.sh [--harness claude|codex|hermes] <session> <message>
#   harness also via $CRITIC_NOTE_HARNESS (default: claude).
#
# Delivery precedence, per harness:
#   1. $CRITIC_NOTE_DELIVER_CMD (a session-injector) — authoritative. We exec it
#      and PASS ITS EXIT CODE THROUGH, so the watcher's load-bearing contract
#      still holds: 0=delivered, 2=ambiguous target, 3=session at a prompt
#      (both keep the queue), other=broken (retry ×3 then give up).
#   2. harness-native channel (hermes: `hermes send`) when available.
#   3. $QUARTET_NOTIFY_CMD owner alert (the human still sees the finding).
#   4. log-and-skip to stderr, exit 0.
# Fallbacks 2–4 return 0 (delivered somewhere the human reads) so the queue
# clears; only a configured injector (1) can signal keep-the-queue via 2/3.

set -u

HARNESS="${CRITIC_NOTE_HARNESS:-claude}"
while [ $# -gt 0 ]; do
  case "$1" in
    --harness) HARNESS="${2:-claude}"; shift 2 ;;
    --) shift; break ;;
    -*) printf 'critic-note: unknown arg %s\n' "$1" >&2; exit 2 ;;
    *) break ;;
  esac
done

SESSION="${1:-}"
MESSAGE="${2:-}"
[ -n "$SESSION" ] || { printf 'critic-note: missing <session>\n' >&2; exit 2; }

# 1. Configured session-injector — authoritative, exit-code passthrough.
if [ -n "${CRITIC_NOTE_DELIVER_CMD:-}" ]; then
  # shellcheck disable=SC2086 — word-splitting the configured command is intentional
  $CRITIC_NOTE_DELIVER_CMD "$SESSION" "$MESSAGE"
  exit $?
fi

# 2. harness-native channel.
case "$HARNESS" in
  hermes)
    if command -v hermes >/dev/null 2>&1 && [ -n "${CRITIC_NOTE_TARGET:-}" ]; then
      if printf '%s' "$MESSAGE" | hermes send -t "$CRITIC_NOTE_TARGET" -q 2>/dev/null; then
        exit 0
      fi
    fi
    ;;
  codex|claude)
    : # no generic in-session inject channel — fall through to owner alert
    ;;
esac

# 3. owner alert fallback — the human still sees the critique.
if [ -n "${QUARTET_NOTIFY_CMD:-}" ]; then
  # shellcheck disable=SC2086
  $QUARTET_NOTIFY_CMD "release critic ($HARNESS)" "$MESSAGE" >/dev/null 2>&1 && exit 0
fi

# 4. nothing configured — log and skip (queue clears; do not spin the watcher).
printf 'critic-note: no delivery channel for harness=%s session=%s; skipping\n' \
  "$HARNESS" "$SESSION" >&2
exit 0
