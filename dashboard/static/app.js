"use strict";

const state = {
  health: null,
  summary: null,
  events: [],
  selectedKey: null,
  source: null,
  refreshing: false,
};

const knownPathFields = new Set(["result_path", "result_file", "scheduler_log", "scheduler_log_path", "log_path"]);

function element(tag, className, text) {
  const item = document.createElement(tag);
  if (className) item.className = className;
  if (text !== undefined) item.textContent = String(text);
  return item;
}

function eventKey(event) {
  return JSON.stringify(event);
}

function formatTimestamp(value) {
  if (!value) return "—";
  const parsed = new Date(value);
  if (Number.isNaN(parsed.valueOf())) return String(value);
  return new Intl.DateTimeFormat(undefined, {dateStyle: "medium", timeStyle: "medium"}).format(parsed);
}

function formatDuration(value) {
  return typeof value === "number" ? `${value.toFixed(value < 10 ? 2 : 0)}s` : "—";
}

function setCount(name, value) {
  document.getElementById(`count-${name}`).textContent = String(value ?? 0);
}

function setFilterOptions(id, values, label) {
  const select = document.getElementById(id);
  const selected = select.value;
  const options = [element("option", "", label)];
  options[0].value = "";
  for (const value of [...values].filter(Boolean).sort()) {
    const option = element("option", "", value);
    option.value = value;
    options.push(option);
  }
  select.replaceChildren(...options);
  if ([...values].includes(selected)) select.value = selected;
}

function renderSummary() {
  const counts = state.summary?.counts || {};
  for (const name of ["healthy", "running", "stale", "failed", "actionable"]) setCount(name, counts[name]);
  document.getElementById("latest-event").textContent = formatTimestamp(state.health?.latest_timestamp);
  document.getElementById("loading-state").hidden = true;
  document.getElementById("empty-state").hidden = state.events.length !== 0;
  const latest = Date.parse(state.health?.latest_timestamp || "");
  const stale = Number.isFinite(latest) && Date.now() - latest > 7200 * 1000;
  const staleState = document.getElementById("stale-state");
  staleState.textContent = stale ? `No new event since ${formatTimestamp(state.health.latest_timestamp)}; inspect scheduler status.` : "";
  staleState.hidden = !stale;
  document.getElementById("parse-state").hidden = !(state.summary?.errors?.length > 0);
}

function inspect(event) {
  const key = eventKey(event);
  const present = state.events.some(item => eventKey(item) === key);
  state.selectedKey = present ? key : null;
  renderEvents(present);
  if (!present) renderDetail(event);
}

function renderActionables() {
  const list = document.getElementById("actionable-list");
  const items = state.summary?.actionables || [];
  document.getElementById("actionable-total").textContent = String(items.length);
  document.getElementById("actionable-empty").hidden = items.length !== 0;
  const children = items.map(item => {
    const li = element("li", "actionable-item");
    const title = element("p", "event-name", item.event?.event || item.kind);
    const label = item.kind === "failure" ? (item.event?.svc || "service failure") : item.key;
    const context = element("p", "quiet-copy", `${item.event?.project || "unknown"} / ${item.event?.role || "unknown"} · ${label}`);
    const button = element("button", "", "Inspect evidence");
    button.type = "button";
    button.addEventListener("click", () => inspect(item.event));
    li.append(title, context, button);
    return li;
  });
  list.replaceChildren(...children);
}

function stateClass(value) {
  return `state state-${value || "unknown"}`;
}

function renderServices() {
  const services = state.summary?.services || [];
  const rows = services.map(service => {
    const tr = document.createElement("tr");
    tr.append(
      element("td", "", service.project || "—"),
      element("td", "", service.role || "—"),
      element("td", stateClass(service.state), service.state || "unknown"),
      element("td", "", formatDuration(service.duration_s)),
      element("td", "", formatTimestamp(service.last_activity)),
    );
    return tr;
  });
  document.getElementById("service-table").replaceChildren(...rows);
  const cards = services.map(service => {
    const card = element("article", "service-card");
    card.append(
      element("p", "", `${service.project || "—"} / ${service.role || "—"}`),
      element("p", stateClass(service.state), service.state || "unknown"),
      element("p", "service-meta", `${service.svc || "—"} · ${formatDuration(service.duration_s)} · ${formatTimestamp(service.last_activity)}`),
    );
    return card;
  });
  document.getElementById("service-cards").replaceChildren(...cards);
}

function makeSelectButton(event, rail) {
  const selected = eventKey(event) === state.selectedKey;
  const button = element("button", rail ? "keel-button" : "");
  button.type = "button";
  button.dataset.role = String(event.role || "unknown");
  button.setAttribute("aria-label", `Inspect ${event.event || "event"} for ${event.project || "unknown"} ${event.role || "unknown"} at ${formatTimestamp(event.ts)}`);
  if (rail) button.setAttribute("aria-pressed", String(selected));
  else button.setAttribute("aria-current", String(selected));
  button.addEventListener("click", () => inspect(event));
  return button;
}

function renderEvents(autoSelect = true) {
  if (state.selectedKey && !state.events.some(item => eventKey(item) === state.selectedKey)) state.selectedKey = null;
  if (autoSelect && !state.selectedKey && state.events.length) state.selectedKey = eventKey(state.events[0]);
  document.getElementById("event-total").textContent = `${state.events.length} ${state.events.length === 1 ? "event" : "events"}`;
  const railItems = state.events.slice().reverse().map(event => {
    const li = element("li", "keel-item");
    li.append(makeSelectButton(event, true), element("span", "keel-label", event.event || "unknown"));
    return li;
  });
  document.getElementById("keel-rail").replaceChildren(...railItems);
  const rows = state.events.map(event => {
    const li = element("li", "event-row");
    const button = makeSelectButton(event, false);
    button.append(
      element("span", "event-name", event.event || "unknown event"),
      element("span", "event-role", `${event.project || "—"} / ${event.role || "—"}`),
      element("time", "event-time", formatTimestamp(event.ts)),
    );
    li.append(button);
    return li;
  });
  document.getElementById("event-list").replaceChildren(...rows);
  const selected = state.events.find(item => eventKey(item) === state.selectedKey);
  renderDetail(selected || null);
}

function renderDetail(event) {
  const root = document.getElementById("event-detail");
  if (!event) {
    root.replaceChildren(element("p", "quiet-copy", "Select an event from the keel rail."));
    return;
  }
  const fields = element("dl", "event-fields");
  for (const [key, value] of Object.entries(event).sort(([left], [right]) => left.localeCompare(right))) {
    fields.append(element("dt", "", key), element("dd", "", typeof value === "object" ? JSON.stringify(value) : value));
  }
  const paths = Object.entries(event).filter(([key, value]) => knownPathFields.has(key) && typeof value === "string");
  const pathSection = element("div", "known-paths");
  if (paths.length) {
    pathSection.append(element("h4", "", "Known local paths"));
    const list = document.createElement("ul");
    for (const [key, value] of paths) {
      const item = document.createElement("li");
      item.append(element("span", "quiet-copy", key), element("code", "", value));
      const copy = element("button", "", "Copy path");
      copy.type = "button";
      copy.addEventListener("click", async () => {
        await navigator.clipboard.writeText(value);
        copy.textContent = "Copied";
      });
      item.append(copy);
      list.append(item);
    }
    pathSection.append(list);
  }
  const disclosure = element("details", "raw-evidence");
  disclosure.append(element("summary", "", "Raw event evidence"), element("pre", "", JSON.stringify(event, null, 2)));
  root.replaceChildren(fields, pathSection, disclosure);
}

function queryString() {
  const values = new URLSearchParams();
  values.set("window", document.getElementById("filter-window").value);
  for (const name of ["project", "role", "status", "event"]) {
    const value = document.getElementById(`filter-${name}`).value.trim();
    if (value) values.set(name, value);
  }
  values.set("limit", "500");
  return values.toString();
}

async function fetchJson(path) {
  const response = await fetch(path, {headers: {"Accept": "application/json"}});
  if (!response.ok) throw new Error(`Local API returned ${response.status}`);
  return response.json();
}

async function refresh({preserve = false, updateOptions = false} = {}) {
  if (state.refreshing) return;
  state.refreshing = true;
  const selected = state.selectedKey;
  const scrollTop = window.scrollY;
  try {
    const windowValue = document.getElementById("filter-window").value;
    const [health, summary, events] = await Promise.all([
      fetchJson("/api/health"),
      fetchJson(`/api/summary?window=${encodeURIComponent(windowValue)}`),
      fetchJson(`/api/events?${queryString()}`),
    ]);
    state.health = health;
    state.summary = summary;
    state.events = events.events || [];
    state.selectedKey = selected;
    if (updateOptions) {
      setFilterOptions("filter-project", new Set(state.events.map(item => item.project)), "All projects");
      setFilterOptions("filter-role", new Set(state.events.map(item => item.role)), "All roles");
    }
    renderSummary();
    renderActionables();
    renderServices();
    renderEvents();
    if (preserve) requestAnimationFrame(() => window.scrollTo(0, scrollTop));
  } catch (error) {
    document.querySelector(".connection").classList.add("is-offline");
    document.getElementById("stream-state").textContent = "Live updates paused; retrying locally.";
  } finally {
    state.refreshing = false;
  }
}

function connectStream() {
  const source = new EventSource("/api/stream");
  state.source = source;
  source.addEventListener("open", () => {
    document.querySelector(".connection").classList.remove("is-offline");
    document.getElementById("stream-state").textContent = "Live updates active.";
  });
  source.addEventListener("shipyard", () => refresh({preserve: true}));
  source.addEventListener("error", () => {
    document.querySelector(".connection").classList.add("is-offline");
    document.getElementById("stream-state").textContent = "Live updates paused; retrying locally.";
  });
}

function configureResponsiveFilters() {
  const disclosure = document.getElementById("filter-disclosure");
  const narrow = window.matchMedia("(max-width: 800px)");
  const apply = event => { disclosure.open = !event.matches; };
  apply(narrow);
  narrow.addEventListener("change", apply);
}

document.getElementById("filter-form").addEventListener("submit", event => {
  event.preventDefault();
  refresh({updateOptions: false});
});
document.getElementById("filter-window").addEventListener("change", () => refresh({updateOptions: true}));
configureResponsiveFilters();
refresh({updateOptions: true});
connectStream();
