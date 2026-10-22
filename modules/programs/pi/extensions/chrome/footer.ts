/**
 * The line under the editor: what is answering on the left (provider, model,
 * effort, other extensions' statuses), measurements right-aligned before git.
 * Steady meters are cost and speed; alarms (quota running out, credit left,
 * a cache miss) appear only when they say something. Layout and shedding live
 * in `footer-line.ts`; git, usage and stats in their own modules.
 */
import type {
  ExtensionAPI,
  ExtensionContext,
  ReadonlyFooterDataProvider,
  Theme,
} from "@earendil-works/pi-coding-agent";
import { layoutFooter } from "./footer-line.ts";
import { formatCost } from "./format.ts";
import { createGit, PR_COMMAND } from "./git.ts";
import type { Part } from "./layout.ts";
import type { ChromeState } from "./state.ts";
import { createStats } from "./stats.ts";
import { createUsage, usageAlarm } from "./usage.ts";

type ActiveModel = NonNullable<ExtensionContext["model"]>;

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
  opencode: "zen",
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

export const createFooter = (pi: ExtensionAPI, state: ChromeState) => {
  const git = createGit(state);
  const usage = createUsage(state);
  const stats = createStats();

  const renderLine = (
    width: number,
    theme: Theme,
    footerData: ReadonlyFooterDataProvider,
  ): string => {
    const ctx = state.ctx;
    if (!ctx) return "";
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
    // Only when the bottom-border gauge could not be drawn.
    const percent = state.gaugeActive ? undefined : ctx.getContextUsage()?.percent;
    if (percent != null) {
      alarms.push({
        id: "context",
        text: `ctx ${Math.floor(percent)}%`,
        color:
          percent >= CONTEXT_ERROR_PCT ? "error" : percent >= CONTEXT_WARN_PCT ? "warning" : "dim",
      });
    }

    const paid = (model?.cost.input ?? 0) > 0 || (model?.cost.output ?? 0) > 0;
    const costText = s.cost > 0 || paid ? formatCost(s.cost) : undefined;
    const speedText =
      s.speed !== undefined && Number.isFinite(s.speed) && s.speed > 0
        ? `${Math.round(s.speed)} t/s`
        : undefined;

    return layoutFooter(width, theme, {
      provider: tag ? { id: "provider", text: tag, color: "dim" } : undefined,
      model: {
        id: "model",
        text: model ? modelAlias(model) : "no model",
        color: "muted",
        tight: true,
      },
      effort:
        model?.reasoning && thinking ? { id: "effort", text: thinking, color: "muted" } : undefined,
      statuses: [...footerData.getExtensionStatuses()]
        .filter(([key]) => key !== "pi-cache-stats")
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([, text]) => sanitize(text))
        .filter(Boolean)
        .map((text, index) => ({ id: `status-${index}`, text, color: "dim" as const })),
      alarms,
      cost: costText ? { id: "cost", text: costText, color: "dim" } : undefined,
      speed: speedText ? { id: "speed", text: speedText, color: "dim" } : undefined,
      git: git.view,
    }).line;
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
};
