// Mermaid on stdin -> self-contained SVG on stdout, via pele.
// Pele themes through CSS custom properties, which rasterizers like resvg
// ignore, so every var() is resolved to a literal before printing.
import { readFileSync } from "node:fs";
import { parseArgs } from "node:util";
import { render } from "pele";

const { values } = parseArgs({
  options: {
    // name=value, sets --pele-<name> (bg, fg, line, accent, series-1, ...).
    var: { type: "string", multiple: true, default: [] },
    font: { type: "string" },
    "mono-font": { type: "string" },
    // Advance width / font size of a monospaced font; lays text out for it.
    "mono-advance": { type: "string" },
  },
});

const vars = Object.fromEntries(
  values.var.map((kv) => {
    const i = kv.indexOf("=");
    if (i < 1) throw new Error(`--var expects name=value, got ${kv}`);
    return [`--pele-${kv.slice(0, i)}`, kv.slice(i + 1)];
  }),
);

const advance = values["mono-advance"] && Number(values["mono-advance"]);
const measurer = advance ? { width: (text, size) => [...text].length * size * advance } : undefined;

const { svg } = render(readFileSync(0, "utf8"), {
  fontFamily: values.font,
  fontFamilyMono: values["mono-font"] ?? values.font,
  measurer,
  responsive: false,
});

// Pele's own --_x shorthands are declared once on the root as `--_x:value`.
for (const [, name, value] of svg.matchAll(/(--_[\w-]+):([^;"]+)/g)) {
  vars[name] ??= value;
}

// Innermost var() first: a fallback containing var() only matches once its inner one is gone.
const VAR = /var\((--[\w-]+)(?:,([^()]*))?\)/g;
let out = svg;
for (let prev; prev !== out; ) {
  prev = out;
  out = out.replace(VAR, (_, name, fallback) => vars[name] ?? fallback ?? "");
}
process.stdout.write(out);
