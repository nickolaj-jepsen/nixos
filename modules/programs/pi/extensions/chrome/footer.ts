/**
 * The line under the editor: what is answering on the left (provider, model,
 * effort, other extensions' statuses), measurements right-aligned before git.
 * Measurements (context, cost, speed) live on the editor's top border;
 * alarms (quota running out, credit left, a cache miss) appear here only when
 * they say something. Layout and shedding live in `footer-line.ts`; git, usage
 * and stats in their own modules.
 */
import type {
  ExtensionAPI,
  ExtensionContext,
  ReadonlyFooterDataProvider,
  Theme,
} from "@earendil-works/pi-coding-agent";
import type { TuiMouseEvent } from "@earendil-works/pi-tui";
import type { createActions } from "./actions.ts";
import { layoutFooter } from "./footer-line.ts";
import { formatCost, shortPath } from "./format.ts";
import { createGit, PR_COMMAND } from "./git.ts";
import { hitTest, hoverAt, isPlainClick, type Part, type Region } from "./layout.ts";
import type { ChromeState } from "./state.ts";
import { createStats } from "./stats.ts";
import { createUsage, usageAlarm } from "./usage.ts";

type ActiveModel = NonNullable<ExtensionContext["model"]>;

// Font Awesome range of the Nerd Font, present in every version of it. Icons are followed by two
// spaces: terminals draw a non-Mono Nerd Font glyph over the space after it, so one would read as none.
const ICON_MODEL = "\uf2db";
const ICON_EFFORT = "\uf0e7";

const CACHE_WARN_PCT = 90;
const CACHE_ERROR_PCT = 50;
const CONTEXT_WARN_PCT = 60;
const CONTEXT_ERROR_PCT = 85;

// Long, well-known lab names only; Qwen, GLM, Kimi, Nemotron and LongCat keep
// their catalog names. Claude is redundant next to the provider tag.
const MODEL_ALIAS_PATTERNS: ReadonlyArray<readonly [RegExp, string]> = [
  [/\bDeepSeek\b/gi, "DS"],
  [/\bMiniMax\b/gi, "MM"],
  [/\bClaude\s+/gi, ""],
];

// Exceptions the patterns cannot express; add an entry when a model needs a
// name of its own.
const MODEL_ALIASES: Record<string, string> = {};

const modelAlias = (model: ActiveModel): string => {
  const explicit = MODEL_ALIASES[model.id];
  if (explicit) return explicit;
  let alias = model.name || model.id;
  for (const [pattern, replacement] of MODEL_ALIAS_PATTERNS) {
    alias = alias.replace(pattern, replacement);
  }
  return alias.replace(/\s+/g, " ").trim() || model.name || model.id;
};

// Short provider tags; unknown providers fall back to their full id.
const PROVIDER_TAGS: Record<string, string> = {
  "opencode-go": "go",
  tensorx: "tx",
  anthropic: "anth",
  local: "\uf015",
};

const sanitize = (text: string) =>
  text
    .replace(/\x1b\[[0-9;]*[A-Za-z]/g, "")
    .replace(/[\r\n\t]+/g, " ")
    .replace(/ +/g, " ")
    .trim();

export const createFooter = (
  pi: ExtensionAPI,
  state: ChromeState,
  actions: ReturnType<typeof createActions>,
) => {
  const git = createGit(state);
  const usage = createUsage(state);
  const stats = createStats();
  let regions: Region[] = [];

  /** Cost and speed as text; `undefined` when there is nothing worth showing. */
  const meterTexts = (ctx: ExtensionContext) => {
    const model = ctx.model;
    const s = stats.statsFor(ctx, model);
    const paid = (model?.cost.input ?? 0) > 0 || (model?.cost.output ?? 0) > 0;
    return {
      cost: s.cost > 0 || paid ? formatCost(s.cost) : undefined,
      speed:
        s.speed !== undefined && Number.isFinite(s.speed) && s.speed > 0
          ? `${Math.round(s.speed)} t/s`
          : undefined,
    };
  };

  /** The measurements the editor's top border shows next to the context. */
  const meters = (): string[] => {
    const ctx = state.ctx;
    if (!ctx) return [];
    const { cost, speed } = meterTexts(ctx);
    return [cost, speed].filter((text): text is string => text !== undefined);
  };

  const renderLine = (
    width: number,
    theme: Theme,
    footerData: ReadonlyFooterDataProvider,
  ): string => {
    const ctx = state.ctx;
    if (!ctx) {
      regions = [];
      return "";
    }
    const model = ctx.model;
    const s = stats.statsFor(ctx, model);
    const thinking = ctx.thinkingLevel ?? pi.getThinkingLevel();
    const tag = model ? (PROVIDER_TAGS[model.provider] ?? model.provider) : "";

    const alarms: Part[] = [];
    const quota = model ? usageAlarm(usage.provider(model.provider)) : undefined;
    if (quota) alarms.push(quota);
    if (s.cacheHit !== undefined && s.cacheHit < CACHE_WARN_PCT) {
      alarms.push({
        id: "cache",
        text: `cache ${Math.round(s.cacheHit)}%`,
        color: s.cacheHit < CACHE_ERROR_PCT ? "error" : "warning",
      });
    }
    // Only until the editor's top border carries it.
    const percent = state.metersActive ? undefined : ctx.getContextUsage()?.percent;
    if (percent != null) {
      alarms.push({
        id: "context",
        text: `ctx ${Math.floor(percent)}%`,
        color:
          percent >= CONTEXT_ERROR_PCT ? "error" : percent >= CONTEXT_WARN_PCT ? "warning" : "dim",
      });
    }

    const { cost: costText, speed: speedText } = meterTexts(ctx);

    const result = layoutFooter(
      width,
      theme,
      {
        provider: tag
          ? {
              id: "provider",
              text: /^\w/.test(tag) ? `${ICON_MODEL}  ${tag}` : tag,
              color: "dim",
            }
          : undefined,
        // Only the model opens the selector; the provider is just a label.
        model: {
          id: "model",
          text: model ? model.name || model.id : "no model",
          short: model ? modelAlias(model) : undefined,
          color: "dim",
          bold: true,
          tight: true,
          action: actions.model,
        },
        // The effort wears the colour of the editor border, which is keyed to the same level.
        effort:
          model?.reasoning && thinking
            ? {
                id: "effort",
                text: `${ICON_EFFORT}  ${thinking}`,
                color: "muted",
                styled: (t) => t.getThinkingBorderColor(thinking)(`${ICON_EFFORT}  ${thinking}`),
                action: actions.effort,
              }
            : undefined,
        statuses: [...footerData.getExtensionStatuses()]
          .filter(([key]) => key !== "pi-cache-stats")
          .sort(([a], [b]) => a.localeCompare(b))
          .map(([, text]) => sanitize(text))
          .filter(Boolean)
          .map((text, index) => ({ id: `status-${index}`, text, color: "dim" as const })),
        alarms,
        path: { id: "path", text: shortPath(ctx.cwd), color: "dim" },
        // The editor's top border carries these; the footer only does until it is installed.
        cost:
          costText && !state.metersActive
            ? { id: "cost", text: costText, color: "dim" }
            : undefined,
        speed:
          speedText && !state.metersActive
            ? { id: "speed", text: speedText, color: "dim" }
            : undefined,
        git: git.view,
      },
      state.hover,
    );
    regions = result.regions;
    return result.line;
  };

  const track = (ctx: ExtensionContext) => {
    state.ctx = ctx;
    usage.refresh();
    git.retarget(ctx.cwd);
  };

  const mountFooter = (ctx: ExtensionContext) => {
    if (ctx.mode !== "tui" || !ctx.hasUI) return;
    ctx.ui.setFooter((tui, theme, footerData) => {
      state.tui = tui;
      const unsubscribe = footerData.onBranchChange(() => {
        git.schedule(0);
        tui.requestRender();
      });
      git.schedule(0);
      return {
        render: (width: number) => [renderLine(width, theme, footerData)],
        invalidate: () => {},
        handleMouse: (event: TuiMouseEvent) => {
          if (event.type === "move") {
            state.setHover(hoverAt(regions, event.x));
            return undefined;
          }
          const ctx = state.ctx;
          const action = isPlainClick(event) ? hitTest(regions, event.x) : undefined;
          if (!ctx || !action) return undefined;
          void Promise.resolve()
            .then(() => action(ctx))
            .catch(() => {});
          return { handled: true };
        },
        dispose: () => {
          unsubscribe();
          git.dispose();
        },
      };
    });
  };

  pi.on("session_start", (_event, ctx) => {
    state.ctx = ctx;
    stats.reset();
    git.reset(ctx.cwd);
    mountFooter(ctx);
    usage.refresh();
  });

  const repaint = (_event: unknown, ctx: ExtensionContext) => {
    track(ctx);
    state.tui?.requestRender();
  };
  const repaintAndGit = (_event: unknown, ctx: ExtensionContext) => {
    repaint(_event, ctx);
    git.schedule();
  };
  const rescan = (_event: unknown, ctx: ExtensionContext) => {
    stats.reset();
    repaint(_event, ctx);
  };

  pi.on("model_select", repaint);
  pi.on("thinking_level_select", repaint);
  pi.on("message_end", repaint);
  pi.on("agent_start", repaint);
  pi.on("session_info_changed", repaint);
  pi.on("turn_end", repaintAndGit);
  pi.on("agent_end", repaintAndGit);
  pi.on("tool_execution_end", repaintAndGit);
  pi.on("session_compact", rescan);
  pi.on("session_tree", rescan);

  // A pull request created or merged a moment ago should not wait out the TTL.
  pi.on("tool_execution_start", (event) => {
    const command = event.toolName === "bash" ? event.args?.command : undefined;
    if (typeof command === "string" && PR_COMMAND.test(command)) git.markPrDirty();
  });

  pi.on("user_bash", (event, ctx) => {
    if (PR_COMMAND.test(event.command)) git.markPrDirty();
    track(ctx);
    git.schedule();
  });

  return { meters };
};
