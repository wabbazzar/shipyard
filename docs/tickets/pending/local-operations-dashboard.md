# Local operations dashboard — a quiet, machine-local view of Shipyard activity

- **Status:** pending — draft ready for polish
- **Priority:** medium
- **Type:** feature
- **Estimated Points:** 13 (P1 5 · P2 5 · P3 3)

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

## Decisions (default-and-record — veto at review)

| # | Decision | Locked default | Why |
|---|---|---|---|
| D-1 | Ownership | Shipyard owns the dashboard, but it is a deterministic service—not a new LLM role | Existing roles already emit the facts; another model would add cost and interpretation where a reader is sufficient. |
| D-2 | Source of truth | The append-only JSONL event stream is canonical | One event path preserves dashboard, CLI, and notification consistency. |
| D-3 | Machine-local storage | On macOS, configure events under `~/Library/Application Support/Shipyard/events/`; retain explicit `QUARTET_EVENTS_DIR` override and avoid baking a personal absolute path into tracked code | Operational state should survive checkout cleanup without entering Git. |
| D-4 | Reach | Bind to `127.0.0.1` only, default port `8765` | This is an owner console, not a public service; remote/tailnet access requires a later explicit security decision. |
| D-5 | Runtime weight | Python standard library server plus plain HTML/CSS/JS; no database, framework, Node build, Docker, Grafana, or Loki in the MVP | Current volume is tiny and daily JSONL is already queryable. |
| D-6 | Interaction authority | Read-only: inspect status, events, incidents, and known log locations; never trigger, restart, merge, or deploy | Observation should not create a second operational control plane. |
| D-7 | Operator entrypoint | Add a deterministic `shipyard dashboard` command and show dashboard health/URL in `shipyard status` | `skills/shipyard/shipyard.sh:1-14,67-119` is already the in-project operator console. |
| D-8 | Alerts | Keep Notification Center as the current actionable/urgent transport. Design a narrow adapter seam for Slack/BopBop, but do not implement remote delivery in the MVP | Chat is useful for attention, not durable history. |
| D-9 | History | Do not delete or rewrite event files. The UI defaults to seven days and allows bounded 24-hour/7-day/30-day views | Retention is a separate owner policy; a viewer must not silently destroy history. |
| D-10 | Platform shape | Dashboard reader and UI stay platform-neutral; native service installation supports launchd first and systemd user services through the same scheduler conventions | `install.sh:78-113,850-862` already defines Shipyard's cross-platform scheduler and baked-environment contract. |

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

### New runtime surface

- **New `dashboard/server.py`:**
  - Resolve events from explicit `QUARTET_EVENTS_DIR`, then the documented
    platform-local default.
  - Bind to `127.0.0.1:${SHIPYARD_DASHBOARD_PORT:-8765}` by default.
  - Serve static assets and these read-only endpoints:
    - `GET /api/health`
    - `GET /api/summary`
    - `GET /api/events?window=&project=&role=&status=&limit=`
    - `GET /api/stream` using server-sent events for newly appended lines.
  - Enforce bounded windows/limits, deterministic ordering, and explicit JSON
    error envelopes.
  - Build an in-memory index at startup; do not introduce persistent database
    state.

- **New `dashboard/static/{index.html,styles.css,app.js}`:**
  - Implement the hierarchy and states above without a build step.
  - Preserve raw event fields in a collapsed evidence view.
  - Show known result and scheduler-log paths as copyable text; do not accept
    arbitrary filesystem paths from requests.

- **New `scripts/install-dashboard.sh`:**
  - Install, audit, and uninstall the one machine-level dashboard service.
  - Use native launchd on macOS and a user service on Linux.
  - Bake the event directory, loopback host, port, and log paths using the same
    explicit-environment model documented at `docs/INSTALL.md:21-34`.
  - Be idempotent and never disturb per-project build/release/medic jobs.

- **Extend `skills/shipyard/shipyard.sh`:**
  - `shipyard dashboard` prints the URL and opens it only when explicitly
    requested by a flag; headless calls remain non-interactive.
  - `shipyard status` reports service loaded/running state, URL, event path,
    latest event timestamp, and a precise install command when absent.

- **Documentation:**
  - Distinguish the public deck from the private operations dashboard.
  - Document macOS Application Support and Logs locations, Linux XDG defaults,
    event-path rebaking, service lifecycle, loopback-only reach, and optional
    future alert fan-out.

## Implementation Plan

### Phase 1 — Event reader and read-only API (5 pts)

Build the platform-neutral event reader, bounded query model, summary
aggregation, health endpoint, and SSE tailing behavior. Cover malformed,
partially written, unknown-field, empty, multi-day, and concurrent-append
fixtures.

Files: new `dashboard/server.py`, new dashboard API fixtures/tests.

High-level proof: Python/shell gate classes plus hermetic API behavior; no
network access outside loopback and no source-file mutation.

Delegation: subagent — implement and characterize the event reader/API against
synthetic JSONL; return schema decisions, edge cases, and focused test results.

### Phase 2 — Operational UI (5 pts)

Build the fleet summary, project-role matrix, actionable queue, keel rail,
filters, event evidence view, responsive recomposition, and all named states.

Files: new `dashboard/static/index.html`, `dashboard/static/styles.css`,
`dashboard/static/app.js`, UI/render tests.

High-level proof: served-app and visual gate classes at `1440×900` and
`390×844`, including keyboard, focus, overflow, reduced motion, empty, stale,
parse-error, and disconnected-stream states.

Delegation: subagent — implement the UI from the recorded design system and
return screenshots plus interaction/accessibility findings at both viewports.

### Phase 3 — Native service, Shipyard console, and docs (3 pts)

Add idempotent launchd/systemd user-service installation, wire the deterministic
`shipyard dashboard` and `shipyard status` surfaces, document storage and
service behavior, and configure this Mac to use Application Support for future
events without committing a personal path.

Files: new `scripts/install-dashboard.sh`; updates to
`skills/shipyard/{SKILL.md,shipyard.sh}`, `README.md`, `docs/INSTALL.md`, and
scheduler/status tests.

High-level proof: shell, launchd/systemd fixture, leak, skill/deck coupling, and
real local served-app gate classes. Reinstallation must be byte-stable.

Delegation: inline (small integration slice whose value is preserving the
installer/status contracts across files already in the orchestrator's
context).

## Testing Strategy

- Add hermetic API coverage for empty and multi-day streams, typed values,
  filters, bounded limits, malformed/partial final lines, unknown fields, and
  concurrent append while SSE is connected.
- Add `tests/dashboard.bats` for loopback binding, health/summary/event
  endpoints, service installer idempotence, launchd/systemd manifests,
  `shipyard status`, absent-service guidance, and uninstall leave-behinds.
- Add browser coverage for the real served UI at `1440×900` and `390×844`;
  inspect the named states, keyboard path, focus, contrast, overflow, reduced
  motion, raw-field escaping, and auto-refresh selection stability.
- Run the existing full Bats suite, shell syntax checks, Python byte-compilation,
  leak check, and Shipyard skill/deck completeness/freshness gates.
- Run one real macOS smoke with the service loaded, a synthetic event appended
  through `agents/lib/log_event.sh`, the UI visibly updated, and no external
  network request observed.

## Acceptance Criteria / Definition of Done

- [ ] A native user service serves the dashboard at
      `http://127.0.0.1:8765` and survives terminal/session closure.
- [ ] The service reads the configured append-only event directory without
      modifying, relocating, or deleting event files.
- [ ] Fleet summary reports healthy/running/stale/failed/actionable counts and
      the latest event timestamp from synthetic and real local streams.
- [ ] Project × role state uses canonical `project`/`role` identity and shows
      last terminal status, duration, and activity.
- [ ] Timeline filters work for time window, project, role, event family, and
      status, with deterministic order and bounded results.
- [ ] SSE updates the page after a new JSONL append without a full reload,
      losing selection, or moving the operator's scroll position.
- [ ] Empty, loading, stale, malformed-line, and disconnected-stream states use
      the exact actionable copy recorded in this ticket.
- [ ] Malformed or partially written final lines never hide earlier valid
      events and never crash the server.
- [ ] Event-provided HTML/script text renders inertly; no endpoint permits
      arbitrary filesystem reads.
- [ ] The UI matches the recorded hierarchy and visual system at `1440×900`
      and `390×844`, with keyboard access, visible focus, readable contrast,
      no overflow, and reduced-motion behavior verified.
- [ ] `scripts/install-dashboard.sh` is idempotent, supports native launchd and
      systemd user services, and leaves per-project scheduler jobs untouched.
- [ ] `shipyard status` reports dashboard health/URL/event path/latest event,
      while `shipyard dashboard` provides the deterministic operator entrypoint.
- [ ] Default reach is loopback-only; no dashboard or event content leaves the
      machine.
- [ ] Notification Center remains the actionable/urgent alert transport; no
      routine event flood is introduced.
- [ ] README and install docs distinguish the public deck, private dashboard,
      event store, service logs, and future Slack/BopBop alert adapters.
- [ ] Full repository gates are green, and a real macOS smoke visibly advances
      the dashboard after a synthetic Shipyard event.

## Dependencies

- Blocked by: none.
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
