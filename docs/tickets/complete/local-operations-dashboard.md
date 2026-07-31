# Local operations dashboard — a quiet, machine-local view of Shipyard activity

- **Created:** 2026-07-29
- **Owner:** wabbazzar
- **Status:** built and verified
- **Priority:** medium
- **Type:** feature
- **Estimated Points:** 13 (five phases: 3 · 3 · 3 · 2 · 2)
- **Refs:** `agents/lib/log_event.sh`, `agents/lib/load-config.sh`,
  `agents/medic/runner.sh`, `skills/shipyard/shipyard.sh`, `install.sh`,
  `docs/INSTALL.md`, `.agents/gates.md`

## Summary

Add a lightweight, read-only Shipyard dashboard that turns the existing JSONL
event stream into a useful local operations view. It should run as a native
user service, open on loopback only, integrate with the deterministic
`shipyard` operator console, and retain Notification Center as the actionable
alert path; Slack or BopBop may fan out alerts later but must not become the
history store.

## Problem / Background

Shipyard already records the facts needed for an operations surface:

- `agents/lib/log_event.sh:24-28` resolves `QUARTET_EVENTS_DIR` and appends to a
  daily JSONL file.
- `agents/lib/log_event.sh:40-103` establishes the base event envelope and
  canonical `source`, `actor`, and `role` fields.
- `README.md:426-434` documents the current `job.*`, design, medic, and release
  event families and explicitly identifies the stream as dashboard input.
- `agents/medic/runner.sh:802-817` persists current incidents and emits a
  successful terminal event even when there is nothing to triage.
- `agents/lib/load-config.sh:43-125` already separates classified owner alerts
  from routine event history.

On this Mac those records are inspectable only through JSONL, result files, and
launchd logs. Actionable messages reach Notification Center, but there is no
at-a-glance history, fleet health summary, or dashboard state. Sending every
event to chat would create a noisy, lossy history and would make a remote
service the primary record of local automation.

The public deck at `docs/index.html` is a narrative/product surface, not this
machine's operational console. The new dashboard must remain a separate,
private runtime surface.

## Verified pre-build baseline (2026-07-31)

- The server event store is already substantial: approximately 400 MB, with
  280,737 JSONL rows across the latest seven daily files. The implementation
  must stream/index compact metadata and must not deserialize the full history
  into Python objects.
- This Mac's current event store is 8 KB (14 rows across two files), but all six
  loaded `com.shipyard.*` LaunchAgents bake the canonical checkout's
  `data/events` directory into `QUARTET_EVENTS_DIR`. Moving the default alone
  would split old and future history; migration requires an explicit service
  rebake.
- Python 3.12, Bats 1.10+, Node, Playwright, Chrome, and Firefox are available
  on the receiving server. The repository gate covers Bats, both shell syntax
  surfaces, Python compilation, leak checks, deck freshness/completeness/render,
  lifecycle checks, installer/doctor behavior, and GitHub CI.
- The prerequisite `macos-native-gate-parity` work is integrated on canonical
  `main`. Preflight from that tip plus the local macOS feedback repair passed
  676/676 native Apple Silicon Bats tests, both Bash syntax surfaces, Python
  compilation, leak, deck freshness/completeness, lifecycle, delegation, and
  diff gates. Deck render returned only its documented Playwright-unavailable
  skip in this checkout.
- Product default remains `127.0.0.1:8765`. This Mac's installed-service proof
  will use the machine-local override `127.0.0.1:8766` because another local
  service already owns port 8765; that process is outside this ticket and must
  not be stopped or changed.

## Decisions

| # | Decision | Locked default | Why |
|---|---|---|---|
| D-1 | Ownership | Shipyard owns the dashboard, but it is a deterministic service—not a new LLM role | Existing roles already emit the facts; another model would add cost and interpretation where a reader is sufficient. |
| D-2 | Source of truth | The append-only JSONL event stream is canonical | One event path preserves dashboard, CLI, and notification consistency. |
| D-3 | Machine-local storage | **Owner-selected 2026-07-30:** preserve each installed crew's currently baked `QUARTET_EVENTS_DIR` for the MVP; resolve `~/Library/Application Support/Shipyard/events/` only for a clean install with no explicit path | This keeps existing history continuous and avoids rebaking six live LaunchAgents. No migration is authorized by this ticket. |
| D-4 | Reach | Bind to `127.0.0.1` only, default port `8765` | This is an owner console, not a public service; remote/tailnet access requires a later explicit security decision. |
| D-5 | Runtime weight | Python standard library server plus plain HTML/CSS/JS; no database, framework, Node build, Docker, Grafana, or Loki in the MVP | Daily JSONL is directly streamable, but the measured 400 MB store requires compact indexes, bounded results, and lazy raw-line reads. |
| D-6 | Interaction authority | Read-only: inspect status, events, incidents, and known log locations; never trigger, restart, merge, or deploy | Observation should not create a second operational control plane. |
| D-7 | Operator entrypoint | Add a deterministic `shipyard dashboard` command and show dashboard health/URL in `shipyard status` | `skills/shipyard/shipyard.sh:1-14,67-119` is already the in-project operator console. |
| D-8 | Alerts | Keep Notification Center as the current actionable/urgent transport. Design a narrow adapter seam for Slack/BopBop, but do not implement remote delivery in the MVP | Chat is useful for attention, not durable history. |
| D-9 | History | Do not delete or rewrite event files. The UI defaults to seven days and allows bounded 24-hour/7-day/30-day views | Retention is a separate owner policy; a viewer must not silently destroy history. |
| D-10 | Platform shape | Dashboard reader and UI stay platform-neutral; native service installation supports launchd first and systemd user services through the same scheduler conventions | `install.sh:78-113,850-862` already defines Shipyard's cross-platform scheduler and baked-environment contract. |

### Owner decision recorded

Preserve the current baked path. The dashboard reads the exact
`QUARTET_EVENTS_DIR` already used by the six LaunchAgents. It must not move or
copy history, rebake those jobs, or reload them. Application Support is only the
fallback for a clean install with no explicit event path.

## UI direction

### Subject, audience, and job

- **Subject:** scheduled agent work, failures, incidents, and delivery history.
- **Audience:** the machine owner operating a small fleet of repositories.
- **Job:** answer “Is the fleet healthy, what changed, and what needs me?” in
  under ten seconds, then expose enough evidence to continue in the terminal.

**Design thesis:** A quiet ship's instrument panel: dense enough to trust,
calm when healthy, and visually decisive only when an event needs attention.

### Information hierarchy and layout

1. Fleet summary: healthy, running, stale, failed, and actionable counts plus
   the stream's latest timestamp.
2. Project × role matrix: last terminal state, duration, and last activity.
3. Actionable queue: unresolved or latest incident/critique evidence.
4. Chronological event rail with filters for project, role, event family,
   status, and time window.
5. Selected-event detail: complete normalized fields, raw JSON disclosure,
   and known result/log paths.

The primary action is **Inspect evidence**. There are no mutation controls.

The signature element is the **keel rail**: one horizontal chronological rail
whose role-colored pips make starts, completions, failures, and incident
lifecycles readable as a sequence without turning the page into a generic log
table.

### Visual system

Six named colors, each with one explicit job:

| Token | Value | Role |
|---|---|---|
| Hull | `#0B1118` | page surface |
| Bulkhead | `#16212D` | panels and selected rows |
| Chalk | `#E7EEF7` | primary text |
| Signal | `#5BC0EB` | focus, links, running state |
| Clear | `#3DDC97` | successful/healthy state |
| Alarm | `#FF6B6B` | failed/actionable state |

- **Display type:** system UI semibold for fleet and project summaries.
- **Body type:** system UI regular for readable operational copy.
- **Utility type:** `ui-monospace` for timestamps, service names, durations,
  event names, and JSON.
- Use a compact 4/8/12/16/24 spacing scale, 8px panel radii, one-pixel borders,
  and no decorative shadows.

### Responsive and interaction requirements

- Desktop proof viewport: `1440×900`; matrix, queue, and timeline can coexist.
- Narrow proof viewport: `390×844`; order becomes summary → actionable queue →
  project cards → timeline, with filters in a keyboard-accessible disclosure.
- Semantic headings, tables/lists where appropriate, complete keyboard path,
  visible focus, readable contrast, and `prefers-reduced-motion` support.
- Auto-refresh must preserve selection and scroll position; no flashing or
  celebratory motion on successful runs.
- Empty: “No Shipyard events in this time range.”
- Loading: “Reading the local event stream…”
- Stale: “No new event since <time>; inspect scheduler status.”
- Parse error: “One event line could not be read; earlier events remain
  available.”
- Disconnected stream: “Live updates paused; retrying locally.”

### Pre-build critique

- Reject a generic card-only admin template: chronology and role relationships
  are the core subject, so the keel rail must carry real information.
- Avoid a permanent sidebar, command palette, settings screen, charts without
  an operator question, and ornamental nautical styling.
- Do not make green health visually louder than the actionable queue.
- Remove aggregate token/cost charts from the MVP; they do not answer the
  immediate operational job.

## Technical Requirements

### Existing contracts to preserve

1. `agents/lib/log_event.sh` remains the only event writer. The dashboard is a
   reader and must tolerate unknown fields and new event families.
2. A partially written or malformed final JSONL line must not hide valid
   earlier events. Report the parse problem without rewriting the source file.
3. Canonical identity comes from `project`, `role`, and `svc`; display names
   must never replace the stable `role`.
4. Classified alert decisions remain governed by
   `agents/lib/load-config.sh:43-125`; dashboard rendering must not call the
   notification transport.
5. Event bodies are untrusted display data. Render with `textContent` or
   equivalent escaping, disallow inline script injection, and never interpret
   event content as HTML.
6. A newline-terminated invalid JSON row is a parse error. An unterminated final
   row is an in-progress append: retain earlier rows, omit the tail, and retry
   it on the next poll.
7. State derivation is deterministic:
   - `running`: a service's latest `job.start` has no later `job.end`;
   - `stale`: that unmatched start is older than
     `SHIPYARD_DASHBOARD_STALE_SEC` (default 7200);
   - `failed`: the latest terminal event has `status=fail`;
   - `healthy`: the latest terminal event has `status=ok`;
   - `actionable`: a failed terminal event, unresolved incident lifecycle, or
     delivered actionable/urgent notification decision remains in the selected
     window. Later matching resolution/dedup evidence suppresses the item.

### New runtime surface

- **New `dashboard/server.py`:**
  - Resolve events from CLI/configured `QUARTET_EVENTS_DIR`, then the
    owner-selected clean-install fallback. Print the resolved directory at
    startup and expose it in health output.
  - Bind to `127.0.0.1:${SHIPYARD_DASHBOARD_PORT:-8765}` by default.
  - Serve static assets and these read-only endpoints:
    - `GET /api/health`
    - `GET /api/summary`
    - `GET /api/events?window=&project=&role=&status=&event=&limit=`
    - `GET /api/stream` using server-sent events for newly appended lines.
  - Accept only `24h`, `7d`, or `30d` windows. Default `limit=500`, cap at
    2,000, reject repeated/unknown query keys, and return deterministic
    newest-first results with a stable `(ts, file, byte_offset)` tie-break.
  - Stream daily files once to build aggregates plus compact byte-offset
    references. Lazily reread raw rows for event detail; never retain all
    decoded event objects. A deterministic 300,000-row fixture must start
    within 10 seconds and remain below 256 MiB RSS on the receiving server.
  - Tail only the current UTC file for SSE, polling at 500 ms, sending a
    heartbeat every 15 seconds, and allowing at most eight clients. Reopen on
    rotation/truncation and release clients promptly.
  - Return explicit JSON error envelopes; health includes schema/build version,
    readiness, index row/error counts, event directory, latest timestamp, host,
    and port.
  - Validate `Host` as loopback/localhost, emit no CORS allowance, set
    `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`, and a
    restrictive CSP. Do not follow caller-selected paths or event-directory
    symlinks outside the resolved root.

- **New `dashboard/static/{index.html,styles.css,app.js}`:**
  - Implement the hierarchy and states above without a build step.
  - Preserve raw event fields in a collapsed evidence view.
  - Show known result and scheduler-log paths as copyable text; do not accept
    arbitrary filesystem paths from requests.

- **New `scripts/install-dashboard.sh`:**
  - Support `--install`, `--doctor`, `--uninstall`, and `--dry-run` for the one
    machine-level dashboard service.
  - Use native launchd on macOS and a user service on Linux.
  - Bake the event directory, loopback host, port, and log paths using the same
    explicit-environment model documented at `docs/INSTALL.md:21-34`.
  - Use label/unit `com.shipyard.dashboard` / `shipyard-dashboard.service`;
    write logs under the platform-local Shipyard log directory; make install
    and reinstall byte-stable; never match or mutate per-project jobs.

- **Extend `skills/shipyard/shipyard.sh`:**
  - `shipyard dashboard` prints the URL and health state. `--open` is the only
    path that calls `open`/`xdg-open`; headless/default calls are
    non-interactive.
  - `shipyard status` reports service loaded/running state, URL, event path,
    latest event timestamp, and a precise install command when absent.

- **Documentation:**
  - Distinguish the public deck from the private operations dashboard.
  - Document macOS Application Support and Logs locations, Linux XDG defaults,
    event-path rebaking, service lifecycle, loopback-only reach, and optional
    future alert fan-out.

## Implementation Plan

### Phase 1 — Bounded event reader and state model (3 pts)

Build a pure Python reader/model with compact byte-offset references,
deterministic aggregation, filtering, state derivation, rotation handling, and
lazy raw-row lookup. No socket or UI work enters this phase.

Files: new `dashboard/reader.py`, `dashboard/tests/test_reader.py`, synthetic
fixtures/generators, and this ticket's Ledger.

**Delegation: subagent (one bounded builder).** The orchestrator delegates this
isolated reader slice, then personally inspects the diff and reruns its gates.
The builder owns only the Phase 1 files and may assume the event schema and
state rules recorded above. Return ≤40 lines: files changed; reader/index
schema; commands plus exit codes and counts; 300,000-row elapsed time and peak
RSS; fixture checksums; evidence lines; blockers. Converge honestly or report
the precise blocker with the actual evidence — NEVER fake green, weaken a
check, or hand-wave "should work". Run the real command, read the real file,
curl the real port, and report exact output (exit codes, JSONL lines, HTTP
codes), not adjectives.

RED/GREEN proof:

```bash
python3 -m unittest -v dashboard.tests.test_reader
python3 dashboard/tests/benchmark_reader.py \
  --rows 300000 --max-seconds 10 --max-rss-mib 256
git diff --check
```

Observable DoD: empty, multi-day, unknown-field, invalid newline row,
unterminated tail, rotation, truncation, and concurrent append fixtures pass;
24h/7d/30d windows and 500/2,000 limits are exact; fixture source checksums are
unchanged.

### Phase 2 — Loopback HTTP API and bounded SSE (3 pts)

Add `dashboard/server.py` and endpoint behavior over the Phase 1 model. Pin
query rejection, headers, host validation, client cap, heartbeat, append,
rotation, disconnect cleanup, and JSON error envelopes.

Files: new `dashboard/server.py`, `dashboard/tests/test_server.py`, and Ledger.

**Delegation: subagent (one bounded builder).** The orchestrator delegates the
HTTP/SSE slice after Phase 1 is committed, then personally reviews it and
reruns its gates. The builder owns only the Phase 2 files and must use the
Phase 1 reader without weakening its bounds. Return ≤40 lines: files changed;
endpoint contract; commands plus exit codes/counts; listener, Host, header, and
SSE evidence lines; blockers. Converge honestly or report the precise blocker
with the actual evidence — NEVER fake green, weaken a check, or hand-wave
"should work". Run the real command, read the real file, curl the real port,
and report exact output (exit codes, JSONL lines, HTTP codes), not adjectives.

Focused and real-port proof:

```bash
python3 -m unittest -v dashboard.tests.test_reader dashboard.tests.test_server
tmp="$(mktemp -d)"
python3 dashboard/server.py --events-dir dashboard/tests/fixtures/live \
  --host 127.0.0.1 --port 0 --port-file "$tmp/port" >"$tmp/server.log" 2>&1 &
server_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  test -s "$tmp/port" && break
  sleep 0.2
done
port="$(cat "$tmp/port")"
curl --fail --silent --show-error \
  "http://127.0.0.1:$port/api/health" | jq -e \
  '.ready==true and .host=="127.0.0.1" and (.port|type)=="number"'
lsof -nP -a -p "$server_pid" -iTCP -sTCP:LISTEN |
  grep -F "127.0.0.1:$port"
kill "$server_pid"
wait "$server_pid" || test "$?" -eq 143
```

The builder records the resolved port, HTTP status, health JSON, listener row,
and process exit. Any wildcard/LAN listener, non-loopback Host acceptance,
source mutation, or ninth SSE client is RED.

### Phase 3 — Operational UI and rendered proof (3 pts)

Implement the recorded hierarchy, matrix, actionable queue, keel rail,
filters, exact states/copy, safe raw evidence disclosure, and stable SSE
refresh behavior in build-free static assets.

Files: new `dashboard/static/index.html`, `styles.css`, `app.js`,
`dashboard/tests/browser.mjs`, browser fixtures, and Ledger.

**Delegation: subagent (one UI builder using the `ui-design` contract).** The
orchestrator delegates the static UI after the served API is committed, then
personally opens both screenshots and reruns the browser assertions. The
builder owns only the Phase 3 files and uses the recorded thesis, hierarchy,
tokens, states, and viewports. Return ≤40 lines plus screenshot paths: files
changed; commands plus exit codes; interaction/accessibility findings; network
request origins; viewport/overflow results; exact evidence lines; blockers.
Converge honestly or report the precise blocker with the actual evidence —
NEVER fake green, weaken a check, or hand-wave "should work". Run the real
command, read the real file, curl the real port, and report exact output (exit
codes, JSONL lines, HTTP codes), not adjectives.

Rendered proof:

```bash
python3 -m unittest -v dashboard.tests.test_reader dashboard.tests.test_server
node dashboard/tests/browser.mjs --browser chromium \
  --viewport 1440x900 --screenshot-dir "$TMPDIR/shipyard-dashboard-wide"
node dashboard/tests/browser.mjs --browser chromium \
  --viewport 390x844 --screenshot-dir "$TMPDIR/shipyard-dashboard-narrow"
```

Inspect both screenshots, not only test output. Browser assertions cover exact
empty/loading/stale/parse/disconnected copy, semantic/keyboard path, visible
focus, contrast, no horizontal overflow, reduced motion, hostile HTML rendered
inertly, preserved selection/scroll after append, and zero request origins
outside the loopback server.

### Phase 4 — Native service installer (2 pts)

Add the idempotent dashboard installer/doctor/uninstaller for launchd and
systemd without touching project crew jobs. Implement only the owner-selected
D-3 path behavior.

Files: new `scripts/install-dashboard.sh`, `tests/dashboard-install.bats`,
platform manifest fixtures, and Ledger.

**Delegation: subagent (one installer builder).** The orchestrator delegates
the hermetic installer slice after D-3 is selected, then personally inspects
the rendered manifests and reruns both Bash parsers and Bats. The builder owns
only the Phase 4 files and must not load, unload, or rewrite real services.
Return ≤40 lines: files changed; commands plus exit codes/counts; manifest
labels/paths; first-install/reinstall checksums; doctor/uninstall evidence;
untouched crew-job checksums; blockers. Converge honestly or report the
precise blocker with the actual evidence — NEVER fake green, weaken a check,
or hand-wave "should work". Run the real command, read the real file, curl the
real port, and report exact output (exit codes, JSONL lines, HTTP codes), not
adjectives.

Proof:

```bash
bats tests/dashboard-install.bats
/bin/bash -n scripts/install-dashboard.sh
bash -n scripts/install-dashboard.sh
git diff --check
```

Observable DoD: dry-run writes nothing; install/reinstall are byte-stable;
doctor detects stopped, wrong-host, wrong-port, wrong-event-dir, and stale
asset/version drift; uninstall removes only the dashboard service and leaves
events/logs plus every project job intact.

### Phase 5 — Operator console, docs, real smoke, and graduation (2 pts)

Wire `shipyard dashboard`/`status`, update operator/install docs, run the full
gate, perform one explicit real Mac service smoke, and graduate the ticket in
the phase commit.

Files: `skills/shipyard/{SKILL.md,shipyard.sh}`, `README.md`,
`docs/INSTALL.md`, `tests/dashboard.bats`, generated deck data when required,
and this ticket.

**Delegation: inline (lead integration).** This final cross-surface slice owns
the only permitted real-service mutation, CLI/docs integration, graduation,
and the whole-tree gate, so the orchestrator must retain rollback and
verify-before-commit context. It personally records every command, exit code,
HTTP response, event line, service PID/listener, and cleanup result. Converge
honestly or report the precise blocker with the actual evidence — NEVER fake
green, weaken a check, or hand-wave "should work". Run the real command, read
the real file, curl the real port, and report exact output (exit codes, JSONL
lines, HTTP codes), not adjectives.

Focused proof:

```bash
bats tests/dashboard.bats tests/dashboard-install.bats
skills/shipyard/shipyard.sh dashboard
skills/shipyard/shipyard.sh status
```

Real smoke (owner-selected event path, explicit mutation):

```bash
scripts/install-dashboard.sh --install
scripts/install-dashboard.sh --doctor
url="$(skills/shipyard/shipyard.sh dashboard | sed -n 's/^url=//p')"
curl --fail --silent --show-error "$url/api/health" | jq -e '.ready==true'
QUARTET_EVENTS_DIR="<resolved configured event dir>" \
  agents/lib/log_event.sh dashboard-smoke dashboard.smoke \
  project=shipyard role=dashboard status=ok tokens=0
curl --fail --silent --show-error \
  "$url/api/events?window=24h&project=shipyard&role=dashboard&limit=10" |
  jq -e 'any(.events[]; .event=="dashboard.smoke" and .status=="ok")'
```

Record the service label, PID, loopback listener, HTTP codes, exact event row,
and UI update. Do not claim the smoke from fixture-only evidence.

## Testing Strategy

- Add hermetic API coverage for empty and multi-day streams, typed values,
  filters, bounded limits, malformed/partial final lines, unknown fields, and
  concurrent append while SSE is connected.
- Add `tests/dashboard.bats` for loopback binding, health/summary/event
  endpoints, `shipyard status`, absent-service guidance, and process cleanup.
  Add `tests/dashboard-install.bats` for installer byte stability,
  launchd/systemd manifests, doctor failures, and uninstall leave-behinds.
- Add browser coverage for the real served UI at `1440×900` and `390×844`;
  inspect the named states, keyboard path, focus, contrast, overflow, reduced
  motion, raw-field escaping, and auto-refresh selection stability.
- Run the existing full Bats suite, shell syntax checks, Python byte-compilation,
  leak check, and Shipyard skill/deck completeness/freshness gates.
- Run one real macOS smoke with the service loaded, a synthetic event appended
  through `agents/lib/log_event.sh`, the UI visibly updated, and no external
  network request observed.

## Final Gate — run before each phase commit as applicable, then end-to-end

New files must be intent-to-add or staged before `leak-check.sh`; otherwise its
tracked-file scan is vacuous. Phase commits run their focused commands plus the
public-repo, delegation, lifecycle, and diff gates. Phase 5 runs this complete
battery from a clean process baseline:

```bash
python3 -m unittest -v dashboard.tests.test_reader dashboard.tests.test_server
python3 dashboard/tests/benchmark_reader.py \
  --rows 300000 --max-seconds 10 --max-rss-mib 256
bats tests/dashboard.bats tests/dashboard-install.bats
bats tests/

/bin/bash -n install.sh agents/lib/*.sh agents/*/runner.sh \
  agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit
bash -n install.sh agents/lib/*.sh agents/*/runner.sh \
  agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit
python3 -m py_compile scripts/gen-deck-data.py dashboard/*.py dashboard/tests/*.py

bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bash scripts/check-deck-complete.sh
node scripts/check-deck-render.mjs
bash scripts/ticket-lifecycle.sh --check
python3 scripts/delegation-report.py
git diff --check
```

On Apple Silicon, also prove the complete suite through the exact interpreter
used by launchd:

```bash
native_shim="$(mktemp -d)"
ln -s /bin/bash "$native_shim/bash"
arch -arm64 env PATH="$native_shim:$PATH" \
  /opt/homebrew/bin/bats tests/
unlink "$native_shim/bash"
rmdir "$native_shim"
```

The browser gate starts the real loopback server and runs both declared
viewports. Capture the pre-run headless browser PIDs, require the harness to
close its own browser in `finally`, then prove the post-run PID set is
identical; do not kill unrelated pre-existing processes. Inspect both rendered
screenshots. The Phase 2 listener proof and the Phase 5 installed-service smoke
are mandatory because `.agents/gates.md` predates this service and currently
labels the served-app class “APPLIES: no.”

`check-deck-render.mjs` exit 3 is the gate's documented Playwright-unavailable
skip only when the runtime is genuinely absent; the dedicated dashboard browser
gate may not skip. Record test counts, benchmark time/RSS, resolved port,
listener row, HTTP codes/headers, screenshots, service PID, emitted JSONL line,
and cleanup evidence in the Ledger.

## Acceptance Criteria / Definition of Done

- [x] A native user service serves the dashboard at its configured loopback
      URL and survives terminal/session closure. The product default remains
      `http://127.0.0.1:8765`; this host's owner-selected smoke used `8766`
      because an unrelated process already owned `8765`.
- [x] D-3 is explicitly selected and recorded; install/upgrade behavior must
      use exactly that path policy without silently splitting event history.
- [x] The service reads the configured append-only event directory without
      modifying, relocating, or deleting event files.
- [x] A deterministic 300,000-row fixture indexes within 10 seconds and below
      256 MiB peak RSS on the receiving server; queries retain at most 2,000
      decoded result rows and raw detail is loaded lazily.
- [x] Fleet summary reports healthy/running/stale/failed/actionable counts and
      the latest event timestamp from synthetic and real local streams, using
      the exact deterministic state rules in Technical Requirements.
- [x] Project × role state uses canonical `project`/`role` identity and shows
      last terminal status, duration, and activity.
- [x] Timeline filters work for time window, project, role, event family, and
      status, with exact 24h/7d/30d windows, default/max limits of 500/2,000,
      rejection of unknown/repeated query keys, and deterministic ordering.
- [x] SSE updates the page after a new JSONL append without a full reload,
      losing selection, or moving the operator's scroll position; rotation,
      truncation, disconnect cleanup, 15-second heartbeats, and the eight-client
      cap are verified.
- [x] Empty, loading, stale, malformed-line, and disconnected-stream states use
      the exact actionable copy recorded in this ticket.
- [x] Malformed or partially written final lines never hide earlier valid
      events and never crash the server.
- [x] Event-provided HTML/script text renders inertly; no endpoint permits
      arbitrary filesystem reads.
- [x] The UI matches the recorded hierarchy and visual system at `1440×900`
      and `390×844`, with keyboard access, visible focus, readable contrast,
      no overflow, and reduced-motion behavior verified.
- [x] `scripts/install-dashboard.sh` is idempotent, supports native launchd and
      systemd user services, and leaves per-project scheduler jobs untouched.
- [x] `shipyard status` reports dashboard health/URL/event path/latest event,
      while `shipyard dashboard` provides the deterministic operator entrypoint.
- [x] `lsof` proves the listener is `127.0.0.1` only; non-loopback `Host`
      values are rejected, no CORS allowance is emitted, and no-store, nosniff,
      and restrictive CSP headers are present.
- [x] No dashboard or event content leaves the machine, including during both
      browser proofs.
- [x] Notification Center remains the actionable/urgent alert transport; no
      routine event flood is introduced.
- [x] README and install docs distinguish the public deck, private dashboard,
      event store, service logs, and future Slack/BopBop alert adapters.
- [x] Full repository gates are green, and a real macOS smoke visibly advances
      the dashboard after a synthetic Shipyard event.

## Dependencies

- Resolved 2026-07-31: `macos-native-gate-parity` is canonicalized on `main`;
  Phase 1 started only after the latest tip passed the native macOS baseline
  and repository gates recorded above.
- External services: none for the MVP.
- Enables: an optional follow-up for BopBop/Slack actionable-alert fan-out and
  later multi-machine aggregation.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Event content injects markup or script | Treat every event field as text, apply a restrictive CSP, and cover hostile fixtures in browser tests. |
| Concurrent append exposes a partial final line | Ignore/retry only the incomplete tail while retaining all earlier valid records. |
| Long history makes initial reads slow | Default to seven days, enforce query limits, and maintain a bounded in-memory index; do not add a database preemptively. |
| Dashboard looks healthy while launchd is dead | Show latest-event age and a stale state; include native service state in `shipyard status`. |
| A local server becomes remotely reachable | Bind loopback explicitly and test that no wildcard/LAN listener exists. |
| Plain static assets become stale after an upgrade | Expose build/version identity in `/api/health`, restart through the installer, and verify the served asset version in the real smoke. |
| Personal paths leak into the public repository | Resolve platform defaults at runtime and keep machine-specific overrides in environment/service configuration; retain leak-check coverage. |
| Chat fan-out becomes a second source of truth | Keep all remote transports downstream of classified notifications and document JSONL as canonical. |

## Out of scope

- A new dashboard/observer LLM agent or any scheduled model invocation.
- Triggering jobs, restarting services, merging PRs, deploying, or editing
  configuration from the GUI.
- Public internet, LAN, or tailnet exposure; authentication and multi-user
  authorization.
- Full Slack, BopBop, Signal, or webhook implementation.
- Multi-machine event aggregation or cloud storage.
- Grafana, Loki, Prometheus, OpenTelemetry, Docker, or a persistent database.
- Replacing the public Shipyard deck or embedding private runtime data in it.
- Automatic retention/deletion policy.

## Ledger

Before each phase, append the exact slice plan. After it, record the builder
line, commit hash, RED/GREEN commands and exit codes/counts, objective evidence,
cleanup, and honest deferrals. Never record a personal path, private email,
secret, or raw session identifier.

Owner decision: preserve existing installations' baked event directories;
Application Support is a clean-install fallback only. Recorded 2026-07-30.

| Phase | Plan | Builder | Commit | Evidence / notes |
|---|---|---|---|---|
| 1 — bounded reader/model | Add only the pure Python reader, reader tests, deterministic synthetic fixture generator, and 300k benchmark. Stream daily JSONL once into compact `(ts, file, byte_offset)` references; retain bounded normalized metadata for filtering/state; lazily reread raw rows; pin empty/multi-day/unknown-field/invalid-row/unterminated-tail/rotation/truncation/concurrent-append behavior; prove exact windows and limits plus source checksums. No socket, UI, installer, console, or docs implementation. | builder: subagent (1 agent) | `82d51dc` | Preflight repair `b661bdc`; 676/676 native Bats. Builder GREEN: reader 17/17, 300k in 3.036s / 112.9 MiB. Orchestrator GREEN: reader 17/17; default Python benchmark 3.055s / 121.7 MiB; system Python benchmark 3.684s / 108.6 MiB; 2,000 results; SHA-256 `a8f54709b7c6a398f7c0e50c64fabd3614fdbef3c6051f59f775e020d252f19d` unchanged. Python compile, leak, deck freshness/completeness, lifecycle, delegation, and diff gates rc=0. Rotation/truncation stale generations, concurrent append deferral, exact windows/limits, project-scoped incident/episode matching, episode-less delivery, and source immutability covered. No socket/UI/installer work entered the slice. |
| 2 — loopback API/SSE | Add only the standard-library server, server tests, and deterministic live fixture. Resolve an explicit/configured event directory without caller-selected file reads; expose health/summary/events plus current-UTC-file SSE; strictly validate one-value query keys, windows, filters, and 1..2,000 limit; enforce loopback Host, loopback bind, JSON errors, no-store/nosniff/CSP and no CORS; cap SSE at eight, poll at 500 ms, heartbeat at 15 s, recover rotation/truncation, and release disconnects. Prove real port 0 listener/health/headers/Host/SSE behavior. No static UI, installer, console, or docs implementation. | builder: subagent (1 agent) | `308f1ed` | Phase 1 committed locally as `82d51dc`. Builder GREEN: 33/33 focused tests; real loopback listener and health/Host checks passed. Orchestrator hardened non-standard JSON constants, lone-surrogate serialization, and event-store failure envelopes, then passed 36/36 tests on default and system Python (0.643s/0.884s) plus Python compile. The 300k gate remained GREEN at 3.598s/125.3 MiB and 4.475s/113.9 MiB, 2,000 results, fixture SHA-256 `a8f54709b7c6a398f7c0e50c64fabd3614fdbef3c6051f59f775e020d252f19d` unchanged. Deterministic live fixture SHA-256: `70f12debc0a27ca99fb7a88461c5f69026e420ea5f09abc16dba0157aa8005cb`. Final real listener proof used ephemeral `127.0.0.1:60893`: health 200/ready with 2 rows and 0 errors; bad Host 400; no-store/nosniff/restrictive CSP and no CORS; exit 143; temporary files and listener removed. Leak, deck freshness/completeness, lifecycle, delegation, and diff gates rc=0. Existing port 8765 process was untouched; 8766 remained free for the installed-service phase. No UI/installer/console implementation entered the slice. |
| 3 — operational UI | Add only build-free `dashboard/static/index.html`, `styles.css`, `app.js`, a deterministic browser fixture/harness, and Ledger evidence. Implement the recorded quiet instrument-panel hierarchy: fleet summary, actionable queue, project × role matrix/cards, keel rail, bounded filters, selected-event evidence, and exact loading/empty/stale/parse/disconnected copy. Render untrusted fields with text-only DOM APIs; preserve selection and scroll across same-origin SSE refresh; provide semantic headings/table/list/disclosure structure, complete keyboard path, visible focus, reduced motion, contrast, and no horizontal overflow at 1440×900 and 390×844. Inspect both screenshots and remove one nonessential accessory after critique. Do not add installer, console, docs, dependencies, remote calls, or mutation controls. | builder: subagent (1 agent using `ui-design`) | `7868c6d` | Phase 2 committed locally as `308f1ed`. Builder GREEN: reader/API 36/36; mandatory dependency-free CDP browser proof at both declared viewports; JavaScript syntax/diff clean. Orchestrator GREEN: 36/36 on default and system Python (0.672s/0.894s), Python/JavaScript compile, and fresh real browser proofs on ephemeral loopback ports 64377/64388. Wide 1440×900: table and coexisting panels visible, filters open, no overflow. Narrow 390×844: actionable queue precedes project cards, table hidden, filters keyboard-expandable, no overflow. Exact loading/empty/stale/parse/disconnected copy passed; skip link, event selection, raw evidence, focus outline 3px, semantic structure, and reduced motion passed. Contrast minima exceeded 4.5:1 (Alarm/Hull lowest at 6.83:1). Hostile HTML remained inert; known result/scheduler paths remained copyable text; mutation controls and external request origins were zero. SSE advanced 6→7 events with selected evidence unchanged and scroll 300→300; filtered actionable evidence clears false rail highlights. Deterministic browser seed SHA-256 `f7d214756d1ed61de6c628bc0de6849d5a6e47c2231b6b7555cf882775c266fa`. Both orchestrator screenshots were visually inspected: hierarchy, wide balance, narrow composition, and the keel rail matched the thesis. The `ui-design` critique removed the nonessential build badge and retained the rail as the sole signature element. Browser/server processes and fixtures cleaned; 8765/8766 untouched. Leak, deck freshness/completeness, lifecycle, delegation, and diff gates rc=0. No installer/console/docs implementation entered the slice. |
| 4 — native installer | Add only `scripts/install-dashboard.sh`, hermetic `tests/dashboard-install.bats`, deterministic launchd/systemd manifest fixtures if needed, and Ledger evidence. Implement `--install`, `--doctor`, `--uninstall`, and `--dry-run` for only `com.shipyard.dashboard` / `shipyard-dashboard.service`; render loopback host, selected port, dashboard source/assets, owner-selected event directory, and platform-local logs with byte-stable reinstall output. Preserve any explicitly configured/baked event path and use Application Support/XDG only for clean fallback; never migrate history or inspect/mutate per-project jobs. Provide test-only path/command seams so macOS/Linux install, loaded/stopped state, wrong host/port/event directory, asset/version drift, uninstall leave-behinds, symlink refusal, modes, and first/reinstall checksums are proven without touching a real service. Parse under system and modern Bash. Do not load/unload a real service, bind a port, edit console/docs, or route remotely. | builder: subagent (1 installer builder) | `4d792f9` | Phase 3 committed locally as `7868c6d`. Builder GREEN: native Apple Bash 14/14; system/modern Bash syntax and diff checks rc=0. Systemd first/reinstall checksum `2891549776:1611` remained identical; launchd `3563540378:2199` remained identical; manifests are mode 0644 and bake only `127.0.0.1`, selected port, preserved event root, local logs, exact source/assets, build version, and deterministic runtime digest. D-3 precedence is explicit CLI/environment → matching crew manifests → existing dashboard manifest → clean Application Support/XDG fallback; ambiguous fleet roots require owner selection. Doctor classifies stopped, wrong host/port/event directory, and stale asset/version drift. Dry-run made no writes or scheduler calls. Uninstall preserved byte-identical crew units, event rows, and logs. Orchestrator hardened portable mode inspection, exact runtime digest inputs, decimal port normalization, scheduler command preflight, and exact-service uninstall after event/log roots move or become symlinks; fresh native 14/14 and both Bash syntax checks remained GREEN. Leak, deck freshness/completeness, lifecycle, delegation, and diff gates rc=0. No manifest fixtures were needed; plist parsing and systemd content are asserted directly. No real scheduler command, listener, event migration, console/docs edit, or remote action occurred; 8765 remained untouched and 8766 free. |
| 5 — console/docs/live final | Extend only the deterministic `shipyard` skill/core, focused dashboard console tests, README/install docs, generated deck metadata required by the skill change, and this Ledger/ticket lifecycle. `shipyard dashboard` reports stable URL/health fields and opens a browser only with explicit `--open`; `shipyard status` adds loaded/running state, URL, event root, latest timestamp, and an exact install command when absent without changing existing crew semantics. Document the public-deck/private-dashboard boundary, macOS/Linux event and log defaults, D-3 preservation/rebake behavior, loopback-only reach, lifecycle commands, and future classified-alert adapters. Run focused console/installer/API/browser proofs, the complete native repository battery, then install the real macOS service at owner-selected `127.0.0.1:8766` against the currently baked crew event root, run doctor/status/health, append one canonical `dashboard.smoke` row through `log_event.sh`, prove API and rendered UI advance, and leave the intended service running while cleaning only proof processes/files. Record exact evidence, mark completed criteria, set status built/verified, and graduate the ticket. Do not touch 8765, delete/rewrite history, send notifications, call external origins, or route remotely. | builder: inline (orchestrator retains real mutation and cross-surface integration) | `c02d454` | Phase 4 committed locally as `4d792f9`. Console/docs GREEN: focused native installer/dashboard/status 30/30; default and system Python 36/36; both Bash parsers, Python/JavaScript compile, and diff checks rc=0. A live macOS preflight found the service absent and `8766` free while unrelated PID 10576 retained `8765`. The first real install exposed two launchd-only gaps: bootstrap did not spawn until kickstart, and `grep -q` under pipefail misread a running job; explicit kickstart plus a launchd console regression fixed both, with focused and complete tests green afterward. The final native repository battery passed 698/698. Reader benchmark: 300,000 rows, 2,000 retained results, 3.702s / 121.8 MiB, SHA-256 `a8f54709b7c6a398f7c0e50c64fabd3614fdbef3c6051f59f775e020d252f19d` unchanged. Fresh browser proofs passed at 1440×900 and 390×844 on ephemeral loopback ports 50760/50759; both screenshots were visually inspected, same-origin-only traffic and SSE 6→7 were proven, and processes/fixtures were cleaned. Real deck render, leak, deck freshness/completeness, lifecycle, delegation, and diff gates passed. Live service proof: `com.shipyard.dashboard`, PID 14243 with PPID 1, exactly `127.0.0.1:8766`, doctor clean, console loaded/running/ready, health 200 with 25 rows / 0 errors / build `0.1.0`, hostile Host 400, no-store/nosniff/restrictive CSP, and no CORS. Canonical helper append changed the daily stream from 10→11 lines and emitted `{"ts":"2026-07-31T15:47:52Z","svc":"dashboard-smoke","event":"dashboard.smoke","project":"shipyard","role":"dashboard","status":"ok","tokens":0,"source":"agent"}`; the filtered API returned exactly one match and the installed UI visibly rendered the selected event using only its own origin. Proof browsers, captures, and interrupted-suite shim were removed; the intended service remains running, event history remains append-only, PID 10576 on `8765` was untouched, no notification fired, and no remote/push/tunnel action occurred. |

Run this ticket with the `execute-ticket` skill after the prerequisite
integration is resolved.
