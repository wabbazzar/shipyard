#!/usr/bin/env node

import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {spawn, execFileSync} from "node:child_process";
import {existsSync} from "node:fs";
import {mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile} from "node:fs/promises";
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

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const work = await mkdtemp(join(tmpdir(), "shipyard-dashboard-browser-"));
  const eventsDir = join(work, "events");
  const profile = join(work, "profile");
  const portFile = join(work, "port");
  await mkdir(eventsDir);
  await mkdir(options.screenshotDir, {recursive: true});
  const sentinel = JSON.parse(await readFile(join(here, "fixtures", "operator-sentinel.json"), "utf8"));
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
  let operatorRequests = 0;
  let pausedApi = true;
  const paused = [];
  let screenshotPath = "";
  let overflow = null;
  let focusOutline = "";
  let scrollBefore = 0;
  let scrollAfter = 0;
  let rawScrollBefore = 0;
  let rawScrollAfter = 0;

  try {
    const port = await waitForFile(portFile, server);
    const origin = `http://127.0.0.1:${port}`;
    const executable = await chromiumExecutable();
    browser = await launchBrowser(executable, profile, options.width, options.height);

    const handlePaused = async params => {
      const url = new URL(params.request.url);
      if (url.pathname === "/api/operator") {
        operatorRequests += 1;
        const document = operatorRequests === 1 ? sentinel.unavailable : sentinel.operator;
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
    await waitFor(browser, "document.getElementById('operator-state').textContent.startsWith('unavailable ·')", "supplied unavailable state");
    verify.match(await evaluate(browser, "document.getElementById('operator-state').textContent"), /^unavailable · Wait for the bounded refresh$/, "unavailable state or next step drifted");
    await waitFor(browser, "document.getElementById('narrative-heading').textContent === 'Sentinel promise audit'", "bounded operator poll");
    verify.equal(operatorRequests, 2, "unavailable state did not poll exactly once before fresh document arrived");
    verify.equal(await evaluate(browser, "document.getElementById('operator-state').textContent"), "stale · Inspect sentinel evidence", "adapter manufactured freshness or copy");
    verify.equal(sha256(await readFile(eventFile)), fixtureBefore, "operator reads mutated raw evidence");

    const operatorOrder = await evaluate(browser, `({
      promises: [...document.querySelectorAll('.promise-card')].map(card => [card.dataset.promiseId, card.dataset.sourceState, card.querySelector('.card-title').textContent]),
      attention: [...document.querySelectorAll('.attention-card')].map(card => [card.dataset.attentionId, card.dataset.sourceState, card.querySelector('.card-title').textContent, card.textContent.includes('Priority 99')]),
      metrics: [...document.querySelectorAll('.kpi-card')].map(card => [card.dataset.metricGroup, card.dataset.sourceState]),
      narrative: [document.getElementById('narrative-heading').textContent, document.getElementById('narrative-subline').textContent]
    })`);
    verify.deepEqual(operatorOrder.promises, [
      ["promise:zeta", "violated", "Zeta promise stays first"],
      ["promise:alpha", "verified", "Alpha promise stays second"],
    ], "promise order/state was re-derived");
    verify.deepEqual(operatorOrder.attention, [
      ["attention:zeta", "waiting", "Zeta attention stays first", true],
      ["attention:alpha", "alarm", "Alpha attention stays second", false],
    ], "attention was sorted or reclassified in the adapter");
    verify.deepEqual(operatorOrder.metrics, [
      ["chains", "incomplete"], ["lineages", "unverified"], ["role_contracts", "partial"],
      ["reliability", "partial"], ["operator_load", "measured"], ["efficiency", "unknown"],
      ["shoulder", "measured"], ["changes", "unknown"],
    ], "outcome/KPI order or states drifted");
    verify.deepEqual(operatorOrder.narrative, ["Sentinel promise audit", "Operator truth beats raw noise"]);
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
    const topology = await evaluate(browser, `({
      nodes: [...document.querySelectorAll('.topology-node')].map(item => [item.dataset.nodeId, item.dataset.order, item.querySelector('.node-card').dataset.sourceState]),
      edges: [...document.querySelectorAll('.route-card')].map(item => [item.dataset.edgeId, item.dataset.order, item.dataset.sourceState]),
      treeRole: document.getElementById('topology-nodes').getAttribute('role'),
      svg: document.querySelectorAll('#mode-crew svg').length,
      display: getComputedStyle(document.getElementById('topology-nodes')).display,
      firstWidth: document.querySelector('.node-card').getBoundingClientRect().width,
      activityDisplay: getComputedStyle(document.querySelector('[data-node-id="role:build"] .activity-mark')).display,
      activityAnimation: getComputedStyle(document.querySelector('[data-node-id="skill:execute-ticket"] .activity-mark')).animationName
    })`);
    verify.deepEqual(topology.nodes, [
      ["skill:polish-ticket", "0", "unknown"], ["role:human", "1", "declared"],
      ["role:build", "2", "alarm"], ["skill:execute-ticket", "3", "observed"],
    ], "node order/state was inferred");
    verify.deepEqual(topology.edges, [
      ["edge:zeta", "0", "declared"], ["edge:alpha", "1", "declared"], ["edge:observed", "2", "observed"],
    ], "edge order/state was inferred");
    verify.equal(topology.treeRole, "tree");
    verify.equal(topology.svg, 0, "narrow map must not rely on squeezed SVG");
    if (options.width <= 700) {
      verify.equal(topology.display, "block", "narrow topology is not a vertical route");
      verify.ok(topology.firstWidth >= 280, `narrow node was squeezed to ${topology.firstWidth}px`);
    } else {
      verify.equal(topology.display, "grid", "wide topology lost its map composition");
    }
    verify.notEqual(topology.activityDisplay, "none", "reduced motion removed the static activity mark");
    verify.equal(topology.activityAnimation, "none", "reduced motion retained an activity pulse");

    await evaluate(browser, "document.querySelector('[data-node-id=\"role:build\"] .node-card').focus()");
    focusOutline = await evaluate(browser, "getComputedStyle(document.activeElement).outlineWidth");
    verify.notEqual(focusOutline, "0px", "crew focus indicator is invisible");
    await press(browser, "Enter", "Enter", 13);
    verify.equal(await evaluate(browser, "document.querySelector('[data-node-id=\"role:build\"] .node-card').getAttribute('aria-pressed')"), "true", "keyboard node selection failed");

    await evaluate(browser, "document.querySelector('[data-promise-id=\"promise:zeta\"] button').click()");
    await waitFor(browser, "document.getElementById('raw-event-count').textContent === '19 raw events'", "lazy raw evidence fetch");
    verify.equal(requestPaths.some(path => path.startsWith("/api/events")), true, "Evidence mode did not fetch raw events");
    verify.equal(await evaluate(browser, "document.querySelector('[data-evidence-id=\"ev:first\"]').getAttribute('aria-current')"), "true", "claim evidence selection was lost");
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
    await writeFile(eventFile, `${await readFile(eventFile, "utf8")}${JSON.stringify(appended)}\n`);
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
      controls: [...document.querySelectorAll('button')].map(item => item.textContent.trim()).filter(text => /restart|trigger|merge|deploy/i.test(text)),
      mutationForms: document.querySelectorAll('form[method="post"], form[method="put"], form[method="delete"]').length,
      panels: [...document.querySelectorAll('[role=tabpanel]')].map(item => [item.id, item.hidden]),
      headings: [...document.querySelectorAll('h1,h2,h3')].map(item => item.textContent.trim()),
      treeItems: document.querySelectorAll('#topology-nodes [role=treeitem]').length
    })`);
    overflow = responsive.overflow;
    verify.ok(responsive.overflow <= 0, `horizontal overflow: ${responsive.overflow}px`);
    verify.equal(responsive.reduced, true);
    verify.deepEqual(responsive.controls, [], "mutation-like controls appeared");
    verify.equal(responsive.mutationForms, 0, "mutation form appeared");
    verify.deepEqual(responsive.panels, [["mode-outcomes", true], ["mode-crew", true], ["mode-evidence", false], ["mode-story", true]], "mode visibility is ambiguous");
    verify.deepEqual(responsive.headings, ["Shipyard", "Outcomes", "Needs you", "Crew", "Skills", "Evidence", "Story"], "headings exceeded the locked short vocabulary");
    verify.equal(responsive.treeItems, 4, "semantic narrow tree is incomplete");

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
    verify.deepEqual(pageErrors, [], `page errors: ${pageErrors.join(" | ")}`);

    if (options.width <= 700) {
      await evaluate(browser, "document.getElementById('tab-crew').focus(); document.getElementById('tab-crew').click()");
    } else {
      await evaluate(browser, "document.getElementById('tab-outcomes').focus(); document.getElementById('tab-outcomes').click()");
    }
    screenshotPath = join(resolve(options.screenshotDir), `dashboard-${options.width}x${options.height}.png`);
    await screenshot(browser, screenshotPath);
    server.kill("SIGTERM");
    await waitForExit(server);
    await waitFor(browser, "document.getElementById('stream-state').textContent === 'Updates paused; retrying locally'", "disconnected state", 10000);
    verify.equal(await evaluate(browser, "document.getElementById('stream-state').textContent"), "Updates paused; retrying locally");
    success = true;

    console.log(`browser=${browser.version.product} executable=${browser.executable}`);
    console.log(`viewport=${options.width}x${options.height} overflow=${overflow}px`);
    console.log(`operator_requests=${operatorRequests} unavailable_poll=true final_inspection_state=stale operator_wins=true`);
    console.log(`modes=Outcomes,Crew,Evidence,Story keyboard=skip,tabs,node,story focus_outline=${focusOutline}`);
    console.log(`topology=nodes:4,edges:3 supplied_order=true narrow_tree=${options.width <= 700}`);
    console.log(`reduced_motion=static_activity_mark contrast=${JSON.stringify(contrast)}`);
    console.log(`hostile_text_inert=true mutation_controls=0 request_origins=${[...requestOrigins].join(",")}`);
    console.log(`network=operator:200,events:200 raw_only_in_evidence=true`);
    console.log(`sse=20_raw_events operator_selection_preserved=true raw_selection_preserved=true window_scroll=${scrollBefore}:${scrollAfter} raw_scroll=${rawScrollBefore}:${rawScrollAfter}`);
    console.log(`fixture_read_checksum=${fixtureBefore} unchanged_before_authorized_append=true`);
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
