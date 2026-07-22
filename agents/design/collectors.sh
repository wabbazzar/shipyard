#!/bin/bash
# agents/design/collectors.sh — read-only telemetry collectors for the
# design loop (mentat). Gathers the signal a design proposal must cite.
#
# Usage:
#   collectors.sh --project <dir> [--json] [--days N]
#   source collectors.sh; collect_signals <project-dir> [days]   # -> JSON
#
# Sources (ALL read-only; each degrades gracefully when absent):
#   1. caddy access log via `journalctl --user -u caddy -o cat` — per-path
#      request counts for the project's domain, IF the domain is derivable
#      from a medic probe URL in the config; otherwise skipped.
#   2. the quartet event stream ($QUARTET_EVENTS_DIR, else
#      $QUARTET_DIR/data/events) — this project's job.end ok/fail counts,
#      medic incidents, and release.critique block/warn/note totals over
#      the last N days (default 7). Read with `jq -R 'fromjson?'` so a
#      corrupt line can never abort the scan.
#   3. <project>/data/fyi-requests.jsonl — user feedback lines.
#   4. <project>/data/usage/*.jsonl — pilot usage beacons, counted by
#      action and by path.
#   5. <project>/tmp/*incident*.json — open medic incident files modified
#      within the last N days (default 7, same window as source 2). Stale
#      files are excluded from the summary, never touched on disk (this
#      collector is read-only, see below).
#
# Emits a compact per-project signal summary: JSON with --json, else a
# human-readable digest. NEVER writes anything, anywhere.

set -uo pipefail

QUARTET_DIR="${QUARTET_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Event stream location. Mirrors the sibling default in
# agents/lib/log_event.sh: the hub sets QUARTET_EVENTS_DIR in the units;
# public-repo default falls back to this checkout's data/events. No
# personal path is baked in.
_design_events_dir() {
  printf '%s\n' "${QUARTET_EVENTS_DIR:-$QUARTET_DIR/data/events}"
}

# ---- helpers ---------------------------------------------------------------

# _read_events <events-dir> <days> — concatenate the last <days> daily
# JSONL files (today + preceding), corrupt-line-safe, as compact objects.
_read_events() {
  local dir="$1" days="${2:-7}" i d f
  [ -d "$dir" ] || return 0
  for ((i=0; i<days; i++)); do
    d="$(date -u -d "-$i day" +%Y-%m-%d 2>/dev/null)" || d=""
    [ -n "$d" ] || continue
    f="$dir/$d.jsonl"
    [ -f "$f" ] || continue
    jq -R 'fromjson?' <"$f" 2>/dev/null
  done
}

# _domain_from_config <cfg-json> — first host from a medic probe URL, or "".
_domain_from_config() {
  jq -r '
    ([.medic.probes[]?.url // empty] | map(select(. != ""))) as $u
    | if ($u | length) > 0
      then ($u[0] | sub("^https?://"; "") | sub("/.*$"; ""))
      else empty end
  ' <<<"$1" 2>/dev/null
}

# ---- the collector ---------------------------------------------------------

# collect_signals <project-dir> [days] — echo the signal summary as JSON.
collect_signals() {
  local project_dir="$1" days="${2:-7}"
  [ -d "$project_dir" ] || { echo "collect_signals: no such dir: $project_dir" >&2; return 2; }

  local cfg_json="{}" project_name
  if [ -f "$project_dir/.agents/config.toml" ]; then
    # shellcheck disable=SC1091
    source "$QUARTET_DIR/agents/lib/load-config.sh"
    cfg_json="$(load_config_json "$project_dir/.agents/config.toml" 2>/dev/null)" || cfg_json="{}"
  fi
  project_name="$(jq -r '.project_name // empty' <<<"$cfg_json")"
  [ -n "$project_name" ] || project_name="$(basename "$project_dir")"

  local events_dir; events_dir="$(_design_events_dir)"

  # --- (2) event stream -----------------------------------------------------
  # Match this project's events by svc prefix "<project>-" (display-name
  # agnostic) or an explicit .project field.
  local events events_summary
  events="$(_read_events "$events_dir" "$days" | \
    jq -c --arg p "$project_name" \
      'select((.svc // "" | startswith($p + "-")) or (.project // "") == $p)' \
      2>/dev/null || true)"
  events_summary="$(printf '%s\n' "$events" | jq -s '
    {
      job_ok:  [.[] | select(.event=="job.end" and (.status=="ok"))]      | length,
      job_fail:[.[] | select(.event=="job.end" and (.status=="fail" or .status=="abort"))] | length,
      medic_incidents: [.[] | select((.event // "") | startswith("medic."))
                             | select((.event // "") | contains("incident"))] | length,
      # Verbatim examples (mentat:aurora:d23e2f48): prefer the consolidated
      # medic.incident events (probe + http_status + restart_action), fall
      # back to any medic.*incident* event for pre-upgrade windows.
      medic_incident_examples:
        (([.[] | select((.event // "") == "medic.incident")] | .[-3:]) as $full
         | if ($full | length) > 0 then $full
           else ([.[] | select((.event // "") | startswith("medic."))
                      | select((.event // "") | contains("incident"))] | .[-3:])
           end),
      release_findings: {
        block: ([.[] | select(.event=="release.critique") | (.block // 0)] | add // 0),
        warn:  ([.[] | select(.event=="release.critique") | (.warn  // 0)] | add // 0),
        note:  ([.[] | select(.event=="release.critique") | (.note  // 0)] | add // 0)
      },
      examples: [.[] | select(.event | test("job.end|medic.|release.critique"))
                     | {ts, svc, event, status: (.status // null)}] | (sort_by(.ts) | reverse | .[0:5])
    }' 2>/dev/null || echo '{}')"

  # --- (3) fyi-requests.jsonl -----------------------------------------------
  local fyi_file="$project_dir/data/fyi-requests.jsonl" fyi_summary
  if [ -f "$fyi_file" ]; then
    fyi_summary="$(jq -R 'fromjson?' <"$fyi_file" 2>/dev/null | jq -s '
      { count: length,
        examples: [.[] | {ts: (.ts // null), text: (.text // "")}] | (reverse | .[0:5]) }' \
      2>/dev/null || echo '{"count":0,"examples":[]}')"
  else
    fyi_summary='{"count":0,"examples":[]}'
  fi

  # --- (4) usage beacons ----------------------------------------------------
  local usage_summary
  if compgen -G "$project_dir/data/usage/*.jsonl" >/dev/null 2>&1; then
    usage_summary="$(cat "$project_dir"/data/usage/*.jsonl 2>/dev/null | jq -R 'fromjson?' 2>/dev/null | jq -s '
      { count: length,
        by_action: (reduce .[] as $e ({}; .[$e.action // "unknown"] += 1)),
        by_path:   (reduce .[] as $e ({}; .[$e.path   // "unknown"] += 1)),
        examples:  [.[] | {ts:(.ts // null), action:(.action // null), path:(.path // null)}] | (reverse | .[0:5]) }' \
      2>/dev/null || echo '{"count":0,"by_action":{},"by_path":{},"examples":[]}')"
  else
    usage_summary='{"count":0,"by_action":{},"by_path":{},"examples":[]}'
  fi

  # --- (5) medic incident files under tmp/ ----------------------------------
  # Bounded by the same $days window as source 2 (mtime-based: simplest,
  # matches "open incident files" framing, no JSON parsing needed to filter).
  # Read-only — this only excludes stale files from the summary, it never
  # deletes/moves them (see file header: collectors.sh never writes).
  local incidents_summary incident_files=()
  if [ -d "$project_dir/tmp" ]; then
    while IFS= read -r f; do incident_files+=("$f"); done \
      < <(find "$project_dir/tmp" -maxdepth 1 -type f -name '*incident*.json' -mtime "-$days" 2>/dev/null | sort)
  fi
  if [ "${#incident_files[@]}" -gt 0 ]; then
    # Some incident files are a single object, others (…-current.json) a
    # JSON array. Coerce both, and `|| true` per file so a malformed one
    # can never make the loop exit non-zero — under `set -o pipefail`
    # that would splice the fallback onto the jq -s output and corrupt it.
    incidents_summary="$(for f in "${incident_files[@]}"; do
        jq -c --arg f "$(basename "$f")" \
          '(if type=="array" then .[] else . end)
           | {file:$f, incident_id:(.incident_id // null), reason:(.reason // .error // null)}' \
          "$f" 2>/dev/null || true
      done | jq -s '{count: length, examples: (.[0:5])}' 2>/dev/null)"
    [ -n "$incidents_summary" ] || incidents_summary='{"count":0,"examples":[]}'
  else
    incidents_summary='{"count":0,"examples":[]}'
  fi

  # --- (1) caddy access log (best-effort, domain-gated) ---------------------
  local caddy_summary domain=""
  domain="$(_domain_from_config "$cfg_json")"
  if command -v journalctl >/dev/null 2>&1 && [ -n "$domain" ]; then
    local caddy_raw
    caddy_raw="$(journalctl --user -u caddy -o cat --since "24 hours ago" 2>/dev/null || true)"
    if [ -n "$caddy_raw" ]; then
      caddy_summary="$(printf '%s\n' "$caddy_raw" | jq -R 'fromjson?' 2>/dev/null | jq -s --arg host "$domain" '
        [ .[] | select((.request.host // "") == $host) ] as $h
        | { available: true, domain: $host, requests: ($h | length),
            paths: (reduce $h[] as $e ({}; .[$e.request.uri // "/"] += 1)),
            examples: [ $h[] | {uri:(.request.uri // null), status:(.status // null)} ] | (.[0:5]) }' \
        2>/dev/null || echo "{\"available\":false,\"reason\":\"parse\"}")"
      # If nothing matched the host, still report available with zeroed counts.
      [ -n "$caddy_summary" ] || caddy_summary="{\"available\":true,\"domain\":\"$domain\",\"requests\":0,\"paths\":{},\"examples\":[]}"
    else
      caddy_summary='{"available":false,"reason":"no_caddy_journal"}'
    fi
  elif [ -z "$domain" ]; then
    caddy_summary='{"available":false,"reason":"no_domain_derivable"}'
  else
    caddy_summary='{"available":false,"reason":"journalctl_absent"}'
  fi

  # --- assemble -------------------------------------------------------------
  jq -n \
    --arg project "$project_name" \
    --argjson days "$days" \
    --argjson events "$events_summary" \
    --argjson caddy "$caddy_summary" \
    --argjson fyi "$fyi_summary" \
    --argjson usage "$usage_summary" \
    --argjson incidents "$incidents_summary" \
    '{ project:$project, window_days:$days,
       sources: { events:$events, caddy:$caddy, fyi:$fyi,
                  usage:$usage, medic_incidents:$incidents } }'
}

# ---- human-readable rendering ----------------------------------------------

_render_human() {
  local json="$1"
  jq -r '
    "project: \(.project)   window: \(.window_days)d",
    "  events:  job_ok=\(.sources.events.job_ok)  job_fail=\(.sources.events.job_fail)  medic_incidents=\(.sources.events.medic_incidents)  release(block/warn/note)=\(.sources.events.release_findings.block)/\(.sources.events.release_findings.warn)/\(.sources.events.release_findings.note)",
    ((.sources.events.medic_incident_examples // []) |
      if length > 0 then
        "  medic incident examples (verbatim, last \(length)):",
        (.[] | "    " + tojson)
      else empty end),
    "  fyi:     \(.sources.fyi.count) line(s)",
    "  usage:   \(.sources.usage.count) beacon(s)",
    "  incidents(tmp): \(.sources.medic_incidents.count) file(s)",
    (if .sources.caddy.available then "  caddy:   \(.sources.caddy.requests) req to \(.sources.caddy.domain)" else "  caddy:   n/a (\(.sources.caddy.reason))" end)
  ' <<<"$json"
}

# ---- CLI entrypoint (only when executed, not when sourced) -----------------

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  PROJECT_DIR=""
  AS_JSON=0
  DAYS=7
  while [ $# -gt 0 ]; do
    case "$1" in
      --project) PROJECT_DIR="$2"; shift 2 ;;
      --json)    AS_JSON=1; shift ;;
      --days)    DAYS="$2"; shift 2 ;;
      -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
      *)         echo "unknown arg: $1" >&2; exit 2 ;;
    esac
  done
  [ -z "$PROJECT_DIR" ] && { echo "--project required" >&2; exit 2; }
  [ -d "$PROJECT_DIR" ] || { echo "project dir missing: $PROJECT_DIR" >&2; exit 2; }

  SUMMARY="$(collect_signals "$PROJECT_DIR" "$DAYS")" || exit $?
  if [ "$AS_JSON" -eq 1 ]; then
    printf '%s\n' "$SUMMARY"
  else
    _render_human "$SUMMARY"
  fi
fi
