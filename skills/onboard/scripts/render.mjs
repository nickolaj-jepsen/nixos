#!/usr/bin/env node
// Usage: render.mjs <report.md>. Renders each fenced mermaid block to assets/<report>-<n>.svg
// beside the report and links it above the block. Reruns replace links and SVGs in place.
// Pele 1.13.0 is vendored from npm (dist/pele.js, MIT, see vendor/LICENSE).
import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { render } from "./vendor/pele.js";

const report = process.argv[2];
if (!report) {
  console.error("usage: render.mjs <report.md>");
  process.exit(2);
}

const stem = basename(report, ".md");
const assets = join(dirname(report), "assets");
const link = (n) => `![Diagram ${n}](assets/${stem}-${n}.svg)`;
const isOurLink = (line) => line?.startsWith("![Diagram ") && line.includes(`(assets/${stem}-`);

const lines = readFileSync(report, "utf8").split("\n");
const out = [];
const svgs = [];
const errors = [];

for (let i = 0; i < lines.length; i++) {
  const open = lines[i].match(/^\s*(`{3,}|~{3,})mermaid\s*$/);
  if (!open) {
    out.push(lines[i]);
    continue;
  }
  let end = i + 1;
  while (end < lines.length && !lines[end].trim().startsWith(open[1])) end++;
  const n = svgs.length + 1;
  try {
    svgs.push(render(lines.slice(i + 1, end).join("\n")).svg);
  } catch (e) {
    svgs.push(null);
    errors.push(`${report}:${i + 1}: ${String(e.message).slice(0, 300)}`);
  }
  while (out.at(-1) === "") out.pop();
  if (isOurLink(out.at(-1))) out.pop();
  while (out.at(-1) === "") out.pop();
  if (out.length) out.push("");
  out.push(link(n), "", ...lines.slice(i, end + 1));
  i = end;
}

if (errors.length) {
  console.error(errors.join("\n"));
  process.exit(1);
}

mkdirSync(assets, { recursive: true });
const ours = new RegExp(`^${stem.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}-\\d+\\.svg$`);
for (const file of readdirSync(assets)) {
  if (ours.test(file)) rmSync(join(assets, file));
}
svgs.forEach((svg, i) => {
  const path = join(assets, `${stem}-${i + 1}.svg`);
  writeFileSync(path, svg);
  console.log(path);
});
writeFileSync(report, out.join("\n"));
