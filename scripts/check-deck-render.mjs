#!/usr/bin/env node
// check-deck-render.mjs — render the deck in a real browser and assert the DOM
// structure the CSS and the click handlers assume.
//
// The deck injects clickable glossary elements into authored prose. If that
// injection ever emits an INTERACTIVE element inside another interactive
// element, the HTML parser closes the outer one and reparents everything after
// it — the card's chip and chevron escape their flex row and stop responding to
// clicks. This script is the guard: it opens every crew drawer and checks that
// each skill item still has exactly [skill-toggle, skill-body], that the toggle
// still owns its disposition chip and chevron, and that clicking either of them
// expands the card.
//
// Usage:  node scripts/check-deck-render.mjs [--port <n>]
//
// Exit codes:  0 = all assertions pass
//              1 = an assertion failed (findings printed)
//              3 = SKIPPED: playwright unavailable (not a failure)
//
// Playwright is resolved from the ambient node resolution paths, or from
// $PLAYWRIGHT_MODULE_DIR / $NODE_PATH when it lives outside this repo. Nothing
// machine-specific is baked in — a checkout without playwright skips cleanly.

import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const DOCS = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'docs');

async function loadPlaywright() {
  const dirs = [process.env.PLAYWRIGHT_MODULE_DIR, ...(process.env.NODE_PATH || '').split(':')]
    .filter(Boolean);
  try {
    return await import('playwright');
  } catch { /* fall through to explicit dirs */ }
  for (const dir of dirs) {
    try {
      const require = createRequire(path.join(dir, 'noop.js'));
      return require('playwright');
    } catch { /* try the next one */ }
  }
  return null;
}

const MIME = { '.html': 'text/html', '.css': 'text/css', '.json': 'application/json',
               '.js': 'text/javascript', '.svg': 'image/svg+xml' };

function serve(root) {
  const server = http.createServer(async (req, res) => {
    const rel = decodeURIComponent(req.url.split('?')[0]).replace(/^\/+/, '') || 'index.html';
    const file = path.join(root, rel);
    if (!file.startsWith(root)) { res.writeHead(403).end(); return; }
    try {
      const body = await fs.readFile(file);
      res.writeHead(200, { 'content-type': MIME[path.extname(file)] || 'application/octet-stream' });
      res.end(body);
    } catch {
      res.writeHead(404).end('not found');
    }
  });
  return new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve(server)));
}

const argPort = (() => {
  const i = process.argv.indexOf('--port');
  return i > -1 ? Number(process.argv[i + 1]) : 0;
})();

const pw = await loadPlaywright();
if (!pw) {
  console.log('SKIPPED: playwright not available (set PLAYWRIGHT_MODULE_DIR or NODE_PATH to enable)');
  process.exit(3);
}

const server = argPort ? await new Promise(r => {
  const s = http.createServer(); s.listen(argPort, '127.0.0.1', () => r(s));
}) : await serve(DOCS);
const port = server.address().port;
if (argPort) { server.close(); }
const live = argPort ? null : server;
const base = `http://127.0.0.1:${port}`;

const findings = [];
const browser = await pw.chromium.launch({ headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  await page.goto(`${base}/index.html`, { waitUntil: 'load' });
  await page.waitForSelector('.loop-node');

  const crews = await page.$$eval('.loop-node', ns => ns.map(n => n.dataset.crew).filter(Boolean));
  if (!crews.length) findings.push('no crew nodes rendered — deck data failed to load');

  for (const crew of crews) {
    await page.evaluate(c => {
      const close = document.getElementById('crew-drawer-close');
      if (close) close.click();
      const n = [...document.querySelectorAll('.loop-node')].find(e => e.dataset.crew === c);
      if (n) n.click();
    }, crew);
    await page.waitForSelector('#crew-drawer-body .skill-item');

    // 1 + 2: structure — no element may escape the toggle.
    const structural = await page.$$eval('#crew-drawer-body .skill-item', items => items.map(it => {
      const toggle = it.querySelector('.skill-toggle');
      return {
        name: toggle ? toggle.innerText.split('\n')[0] : '(no toggle)',
        children: [...it.children].map(c => c.className || c.tagName),
        chipInToggle: !!(toggle && toggle.querySelector('.disposition')),
        chevInToggle: !!(toggle && toggle.querySelector('.chev')),
      };
    }));
    for (const s of structural) {
      const expected = ['skill-toggle', 'skill-body'];
      if (s.children.length !== 2 || s.children[0] !== expected[0] || s.children[1] !== expected[1]) {
        findings.push(`${crew}/"${s.name}": .skill-item children are [${s.children}] — expected [${expected}]`);
      }
      if (!s.chipInToggle) findings.push(`${crew}/"${s.name}": .disposition escaped the toggle`);
      if (!s.chevInToggle) findings.push(`${crew}/"${s.name}": .chev escaped the toggle`);
    }

    // 3: behavior — chevron and chip must expand the card.
    const clicks = await page.$$eval('#crew-drawer-body .skill-item', items => items.map((it, i) => {
      const name = it.querySelector('.skill-toggle')?.innerText.split('\n')[0] || `#${i}`;
      const res = { name, chev: null, chip: null };
      for (const [key, sel] of [['chev', '.chev'], ['chip', '.disposition']]) {
        const el = it.querySelector(sel);
        if (!el) { res[key] = 'missing'; continue; }
        it.classList.remove('open');
        el.click();
        res[key] = it.classList.contains('open') ? 'opens' : 'dead';
        it.classList.remove('open');
      }
      return res;
    }));
    for (const c of clicks) {
      if (c.chev !== 'opens') findings.push(`${crew}/"${c.name}": clicking .chev does not expand the card (${c.chev})`);
      if (c.chip !== 'opens') findings.push(`${crew}/"${c.name}": clicking .disposition does not expand the card (${c.chip})`);
    }
  }

  // 4: the glossary popover still works from inside a skill summary.
  const gloss = await page.evaluate(() => {
    const close = document.getElementById('crew-drawer-close');
    if (close) close.click();
    const withGloss = [...document.querySelectorAll('.loop-node')].map(n => n.dataset.crew);
    for (const c of withGloss) {
      const n = [...document.querySelectorAll('.loop-node')].find(e => e.dataset.crew === c);
      n.click();
      const g = document.querySelector('#crew-drawer-body .skill-summary .gloss, #crew-drawer-body .skill-toggle .gloss');
      if (g) { g.click(); const pop = document.querySelector('.gloss-pop');
               return { crew: c, term: g.dataset.term, popover: !!pop, heading: pop?.querySelector('h4')?.textContent }; }
      document.getElementById('crew-drawer-close').click();
    }
    return null;
  });
  if (gloss && !gloss.popover) findings.push(`glossary link in a skill summary (${gloss.term}) opened no popover`);
  if (gloss && gloss.popover && gloss.heading !== gloss.term) {
    findings.push(`glossary popover heading "${gloss.heading}" != term "${gloss.term}"`);
  }
} finally {
  await browser.close();
  if (live) live.close();
}

if (findings.length) {
  console.log(`deck-render: ${findings.length} finding(s)`);
  for (const f of findings) console.log(`  FAIL ${f}`);
  process.exit(1);
}
console.log('deck-render: all assertions pass');
