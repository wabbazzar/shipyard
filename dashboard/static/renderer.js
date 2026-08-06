const activeMounts = new WeakMap();

function scopedDocument(root) {
  const ownerDocument = root.ownerDocument;
  const escape = value => ownerDocument.defaultView.CSS.escape(String(value));
  return {
    createElement: tag => ownerDocument.createElement(tag),
    createElementNS: (namespace, tag) => ownerDocument.createElementNS(namespace, tag),
    createTextNode: value => ownerDocument.createTextNode(value),
    getElementById: id => root.querySelector(`#${escape(id)}`),
    querySelector: selector => root.querySelector(selector),
    querySelectorAll: selector => root.querySelectorAll(selector),
  };
}

const RENDERER_TEMPLATE = `
  <a class="skip-link" href="#shipyard-main">Skip to dashboard</a>
  <header class="topbar">
    <div class="brand-row">
      <h1>Shipyard</h1>
      <div class="connection" aria-live="polite">
        <span class="connection-pip" aria-hidden="true"></span>
        <span id="stream-state">Connecting locally…</span>
      </div>
    </div>
    <p id="host-provenance" class="host-provenance utility" hidden></p>
    <div class="control-row">
      <nav class="mode-tabs" aria-label="Dashboard modes" role="tablist">
        <button id="tab-outcomes" type="button" role="tab" aria-selected="true" aria-controls="mode-outcomes" data-mode="outcomes">Outcomes</button>
        <button id="tab-crew" type="button" role="tab" aria-selected="false" aria-controls="mode-crew" data-mode="crew" tabindex="-1">Crew</button>
        <button id="tab-evidence" type="button" role="tab" aria-selected="false" aria-controls="mode-evidence" data-mode="evidence" tabindex="-1">Evidence</button>
        <button id="tab-story" type="button" role="tab" aria-selected="false" aria-controls="mode-story" data-mode="story" tabindex="-1">Story</button>
      </nav>
      <label class="window-control">Window
        <select id="window-select" aria-label="Operator window">
          <option value="24h">24 hours</option>
          <option value="7d">7 days</option>
          <option value="30d">30 days</option>
        </select>
      </label>
    </div>
  </header>

  <main id="shipyard-main" class="shipyard-main" tabindex="-1">
    <div id="loading-state" class="notice" role="status">Reading the operator view…</div>
    <div id="operator-state" class="notice" role="status" hidden></div>
    <div id="error-state" class="notice" role="alert" hidden></div>

    <section id="mode-outcomes" class="mode-panel" role="tabpanel" aria-labelledby="tab-outcomes" tabindex="0">
      <header class="brief-hero">
        <div class="brief-copy">
          <h2 id="brief-takeaway">—</h2>
          <p id="brief-action">—</p>
        </div>
        <p id="generated-at" class="utility">—</p>
      </header>
      <div id="signal-list" class="signal-grid" aria-label="Fleet signals"></div>
      <section class="attention-section" aria-labelledby="attention-heading">
        <div class="section-row">
          <h2 id="attention-heading">Needs you</h2>
          <span id="attention-count" class="count-mark">0</span>
        </div>
        <ol id="attention-list" class="attention-list"></ol>
        <p id="attention-empty" class="quiet">No operator action is currently evidenced.</p>
      </section>
      <div class="outcome-details">
        <details id="promise-disclosure">
          <summary>Promises <span id="promise-count">0</span></summary>
          <div id="promise-list" class="promise-grid" aria-label="Promise states"></div>
        </details>
        <details id="measurement-disclosure">
          <summary>Measurements</summary>
          <div id="kpi-list" class="kpi-grid" aria-label="Outcome measures"></div>
        </details>
      </div>
    </section>

    <section id="mode-crew" class="mode-panel" role="tabpanel" aria-labelledby="tab-crew" tabindex="0" hidden>
      <header class="mode-heading">
        <div>
          <h2>Crew</h2>
          <p id="graph-scope" class="subline">Choose a supplied graph.</p>
        </div>
        <label class="graph-control">Graph
          <select id="graph-select" aria-label="Crew graph"></select>
        </label>
      </header>
      <div class="crew-layout">
        <div class="map-panel">
          <div id="graph-stage" class="graph-stage">
            <svg id="graph-edges" class="graph-edges" aria-hidden="true"></svg>
            <div id="topology-nodes" class="graph-ranks" aria-label="Nodes in supplied ranks"></div>
          </div>
          <div class="connections-heading">
            <h3>Connections</h3>
            <p class="quiet">The same supplied endpoints shown on the map.</p>
          </div>
          <div class="connection-table-wrap">
            <table class="connection-table">
              <thead><tr><th scope="col">From</th><th scope="col">To</th><th scope="col">Why</th><th scope="col">State</th></tr></thead>
              <tbody id="topology-routes"></tbody>
            </table>
          </div>
        </div>
        <aside id="crew-selection" class="selection-panel" aria-live="polite">
          <h3>Selection</h3>
          <p class="quiet">Select a node in this graph.</p>
        </aside>
      </div>
    </section>

    <section id="mode-evidence" class="mode-panel" role="tabpanel" aria-labelledby="tab-evidence" tabindex="0" hidden>
      <header class="mode-heading">
        <h2>Evidence</h2>
        <p id="raw-event-count" class="utility">Raw events not loaded</p>
      </header>
      <div class="evidence-grid">
        <div>
          <div id="evidence-detail" class="evidence-detail"><p class="quiet">Choose “Inspect evidence” from any supplied claim.</p></div>
          <ol id="evidence-list" class="evidence-list" aria-label="Operator evidence in supplied order"></ol>
        </div>
        <aside class="raw-panel">
          <div id="raw-loading" class="quiet" role="status">Raw events load only in Evidence.</div>
          <ol id="raw-event-list" class="raw-event-list" aria-label="Raw event evidence"></ol>
          <div id="raw-detail" class="raw-detail"><p class="quiet">Select a raw event.</p></div>
        </aside>
      </div>
      <ul id="coverage-list" class="coverage-list" aria-label="Evidence coverage"></ul>
    </section>

    <section id="mode-story" class="mode-panel" role="tabpanel" aria-labelledby="tab-story" tabindex="0" hidden>
      <header class="mode-heading">
        <div><h2>Story</h2><p id="story-focus" class="subline">—</p></div>
        <p id="story-position" class="utility">0 / 0</p>
      </header>
      <article id="story-card" class="story-card" aria-live="polite">
        <p class="quiet">No story beat is supplied.</p>
      </article>
      <div class="story-controls">
        <button id="story-previous" type="button">Previous</button>
        <button id="story-next" type="button">Next</button>
      </div>
    </section>
  </main>`;

export function mountShipyardRenderer(root, adapter) {
if (!root || root.nodeType !== 1 || typeof root.replaceChildren !== "function") throw new TypeError("Shipyard renderer root must be an Element");
if (!adapter || ["fetchOperator", "fetchEvents", "subscribe", "updateRoute", "teardown"].some(name => typeof adapter[name] !== "function")) {
  throw new TypeError("Shipyard renderer adapter must provide fetchOperator, fetchEvents, subscribe, updateRoute, and teardown");
}
if (adapter.initialOperator !== undefined && adapter.initialOperator !== null
  && (adapter.initialOperator.schema_version !== 1 || adapter.initialOperator.kind !== "shipyard.operator")) {
  throw new TypeError("Shipyard renderer initialOperator must be a schema-v1 operator document");
}
activeMounts.get(root)?.();
const ownerDocument = root.ownerDocument;
const window = ownerDocument.defaultView;
const document = scopedDocument(root);
const hadRendererClass = root.classList.contains("shipyard-renderer");
const previousMarker = root.getAttribute("data-shipyard-renderer");
root.classList.add("shipyard-renderer");
root.dataset.shipyardRenderer = "mounted";
root.innerHTML = RENDERER_TEMPLATE;
let destroyed = false;
let resizeObserver = null;
let unsubscribe = null;
let unsubscribeRoute = null;

const state = {
  document: null,
  mode: "outcomes",
  selectedEvidenceId: null,
  selectedGraphId: null,
  selectedNodeId: null,
  selectedRawKey: null,
  storyIndex: 0,
  rawEvents: [],
  refreshing: false,
  rawRefreshing: false,
  unavailablePolls: 0,
  pollTimer: null,
  streamRetryTimer: null,
  graphFrame: null,
};

const modeNames = ["outcomes", "crew", "evidence", "story"];
const stateTokens = new Map([
  ["verified", "verified"], ["clear", "clear"], ["healthy", "healthy"],
  ["complete", "clear"],
  ["violated", "violated"], ["alarm", "alarm"], ["failed", "failed"],
  ["unverified", "unverified"], ["waiting", "waiting"], ["partial", "partial"], ["stale", "stale"], ["incomplete", "waiting"],
  ["observed", "observed"], ["signal", "signal"], ["measured", "measured"], ["fresh", "fresh"], ["running", "signal"], ["available", "signal"],
  ["unknown", "unknown"], ["declared", "declared"], ["not_applicable", "not_applicable"], ["unavailable", "unavailable"],
]);

function element(tag, className, text) {
  const item = document.createElement(tag);
  if (className) item.className = className;
  if (text !== undefined) item.textContent = String(text);
  return item;
}

function present(value) {
  if (value === null || value === undefined || value === "") return "—";
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}

function labelKey(value) {
  return String(value).replaceAll("_", " ");
}

function humanizeCode(value) {
  if (value === null || value === undefined || value === "") return "Not reported";
  const text = String(value);
  if (!/^[a-z0-9]+(?:[_:-][a-z0-9]+)*$/.test(text)) return text;
  const words = text.replaceAll(/[_:-]+/g, " ");
  return words.charAt(0).toUpperCase() + words.slice(1);
}

function isReasonCodeField(key) {
  return /(?:^|_)reason(?:_code)?$/.test(String(key));
}

function metricValue(key, value) {
  if (isReasonCodeField(key)) return humanizeCode(value);
  if (Array.isArray(value)) return value.map(humanizeCode).join(", ") || "—";
  if (value && typeof value === "object") {
    if (Number.isFinite(value.count)) return String(value.count);
    return Array.isArray(value.evidence_ids) && value.evidence_ids.length ? "See linked evidence" : "Available";
  }
  return present(value);
}

function sourceState(value) {
  return typeof value === "string" && value ? value : "unknown";
}

function stateToken(value) {
  return stateTokens.get(sourceState(value)) || "unknown";
}

function markState(item, value) {
  const supplied = sourceState(value);
  item.dataset.state = stateToken(supplied);
  item.dataset.sourceState = supplied;
}

function stateMark(value) {
  const supplied = sourceState(value);
  const badge = element("span", "state-mark", supplied);
  badge.dataset.state = stateToken(supplied);
  badge.dataset.sourceState = supplied;
  badge.setAttribute("aria-label", `State: ${supplied}`);
  return badge;
}

function formatTimestamp(value) {
  if (!value) return "—";
  const parsed = new Date(value);
  if (Number.isNaN(parsed.valueOf())) return String(value);
  return new Intl.DateTimeFormat(undefined, {dateStyle: "medium", timeStyle: "short"}).format(parsed);
}

function eventKey(event) {
  return JSON.stringify(event);
}

function limitationsText(value) {
  return Array.isArray(value) && value.length ? value.map(humanizeCode).join(", ") : "None";
}

function evidenceButton(evidenceIds, suppliedCount = null) {
  const ids = Array.isArray(evidenceIds) ? evidenceIds.map(String) : [];
  if (ids.length === 0) return null;
  const count = Number.isFinite(suppliedCount) && suppliedCount >= 0 ? suppliedCount : ids.length;
  const noun = count === 1 ? "record" : "records";
  const button = element("button", "evidence-action", `Review ${count} ${noun}`);
  button.type = "button";
  button.dataset.evidenceTargetId = ids[0];
  return button;
}

function appendEvidenceButton(root, evidenceIds, suppliedCount = null) {
  const button = evidenceButton(evidenceIds, suppliedCount);
  if (button) root.append(button);
}

function renderOperatorState() {
  const metadata = state.document?.metadata || {};
  const supplied = sourceState(metadata.inspection_state);
  const limitations = Array.isArray(metadata.limitations) ? metadata.limitations : [];
  const notice = document.getElementById("operator-state");
  markState(notice, supplied);
  if (supplied === "unavailable") {
    if (state.unavailablePolls >= 3) {
      notice.textContent = "Fleet inspection unavailable · automatic retries stopped";
    } else {
      notice.textContent = limitations.includes("inspection_refresh_failed")
        ? "Fleet inspection unavailable · retrying locally"
        : "Fleet inspection not yet available · retrying locally";
    }
  } else if (limitations.includes("event_index_refresh_failed")) {
    notice.textContent = `Fleet evidence update failed · showing the last good snapshot from ${formatTimestamp(metadata.generated_at)}`;
  } else if (limitations.includes("event_index_refreshing") || supplied === "stale") {
    notice.textContent = `Updating fleet evidence · showing the last good snapshot from ${formatTimestamp(metadata.generated_at)}`;
  } else {
    notice.textContent = `Fleet evidence current · ${formatTimestamp(metadata.generated_at)}`;
  }
  notice.hidden = false;
  document.getElementById("generated-at").textContent = `${present(metadata.window)} · ${formatTimestamp(metadata.generated_at)}`;
}

function renderBrief() {
  const brief = state.document?.brief || {};
  document.getElementById("brief-takeaway").textContent = present(brief.takeaway);
  document.getElementById("brief-action").textContent = present(brief.action);
  markState(document.querySelector(".brief-hero"), brief.state);
  const signals = Array.isArray(brief.signals) ? brief.signals : [];
  const cards = signals.map((signal, index) => {
    const card = element("article", "signal-card");
    card.dataset.signalId = present(signal.id);
    card.dataset.order = String(index);
    markState(card, signal.state);
    const value = element("p", "signal-value", present(signal.value));
    if (signal.value !== null && signal.value !== undefined && signal.value !== ""
      && signal.unit !== null && signal.unit !== undefined && signal.unit !== "") {
      value.append(element("span", "signal-unit", present(signal.unit)));
    }
    const coverage = signal.observed === null || signal.observed === undefined || signal.total === null || signal.total === undefined
      ? "Coverage unknown"
      : `${present(signal.observed)} of ${present(signal.total)} observed`;
    card.append(
      element("p", "signal-label", present(signal.label)),
      value,
      element("p", "signal-coverage", coverage),
      stateMark(signal.state),
    );
    return card;
  });
  document.getElementById("signal-list").replaceChildren(...cards);
}

function renderPromises() {
  const promises = Array.isArray(state.document?.promises) ? state.document.promises : [];
  const cards = promises.map((promise, index) => {
    const card = element("article", "promise-card");
    card.dataset.promiseId = present(promise.id);
    card.dataset.order = String(index);
    markState(card, promise.state);
    const title = element("p", "card-title", present(promise.label));
    const values = element("div", "claim-values");
    const observed = element("div");
    observed.append(element("span", "", "Observed"), element("strong", "", present(promise.observed_value)));
    const target = element("div");
    const targetValue = promise.target || {};
    target.append(
      element("span", "", "Target"),
      element("strong", "", [targetValue.operator, targetValue.value, targetValue.unit].filter(value => value !== null && value !== undefined && value !== "").map(String).join(" ") || "—"),
    );
    values.append(observed, target);
    const limitations = element("p", "quiet", `Limits · ${limitationsText(promise.limitations)}`);
    card.append(title, values, stateMark(promise.state), limitations);
    appendEvidenceButton(card, promise.evidence_ids);
    return card;
  });
  document.getElementById("promise-list").replaceChildren(...cards);
  document.getElementById("promise-count").textContent = String(promises.length);
}

function metricCard(group, item, index) {
  const card = element("article", "kpi-card");
  card.dataset.metricGroup = group;
  card.dataset.order = String(index);
  markState(card, item?.state);
  card.append(element("p", "kpi-name", labelKey(group)), stateMark(item?.state));
  const fields = element("dl", "metric-list");
  for (const [key, value] of Object.entries(item || {})) {
    if (key === "state" || key === "limitations" || key === "evidence_ids") continue;
    const display = metricValue(key, value);
    fields.append(element("dt", "", labelKey(key)), element("dd", "", display));
  }
  fields.append(element("dt", "", "limitations"), element("dd", "", limitationsText(item?.limitations)));
  card.append(fields);
  if (Array.isArray(item?.evidence_ids) && item.evidence_ids.length) card.append(evidenceButton(item.evidence_ids));
  return card;
}

function renderMetrics() {
  const outcomes = state.document?.outcomes || {};
  const cards = [];
  let order = 0;
  for (const [group, value] of Object.entries(outcomes)) {
    if (Array.isArray(value)) {
      const disclosure = element("details", "outcome-group");
      disclosure.dataset.metricGroup = group;
      disclosure.append(element("summary", "", `${labelKey(group)} · ${value.length}`));
      const groupCards = element("div", "outcome-group-cards");
      groupCards.append(...value.map(item => metricCard(group, item, order++)));
      disclosure.append(groupCards);
      cards.push(disclosure);
    } else if (value && typeof value === "object") {
      cards.push(metricCard(group, value, order++));
    }
  }
  const changes = Array.isArray(state.document?.changes) ? state.document.changes : [];
  for (const change of changes) cards.push(metricCard("changes", change, order++));
  document.getElementById("kpi-list").replaceChildren(...cards);
}

function renderAttention() {
  const brief = state.document?.brief || {};
  const attention = Array.isArray(brief.attention_groups) ? brief.attention_groups : [];
  const signal = (Array.isArray(brief.signals) ? brief.signals : []).find(item => item?.id === "attention");
  document.getElementById("attention-count").textContent = present(signal?.value);
  const empty = document.getElementById("attention-empty");
  empty.textContent = Array.isArray(brief.limitations) && brief.limitations.includes("inspection_unavailable")
    ? "Inspection-based attention is unavailable."
    : "No operator action is currently evidenced.";
  empty.hidden = attention.length !== 0;
  const cards = attention.map((item, index) => {
    const li = document.createElement("li");
    const card = element("article", "attention-card attention-summary");
    card.dataset.attentionId = present(item.id);
    card.dataset.order = String(index);
    markState(card, item.state);
    const scale = [
      `${present(item.item_count)} ${item.item_count === 1 ? "item" : "items"}`,
      `${present(item.evidence_count)} ${item.evidence_count === 1 ? "record" : "records"}`,
      item.project_count === null || item.project_count === undefined ? "project coverage unknown" : `${present(item.project_count)} ${item.project_count === 1 ? "project" : "projects"}`,
    ].join(" · ");
    card.append(
      element("p", "card-title", present(item.label)),
      element("p", "attention-action", present(item.action)),
      element("p", "attention-scale", scale),
      stateMark(item.state),
      element("p", "utility", formatTimestamp(item.latest_at)),
    );
    appendEvidenceButton(card, item.evidence_ids, item.evidence_count);
    li.append(card);
    return li;
  });
  document.getElementById("attention-list").replaceChildren(...cards);
}

function suppliedGraphs() {
  return Array.isArray(state.document?.graphs) ? state.document.graphs : [];
}

function selectedGraph() {
  return suppliedGraphs().find(graph => String(graph.id) === state.selectedGraphId) || null;
}

function nodeById(id) {
  const nodes = Array.isArray(selectedGraph()?.nodes) ? selectedGraph().nodes : [];
  return nodes.find(node => String(node.id) === id) || null;
}

function graphScopeText(graph) {
  const scope = graph?.scope || {};
  if (scope.kind === "current_user_fleet") return "Scope · current-user Shipyard fleet";
  if (scope.kind === "unattributed") return `Scope · ${present(scope.project_label)} · not assigned to a named project`;
  return `Scope · project ${present(scope.project_label)} (${present(scope.project_id)})`;
}

function renderGraphEdges() {
  window.cancelAnimationFrame(state.graphFrame);
  state.graphFrame = window.requestAnimationFrame(() => {
    const graph = selectedGraph();
    const stage = document.getElementById("graph-stage");
    const svg = document.getElementById("graph-edges");
    if (!graph || stage.closest("[hidden]") || stage.clientWidth === 0 || stage.clientHeight === 0) {
      svg.replaceChildren();
      return;
    }
    const bounds = stage.getBoundingClientRect();
    const width = Math.max(1, stage.scrollWidth);
    const height = Math.max(1, stage.scrollHeight);
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
    svg.setAttribute("width", String(width));
    svg.setAttribute("height", String(height));
    const marker = document.createElementNS("http://www.w3.org/2000/svg", "marker");
    marker.setAttribute("id", "graph-arrow");
    marker.setAttribute("markerWidth", "8");
    marker.setAttribute("markerHeight", "8");
    marker.setAttribute("refX", "7");
    marker.setAttribute("refY", "4");
    marker.setAttribute("orient", "auto");
    marker.setAttribute("markerUnits", "strokeWidth");
    const arrow = document.createElementNS("http://www.w3.org/2000/svg", "path");
    arrow.setAttribute("d", "M 0 0 L 8 4 L 0 8 z");
    marker.append(arrow);
    const defs = document.createElementNS("http://www.w3.org/2000/svg", "defs");
    defs.append(marker);
    const paths = [];
    const vertical = window.matchMedia("(max-width: 700px)").matches;
    for (const edge of Array.isArray(graph.edges) ? graph.edges : []) {
      const source = stage.querySelector(`[data-node-id="${window.CSS.escape(String(edge.from))}"] .node-card`);
      const target = stage.querySelector(`[data-node-id="${window.CSS.escape(String(edge.to))}"] .node-card`);
      if (!source || !target) continue;
      const from = source.getBoundingClientRect();
      const to = target.getBoundingClientRect();
      const x1 = vertical ? from.left + from.width / 2 - bounds.left : from.right - bounds.left;
      const y1 = vertical ? from.bottom - bounds.top : from.top + from.height / 2 - bounds.top;
      const x2 = vertical ? to.left + to.width / 2 - bounds.left : to.left - bounds.left;
      const y2 = vertical ? to.top - bounds.top : to.top + to.height / 2 - bounds.top;
      const bend = vertical ? Math.max(18, Math.abs(y2 - y1) / 2) : Math.max(6, Math.abs(x2 - x1) / 2);
      const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
      path.dataset.edgeId = String(edge.id);
      path.dataset.from = String(edge.from);
      path.dataset.to = String(edge.to);
      path.dataset.sourceState = sourceState(edge.state);
      path.setAttribute("d", vertical
        ? `M ${x1} ${y1} C ${x1} ${y1 + bend}, ${x2} ${y2 - bend}, ${x2} ${y2}`
        : `M ${x1} ${y1} C ${x1 + bend} ${y1}, ${x2 - bend} ${y2}, ${x2} ${y2}`);
      path.setAttribute("marker-end", "url(#graph-arrow)");
      paths.push(path);
    }
    svg.replaceChildren(defs, ...paths);
  });
}

function renderCrewSelection() {
  const root = document.getElementById("crew-selection");
  const heading = element("h3", "", "Selection");
  const node = nodeById(state.selectedNodeId);
  if (!node) {
    root.replaceChildren(heading, element("p", "quiet", "Select a node in this graph."));
    return;
  }
  const fields = element("dl", "evidence-fields");
  for (const [key, value] of Object.entries(node)) {
    if (key === "evidence_ids") continue;
    const display = key === "last_activity"
      ? formatTimestamp(value)
      : (key === "limitations" ? limitationsText(value) : (isReasonCodeField(key) ? humanizeCode(value) : present(value)));
    fields.append(element("dt", "", labelKey(key)), element("dd", "", display));
  }
  root.replaceChildren(heading, element("p", "card-title", present(node.label)), stateMark(node.state), fields);
  appendEvidenceButton(root, node.evidence_ids);
}

function renderCrew() {
  const graphs = suppliedGraphs();
  if (!graphs.some(graph => String(graph.id) === state.selectedGraphId)) {
    state.selectedGraphId = graphs[0] ? String(graphs[0].id) : null;
  }
  const graph = selectedGraph();
  const select = document.getElementById("graph-select");
  select.replaceChildren(...graphs.map(item => {
    const option = element("option", "", `${present(item.label)} · ${present(item.scope?.project_label || item.scope?.kind)}`);
    option.value = String(item.id);
    option.selected = String(item.id) === state.selectedGraphId;
    return option;
  }));
  select.disabled = graphs.length === 0;
  document.getElementById("graph-scope").textContent = graph ? graphScopeText(graph) : "No supplied graph is available.";
  const nodes = Array.isArray(graph?.nodes) ? graph.nodes : [];
  if (!nodeById(state.selectedNodeId)) state.selectedNodeId = nodes[0] ? String(nodes[0].id) : null;
  const nodeMap = new Map(nodes.map((node, index) => [String(node.id), {node, index}]));
  const ranks = Array.isArray(graph?.ranks) ? graph.ranks : [];
  const rankItems = ranks.map((rank, rankIndex) => {
    const group = element("div", "graph-rank");
    group.dataset.rank = String(rankIndex);
    group.setAttribute("role", "group");
    group.setAttribute("aria-label", `Rank ${rankIndex + 1}`);
    const items = (Array.isArray(rank) ? rank : []).flatMap(nodeId => {
      const found = nodeMap.get(String(nodeId));
      if (!found) return [];
      const {node, index} = found;
    const li = element("li", "topology-node");
      li.setAttribute("role", "listitem");
    li.dataset.nodeId = present(node.id);
    li.dataset.order = String(index);
      li.dataset.rank = String(rankIndex);
    const button = element("button", "node-card");
    button.type = "button";
    button.setAttribute("aria-pressed", String(String(node.id) === state.selectedNodeId));
    markState(button, node.state);
    const activity = element("span", "activity-mark");
    activity.setAttribute("aria-hidden", "true");
    const meta = element("span", "node-meta");
    meta.append(activity, document.createTextNode(`${sourceState(node.state)} · ${present(node.evidence_count)} records`));
    const runtimeDetails = [];
    if (graph?.kind === "project_runtime" && ["role", "role_runtime"].includes(node.kind)) {
      const observedCount = Number.isInteger(node.observed_count) && node.observed_count >= 0
        ? `${node.observed_count} observation${node.observed_count === 1 ? "" : "s"}`
        : "Observations · not reported";
      const terminalStatus = typeof node.terminal_status === "string" && node.terminal_status
        ? node.terminal_status
        : null;
      const terminalReason = typeof node.terminal_reason === "string" && node.terminal_reason
        ? humanizeCode(node.terminal_reason)
        : null;
      runtimeDetails.push(
        element("span", "node-meta", observedCount),
        element("span", "node-meta", terminalStatus
          ? `Terminal · ${terminalStatus}${terminalReason ? ` / ${terminalReason}` : ""}`
          : "Terminal · not recorded"),
      );
      if (typeof node.impact === "string" && node.impact) {
        runtimeDetails.push(element("span", "node-meta", node.impact));
      }
    }
    button.append(
      element("span", "node-kind", present(node.kind)),
      element("span", "node-label", present(node.label)),
      meta,
      ...runtimeDetails,
      element("span", "node-meta", formatTimestamp(node.last_activity)),
    );
    li.append(button);
    return li;
    });
    const list = element("ol", "graph-rank-nodes");
    list.append(...items);
    group.append(list);
    return group;
  });
  document.getElementById("topology-nodes").replaceChildren(...rankItems);

  const edges = Array.isArray(graph?.edges) ? graph.edges : [];
  const routes = edges.map((edge, index) => {
    const row = element("tr", "route-card");
    row.dataset.edgeId = present(edge.id);
    row.dataset.from = present(edge.from);
    row.dataset.to = present(edge.to);
    row.dataset.order = String(index);
    markState(row, edge.state);
    const from = element("td", "route-endpoint", present(edge.from));
    const to = element("td", "route-endpoint", present(edge.to));
    const reason = element("td", "route-reason", humanizeCode(edge.reason));
    const routeState = element("td", "route-meta", `${present(edge.kind)} · ${sourceState(edge.state)}`);
    for (const [cell, label] of [[from, "From"], [to, "To"], [reason, "Why"], [routeState, "State"]]) cell.dataset.label = label;
    row.append(from, to, reason, routeState);
    if (Array.isArray(edge.evidence_ids) && edge.evidence_ids.length) {
      row.tabIndex = 0;
      row.setAttribute("aria-label", `Inspect evidence for ${present(edge.id)}`);
      row.dataset.evidenceTargetId = String(edge.evidence_ids[0]);
    }
    return row;
  });
  document.getElementById("topology-routes").replaceChildren(...routes);
  renderCrewSelection();
  renderGraphEdges();
}

function evidenceById(id) {
  const rows = Array.isArray(state.document?.evidence) ? state.document.evidence : [];
  return rows.find(row => String(row.id) === id) || null;
}

function detailFields(record) {
  const fields = element("dl", "evidence-fields");
  for (const [key, value] of Object.entries(record || {})) {
    const display = key === "observed_at" || key === "ts"
      ? formatTimestamp(value)
      : (isReasonCodeField(key) ? humanizeCode(value) : present(value));
    fields.append(element("dt", "", labelKey(key)), element("dd", "", display));
  }
  return fields;
}

function renderEvidenceDetail() {
  const root = document.getElementById("evidence-detail");
  const row = evidenceById(state.selectedEvidenceId);
  if (!row) {
    root.replaceChildren(element("p", "quiet", "Choose “Inspect evidence” from any supplied claim."));
    return;
  }
  root.replaceChildren(element("p", "card-title", present(row.id)), detailFields(row));
}

function renderEvidence() {
  const rows = Array.isArray(state.document?.evidence) ? state.document.evidence : [];
  const items = rows.map((row, index) => {
    const li = document.createElement("li");
    const button = element("button", "");
    button.type = "button";
    button.dataset.evidenceId = present(row.id);
    button.dataset.order = String(index);
    button.setAttribute("aria-current", String(String(row.id) === state.selectedEvidenceId));
    button.append(element("span", "", present(row.id)), element("span", "utility", present(row.kind)));
    li.append(button);
    return li;
  });
  document.getElementById("evidence-list").replaceChildren(...items);
  const coverage = Array.isArray(state.document?.coverage) ? state.document.coverage : [];
  document.getElementById("coverage-list").replaceChildren(...coverage.map((row, index) => {
    const summary = [humanizeCode(row.source), humanizeCode(sourceState(row.state)), humanizeCode(row.reason)];
    if (Array.isArray(row.limitations) && row.limitations.length) {
      summary.push(`Limits: ${limitationsText(row.limitations)}`);
    }
    const li = element("li", "", summary.join(" · "));
    li.dataset.coverageSource = present(row.source);
    li.dataset.order = String(index);
    markState(li, row.state);
    return li;
  }));
  renderEvidenceDetail();
}

function renderRawEvents() {
  const items = state.rawEvents.map((event, index) => {
    const li = document.createElement("li");
    const key = eventKey(event);
    const button = element("button", "");
    button.type = "button";
    button.dataset.rawKey = key;
    button.dataset.order = String(index);
    button.setAttribute("aria-current", String(key === state.selectedRawKey));
    button.append(element("span", "", present(event.event)), element("time", "utility", formatTimestamp(event.ts)));
    li.append(button);
    return li;
  });
  document.getElementById("raw-event-list").replaceChildren(...items);
  const selected = state.rawEvents.find(event => eventKey(event) === state.selectedRawKey);
  const detail = document.getElementById("raw-detail");
  detail.replaceChildren(selected ? detailFields(selected) : element("p", "quiet", "Select a raw event."));
  document.getElementById("raw-event-count").textContent = `${state.rawEvents.length} raw ${state.rawEvents.length === 1 ? "event" : "events"}`;
}

function renderStory() {
  const narrative = state.document?.narrative || {};
  const beats = Array.isArray(narrative.beats) ? narrative.beats : [];
  if (state.storyIndex >= beats.length) state.storyIndex = Math.max(0, beats.length - 1);
  document.getElementById("story-focus").textContent = present(narrative.focus);
  document.getElementById("story-position").textContent = beats.length ? `${state.storyIndex + 1} / ${beats.length}` : "0 / 0";
  const card = document.getElementById("story-card");
  const beat = beats[state.storyIndex];
  if (!beat) {
    card.removeAttribute("data-source-state");
    card.removeAttribute("data-state");
    card.replaceChildren(element("p", "quiet", "No story beat is supplied."));
  } else {
    card.dataset.storyId = present(beat.id);
    card.dataset.order = String(state.storyIndex);
    markState(card, beat.state);
    const children = [
      element("p", "story-heading", present(beat.heading)),
      element("p", "story-body", present(beat.body)),
      stateMark(beat.state),
    ];
    const action = evidenceButton(beat.evidence_ids);
    if (action) children.push(action);
    card.replaceChildren(...children);
  }
  document.getElementById("story-previous").disabled = state.storyIndex <= 0;
  document.getElementById("story-next").disabled = !beats.length || state.storyIndex >= beats.length - 1;
}

function renderDocument() {
  document.getElementById("loading-state").hidden = true;
  document.getElementById("error-state").hidden = true;
  renderOperatorState();
  renderBrief();
  renderPromises();
  renderMetrics();
  renderAttention();
  renderCrew();
  renderEvidence();
  renderStory();
}

function scheduleUnavailablePoll() {
  window.clearTimeout(state.pollTimer);
  state.pollTimer = null;
  if (destroyed || state.document?.metadata?.inspection_state !== "unavailable" || state.unavailablePolls >= 3) return;
  state.unavailablePolls += 1;
  state.pollTimer = window.setTimeout(() => refreshOperator({preserve: true}), 1000);
}

async function refreshOperator({preserve = false} = {}) {
  if (destroyed || state.refreshing) return;
  state.refreshing = true;
  try {
    const windowValue = document.getElementById("window-select").value;
    const operator = await adapter.fetchOperator(windowValue);
    if (destroyed) return;
    if (operator?.schema_version !== 1 || operator?.kind !== "shipyard.operator") throw new Error("Unsupported operator document");
    state.document = operator;
    renderDocument();
    scheduleUnavailablePoll();
  } catch (error) {
    if (destroyed) return;
    const notice = document.getElementById("error-state");
    notice.dataset.state = "error";
    notice.textContent = "Operator view unavailable. Retrying locally.";
    notice.hidden = false;
  } finally {
    state.refreshing = false;
  }
}

async function refreshRawEvents({preserve = false} = {}) {
  if (destroyed || state.mode !== "evidence" || state.rawRefreshing) return;
  state.rawRefreshing = true;
  try {
    document.getElementById("raw-loading").textContent = "Reading raw evidence…";
    const windowValue = document.getElementById("window-select").value;
    const payload = await adapter.fetchEvents(windowValue, 500);
    if (destroyed) return;
    state.rawEvents = Array.isArray(payload.events) ? payload.events : [];
    if (state.selectedRawKey && !state.rawEvents.some(event => eventKey(event) === state.selectedRawKey)) state.selectedRawKey = null;
    document.getElementById("raw-loading").textContent = state.rawEvents.length ? "Raw event evidence" : "No raw events supplied in this window.";
    renderRawEvents();
  } catch (error) {
    if (destroyed) return;
    document.getElementById("raw-loading").textContent = "Raw evidence unavailable; operator evidence remains visible.";
  } finally {
    state.rawRefreshing = false;
  }
}

function setMode(mode, {focus = false} = {}) {
  if (!modeNames.includes(mode)) return;
  state.mode = mode;
  for (const name of modeNames) {
    const active = name === mode;
    const tab = document.getElementById(`tab-${name}`);
    const panel = document.getElementById(`mode-${name}`);
    tab.setAttribute("aria-selected", String(active));
    tab.tabIndex = active ? 0 : -1;
    panel.hidden = !active;
  }
  if (mode === "evidence") {
    renderEvidence();
    refreshRawEvents();
  }
  if (mode === "crew") renderGraphEdges();
  if (focus) document.getElementById(`mode-${mode}`).focus();
}

function connectStream() {
  unsubscribe = adapter.subscribe({
    onOpen: () => {
      if (destroyed) return;
      document.querySelector(".connection").classList.remove("is-offline");
      document.getElementById("stream-state").textContent = "Live";
    },
    onUpdate: () => {
      if (destroyed) return;
      refreshOperator({preserve: true});
      if (state.mode === "evidence") {
        refreshRawEvents({preserve: true});
        window.clearTimeout(state.streamRetryTimer);
        state.streamRetryTimer = window.setTimeout(() => refreshRawEvents({preserve: true}), 250);
      }
    },
    onError: () => {
      if (destroyed) return;
      document.querySelector(".connection").classList.add("is-offline");
      document.getElementById("stream-state").textContent = "Updates paused; retrying locally";
    },
  });
  if (typeof unsubscribe !== "function") {
    throw new TypeError("Shipyard renderer adapter subscribe must return a teardown function");
  }
}

function openEvidence(evidenceId) {
  if (!evidenceId) return;
  state.selectedEvidenceId = String(evidenceId);
  setMode("evidence", {focus: true});
}

function onClick(event) {
  const target = event.target instanceof window.Element ? event.target : null;
  if (!target) return;
  const tab = target.closest("[role=tab][data-mode]");
  if (tab && root.contains(tab)) return setMode(tab.dataset.mode);
  const evidenceAction = target.closest(".evidence-action[data-evidence-target-id]");
  if (evidenceAction && root.contains(evidenceAction)) return openEvidence(evidenceAction.dataset.evidenceTargetId);
  const nodeButton = target.closest(".node-card");
  if (nodeButton && root.contains(nodeButton)) {
    const nodeId = nodeButton.closest("[data-node-id]")?.dataset.nodeId;
    if (!nodeId) return;
    state.selectedNodeId = nodeId;
    renderCrew();
    document.querySelector(`[data-node-id="${window.CSS.escape(nodeId)}"] .node-card`)?.focus();
    return;
  }
  const route = target.closest(".route-card[data-evidence-target-id]");
  if (route && root.contains(route)) return openEvidence(route.dataset.evidenceTargetId);
  const evidence = target.closest("#evidence-list [data-evidence-id]");
  if (evidence && root.contains(evidence)) {
    state.selectedEvidenceId = evidence.dataset.evidenceId;
    renderEvidence();
    return;
  }
  const raw = target.closest("#raw-event-list [data-raw-key]");
  if (raw && root.contains(raw)) {
    state.selectedRawKey = raw.dataset.rawKey;
    renderRawEvents();
    return;
  }
  if (target.closest("#story-previous")) {
    if (state.storyIndex > 0) { state.storyIndex -= 1; renderStory(); }
    return;
  }
  if (target.closest("#story-next")) {
    const beats = Array.isArray(state.document?.narrative?.beats) ? state.document.narrative.beats : [];
    if (state.storyIndex < beats.length - 1) { state.storyIndex += 1; renderStory(); }
  }
}

function onKeydown(event) {
  const target = event.target instanceof window.Element ? event.target : null;
  if (!target) return;
  const tab = target.closest("[role=tab][data-mode]");
  if (tab && root.contains(tab)) {
    const index = modeNames.indexOf(tab.dataset.mode);
    let next = null;
    if (event.key === "ArrowRight") next = (index + 1) % modeNames.length;
    if (event.key === "ArrowLeft") next = (index + modeNames.length - 1) % modeNames.length;
    if (event.key === "Home") next = 0;
    if (event.key === "End") next = modeNames.length - 1;
    if (next !== null) {
      event.preventDefault();
      setMode(modeNames[next]);
      document.getElementById(`tab-${modeNames[next]}`).focus();
    }
    return;
  }
  const route = target.closest(".route-card[data-evidence-target-id]");
  if (route && root.contains(route) && (event.key === "Enter" || event.key === " ")) {
    event.preventDefault();
    openEvidence(route.dataset.evidenceTargetId);
  }
}

function onChange(event) {
  if (event.target === document.getElementById("window-select")) {
    state.unavailablePolls = 0;
    state.selectedEvidenceId = null;
    state.selectedRawKey = null;
    adapter.updateRoute(event.target.value);
    refreshOperator();
    if (state.mode === "evidence") refreshRawEvents();
  } else if (event.target === document.getElementById("graph-select")) {
    state.selectedGraphId = event.target.value;
    state.selectedNodeId = null;
    renderCrew();
  }
}

root.addEventListener("click", onClick);
root.addEventListener("keydown", onKeydown);
root.addEventListener("change", onChange);
resizeObserver = new window.ResizeObserver(() => {
  if (state.mode === "crew") renderGraphEdges();
});
resizeObserver.observe(document.getElementById("graph-stage"));
const initialWindow = adapter.initialWindow;
document.getElementById("window-select").value = ["24h", "7d", "30d"].includes(initialWindow) ? initialWindow : "7d";
const provenance = adapter.hostProvenance;
if (provenance !== null && provenance !== undefined && String(provenance)) {
  const slot = document.getElementById("host-provenance");
  slot.textContent = String(provenance);
  slot.hidden = false;
}
setMode("outcomes");
connectStream();
if (typeof adapter.subscribeRoute === "function") {
  unsubscribeRoute = adapter.subscribeRoute(windowValue => {
    if (destroyed || !["24h", "7d", "30d"].includes(windowValue)) return;
    const select = document.getElementById("window-select");
    if (select.value === windowValue) return;
    select.value = windowValue;
    state.unavailablePolls = 0;
    state.selectedEvidenceId = null;
    state.selectedRawKey = null;
    refreshOperator();
    if (state.mode === "evidence") refreshRawEvents();
  });
}
if (adapter.initialOperator) {
  state.document = adapter.initialOperator;
  renderDocument();
  scheduleUnavailablePoll();
} else {
  refreshOperator();
}

const teardown = () => {
  if (destroyed) return;
  destroyed = true;
  window.clearTimeout(state.pollTimer);
  window.clearTimeout(state.streamRetryTimer);
  window.cancelAnimationFrame(state.graphFrame);
  resizeObserver?.disconnect();
  unsubscribe?.();
  unsubscribeRoute?.();
  root.removeEventListener("click", onClick);
  root.removeEventListener("keydown", onKeydown);
  root.removeEventListener("change", onChange);
  adapter.teardown();
  root.replaceChildren();
  if (!hadRendererClass) root.classList.remove("shipyard-renderer");
  if (previousMarker === null) root.removeAttribute("data-shipyard-renderer");
  else root.setAttribute("data-shipyard-renderer", previousMarker);
  if (activeMounts.get(root) === teardown) activeMounts.delete(root);
};
activeMounts.set(root, teardown);
return teardown;
}
