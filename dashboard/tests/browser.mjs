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
  const seed = JSON.parse(await readFile(join(here, "fixtures", "browser-seed.json"), "utf8"));
  const rows = seed.map(({seconds_ago: secondsAgo, ...event}) => ({
    ts: new Date(Date.now() - secondsAgo * 1000).toISOString(),
    ...event,
  }));
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
  try {
    const port = await waitForFile(portFile, server);
    const origin = `http://127.0.0.1:${port}`;
    const executable = await chromiumExecutable();
    browser = await launchBrowser(executable, profile, options.width, options.height);
    const requests = new Set();
    const pageErrors = [];
    let pauseApi = true;
    const paused = [];
    browser.cdp.on("Network.requestWillBeSent", params => {
      if (/^https?:/.test(params.request.url)) requests.add(new URL(params.request.url).origin);
    });
    browser.cdp.on("Runtime.exceptionThrown", params => pageErrors.push(params.exceptionDetails.text));
    browser.cdp.on("Fetch.requestPaused", params => {
      if (pauseApi) paused.push(params.requestId);
      else browser.cdp.send("Fetch.continueRequest", {requestId: params.requestId}, browser.sessionId).catch(error => pageErrors.push(error.message));
    });
    await browser.cdp.send("Fetch.enable", {patterns: [{urlPattern: "*/api/*"}]}, browser.sessionId);
    await browser.cdp.send("Page.navigate", {url: origin}, browser.sessionId);
    await waitFor(browser, "document.readyState === 'interactive' || document.readyState === 'complete'", "DOM ready");
    assert.equal(await evaluate(browser, "document.getElementById('loading-state').textContent"), "Reading the local event stream…");
    assert.equal(await evaluate(browser, "document.getElementById('loading-state').hidden"), false);
    pauseApi = false;
    for (const requestId of paused.splice(0)) await browser.cdp.send("Fetch.continueRequest", {requestId}, browser.sessionId);
    await waitFor(browser, "document.getElementById('event-total').textContent === '6 events'", "six fixture events");
    assert.equal(sha256(await readFile(eventFile)), fixtureBefore, "initial UI reads mutated the fixture");

    const exactStates = await evaluate(browser, `({
      stale: document.getElementById('stale-state').textContent,
      parse: document.getElementById('parse-state').textContent,
      staleVisible: !document.getElementById('stale-state').hidden,
      parseVisible: !document.getElementById('parse-state').hidden
    })`);
    assert.equal(exactStates.staleVisible, true);
    assert.match(exactStates.stale, /^No new event since .+; inspect scheduler status\.$/);
    assert.equal(exactStates.parseVisible, true);
    assert.equal(exactStates.parse, "One event line could not be read; earlier events remain available.");

    await evaluate(browser, `(() => {
      const input = document.getElementById('filter-event'); input.value = 'does-not-exist';
      input.dispatchEvent(new Event('input', {bubbles: true})); document.getElementById('filter-form').requestSubmit();
    })()`);
    await waitFor(browser, "!document.getElementById('empty-state').hidden", "empty filter state");
    assert.equal(await evaluate(browser, "document.getElementById('empty-state').textContent"), "No Shipyard events in this time range.");
    await evaluate(browser, "document.querySelector('#actionable-list button').click()");
    assert.equal(await evaluate(browser, "document.querySelectorAll('.keel-button[aria-pressed=true]').length"), 0, "filtered actionable produced a false timeline highlight");
    assert.equal(await evaluate(browser, "document.getElementById('event-detail').textContent.includes('notification.decision')"), true);
    await evaluate(browser, `(() => { document.getElementById('filter-event').value = ''; document.getElementById('filter-form').requestSubmit(); })()`);
    await waitFor(browser, "document.getElementById('event-total').textContent === '6 events'", "filter reset");

    await evaluate(browser, `document.querySelector('[aria-label^="Inspect job.end for atlas build"]').focus()`);
    const focusOutline = await evaluate(browser, "getComputedStyle(document.activeElement).outlineWidth");
    assert.notEqual(focusOutline, "0px", "event focus indicator is invisible");
    await press(browser, "Enter", "Enter", 13);
    await waitFor(browser, "document.getElementById('event-detail').textContent.includes('<img src=x onerror=')", "hostile row selected");
    const hostile = await evaluate(browser, `({
      executed: window.__hostile === 1,
      elements: Boolean(document.querySelector('#event-detail img, #event-detail script')),
      text: document.getElementById('event-detail').textContent.includes('<script>window.__hostile=1</script>')
    })`);
    assert.deepEqual(hostile, {executed: false, elements: false, text: true});

    await evaluate(browser, "document.querySelector('.raw-evidence summary').focus()");
    await press(browser, "Enter", "Enter", 13);
    assert.equal(await evaluate(browser, "document.querySelector('.raw-evidence').open"), true);
    assert.equal(await evaluate(browser, "document.querySelector('.raw-evidence pre').textContent.includes('<script>window.__hostile=1</script>')"), true);
    await evaluate(browser, `document.querySelector('[aria-label^="Inspect medic.incident.detected for atlas medic"]').click()`);
    assert.equal(await evaluate(browser, "document.getElementById('event-detail').textContent.includes('/var/tmp/shipyard/logs/atlas-medic.log')"), true);
    await evaluate(browser, `document.querySelector('[aria-label^="Inspect job.end for atlas build"]').click()`);

    await evaluate(browser, `(() => {
      document.body.setAttribute('tabindex', '-1'); document.body.focus(); document.body.removeAttribute('tabindex'); window.scrollTo(0, 0);
    })()`);
    await press(browser, "Tab", "Tab", 9);
    assert.equal(await evaluate(browser, "document.activeElement.classList.contains('skip-link')"), true, "skip link is not first keyboard stop");
    await press(browser, "Enter", "Enter", 13);
    assert.equal(await evaluate(browser, "document.activeElement.id"), "main");

    const responsive = await evaluate(browser, `({
      overflow: document.documentElement.scrollWidth - window.innerWidth,
      table: getComputedStyle(document.querySelector('.table-wrap')).display,
      cards: getComputedStyle(document.getElementById('service-cards')).display,
      filtersOpen: document.getElementById('filter-disclosure').open,
      queueTop: document.querySelector('.actionable-panel').getBoundingClientRect().top,
      matrixTop: document.querySelector('.matrix-panel').getBoundingClientRect().top,
      reduced: matchMedia('(prefers-reduced-motion: reduce)').matches,
      duration: getComputedStyle(document.body).transitionDuration,
      controls: [...document.querySelectorAll('button')].map(item => item.textContent.trim()).filter(text => /restart|trigger|merge|deploy/i.test(text)),
      mutationForms: document.querySelectorAll('form[method="post"], form[method="put"], form[method="delete"]').length
    })`);
    const semantics = await evaluate(browser, `({
      main: document.querySelectorAll('main').length,
      h1: document.querySelectorAll('h1').length,
      sections: document.querySelectorAll('section[aria-labelledby]').length,
      tables: document.querySelectorAll('table th[scope="col"]').length,
      lists: document.querySelectorAll('ol').length,
      disclosures: document.querySelectorAll('details > summary').length
    })`);
    assert.ok(responsive.overflow <= 0, `horizontal overflow: ${responsive.overflow}px`);
    assert.equal(responsive.reduced, true);
    assert.ok(parseFloat(responsive.duration) <= 0.001, `reduced-motion duration remained ${responsive.duration}`);
    assert.deepEqual(responsive.controls, []);
    assert.equal(responsive.mutationForms, 0);
    assert.deepEqual(semantics, {main: 1, h1: 1, sections: 4, tables: 5, lists: 3, disclosures: 2});
    if (options.width <= 800) {
      assert.equal(responsive.table, "none");
      assert.notEqual(responsive.cards, "none");
      assert.equal(responsive.filtersOpen, false);
      assert.ok(responsive.queueTop < responsive.matrixTop, "narrow queue must precede project cards");
      await evaluate(browser, "document.querySelector('#filter-disclosure summary').focus()");
      await press(browser, "Enter", "Enter", 13);
      assert.equal(await evaluate(browser, "document.getElementById('filter-disclosure').open"), true);
      await press(browser, "Enter", "Enter", 13);
      assert.equal(await evaluate(browser, "document.getElementById('filter-disclosure').open"), false);
    } else {
      assert.notEqual(responsive.table, "none");
      assert.equal(responsive.cards, "none");
      assert.equal(responsive.filtersOpen, true);
      assert.ok(Math.abs(responsive.queueTop - responsive.matrixTop) < 2, "desktop matrix and queue do not coexist");
    }

    const contrast = await evaluate(browser, `(() => {
      const root = getComputedStyle(document.documentElement);
      const rgb = value => { const hex = root.getPropertyValue(value).trim().slice(1); return [0,2,4].map(i => parseInt(hex.slice(i,i+2),16)/255); };
      const lum = value => rgb(value).map(c => c <= .04045 ? c/12.92 : ((c+.055)/1.055)**2.4).reduce((n,c,i) => n + c*[.2126,.7152,.0722][i],0);
      const ratio = (a,b) => (Math.max(lum(a),lum(b))+.05)/(Math.min(lum(a),lum(b))+.05);
      return {chalkHull: ratio('--chalk','--hull'), signalHull: ratio('--signal','--hull'), clearHull: ratio('--clear','--hull'), alarmHull: ratio('--alarm','--hull'), chalkBulkhead: ratio('--chalk','--bulkhead')};
    })()`);
    for (const [name, ratio] of Object.entries(contrast)) assert.ok(ratio >= 4.5, `${name} contrast ${ratio} is below 4.5`);

    const selectedBefore = await evaluate(browser, "document.getElementById('event-detail').textContent");
    const scrollBefore = await evaluate(browser, "window.scrollTo(0, Math.min(300, document.documentElement.scrollHeight - innerHeight)); window.scrollY");
    const appended = {ts: new Date().toISOString(), event: "job.end", project: "delta", role: "release", svc: "delta-release", status: "ok", duration_s: 3};
    await writeFile(eventFile, `${await readFile(eventFile, "utf8")}${JSON.stringify(appended)}\n`);
    await waitFor(browser, "document.getElementById('event-total').textContent === '7 events'", "SSE append refresh", 10000);
    await waitFor(browser, `Math.abs(window.scrollY - ${scrollBefore}) <= 2`, "SSE scroll restoration");
    assert.equal(await evaluate(browser, "document.getElementById('event-detail').textContent"), selectedBefore, "SSE changed selected evidence");
    const scrollAfter = await evaluate(browser, "window.scrollY");
    assert.ok(Math.abs(scrollAfter - scrollBefore) <= 2, `SSE moved scroll from ${scrollBefore} to ${scrollAfter}`);

    await evaluate(browser, `(() => {
      const heading = document.querySelector('h1'); heading.setAttribute('tabindex', '-1'); heading.focus(); heading.blur();
    })()`);
    assert.equal(await evaluate(browser, "document.querySelector('.skip-link').matches(':focus')"), false);

    const screenshotPath = join(resolve(options.screenshotDir), `dashboard-${options.width}x${options.height}.png`);
    await screenshot(browser, screenshotPath);
    server.kill("SIGTERM");
    await waitForExit(server);
    await waitFor(browser, "document.getElementById('stream-state').textContent === 'Live updates paused; retrying locally.'", "disconnected state", 10000);
    assert.equal(await evaluate(browser, "document.getElementById('stream-state').textContent"), "Live updates paused; retrying locally.");

    assert.deepEqual([...requests], [origin], `requests escaped loopback: ${[...requests].join(",")}`);
    assert.deepEqual(pageErrors, [], `page errors: ${pageErrors.join(" | ")}`);
    console.log(`browser=${browser.version.product} executable=${browser.executable}`);
    console.log(`viewport=${options.width}x${options.height} overflow=${responsive.overflow}px table=${responsive.table} cards=${responsive.cards} filters_open=${responsive.filtersOpen}`);
    console.log(`states=loading,empty,stale,parse,disconnected exact=true`);
    console.log(`keyboard=skip-link,event-selection,raw-disclosure${options.width <= 800 ? ",filter-disclosure" : ""} focus_outline=${focusOutline}`);
    console.log(`semantics=${JSON.stringify(semantics)} filtered_actionable_highlight=truthful known_paths=result,scheduler_log`);
    console.log(`contrast=${JSON.stringify(contrast)} reduced_motion=${responsive.reduced}`);
    console.log(`hostile_text_inert=true mutation_controls=0 request_origins=${[...requests].join(",")}`);
    console.log(`sse=7_events selection_preserved=true scroll_before=${scrollBefore} scroll_after=${scrollAfter}`);
    console.log(`fixture_read_checksum=${fixtureBefore} unchanged_before_authorized_append=true`);
    console.log(`screenshot=${screenshotPath}`);
    console.log(`server_port=${port} server_log_lines=${serverLog.trim().split("\n").filter(Boolean).length}`);
  } finally {
    if (browser) {
      try { await browser.cdp.send("Browser.close"); } catch {}
      try { await waitForExit(browser.child); } catch { browser.child.kill("SIGTERM"); await waitForExit(browser.child); }
      browser.socket.close();
      await new Promise(resolvePromise => setTimeout(resolvePromise, 100));
      assert.deepEqual(processSet("chrome-headless-shell"), browser.before, "browser process set changed after cleanup");
    }
    if (server.exitCode === null && server.signalCode === null) server.kill("SIGTERM");
    const serverExit = await waitForExit(server);
    await rm(work, {recursive: true});
    console.log(`cleanup=browser_closed,temp_removed,server_${serverExit.signal || serverExit.code}`);
  }
}

main().catch(error => {
  console.error(error.stack || error.message);
  process.exitCode = 1;
});
