/**
 * `/models` (alt+p or ctrl+l): pi's model picker with the data-handling glyphs from
 * ./model-labels/registry.ts next to each model, and a one-line description for
 * the virtual models in ./routers.ts.
 *
 * It renders inline like the built-in selector, not as an overlay, so it takes
 * the input focus: escape closes the picker instead of reaching the agent.
 *
 * Typing filters fuzzily over name, id, provider, labels and description; tab
 * switches between the enabledModels scope and every available model. Enter
 * switches this session's model, never the saved default: settings.json is
 * Nix-managed, and stock /model keeps alt+s for the default.
 */
import type { Model } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import {
  type Component,
  fuzzyFilter,
  Key,
  matchesKey,
  parseColor,
  type TUI,
  truncateToWidth,
  visibleWidth,
} from "@earendil-works/pi-tui";
import { modelName, providerName } from "./lib/model-names.ts";
import { setModelsClose } from "./lib/models-picker.ts";
import { descriptionFor, LABELS, type Label, labelsFor } from "./model-labels/registry.ts";
import { LADDERS, PROVIDER } from "./routers/kinds.ts";

/** Rows kept free above the footer, so the picker never crowds the editor out. */
const MARGIN_ROWS = 2;
/** Lines the picker spends besides its model rows: two borders, scope, query, count, name, legend, hints and blanks. */
const CHROME = 15;
const MAX_NAME = 28;
const MAX_PROVIDER = 18;
/** Below this the provider column says less than the ellipsis costs. */
const MIN_PROVIDER = 6;
/** Columns the description is guaranteed before the provider column shrinks. */
const MIN_DESCRIPTION = 12;
const MAX_GLYPHS = 12;
/** Claude Code's picker key and pi's; keybindings.json frees both from pi's own bindings. */
const PICKER_KEYS = ["alt+p", "ctrl+l"] as const;

type Cost = { tier: number; text: string };

type Row = {
  model: Model<any>;
  labels: Label[];
  description: string;
  /** What the model is searched by. */
  text: string;
  name: string;
  /** The provider as a person reads it, e.g. `OpenCode Go`. */
  provider: string;
  glyphs: string;
  cost: Cost;
  /** Context window, compacted for the column. */
  context: string;
};

/** `524k`, `1M`, `?` when pi does not know the window. */
const contextText = (tokens: number | undefined): string => {
  if (!tokens) return "?";
  if (tokens >= 1_000_000) return `${Number((tokens / 1_000_000).toFixed(1))}M`;
  return `${Math.floor(tokens / 1000)}k`;
};

/**
 * List price per million tokens, blended 3:1 input:output, which is roughly an
 * agent turn's mix. A subscription bills at list too, so this compares what a
 * pool costs to spend, not money actually paid; `/cost` has the latter.
 */
const blended = (model: Model<any>): number | undefined => {
  const input = model.cost?.input;
  const output = model.cost?.output;
  if (input === undefined || output === undefined) return undefined;
  return (3 * input + output) / 4;
};

/** Price brackets for the glyph column: cheap, middling, pricey. */
const tierOf = (usd: number | undefined): number => {
  if (usd === undefined) return -1;
  if (usd === 0) return 0;
  return usd < 0.5 ? 1 : usd < 4 ? 2 : 3;
};

const priceText = (usd: number | undefined): string =>
  usd === undefined ? "price unknown" : usd === 0 ? "free" : `$${usd.toFixed(2)}/Mtok`;

/** One glyph for every bracket, coloured by it; `?` when the catalogue has no price. */
const COST_GLYPH = "\u{f01c1}";
const costGlyph = (tier: number): string => (tier < 0 ? "?" : COST_GLYPH);

const costColor = (tier: number): "muted" | "success" | "warning" | "error" =>
  tier < 0 || tier === 0 ? "muted" : tier === 1 ? "success" : tier === 2 ? "warning" : "error";

export default function (pi: ExtensionAPI) {
  const find = (ctx: ExtensionContext) => (provider: string, id: string) =>
    ctx.modelRegistry.find(provider, id);

  const cost = (ctx: ExtensionContext, model: Model<any>): Cost => {
    const at = find(ctx);
    // A virtual model spans its ladder: the tier of what it usually runs on, and
    // the range a spent pool can push it into.
    if (model.provider === PROVIDER) {
      const ladder = LADDERS[model.id as keyof typeof LADDERS];
      const prices = (ladder ?? [])
        .flatMap((stage) => stage.variants.map((v) => at(stage.provider, v.id)))
        .map((m) => (m ? blended(m) : undefined))
        .filter((usd): usd is number => usd !== undefined);
      const first = ladder ? at(ladder[0].provider, ladder[0].variants[0].id) : undefined;
      const min = prices.length > 0 ? Math.min(...prices) : undefined;
      const max = prices.length > 0 ? Math.max(...prices) : undefined;
      return {
        tier: tierOf(first ? blended(first) : undefined),
        text:
          min === undefined || max === undefined
            ? "price unknown"
            : min === max
              ? priceText(min)
              : `${priceText(min).replace("/Mtok", "")}–${priceText(max)}`,
      };
    }
    const usd = blended(model);
    return { tier: tierOf(usd), text: priceText(usd) };
  };

  const row = (ctx: ExtensionContext, model: Model<any>): Row => {
    const labels = labelsFor(model, find(ctx));
    const description = descriptionFor(model);
    const name = modelName(model);
    const provider = providerName(model.provider, ctx.modelRegistry);
    return {
      model,
      labels,
      description,
      name,
      provider,
      glyphs: labels.map((label) => LABELS[label].glyph).join(" "),
      cost: cost(ctx, model),
      context: contextText(model.contextWindow),
      text: `${model.provider}/${model.id} ${provider} ${model.name} ${labels.join(" ")} ${description}`,
    };
  };

  /** The open picker, so its key closes what it opened; one at a time. */
  let picker: ModelPicker | undefined;

  const open = async (ctx: ExtensionContext) => {
    if (picker) {
      picker.cancel();
      return;
    }
    const isCurrent = (model: Model<any>) => (ctx.model ? sameModel(model, ctx.model) : false);
    // The catalogue's order, current model first like the built-in selector.
    const available = [...ctx.modelRegistry.getAvailable()]
      .sort((a, b) => {
        const first = Number(isCurrent(b)) - Number(isCurrent(a));
        return first || a.provider.localeCompare(b.provider) || a.id.localeCompare(b.id);
      })
      .map((model) => row(ctx, model));
    const scoped = ctx.scopedModels
      .map((scoped) => available.find((r) => sameModel(r.model, scoped.model)))
      .filter((r): r is Row => r !== undefined);

    const picked = await ctx.ui.custom<Model<any> | undefined>((tui, theme, _keybindings, done) => {
      picker = new ModelPicker(tui, theme, available, scoped, ctx.model, (result) => {
        picker = undefined;
        setModelsClose(undefined);
        done(result);
      });
      // Told to the footer, so its click on the model name closes this instead of stacking a second one.
      setModelsClose(() => picker?.cancel());
      return picker;
    });
    picker = undefined;
    if (!picked) return;
    if (!(await pi.setModel(picked))) {
      ctx.ui.notify(`${picked.provider}/${picked.id} has no credentials`, "warning");
    }
  };

  pi.registerCommand("models", {
    description: "Pick a model, with its data-handling labels",
    handler: (_args, ctx) => open(ctx),
  });
  for (const key of PICKER_KEYS) {
    pi.registerShortcut(key, {
      description: "Pick a model, with its data-handling labels",
      handler: open,
    });
  }
  // A picker torn down with its session never reports back, and a stale handle
  // would make the footer's click do nothing in the next one.
  pi.on("session_start", () => setModelsClose(undefined));
}

/** Whether two catalogue entries name the same model. */
const sameModel = (a: Model<any>, b: Model<any>) => a.provider === b.provider && a.id === b.id;

/** One label as its coloured glyph; capability labels have no colour and stay muted. */
const glyph = (theme: Theme, label: Label): string => {
  const { glyph, color } = LABELS[label];
  return color ? theme.style(glyph, { fg: parseColor(color) }) : theme.fg("muted", glyph);
};

const pad = (text: string, plain: string, width: number) =>
  text + " ".repeat(Math.max(0, width - visibleWidth(plain)));

const padLeft = (text: string, plain: string, width: number) =>
  " ".repeat(Math.max(0, width - visibleWidth(plain))) + text;

/**
 * The picker, laid out like pi's built-in model selector: full-width border
 * lines, scope line, query, models, the selected model's name, and hints.
 * `scoped` empty means the settings scope everything, so there is only the full
 * list.
 */
class ModelPicker implements Component {
  private query = "";
  private index = 0;
  private scope: "scoped" | "all";
  private rows: Row[];

  constructor(
    private readonly tui: TUI,
    private readonly theme: Theme,
    private readonly available: Row[],
    private readonly scoped: Row[],
    private readonly current: Model<any> | undefined,
    private readonly done: (result: Model<any> | undefined) => void,
  ) {
    this.scope = scoped.length > 0 ? "scoped" : "all";
    this.rows = this.source();
  }

  dispose() {}

  invalidate() {}

  /** Close from outside, e.g. its key pressed again. */
  cancel() {
    this.finish(undefined);
  }

  private closed = false;

  private finish(result: Model<any> | undefined) {
    if (this.closed) return;
    this.closed = true;
    this.done(result);
  }

  handleInput(data: string) {
    if (
      matchesKey(data, Key.escape) ||
      matchesKey(data, "ctrl+c") ||
      PICKER_KEYS.some((key) => matchesKey(data, key))
    ) {
      this.finish(undefined);
      return;
    }
    if (matchesKey(data, Key.enter)) {
      this.finish(this.rows[this.index]?.model);
      return;
    }
    if (matchesKey(data, Key.tab) && this.scoped.length > 0) {
      this.scope = this.scope === "scoped" ? "all" : "scoped";
      this.refilter();
      return;
    }
    const step = matchesKey(data, Key.up)
      ? -1
      : matchesKey(data, Key.down)
        ? 1
        : matchesKey(data, Key.pageUp)
          ? -10
          : matchesKey(data, Key.pageDown)
            ? 10
            : 0;
    if (step !== 0) {
      this.move(step);
      return;
    }
    if (matchesKey(data, Key.backspace) || matchesKey(data, Key.delete)) {
      this.query = this.query.slice(0, -1);
      this.refilter();
      return;
    }
    // Printable input, including non-ASCII; escape sequences are multi-character.
    if (data.length === 1 && data >= " ") {
      this.query += data;
      this.refilter();
    }
  }

  render(width: number): string[] {
    const theme = this.theme;
    const rows = this.rows;
    const nameWidth = Math.min(MAX_NAME, Math.max(0, ...rows.map((r) => visibleWidth(r.name))));
    const glyphWidth = Math.min(
      MAX_GLYPHS,
      Math.max(0, ...rows.map((r) => visibleWidth(r.glyphs))),
    );
    const providerMax = Math.min(
      MAX_PROVIDER,
      Math.max(0, ...rows.map((r) => visibleWidth(r.provider))),
    );
    const costWidth = Math.max(0, ...rows.map((r) => costGlyph(r.cost.tier).length));
    const contextWidth = Math.max(0, ...rows.map((r) => visibleWidth(r.context)));
    // The column gives way before the name and the description do: when the rest of
    // the row needs the space, it shrinks and a long provider name truncates.
    const rest =
      4 + nameWidth + 2 + contextWidth + 2 + costWidth + 2 + glyphWidth + 2 + MIN_DESCRIPTION;
    const providerWidth = Math.min(providerMax, Math.max(MIN_PROVIDER, width - rest));

    // Stay inside the interactive area; the picker is not an overlay.
    const room = Math.max(3, this.tui.terminal.rows - MARGIN_ROWS - CHROME);
    const start = Math.max(0, Math.min(this.index - Math.floor(room / 2), rows.length - room));
    const visible = rows.slice(start, start + room);
    const body =
      rows.length === 0
        ? [theme.fg("muted", "  No matching models")]
        : visible.map((r, i) =>
            this.line(
              r,
              start + i === this.index,
              { nameWidth, providerWidth, glyphWidth, costWidth, contextWidth },
              width,
            ),
          );

    const enabled = this.scope === "scoped";
    const part = (name: "all" | "enabled", active: boolean) =>
      theme.fg(active ? "accent" : "muted", name);
    const both = this.scoped.length > 0;
    const scope =
      theme.fg("muted", "Scope: ") +
      part("all", !enabled) +
      (both ? theme.fg("muted", " | ") + part("enabled", enabled) : "");
    const selected = rows[this.index];
    const border = theme.fg("border", "─".repeat(Math.max(1, width)));

    return [
      border,
      "",
      scope,
      theme.fg("muted", `tab scope (${enabled ? "all" : "enabled"})`),
      "",
      `${theme.fg("accent", ">")} ${this.query}${theme.style(" ", { inverse: true })}`,
      "",
      ...body,
      "",
      theme.fg("muted", `  (${rows.length === 0 ? 0 : this.index + 1}/${rows.length})`),
      "",
      theme.fg("muted", `  Model Name: ${selected ? this.describe(selected) : ""}`),
      "",
      `  ${this.legend()}`,
      "",
      theme.fg("dim", "  Enter to select   tab scope   Escape/Ctrl+C to cancel"),
      border,
    ];
  }

  /** The rows of the active scope, filtered by the query. */
  private source(): Row[] {
    return this.scope === "scoped" ? this.scoped : this.available;
  }

  /** The selected model's name and list price, under the list as in the built-in selector. */
  private describe(row: Row): string {
    return `${row.name}  ${row.cost.text}`;
  }

  /** Only the glyphs in scope, so a legend never explains marks that are not shown. */
  private legend(): string {
    const theme = this.theme;
    const present = new Set(this.source().flatMap((r) => r.labels));
    const entries = (Object.keys(LABELS) as Label[])
      .filter((label) => present.has(label))
      .map((label) => `${glyph(theme, label)} ${theme.fg("dim", LABELS[label].meaning)}`);
    return entries.join(theme.fg("dim", "   "));
  }

  private refilter() {
    this.index = 0;
    this.rows = this.query ? fuzzyFilter(this.source(), this.query, (r) => r.text) : this.source();
    this.tui.requestRender();
  }

  private move(step: number) {
    if (this.rows.length === 0) return;
    this.index = Math.max(0, Math.min(this.rows.length - 1, this.index + step));
    this.tui.requestRender();
  }

  private line(
    row: Row,
    selected: boolean,
    columns: {
      nameWidth: number;
      providerWidth: number;
      glyphWidth: number;
      costWidth: number;
      contextWidth: number;
    },
    width: number,
  ) {
    const { nameWidth, providerWidth, glyphWidth, costWidth, contextWidth } = columns;
    const theme = this.theme;
    const cursor = selected ? theme.fg("accent", "→ ") : "  ";
    const current = this.current !== undefined && sameModel(row.model, this.current);
    const marker = current ? theme.fg("accent", "✓ ") : "  ";
    // Bold marks the model in use: with the provider column beside it, the check
    // alone is too easy to lose.
    const name = selected
      ? theme.bold(theme.fg("accent", row.name))
      : current
        ? theme.bold(theme.fg("text", row.name))
        : theme.fg("text", row.name);
    const provider = padLeft(
      theme.fg("dim", truncateToWidth(row.provider, providerWidth, "…")),
      row.provider,
      providerWidth,
    );
    const glyphs = row.labels.map((label) => glyph(theme, label)).join(" ");
    const cost = costGlyph(row.cost.tier);
    const price = padLeft(theme.fg(costColor(row.cost.tier), cost), cost, costWidth);
    const context = padLeft(theme.fg("dim", row.context), row.context, contextWidth);
    const line =
      `${cursor}${marker}${provider}  ${pad(name, row.name, nameWidth)}  ` +
      `${context}  ${price}  ${pad(glyphs, row.glyphs, glyphWidth)}  ${theme.fg("muted", row.description)}`;
    return truncateToWidth(line, width, "…", true);
  }
}
