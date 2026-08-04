#!/usr/bin/env node

import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {spawn, execFileSync} from "node:child_process";
import {existsSync} from "node:fs";
import {appendFile, mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile} from "node:fs/promises";
import {homedir, tmpdir} from "node:os";
import {dirname, join, resolve} from "node:path";
import {fileURLToPath} from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..", "..");

function parseArgs(argv) {
  const options = {browser: "chromium", viewport: "1440x900", screenshotDir: null};
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    const value = argv[index + 1];
    if (key === "--browser") options.browser = value;
    else if (key === "--viewport") options.viewport = value;
    else if (key === "--screenshot-dir") options.screenshotDir = value;
    else throw new Error(`unknown argument: ${key}`);
    index += 1;
  }
  if (options.browser !== "chromium") throw new Error("only --browser chromium is supported");
  if (!options.screenshotDir) throw new Error("--screenshot-dir is required");
  const match = /^(\d+)x(\d+)$/.exec(options.viewport);
  if (!match) throw new Error("--viewport must use WIDTHxHEIGHT");
  options.width = Number(match[1]);
  options.height = Number(match[2]);
  if (options.width < 320 || options.height < 480) throw new Error("viewport is below the supported minimum");
  return options;
}

async function walkForExecutable(directory, name, depth = 5) {
  if (depth < 0 || !existsSync(directory)) return [];
  const found = [];
  for (const entry of await readdir(directory, {withFileTypes: true})) {
    const path = join(directory, entry.name);
    if (entry.isFile() && entry.name === name) found.push(path);
    else if (entry.isDirectory()) found.push(...await walkForExecutable(path, name, depth - 1));
  }
  return found;
}

async function chromiumExecutable() {
  const candidates = [];
  if (process.env.CHROMIUM_EXECUTABLE) candidates.push(process.env.CHROMIUM_EXECUTABLE);
  candidates.push(...await walkForExecutable(join(homedir(), "Library", "Caches", "ms-playwright"), "chrome-headless-shell"));
  candidates.push(
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
  );
  for (const candidate of candidates) {
    try {
      const info = await stat(candidate);
      if (info.isFile() && (info.mode & 0o111)) return candidate;
    } catch {}
  }
  throw new Error("RED: no executable Chromium browser found; browser proof may not skip");
}

function processSet(pattern) {
  const output = execFileSync("ps", ["-axo", "pid=,command="], {encoding: "utf8"});
  return output.split("\n").filter(line => line.includes(pattern)).map(line => Number(line.trim().split(/\s+/, 1)[0])).filter(Boolean).sort((a, b) => a - b);
}

function waitForExit(child, timeout = 5000) {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve({code: child.exitCode, signal: child.signalCode});
  return new Promise((resolvePromise, reject) => {
    const timer = setTimeout(() => reject(new Error(`process ${child.pid} did not exit`)), timeout);
    child.once("exit", (code, signal) => {
      clearTimeout(timer);
      resolvePromise({code, signal});
    });
  });
}

async function waitForFile(path, child, timeout = 10000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error(`server exited before writing port file: ${child.exitCode}`);
    try {
      const value = (await readFile(path, "utf8")).trim();
      if (value) return value;
    } catch {}
    await new Promise(resolvePromise => setTimeout(resolvePromise, 50));
  }
  throw new Error("server did not write its ephemeral port within 10 seconds");
}

class Cdp {
  constructor(socket) {
    this.socket = socket;
    this.nextId = 1;
    this.pending = new Map();
    this.listeners = new Map();
    socket.addEventListener("message", event => {
      const message = JSON.parse(event.data);
      if (message.id) {
        const pending = this.pending.get(message.id);
        if (!pending) return;
        this.pending.delete(message.id);
        if (message.error) pending.reject(new Error(`${pending.method}: ${message.error.message}`));
        else pending.resolve(message.result);
        return;
      }
      for (const listener of this.listeners.get(message.method) || []) listener(message.params, message.sessionId);
    });
  }

  send(method, params = {}, sessionId = undefined) {
    const id = this.nextId++;
    return new Promise((resolvePromise, reject) => {
      this.pending.set(id, {resolve: resolvePromise, reject, method});
      this.socket.send(JSON.stringify({id, method, params, ...(sessionId ? {sessionId} : {})}));
    });
  }

  on(method, listener) {
    const listeners = this.listeners.get(method) || [];
    listeners.push(listener);
    this.listeners.set(method, listeners);
  }
}

async function connectWebSocket(url) {
  const socket = new WebSocket(url);
  await new Promise((resolvePromise, reject) => {
    const timer = setTimeout(() => reject(new Error("DevTools WebSocket did not open")), 5000);
    socket.addEventListener("open", () => { clearTimeout(timer); resolvePromise(); }, {once: true});
    socket.addEventListener("error", () => { clearTimeout(timer); reject(new Error("DevTools WebSocket failed")); }, {once: true});
  });
  return socket;
}

async function launchBrowser(executable, profile, width, height) {
  const before = processSet("chrome-headless-shell");
  const args = [
    "--headless=new", "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0",
    `--user-data-dir=${profile}`, "--no-first-run", "--no-default-browser-check",
    "--disable-background-networking", "--disable-component-update", "--disable-default-apps",
    "--disable-sync", "--metrics-recording-only", "--no-pings",
    "--host-resolver-rules=MAP * 0.0.0.0, EXCLUDE 127.0.0.1, EXCLUDE localhost",
    "about:blank",
  ];
  const child = spawn(executable, args, {stdio: ["ignore", "ignore", "pipe"]});
  let stderr = "";
  const websocketUrl = await new Promise((resolvePromise, reject) => {
    const timer = setTimeout(() => reject(new Error(`Chromium did not expose DevTools: ${stderr}`)), 10000);
    child.stderr.on("data", chunk => {
      stderr += chunk.toString();
      const match = /DevTools listening on (ws:\/\/[^\s]+)/.exec(stderr);
      if (match) { clearTimeout(timer); resolvePromise(match[1]); }
    });
    child.once("exit", code => { clearTimeout(timer); reject(new Error(`Chromium exited before DevTools: ${code}: ${stderr}`)); });
  });
  const socket = await connectWebSocket(websocketUrl);
  const cdp = new Cdp(socket);
  const version = await cdp.send("Browser.getVersion");
  const {targetId} = await cdp.send("Target.createTarget", {url: "about:blank"});
  const {sessionId} = await cdp.send("Target.attachToTarget", {targetId, flatten: true});
  await Promise.all([
    cdp.send("Page.enable", {}, sessionId),
    cdp.send("Runtime.enable", {}, sessionId),
    cdp.send("Network.enable", {}, sessionId),
    cdp.send("Emulation.setDeviceMetricsOverride", {width, height, deviceScaleFactor: 1, mobile: false}, sessionId),
    cdp.send("Emulation.setEmulatedMedia", {features: [{name: "prefers-reduced-motion", value: "reduce"}]}, sessionId),
  ]);
  return {cdp, sessionId, child, socket, version, before, executable};
}

async function evaluate(browser, expression) {
  const result = await browser.cdp.send("Runtime.evaluate", {expression, awaitPromise: true, returnByValue: true}, browser.sessionId);
  if (result.exceptionDetails) throw new Error(`browser evaluation failed: ${result.exceptionDetails.text}`);
  return result.result.value;
}

async function waitFor(browser, expression, message, timeout = 8000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await evaluate(browser, expression)) return;
    await new Promise(resolvePromise => setTimeout(resolvePromise, 50));
  }
  throw new Error(`timed out: ${message}`);
}

async function press(browser, key, code, virtualKeyCode) {
  const params = {key, code, windowsVirtualKeyCode: virtualKeyCode, nativeVirtualKeyCode: virtualKeyCode};
  const text = key === "Enter" ? {text: "\r", unmodifiedText: "\r"} : {};
  await browser.cdp.send("Input.dispatchKeyEvent", {type: "keyDown", ...params, ...text}, browser.sessionId);
  await browser.cdp.send("Input.dispatchKeyEvent", {type: "keyUp", ...params}, browser.sessionId);
}

async function screenshot(browser, path) {
  const metrics = await browser.cdp.send("Page.getLayoutMetrics", {}, browser.sessionId);
  const size = metrics.cssContentSize;
  const result = await browser.cdp.send("Page.captureScreenshot", {
    format: "png",
    captureBeyondViewport: true,
    clip: {x: 0, y: 0, width: size.width, height: size.height, scale: 1},
  }, browser.sessionId);
  await writeFile(path, Buffer.from(result.data, "base64"));
}

function sha256(buffer) {
  return createHash("sha256").update(buffer).digest("hex");
}

function graphNode(id, kind, label, state, projectId = null, limitations = [], reason = null) {
  return {
    id, kind, label, state,
    ...(projectId ? {project_id: projectId} : {}),
    reason: reason || (limitations.length ? "No explicit correlated evidence is available for this stage." : "This node is supplied by the operator graph contract."),
    evidence_count: 0,
    evidence_ids: [],
    limitations,
  };
}

function graphEdge(id, from, to, kind = "explicit_lineage", state = "observed") {
  return {
    id, kind, from, to, state,
    reason: "This exact connection is supplied by the operator graph contract.",
    evidence_count: 0,
    evidence_ids: [],
    limitations: [],
  };
}

function browserGraphs() {
  const project = {kind: "project", project_id: "project-safe", project_label: "demo"};
  return [
    {
      id: "graph:architecture", kind: "architecture", label: "Fleet architecture",
      scope: {kind: "current_user_fleet", project_id: null, project_label: null}, state: "declared",
      nodes: [
        {...graphNode("role:human", "human", "Human", "declared"), reason_code: "inspection_snapshot_missing"},
        graphNode("skill:polish-ticket", "skill", "<img src=x onerror=window.__hostileGraph=1>", "unknown"),
        graphNode("role:build", "role", "Helldiver", "unknown"),
        graphNode("skill:execute-ticket", "skill", "Execute Ticket", "observed"),
      ],
      edges: [
        graphEdge("edge:human:polish", "role:human", "skill:polish-ticket", "membership", "declared"),
        graphEdge("edge:human:build", "role:human", "role:build", "membership", "declared"),
        graphEdge("edge:build:execute", "role:build", "skill:execute-ticket", "pipeline", "declared"),
      ],
      ranks: [["role:human"], ["skill:polish-ticket", "role:build"], ["skill:execute-ticket"]], limitations: [],
    },
    {
      id: "graph:runtime:demo", kind: "project_runtime", label: "demo runtime", scope: project, state: "unknown",
      nodes: [
        graphNode("runtime-project:demo", "project", "demo", "observed", "project-safe"),
        {
          ...graphNode("runtime:demo:build", "role", "Helldiver", "unknown", "project-safe", [], "The scheduled run stopped before producing a result."),
          role: "build", role_id: "build", observed_count: 2,
          terminal_status: "abort", terminal_reason: "dirty",
          impact: "This recorded early stop is not an outage; no completed result was produced.",
        },
        {
          ...graphNode("runtime:demo:release", "role", "Release", "healthy", "project-safe"),
          role: "release", role_id: "release", observed_count: 1,
          terminal_status: "ok", terminal_reason: null,
          impact: "No runtime failure is evidenced for this role in the selected window.",
        },
      ],
      edges: [
        graphEdge("runtime:demo:build", "runtime-project:demo", "runtime:demo:build", "project_role", "scoped"),
        graphEdge("runtime:demo:release", "runtime-project:demo", "runtime:demo:release", "project_role", "scoped"),
      ],
      ranks: [["runtime-project:demo"], ["runtime:demo:build", "runtime:demo:release"]], limitations: [],
    },
    {
      id: "graph:delivery:demo", kind: "delivery", label: "demo delivery", scope: project, state: "incomplete",
      nodes: [
        graphNode("delivery:gap:ask", "missing_stage", "Ask not linked", "unverified", "project-safe", ["ask_evidence_missing"]),
        graphNode("delivery:work:ticket", "ticket", "Ticket", "observed", "project-safe"),
        graphNode("delivery:work:left", "work", "Left branch", "observed", "project-safe"),
        graphNode("delivery:work:right", "work", "Right branch", "observed", "project-safe"),
        graphNode("delivery:work:joined", "work", "Converged work", "observed", "project-safe"),
        graphNode("delivery:pr:safe", "pull_request", "Pull request", "observed", "project-safe"),
        graphNode("delivery:gap:deploy", "missing_stage", "Deploy not linked", "unverified", "project-safe", ["deploy_evidence_missing"]),
        graphNode("delivery:gap:usage", "missing_stage", "Usage outcome not linked", "unverified", "project-safe", ["usage_evidence_missing"]),
      ],
      edges: [
        graphEdge("delivery:ask:ticket", "delivery:gap:ask", "delivery:work:ticket", "missing_stage", "expected"),
        graphEdge("delivery:ticket:left", "delivery:work:ticket", "delivery:work:left"),
        graphEdge("delivery:ticket:right", "delivery:work:ticket", "delivery:work:right"),
        graphEdge("delivery:left:joined", "delivery:work:left", "delivery:work:joined"),
        graphEdge("delivery:right:joined", "delivery:work:right", "delivery:work:joined"),
        graphEdge("delivery:joined:pr", "delivery:work:joined", "delivery:pr:safe", "explicit_outcome"),
        graphEdge("delivery:pr:deploy", "delivery:pr:safe", "delivery:gap:deploy", "missing_stage", "expected"),
        graphEdge("delivery:deploy:usage", "delivery:gap:deploy", "delivery:gap:usage", "missing_stage", "expected"),
      ],
      ranks: [
        ["delivery:gap:ask"], ["delivery:work:ticket"], ["delivery:work:left", "delivery:work:right"],
        ["delivery:work:joined"], ["delivery:pr:safe"], ["delivery:gap:deploy"], ["delivery:gap:usage"],
      ],
      limitations: ["deploy_evidence_missing", "usage_outcome_evidence_missing"],
    },
  ];
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const work = await mkdtemp(join(tmpdir(), "shipyard-dashboard-browser-"));
  const eventsDir = join(work, "events");
  const profile = join(work, "profile");
  const portFile = join(work, "port");
  await mkdir(eventsDir);
  await mkdir(options.screenshotDir, {recursive: true});
  const sentinel = JSON.parse(await readFile(join(here, "fixtures", "operator-sentinel.json"), "utf8"));
  sentinel.unavailable = structuredClone(sentinel.operator);
  sentinel.unavailable.metadata = {
    ...sentinel.unavailable.metadata,
    generated_at: "2026-08-01T11:59:00Z",
    inspection_state: "unavailable",
    refresh_age_seconds: null,
    limitations: ["inspection_refresh_failed", "inspection_snapshot_missing", "relationship_snapshot_missing"],
  };
  sentinel.unavailable.brief = {
    state: "alarm",
    takeaway: "1 completed run needs review",
    action: "Review the linked terminal evidence",
    signals: [
      {id: "promises_verified", label: "Promises verified", value: 0, unit: "promises", state: "waiting", observed: 0, total: 2, limitations: ["promise_evidence_incomplete"]},
      {id: "successful_runs", label: "Successful runs", value: 3, unit: "completed runs", state: "alarm", observed: 3, total: 7, controlled: 3, actionable: 1, limitations: []},
      {id: "attention", label: "Attention", value: null, unit: "groups", state: "unknown", observed: null, total: null, limitations: ["inspection_unavailable"]},
    ],
    attention_groups: [],
    limitations: ["inspection_unavailable"],
  };
  sentinel.unavailable.promises = sentinel.operator.promises.map(promise => ({
    ...promise,
    state: "unverified",
    target: {operator: null, value: null, unit: null},
    observed_value: null,
    evidence_ids: [],
    limitations: ["inspection_unavailable"],
  }));
  sentinel.unavailable.outcomes = {
    ...sentinel.operator.outcomes,
    role_contracts: sentinel.operator.outcomes.role_contracts.map(contract => ({...contract, evidence_ids: ["ev:first"]})),
    reliability: {...sentinel.operator.outcomes.reliability, state: "measured", evidence_ids: ["ev:first"], limitations: []},
    operator_load: {state: "unknown", attention_items: null, evidence_ids: [], limitations: ["operator_attention_unavailable"]},
  };
  sentinel.unavailable.coverage = [
    {source: "fleet_inspection", state: "unavailable", reason: "snapshot_missing", limitations: ["inspection_snapshot_missing", "inspection_unavailable"]},
    {source: "operator_relationships", state: "unavailable", reason: "snapshot_missing", limitations: ["relationship_snapshot_missing"]},
    {source: "operator_events", state: "available", reason: "ok", records_total: 19, limitations: []},
  ];
  sentinel.unavailable.attention = [];
  sentinel.operator.evidence = sentinel.operator.evidence.map(row => row.id === "ev:first"
    ? {...row, reason_code: "inspection_snapshot_missing"}
    : row);
  sentinel.unavailable.evidence = sentinel.operator.evidence;
  sentinel.unavailable.narrative = {
    heading: sentinel.unavailable.brief.takeaway,
    subline: sentinel.unavailable.brief.action,
    focus: sentinel.unavailable.brief.takeaway,
    operator_action: sentinel.unavailable.brief.action,
    beats: [{id: "story:inspection", heading: "Inspection", body: "Fleet inspection evidence is unavailable.", state: "unknown", evidence_ids: []}],
  };
  sentinel.operator.graphs = browserGraphs();
  sentinel.unavailable.graphs = browserGraphs();
  const seed = JSON.parse(await readFile(join(here, "fixtures", "browser-seed.json"), "utf8"));
  const rows = seed.map(({seconds_ago: secondsAgo, ...event}) => ({
    ts: new Date(Date.now() - secondsAgo * 1000).toISOString(),
    ...event,
  }));
  rows.push({
    ts: new Date(Date.now() - 30 * 1000).toISOString(),
    event: "raw.conflict.says.clear",
    project: "raw-only",
    role: "release",
    status: "ok",
    message: "RAW SAYS CLEAR SENTINEL",
  });
  for (let index = 0; index < 12; index += 1) {
    rows.push({
      ts: new Date(Date.now() - (40 + index) * 1000).toISOString(),
      event: `raw.padding.${index}`,
      project: "raw-only",
      role: "release",
      status: "ok",
    });
  }
  const today = new Date().toISOString().slice(0, 10);
  const eventFile = join(eventsDir, `${today}.jsonl`);
  await writeFile(eventFile, rows.map(row => JSON.stringify(row)).join("\n") + "\n{\"broken\":]\n");
  const fixtureBefore = sha256(await readFile(eventFile));
  const server = spawn("python3", ["dashboard/server.py", "--events-dir", eventsDir, "--host", "127.0.0.1", "--port", "0", "--port-file", portFile], {
    cwd: root,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let serverLog = "";
  server.stdout.on("data", chunk => { serverLog += chunk.toString(); });
  server.stderr.on("data", chunk => { serverLog += chunk.toString(); });
  let browser = null;
  let success = false;
  let assertions = 0;
  const verify = {
    equal(actual, expected, message) { assertions += 1; assert.equal(actual, expected, message); },
    notEqual(actual, expected, message) { assertions += 1; assert.notEqual(actual, expected, message); },
    deepEqual(actual, expected, message) { assertions += 1; assert.deepEqual(actual, expected, message); },
    ok(value, message) { assertions += 1; assert.ok(value, message); },
    match(value, pattern, message) { assertions += 1; assert.match(value, pattern, message); },
  };
  const requestOrigins = new Set();
  const requestPaths = [];
  const responseStatuses = [];
  const pageErrors = [];
  const consoleErrors = [];
  const requestErrors = [];
  let operatorRequests = 0;
  let unavailableResponses = 0;
  let recoveredResponses = 0;
  let allowRecovery = false;
  let pausedApi = true;
  const paused = [];
  let screenshotPath = "";
  let degradedScreenshotPath = "";
  let exhaustedScreenshotPath = "";
  let overflow = null;
  let focusOutline = "";
  let scrollBefore = 0;
  let scrollAfter = 0;
  let rawScrollBefore = 0;
  let rawScrollAfter = 0;
  let outcomesHeight = 0;

  try {
    const port = await waitForFile(portFile, server);
    const origin = `http://127.0.0.1:${port}`;
    const executable = await chromiumExecutable();
    browser = await launchBrowser(executable, profile, options.width, options.height);

    const handlePaused = async params => {
      const url = new URL(params.request.url);
      if (url.pathname === "/api/operator") {
        operatorRequests += 1;
        const document = allowRecovery ? sentinel.operator : sentinel.unavailable;
        if (allowRecovery) recoveredResponses += 1;
        else unavailableResponses += 1;
        const body = Buffer.from(JSON.stringify(document)).toString("base64");
        await browser.cdp.send("Fetch.fulfillRequest", {
          requestId: params.requestId,
          responseCode: 200,
          responseHeaders: [
            {name: "Content-Type", value: "application/json; charset=utf-8"},
            {name: "Cache-Control", value: "no-store"},
          ],
          body,
        }, browser.sessionId);
      } else {
        await browser.cdp.send("Fetch.continueRequest", {requestId: params.requestId}, browser.sessionId);
      }
    };

    browser.cdp.on("Network.requestWillBeSent", params => {
      if (/^https?:/.test(params.request.url)) {
        const url = new URL(params.request.url);
        requestOrigins.add(url.origin);
        requestPaths.push(url.pathname + url.search);
      }
    });
    browser.cdp.on("Network.responseReceived", params => {
      if (/^https?:/.test(params.response.url)) {
        const url = new URL(params.response.url);
        responseStatuses.push(`${url.pathname}:${Math.trunc(params.response.status)}`);
      }
    });
    browser.cdp.on("Runtime.exceptionThrown", params => pageErrors.push(params.exceptionDetails.text));
    browser.cdp.on("Runtime.consoleAPICalled", params => {
      if (params.type === "error") consoleErrors.push(params.args.map(arg => arg.value ?? arg.description ?? "console error").join(" "));
    });
    browser.cdp.on("Network.loadingFailed", params => requestErrors.push(params.errorText));
    browser.cdp.on("Fetch.requestPaused", params => {
      if (pausedApi) paused.push(params);
      else handlePaused(params).catch(error => pageErrors.push(error.message));
    });
    await browser.cdp.send("Fetch.enable", {patterns: [{urlPattern: "*/api/*"}]}, browser.sessionId);
    await browser.cdp.send("Page.navigate", {url: origin}, browser.sessionId);
    await waitFor(browser, "document.readyState === 'interactive' || document.readyState === 'complete'", "DOM ready");

    verify.equal(await evaluate(browser, "document.getElementById('loading-state').hidden"), false, "loading state vanished before operator response");
    verify.equal(requestPaths.some(path => path.startsWith("/api/events")), false, "raw events were fetched outside Evidence");
    pausedApi = false;
    for (const params of paused.splice(0)) await handlePaused(params);
    await waitFor(browser, "document.getElementById('operator-state').textContent.startsWith('Fleet inspection unavailable')", "supplied unavailable state");
    verify.equal(await evaluate(browser, "document.getElementById('operator-state').textContent"), "Fleet inspection unavailable · retrying locally", "failed inspection was presented as loading");
    const degraded = await evaluate(browser, `({
      hero: [document.getElementById('brief-takeaway').textContent, document.getElementById('brief-action').textContent, document.querySelector('.brief-hero').dataset.sourceState],
      attention: [
        document.querySelector('[data-signal-id="attention"] .signal-value').textContent,
        document.querySelectorAll('[data-signal-id="attention"] .signal-unit').length,
        document.querySelector('[data-signal-id="attention"] .signal-coverage').textContent,
      ],
      attentionEmpty: document.getElementById('attention-empty').textContent,
      coverage: [...document.querySelectorAll('#coverage-list li')].map(item => item.textContent),
      promiseLimits: [...document.querySelectorAll('.promise-card .quiet')].map(item => item.textContent),
      stableCodesVisible: /inspection_unavailable|inspection_snapshot_missing|relationship_snapshot_missing|snapshot_missing/.test(document.body.innerText),
      reviewControls: [...document.querySelectorAll('.evidence-action')].map(item => [item.textContent, item.disabled]),
      zeroReviewControls: [...document.querySelectorAll('.evidence-action')].filter(item => item.textContent === 'Review 0 records').length,
      overflow: document.documentElement.scrollWidth - innerWidth,
      mutationControls: [...document.querySelectorAll('button')].map(item => item.textContent.trim()).filter(text => /restart|trigger|merge|deploy/i.test(text)),
      mutationForms: document.querySelectorAll('form[method="post"], form[method="put"], form[method="delete"]').length,
    })`);
    verify.deepEqual(degraded.hero, ["1 completed run needs review", "Review the linked terminal evidence", "alarm"], "qualified measured alarm did not lead degraded inspection");
    verify.deepEqual(degraded.attention, ["—", 0, "Coverage unknown"], "unavailable attention retained an inapplicable unit");
    verify.equal(degraded.attentionEmpty, "Inspection-based attention is unavailable.", "unavailable attention retained no-action copy");
    verify.deepEqual(degraded.coverage, [
      "Fleet inspection · Unavailable · Snapshot missing · Limits: Inspection snapshot missing, Inspection unavailable",
      "Operator relationships · Unavailable · Snapshot missing · Limits: Relationship snapshot missing",
      "Operator events · Available · Ok",
    ], "degraded coverage limitations were not human-readable");
    verify.deepEqual(degraded.promiseLimits, ["Limits · Inspection unavailable", "Limits · Inspection unavailable"], "promise limitations leaked machine codes");
    verify.equal(degraded.stableCodesVisible, false, "stable degraded-state codes leaked into operator copy");
    verify.deepEqual(degraded.reviewControls, Array.from({length: 5}, () => ["Review 1 record", false]), "nonzero evidence navigation drifted");
    verify.equal(degraded.zeroReviewControls, 0, "zero-evidence review control was rendered");
    verify.ok(degraded.overflow <= 0, `degraded horizontal overflow: ${degraded.overflow}px`);
    verify.deepEqual(degraded.mutationControls, [], "mutation-like controls appeared while degraded");
    verify.equal(degraded.mutationForms, 0, "mutation form appeared while degraded");
    degradedScreenshotPath = join(resolve(options.screenshotDir), `dashboard-degraded-${options.width}x${options.height}.png`);
    await screenshot(browser, degradedScreenshotPath);
    verify.ok(unavailableResponses >= 1, "unavailable fixture was not held for inspection");
    await waitFor(browser, "document.getElementById('operator-state').textContent === 'Fleet inspection unavailable · automatic retries stopped'", "exhausted unavailable polling", 10000);
    verify.equal(await evaluate(browser, "state.unavailablePolls"), 3, "unavailable polling did not stop at its bound");
    verify.equal(unavailableResponses, 4, "bounded polling did not use the initial response plus three retries");
    const exhaustedRequests = operatorRequests;
    await new Promise(resolvePromise => setTimeout(resolvePromise, 1200));
    verify.equal(operatorRequests, exhaustedRequests, "operator polling continued after exhaustion");
    exhaustedScreenshotPath = join(resolve(options.screenshotDir), `dashboard-exhausted-${options.width}x${options.height}.png`);
    await screenshot(browser, exhaustedScreenshotPath);
    allowRecovery = true;
    await evaluate(browser, "refreshOperator({preserve: true})");
    await waitFor(browser, "document.getElementById('brief-takeaway').textContent === 'Repair observed Shipyard core job failure'", "bounded operator poll");
    verify.equal(recoveredResponses, 1, "fresh recovery did not use one explicit operator response");
    verify.equal(operatorRequests, unavailableResponses + recoveredResponses, "operator response accounting drifted");
    verify.match(await evaluate(browser, "document.getElementById('operator-state').textContent"), /^Updating fleet evidence · showing the last good snapshot from /, "refreshing snapshot was presented as current");
    verify.match(await evaluate(browser, `(() => {
      const original = state.document.metadata.limitations;
      state.document.metadata.limitations = ["event_index_refresh_failed"];
      renderOperatorState();
      const copy = document.getElementById('operator-state').textContent;
      state.document.metadata.limitations = original;
      renderOperatorState();
      return copy;
    })()`), /^Fleet evidence update failed · showing the last good snapshot from /, "failed refresh was presented as current");
    verify.equal(sha256(await readFile(eventFile)), fixtureBefore, "operator reads mutated raw evidence");
    verify.equal(await evaluate(browser, "document.getElementById('window-select').value"), "7d", "shared dashboard did not default to 7d");
    verify.equal(await evaluate(browser, "document.getElementById('brief-takeaway').textContent"), "Repair observed Shipyard core job failure", "core takeaway was not rendered verbatim");
    verify.equal(await evaluate(browser, "document.getElementById('brief-action').textContent"), "Repair 18 observed Shipyard job failures", "qualified core action was not rendered verbatim");
    verify.deepEqual(await evaluate(browser, "[...document.querySelectorAll('.signal-card')].map(card => card.dataset.signalId)"), ["promises_verified", "successful_runs", "attention"], "brief signal order was re-derived");
    verify.equal(await evaluate(browser, "document.querySelector('.attention-summary button').textContent"), "Review 18 records", "summary evidence was not compressed into a count");
    verify.equal(await evaluate(browser, `(() => { const text = document.getElementById('mode-outcomes').innerText; return /\\b[0-9a-f]{16,}\\b/i.test(text); })()`), false, "opaque evidence ID was visible in Outcomes");
    outcomesHeight = await evaluate(browser, "document.getElementById('mode-outcomes').scrollHeight");
    verify.ok(outcomesHeight > 0 && outcomesHeight <= 12000, `Outcomes height ${outcomesHeight}px exceeded the bounded brief`);

    const operatorOrder = await evaluate(browser, `({
      promises: [...document.querySelectorAll('.promise-card')].map(card => [card.dataset.promiseId, card.dataset.sourceState, card.querySelector('.card-title').textContent]),
      attention: [...document.querySelectorAll('.attention-card')].map(card => [card.dataset.attentionId, card.dataset.sourceState, card.querySelector('.card-title').textContent, card.querySelector('.attention-scale').textContent]),
      metrics: [...document.querySelectorAll('.kpi-card')].map(card => [card.dataset.metricGroup, card.dataset.sourceState]),
      brief: [document.getElementById('brief-takeaway').textContent, document.getElementById('brief-action').textContent]
    })`);
    verify.deepEqual(operatorOrder.promises, [
      ["promise:zeta", "violated", "Zeta promise stays first"],
      ["promise:alpha", "verified", "Alpha promise stays second"],
    ], "promise order/state was re-derived");
    verify.deepEqual(operatorOrder.attention, [
      ["attention-group:core-job-failure", "alarm", "Repair observed Shipyard core job failure", "2 items · 18 records · 1 project"],
    ], "core-grouped attention order/counts were re-derived");
    verify.deepEqual(operatorOrder.metrics, [
      ["chains", "incomplete"], ["lineages", "unverified"], ["role_contracts", "partial"],
      ["reliability", "partial"], ["operator_load", "measured"], ["efficiency", "unknown"],
      ["shoulder", "measured"], ["changes", "unknown"],
    ], "outcome/KPI order or states drifted");
    verify.deepEqual(operatorOrder.brief, ["Repair observed Shipyard core job failure", "Repair 18 observed Shipyard job failures"]);
    const semanticTokens = await evaluate(browser, `Object.fromEntries(
      ['complete','incomplete','running','available','measured','partial','observed','declared','fresh','stale','unavailable','future_state']
        .map(value => [value, stateToken(value)]))`);
    verify.deepEqual(semanticTokens, {
      complete: "clear", incomplete: "waiting", running: "signal", available: "signal",
      measured: "measured", partial: "partial", observed: "observed", declared: "declared",
      fresh: "fresh", stale: "stale", unavailable: "unavailable", future_state: "unknown",
    }, "core enum to semantic-token mapping is incomplete");
    verify.equal(await evaluate(browser, "document.querySelector('[data-metric-group=operator_load]').textContent.includes('73')"), true, "supplied operator load lost");
    verify.equal(await evaluate(browser, "document.body.textContent.includes('RAW SAYS CLEAR SENTINEL')"), false, "raw event content escaped Evidence mode");

    await evaluate(browser, "document.getElementById('tab-outcomes').focus()");
    await press(browser, "ArrowRight", "ArrowRight", 39);
    verify.equal(await evaluate(browser, "document.activeElement.id"), "tab-crew", "right arrow did not focus Crew");
    verify.equal(await evaluate(browser, "document.getElementById('mode-crew').hidden"), false, "Crew mode did not activate");
    await waitFor(browser, "document.querySelectorAll('#graph-edges > path').length === 3", "architecture paths");
    const topology = await evaluate(browser, `({
      nodes: [...document.querySelectorAll('.topology-node')].map(item => [item.dataset.nodeId, item.dataset.rank, item.querySelector('.node-card').dataset.sourceState]),
      supplied: state.document.graphs[0].edges.map(edge => [edge.id, edge.from, edge.to]),
      paths: [...document.querySelectorAll('#graph-edges > path')].map(path => [path.dataset.edgeId, path.dataset.from, path.dataset.to]),
      semantic: [...document.querySelectorAll('.route-card')].map(item => [item.dataset.edgeId, item.dataset.from, item.dataset.to]),
      options: [...document.getElementById('graph-select').options].map(option => option.value),
      scope: document.getElementById('graph-scope').textContent,
      adjacentNonedge: Boolean(document.querySelector('#graph-edges > path[data-from="skill:polish-ticket"][data-to="role:build"]')),
      firstWidth: document.querySelector('.node-card').getBoundingClientRect().width,
      firstHeight: document.querySelector('.node-card').getBoundingClientRect().height,
      activityDisplay: getComputedStyle(document.querySelector('[data-node-id="role:build"] .activity-mark')).display,
      activityAnimation: getComputedStyle(document.querySelector('[data-node-id="skill:execute-ticket"] .activity-mark')).animationName
    })`);
    verify.deepEqual(topology.nodes, [
      ["role:human", "0", "declared"], ["skill:polish-ticket", "1", "unknown"],
      ["role:build", "1", "unknown"], ["skill:execute-ticket", "2", "observed"],
    ], "supplied graph ranks or states were re-derived");
    verify.deepEqual(topology.paths, topology.supplied, "rendered architecture paths differ from supplied endpoints");
    verify.deepEqual(topology.semantic, topology.supplied, "semantic connections differ from supplied endpoints");
    verify.deepEqual(topology.options, ["graph:architecture", "graph:runtime:demo", "graph:delivery:demo"], "graph selector lost supplied graphs");
    verify.equal(topology.scope, "Scope · current-user Shipyard fleet", "fleet scope is ambiguous");
    verify.equal(topology.adjacentNonedge, false, "an adjacent non-edge was drawn");
    verify.ok(topology.firstWidth >= 44 && topology.firstHeight >= 44, "graph node target is below 44px");
    verify.notEqual(topology.activityDisplay, "none", "reduced motion removed the static activity mark");
    verify.equal(topology.activityAnimation, "none", "reduced motion retained an activity pulse");
    verify.equal(await evaluate(browser, `(() => {
      const term = [...document.querySelectorAll('#crew-selection dt')].find(item => item.textContent === 'reason code');
      return term?.nextElementSibling?.textContent;
    })()`), "Inspection snapshot missing", "Crew reason_code leaked a machine code");
    verify.deepEqual(await evaluate(browser, `(() => {
      const vertical = innerWidth <= 700;
      return [...document.querySelectorAll('#graph-edges > path')].map(path => {
        const from = document.querySelector('[data-node-id="' + CSS.escape(path.dataset.from) + '"] .node-card').getBoundingClientRect();
        const to = document.querySelector('[data-node-id="' + CSS.escape(path.dataset.to) + '"] .node-card').getBoundingClientRect();
        return vertical ? from.bottom <= to.top : from.right <= to.left;
      });
    })()`), [true, true, true], "architecture did not follow viewport direction");

    await evaluate(browser, "document.querySelector('[data-node-id=\"role:build\"] .node-card').focus()");
    focusOutline = await evaluate(browser, "getComputedStyle(document.activeElement).outlineWidth");
    verify.notEqual(focusOutline, "0px", "crew focus indicator is invisible");
    await press(browser, "Enter", "Enter", 13);
    verify.equal(await evaluate(browser, "document.querySelector('[data-node-id=\"role:build\"] .node-card').getAttribute('aria-pressed')"), "true", "keyboard node selection failed");

    await evaluate(browser, `(() => {
      const select = document.getElementById('graph-select');
      select.value = 'graph:runtime:demo';
      select.dispatchEvent(new Event('change', {bubbles: true}));
    })()`);
    await waitFor(browser, "document.querySelectorAll('#graph-edges > path').length === 2", "runtime graph paths");
    verify.equal(await evaluate(browser, "document.getElementById('graph-scope').textContent"), "Scope · project demo (project-safe)", "runtime project scope is ambiguous");
    const runtimeCard = await evaluate(browser, "document.querySelector('[data-node-id=\"runtime:demo:build\"] .node-card').textContent");
    verify.equal(runtimeCard.includes("2 observations"), true, "runtime card omits its observation count");
    verify.equal(runtimeCard.includes("Terminal · abort / Dirty"), true, "runtime card omits its terminal outcome and reason");
    verify.equal(runtimeCard.includes("not an outage"), true, "runtime card omits the controlled impact");
    await evaluate(browser, "document.querySelector('[data-node-id=\"runtime:demo:build\"] .node-card').click()");
    verify.equal(await evaluate(browser, "document.getElementById('crew-selection').textContent.includes('not an outage')"), true, "Helldiver terminal outcome lacks its controlled explanation");

    await evaluate(browser, `(() => {
      const select = document.getElementById('graph-select');
      select.value = 'graph:delivery:demo';
      select.dispatchEvent(new Event('change', {bubbles: true}));
    })()`);
    await waitFor(browser, "document.querySelectorAll('#graph-edges > path').length === 8", "delivery graph paths");
    const deliveryGraph = await evaluate(browser, `({
      supplied: state.document.graphs.find(graph => graph.id === 'graph:delivery:demo').edges.map(edge => [edge.id, edge.from, edge.to]),
      paths: [...document.querySelectorAll('#graph-edges > path')].map(path => [path.dataset.edgeId, path.dataset.from, path.dataset.to]),
      semantic: [...document.querySelectorAll('.route-card')].map(row => [row.dataset.edgeId, row.dataset.from, row.dataset.to]),
      gaps: [...document.querySelectorAll('[data-node-id] .node-kind')].filter(node => node.textContent === 'missing_stage').length,
      scope: document.getElementById('graph-scope').textContent,
      hostileExecuted: window.__hostileGraph === 1,
      hostileElement: Boolean(document.querySelector('#mode-crew img, #mode-crew script'))
    })`);
    verify.deepEqual(deliveryGraph.paths, deliveryGraph.supplied, "branched delivery paths differ from supplied endpoints");
    verify.deepEqual(deliveryGraph.semantic, deliveryGraph.supplied, "delivery semantic connections differ from paths");
    verify.equal(deliveryGraph.gaps, 3, "controlled missing-stage gaps were not visible");
    verify.equal(deliveryGraph.scope, "Scope · project demo (project-safe)", "delivery project scope is ambiguous");
    verify.equal(deliveryGraph.hostileExecuted, false, "hostile graph label executed");
    verify.equal(deliveryGraph.hostileElement, false, "hostile graph label created an element");
    verify.deepEqual(await evaluate(browser, `(() => {
      const endpoints = [...document.querySelectorAll('#graph-edges > path')].map(path => path.dataset.from + '>' + path.dataset.to);
      return {
        branch: endpoints.filter(value => value.startsWith('delivery:work:ticket>')).sort(),
        converge: endpoints.filter(value => value.endsWith('>delivery:work:joined')).sort(),
        adjacentNonedge: endpoints.includes('delivery:work:left>delivery:work:right')
      };
    })()`), {
      branch: ["delivery:work:ticket>delivery:work:left", "delivery:work:ticket>delivery:work:right"],
      converge: ["delivery:work:left>delivery:work:joined", "delivery:work:right>delivery:work:joined"],
      adjacentNonedge: false,
    }, "branch, convergence, or non-edge semantics drifted");
    await evaluate(browser, "renderDocument()");
    await waitFor(browser, "document.querySelectorAll('#graph-edges > path').length === 8", "stable graph selection after refresh");
    verify.equal(await evaluate(browser, "document.getElementById('graph-select').value"), "graph:delivery:demo", "graph selection changed across refresh");

    await evaluate(browser, "document.querySelector('.attention-summary button').click()");
    await waitFor(browser, "document.getElementById('raw-event-count').textContent === '19 raw events'", "lazy raw evidence fetch");
    verify.equal(requestPaths.some(path => path.startsWith("/api/events")), true, "Evidence mode did not fetch raw events");
    verify.equal(await evaluate(browser, "document.querySelector('[data-evidence-id=\"abcdef0123456789abcdef0123456789\"]').getAttribute('aria-current')"), "true", "count drill-in did not select grouped evidence");
    verify.equal(await evaluate(browser, "document.getElementById('mode-evidence').innerText.includes('abcdef0123456789abcdef0123456789')"), true, "opaque ID was not reachable in Evidence");
    await evaluate(browser, "document.querySelector('[data-evidence-id=\"ev:first\"]').click()");
    verify.equal(await evaluate(browser, "document.querySelector('[data-evidence-id=\"ev:first\"]').getAttribute('aria-current')"), "true", "claim evidence selection was lost");
    verify.equal(await evaluate(browser, `(() => {
      const term = [...document.querySelectorAll('#evidence-detail dt')].find(item => item.textContent === 'reason code');
      return term?.nextElementSibling?.textContent;
    })()`), "Inspection snapshot missing", "evidence detail reason_code leaked a machine code");
    const hostileEvidence = await evaluate(browser, `({
      executed: window.__hostile === 1,
      elements: Boolean(document.querySelector('#evidence-detail img, #evidence-detail script')),
      text: document.getElementById('evidence-detail').textContent.includes('<script>window.__hostile=1</script>'),
      rawConflict: document.getElementById('raw-event-list').textContent.includes('raw.conflict.says.clear')
    })`);
    verify.deepEqual(hostileEvidence, {executed: false, elements: false, text: true, rawConflict: true}, "hostile operator text executed or raw evidence was missing");

    await evaluate(browser, `document.querySelector('#raw-event-list button[data-raw-key*="raw.conflict.says.clear"]').click()`);
    verify.equal(await evaluate(browser, "document.getElementById('raw-detail').textContent.includes('RAW SAYS CLEAR SENTINEL')"), true, "raw evidence cannot be inspected inside Evidence");
    const rawSelectionBefore = await evaluate(browser, "document.querySelector('#raw-event-list button[aria-current=true]').dataset.rawKey");
    rawScrollBefore = await evaluate(browser, "document.getElementById('raw-event-list').scrollTo(0, 120); document.getElementById('raw-event-list').scrollTop");
    verify.ok(rawScrollBefore > 0, "raw evidence fixture did not create a meaningful scroll position");

    await evaluate(browser, "document.getElementById('tab-story').click()");
    verify.equal(await evaluate(browser, "document.querySelector('#story-card .story-heading').textContent"), "Zeta beat first", "story did not start in supplied order");
    await evaluate(browser, "document.getElementById('story-next').focus()");
    await press(browser, "Enter", "Enter", 13);
    verify.equal(await evaluate(browser, "document.querySelector('#story-card .story-heading').textContent"), "Alpha beat second", "story keyboard order drifted");
    const hostileStory = await evaluate(browser, `({
      state: document.getElementById('story-card').dataset.sourceState,
      executed: window.__hostile === 1,
      elements: Boolean(document.querySelector('#story-card img, #story-card script')),
      text: document.querySelector('#story-card .story-body').textContent.includes('<script>window.__hostile=1</script>')
    })`);
    verify.deepEqual(hostileStory, {state: "clear", executed: false, elements: false, text: true}, "story copy/state was changed or executed");
    verify.equal(await evaluate(browser, `(() => /\\b[0-9a-f]{16,}\\b/i.test(document.getElementById('mode-story').innerText))()`), false, "opaque evidence ID was visible in Story");

    await evaluate(browser, `(() => {
      document.body.setAttribute('tabindex', '-1'); document.body.focus(); document.body.removeAttribute('tabindex'); window.scrollTo(0, 0);
    })()`);
    await press(browser, "Tab", "Tab", 9);
    verify.equal(await evaluate(browser, "document.activeElement.classList.contains('skip-link')"), true, "skip link is not first keyboard stop");
    await press(browser, "Enter", "Enter", 13);
    verify.equal(await evaluate(browser, "document.activeElement.id"), "main", "skip link did not focus main");

    await evaluate(browser, "document.getElementById('tab-evidence').click()");
    await evaluate(browser, "document.querySelector('[data-evidence-id=\"ev:first\"]').click()");
    scrollBefore = await evaluate(browser, "window.scrollTo(0, Math.min(320, document.documentElement.scrollHeight - innerHeight)); window.scrollY");
    const appended = {ts: new Date().toISOString(), event: "job.end", project: "delta", role: "release", svc: "delta-release", status: "ok", duration_s: 3};
    await appendFile(eventFile, `${JSON.stringify(appended)}\n`);
    await waitFor(browser, "document.getElementById('raw-event-count').textContent === '20 raw events'", "SSE raw refresh", 10000);
    await waitFor(browser, `Math.abs(window.scrollY - ${scrollBefore}) <= 2`, "SSE scroll restoration");
    scrollAfter = await evaluate(browser, "window.scrollY");
    rawScrollAfter = await evaluate(browser, "document.getElementById('raw-event-list').scrollTop");
    verify.equal(await evaluate(browser, "document.querySelector('[data-evidence-id=\"ev:first\"]').getAttribute('aria-current')"), "true", "SSE changed operator evidence selection");
    verify.equal(await evaluate(browser, `document.querySelector('#raw-event-list button[aria-current=true]').dataset.rawKey === ${JSON.stringify(rawSelectionBefore)}`), true, "SSE changed raw evidence selection");
    verify.ok(Math.abs(scrollAfter - scrollBefore) <= 2, `SSE moved scroll from ${scrollBefore} to ${scrollAfter}`);
    verify.ok(Math.abs(rawScrollAfter - rawScrollBefore) <= 2, `SSE moved raw-list scroll from ${rawScrollBefore} to ${rawScrollAfter}`);

    const responsive = await evaluate(browser, `({
      overflow: document.documentElement.scrollWidth - window.innerWidth,
      reduced: matchMedia('(prefers-reduced-motion: reduce)').matches,
      controls: [...document.querySelectorAll('button:not(.node-card)')].map(item => item.textContent.trim()).filter(text => /restart|trigger|merge|deploy/i.test(text)),
      mutationForms: document.querySelectorAll('form[method="post"], form[method="put"], form[method="delete"]').length,
      panels: [...document.querySelectorAll('[role=tabpanel]')].map(item => [item.id, item.hidden]),
      headings: [...document.querySelectorAll('h1,h2,h3')].map(item => item.textContent.trim()),
      graphItems: document.querySelectorAll('#topology-nodes [role=listitem]').length,
      graphTargets: [...document.querySelectorAll('#mode-crew button, #mode-crew select')].every(item => parseFloat(getComputedStyle(item).minHeight) >= 44),
      promiseChildrenContained: [...document.querySelectorAll('.promise-card')].every(card => {
        const bounds = card.getBoundingClientRect();
        return [...card.children].every(child => child.getBoundingClientRect().right <= bounds.right + 1);
      })
    })`);
    overflow = responsive.overflow;
    verify.ok(responsive.overflow <= 0, `horizontal overflow: ${responsive.overflow}px`);
    verify.equal(responsive.reduced, true);
    verify.deepEqual(responsive.controls, [], "mutation-like controls appeared");
    verify.equal(responsive.mutationForms, 0, "mutation form appeared");
    verify.deepEqual(responsive.panels, [["mode-outcomes", true], ["mode-crew", true], ["mode-evidence", false], ["mode-story", true]], "mode visibility is ambiguous");
    verify.deepEqual(responsive.headings, ["Shipyard", "Repair observed Shipyard core job failure", "Needs you", "Crew", "Connections", "Selection", "Evidence", "Story"], "heading hierarchy drifted or retained a redundant Outcomes label");
    verify.equal(responsive.graphItems, 8, "semantic delivery graph is incomplete");
    verify.equal(responsive.graphTargets, true, "crew controls are below 44px");
    verify.equal(responsive.promiseChildrenContained, true, "promise content escaped its card");

    const contrast = await evaluate(browser, `(() => {
      const root = getComputedStyle(document.documentElement);
      const rgb = value => { const hex = root.getPropertyValue(value).trim().slice(1); return [0,2,4].map(i => parseInt(hex.slice(i,i+2),16)/255); };
      const lum = value => rgb(value).map(c => c <= .04045 ? c/12.92 : ((c+.055)/1.055)**2.4).reduce((n,c,i) => n + c*[.2126,.7152,.0722][i],0);
      const ratio = (a,b) => (Math.max(lum(a),lum(b))+.05)/(Math.min(lum(a),lum(b))+.05);
      return Object.fromEntries(['--chalk','--signal','--clear','--waiting','--alarm','--neutral'].map(token => [token, ratio(token,'--hull')]));
    })()`);
    for (const [name, ratio] of Object.entries(contrast)) verify.ok(ratio >= 4.5, `${name} contrast ${ratio} is below 4.5`);

    verify.deepEqual([...requestOrigins], [origin], `requests escaped same origin: ${[...requestOrigins].join(",")}`);
    verify.equal(requestPaths.some(path => path.startsWith("/api/summary") || path.startsWith("/api/health")), false, "legacy semantic endpoints were fetched");
    verify.equal(responseStatuses.some(item => item === "/api/operator:200"), true, "operator HTTP 200 not observed");
    verify.equal(responseStatuses.some(item => item === "/api/events:200"), true, "events HTTP 200 not observed");
    verify.deepEqual(responseStatuses.filter(item => !item.endsWith(":200")), [], "non-200 HTTP response observed");
    verify.deepEqual(requestErrors, [], `request errors: ${requestErrors.join(" | ")}`);
    verify.deepEqual(consoleErrors, [], `console errors: ${consoleErrors.join(" | ")}`);
    verify.deepEqual(pageErrors, [], `page errors: ${pageErrors.join(" | ")}`);

    await evaluate(browser, "document.getElementById('tab-crew').focus(); document.getElementById('tab-crew').click()");
    screenshotPath = join(resolve(options.screenshotDir), `dashboard-${options.width}x${options.height}.png`);
    await screenshot(browser, screenshotPath);
    server.kill("SIGTERM");
    await waitForExit(server);
    await waitFor(browser, "document.getElementById('stream-state').textContent === 'Updates paused; retrying locally'", "disconnected state", 10000);
    verify.equal(await evaluate(browser, "document.getElementById('stream-state').textContent"), "Updates paused; retrying locally");
    success = true;

    console.log(`browser=${browser.version.product} executable=${browser.executable}`);
    console.log(`viewport=${options.width}x${options.height} overflow=${overflow}px outcomes_height=${outcomesHeight}px`);
    console.log(`operator_requests=${operatorRequests} unavailable_responses=${unavailableResponses} recovered_responses=${recoveredResponses} final_inspection_state=stale operator_wins=true`);
    console.log(`modes=Outcomes,Crew,Evidence,Story keyboard=skip,tabs,node,story focus_outline=${focusOutline}`);
    console.log(`graphs=architecture,runtime,branched_delivery paths_equal_supplied=true semantic_equal=true vertical=${options.width <= 700}`);
    console.log(`reduced_motion=static_activity_mark contrast=${JSON.stringify(contrast)}`);
    console.log(`hostile_text_inert=true mutation_controls=0 request_origins=${[...requestOrigins].join(",")}`);
    console.log(`network=operator:200,events:200 raw_only_in_evidence=true`);
    console.log(`sse=20_raw_events operator_selection_preserved=true raw_selection_preserved=true window_scroll=${scrollBefore}:${scrollAfter} raw_scroll=${rawScrollBefore}:${rawScrollAfter}`);
    console.log(`fixture_read_checksum=${fixtureBefore} unchanged_before_authorized_append=true`);
    console.log(`degraded_screenshot=${degradedScreenshotPath}`);
    console.log(`exhausted_screenshot=${exhaustedScreenshotPath}`);
    console.log(`screenshot=${screenshotPath}`);
    console.log(`server_port=${port} server_log_lines=${serverLog.trim().split("\n").filter(Boolean).length}`);
  } finally {
    if (browser) {
      try { await browser.cdp.send("Browser.close"); } catch {}
      try { await waitForExit(browser.child); } catch { browser.child.kill("SIGTERM"); await waitForExit(browser.child); }
      browser.socket.close();
      await new Promise(resolvePromise => setTimeout(resolvePromise, 100));
      verify.deepEqual(processSet(profile), [], "browser processes survived cleanup");
    }
    if (server.exitCode === null && server.signalCode === null) server.kill("SIGTERM");
    const serverExit = await waitForExit(server);
    await rm(work, {recursive: true});
    console.log(`cleanup=browser_closed,temp_removed,server_${serverExit.signal || serverExit.code} success=${success} assertions=${assertions}`);
  }
}

main().catch(error => {
  console.error(error.stack || error.message);
  process.exitCode = 1;
});
