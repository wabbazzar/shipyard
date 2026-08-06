#!/usr/bin/env node

import assert from "node:assert/strict";
import {spawnSync} from "node:child_process";
import {mkdirSync, readFileSync} from "node:fs";
import {dirname, join, resolve} from "node:path";
import {fileURLToPath} from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

function parseArgs(argv) {
  const options = {viewport: "1440x900", screenshotDir: null};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (key === "--viewport") options.viewport = value;
    else if (key === "--screenshot-dir") options.screenshotDir = value;
    else throw new Error(`unknown argument: ${key}`);
  }
  const match = /^(\d+)x(\d+)$/.exec(options.viewport);
  if (!match) throw new Error("--viewport must use WIDTHxHEIGHT");
  if (Number(match[1]) < 320 || Number(match[2]) < 480) throw new Error("viewport is below the supported minimum");
  if (!options.screenshotDir) throw new Error("--screenshot-dir is required");
  return options;
}

function runHost(options, host) {
  const outputDir = join(resolve(options.screenshotDir), host);
  const snapshotFile = join(outputDir, "renderer-contract.json");
  mkdirSync(outputDir, {recursive: true});
  const result = spawnSync(process.execPath, [
    join(here, "browser.mjs"),
    "--browser", "chromium",
    "--host", host,
    "--viewport", options.viewport,
    "--screenshot-dir", outputDir,
    "--snapshot-file", snapshotFile,
  ], {encoding: "utf8", maxBuffer: 16 * 1024 * 1024});
  process.stdout.write(result.stdout || "");
  process.stderr.write(result.stderr || "");
  if (result.status !== 0) throw new Error(`${host} browser contract exited ${result.status ?? "without status"}`);
  return JSON.parse(readFileSync(snapshotFile, "utf8"));
}

function compareContracts(standalone, embedded) {
  let assertions = 0;
  const same = (label, left, right) => {
    assertions += 1;
    try {
      assert.deepEqual(left, right);
    } catch (error) {
      error.message = `PARITY MISMATCH ${label}\n${error.message}`;
      throw error;
    }
  };
  const exact = (label, actual, expected) => same(label, actual, expected);

  exact("schema", [standalone.schemaVersion, embedded.schemaVersion], [1, 1]);
  same("viewport", standalone.viewport, embedded.viewport);
  same("locked normalization", standalone.normalization, embedded.normalization);
  exact("normalization list", standalone.normalization, [
    "outer host excluded by renderer-root boundary",
    "declared host provenance hidden and replaced",
    "exact asset origin strings replaced",
    "fixture timestamps replaced",
  ]);
  exact("host kinds", [standalone.host, embedded.host], ["standalone", "embedded"]);
  exact("standalone shell", standalone.hostProof, {
    kind: "standalone", outerNav: null, sentinel: null, provenance: ["", true],
  });
  exact("embedded navigation boundary", embedded.hostProof.outerNav, ["Ice Health", "OperationsShipyardIce host sentinel", false]);
  exact("embedded sentinel boundary", embedded.hostProof.sentinel, ["Ice host sentinel", "rgb(1, 2, 3)", false]);
  exact("embedded provenance input", embedded.hostProof.provenance, ["Ice host · shared Shipyard renderer", false]);

  same("normalized renderer DOM", standalone.renderer.dom, embedded.renderer.dom);
  same("accessibility order", standalone.renderer.accessibility, embedded.renderer.accessibility);
  same("visible renderer copy", standalone.renderer.visibleCopy, embedded.renderer.visibleCopy);
  same("supplied state attributes", standalone.renderer.stateAttributes, embedded.renderer.stateAttributes);
  same("Hearth semantic tokens", standalone.renderer.tokens, embedded.renderer.tokens);
  same("computed state presentation", standalone.renderer.computedStates, embedded.renderer.computedStates);
  same("focus target and outline", standalone.renderer.focus, embedded.renderer.focus);
  same("root-relative responsive geometry", standalone.renderer.geometry, embedded.renderer.geometry);
  same("degraded state", standalone.renderer.interactions.degraded, embedded.renderer.interactions.degraded);
  same("window and back-forward sequence", standalone.renderer.interactions.windows, embedded.renderer.interactions.windows);
  same("operator copy and supplied order", standalone.renderer.interactions.operatorOrder, embedded.renderer.interactions.operatorOrder);
  same("source-state token grammar", standalone.renderer.interactions.semanticTokens, embedded.renderer.interactions.semanticTokens);
  same("architecture nodes and endpoints", standalone.renderer.interactions.architectureGraph, embedded.renderer.interactions.architectureGraph);
  same("delivery nodes and endpoints", standalone.renderer.interactions.deliveryGraph, embedded.renderer.interactions.deliveryGraph);
  same("evidence drill-in", standalone.renderer.interactions.evidence, embedded.renderer.interactions.evidence);
  same("story navigation", standalone.renderer.interactions.story, embedded.renderer.interactions.story);
  const {overflow: standaloneOverflow, ...standaloneResponsive} = standalone.renderer.interactions.responsive;
  const {overflow: embeddedOverflow, ...embeddedResponsive} = embedded.renderer.interactions.responsive;
  same("responsive composition", standaloneResponsive, embeddedResponsive);
  exact("outer-document overflow safety", [standaloneOverflow <= 0, embeddedOverflow <= 0], [true, true]);
  same("contrast", standalone.renderer.interactions.contrast, embedded.renderer.interactions.contrast);
  same("final mode and graph selection", standalone.renderer.interactions.finalMode, embedded.renderer.interactions.finalMode);
  return assertions;
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  mkdirSync(options.screenshotDir, {recursive: true});
  const standalone = runHost(options, "standalone");
  const embedded = runHost(options, "embedded");
  const assertions = compareContracts(standalone, embedded);
  console.log(`parity=standalone:embedded viewport=${options.viewport} success=true assertions=${assertions}`);
  console.log(`normalization=${standalone.normalization.join(" | ")}`);
  console.log(`renderer_dom_bytes=${Buffer.byteLength(standalone.renderer.dom)} accessibility_nodes=${standalone.renderer.accessibility.length} visible_copy_items=${standalone.renderer.visibleCopy.length}`);
  console.log(`screenshots=${resolve(options.screenshotDir)}/standalone,${resolve(options.screenshotDir)}/embedded`);
}

try {
  main();
} catch (error) {
  console.error(error.stack || error.message);
  process.exitCode = 1;
}
