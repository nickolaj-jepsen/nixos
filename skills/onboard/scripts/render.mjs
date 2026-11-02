#!/usr/bin/env node
// Usage: render.mjs <report.md>. Renders each fenced mermaid block to assets/<report>-<n>.svg
// beside the report and links it above the block. Reruns replace links and SVGs in place.
// Pele 1.13.0 is vendored from npm (dist/pele.js, MIT, see vendor/LICENSE).
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { render } from "./vendor/pele.js";

const report = process.argv[2];
if (!report) {
  console.error("usage: render.mjs <report.md>");
  process.exit(2);
}

const stem = basename(report, ".md");
const stemPattern = stem.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const assets = join(dirname(report), "assets");
const generatedLink = new RegExp(
  `^\\s*!\\[Diagram \\d+\\]\\(assets/${stemPattern}-\\d+\\.svg\\)\\s*$`,
);
const generatedSvg = new RegExp(`^${stemPattern}-\\d+\\.svg$`);
// Any indent counts as a fence: a diagram nested in a list must not be skipped silently.
const fenceOpen = /^(\s*)(`{3,}|~{3,})\s*(.*)$/;

const lines = readFileSync(report, "utf8").split(/\r?\n/);
const out = [];
const svgs = [];
const errors = [];

for (let i = 0; i < lines.length; i++) {
  const line = lines[i];
  if (generatedLink.test(line)) {
    if (lines[i + 1] === "") i++;
    continue;
  }
  const open = line.match(fenceOpen);
  // A backtick fence's info string can't hold backticks; such a line is inline code.
  if (!open || (open[2][0] === "`" && open[3].includes("`"))) {
    out.push(line);
    continue;
  }

  const [, indent, marker, info] = open;
  const closes = (candidate) => {
    const text = candidate.trim();
    return text.length >= marker.length && [...text].every((c) => c === marker[0]);
  };
  let end = i + 1;
  while (end < lines.length && !closes(lines[end])) end++;

  if (info.split(/\s+/)[0] !== "mermaid") {
    out.push(...lines.slice(i, end + 1));
    i = end;
    continue;
  }
  if (end === lines.length) {
    errors.push(`${report}:${i + 1}: unclosed mermaid block`);
    break;
  }

  const body = lines
    .slice(i + 1, end)
    .map((l) => (l.startsWith(indent) ? l.slice(indent.length) : l.trimStart()))
    .join("\n");
  try {
    svgs.push(render(body).svg);
  } catch (e) {
    errors.push(`${report}:${i + 1}: ${String(e.message).slice(0, 300)}`);
  }
  if (out.length && out.at(-1) !== "") out.push("");
  out.push(`${indent}![Diagram ${svgs.length}](assets/${stem}-${svgs.length}.svg)`, "");
  out.push(...lines.slice(i, end + 1));
  i = end;
}

if (errors.length) {
  console.error(errors.join("\n"));
  process.exit(1);
}

if (existsSync(assets)) {
  for (const file of readdirSync(assets)) {
    if (generatedSvg.test(file)) rmSync(join(assets, file));
  }
}
if (svgs.length) mkdirSync(assets, { recursive: true });
svgs.forEach((svg, i) => {
  const path = join(assets, `${stem}-${i + 1}.svg`);
  writeFileSync(path, svg);
  console.log(path);
});
writeFileSync(report, out.join("\n"));
