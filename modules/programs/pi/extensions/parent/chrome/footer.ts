/**
 * The line under the editor: what is answering on the left, alarms and git on
 * the right. Alarms appear only when they say something; the measurements live
 * on the editor's top border and come here only while it is not drawn.
 */
import {
  createLocalBashOperations,
  type ExtensionAPI,
  type ExtensionContext,
  type ReadonlyFooterDataProvider,
  type Theme,
} from "@earendil-works/pi-coding-agent";
import type { TuiMouseEvent } from "@earendil-works/pi-tui";
import type { createActions } from "./actions.ts";
import { agentParts } from "./agents.ts";
import { layoutFooter } from "./footer-line.ts";
import { formatCost, splitPath } from "../lib/format.ts";
import { createGit, PR_COMMAND } from "./git.ts";
import { hitTest, hoverAt, isPlainClick, type Part, type Region } from "./layout.ts";
import { contextColor, type Measurements, type Meter } from "./measurements.ts";
import { modelAlias, providerName, providerShortName } from "../lib/model-names.ts";
import { createRouted } from "../../shared/routed-model.ts";
import type { ChromeState } from "./state.ts";
import { createStats } from "./stats.ts";
import { createUsage } from "./usage.ts";
import { stageTone } from "../../shared/kinds.ts";

type ActiveModel = NonNullable<ExtensionContext["model"]>;

// Font Awesome range of the Nerd Font, present in every version of it. One space follows an icon:
// these fonts draw the glyph into its own cells, so a second one reads as a gap.
const ICON_EFFORT = "\uf0e7";

const CACHE_WARN_PCT = 90;
const CACHE_ERROR_PCT = 50;

// Any CSI (private and colon forms too), then OSC, DCS, PM and APC strings up to BEL or ST.
const TERMINAL_SEQUENCE = /\x1b\[[0-?]*[ -/]*[@-~]|\x1b[\]P^_][\s\S]*?(?:\x07|\x1b\\)/g;

const sanitize = (text: string) =>
  text
    .replace(TERMINAL_SEQUENCE, "")
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
  const routed = createRouted();
  let regions: Region[] = [];

  /** Cost and speed as text; `undefined` when there is nothing worth showing. */
  const meterTexts = (ctx: ExtensionContext, model: ActiveModel | undefined) => {
    const s = stats.statsFor(ctx, model);
    const paid = (model?.cost.input ?? 0) > 0 || (model?.cost.output ?? 0) > 0;
    return {
      cost: s.cost > 0 || paid ? formatCost(s.cost) : undefined,
      // The speed belongs to one reply, so off-turn it is the last number that
      // happened rather than the current one — the busiest part of the border
      // saying nothing.
      speed:
        !ctx.isIdle() && s.speed !== undefined && Number.isFinite(s.speed) && s.speed > 0
          ? `${Math.round(s.speed)} t/s`
          : undefined,
    };
  };

  /** What the editor's top border shows: the context, then the meters; the cost opens /cost. */
  const measurements = (): Measurements => {
    const ctx = state.ctx;
    if (!ctx) return { context: undefined, meters: [] };
    const model = routed(ctx)?.model ?? ctx.model;
    const { cost, speed } = meterTexts(ctx, model);
    const meters = [
      cost === undefined ? undefined : { id: "cost", text: cost, action: actions.cost },
      speed === undefined ? undefined : { id: "speed", text: speed },
    ].filter((meter): meter is Meter => meter !== undefined);
    return { context: stats.contextFor(ctx, model), meters };
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
    const selected = ctx.model;
    const route = routed(ctx);
    const routedTo = route?.model;
    const phase = route?.phase;
    // Provider, quota and stats follow the model that answers.
    const model = routedTo ?? selected;
    const s = stats.statsFor(ctx, model);
    const thinking = ctx.thinkingLevel ?? pi.getThinkingLevel();

    const alarms: Part[] = [];
    const quota = model ? usage.alarm(usage.provider(model.provider)) : undefined;
    if (quota) alarms.push(quota);
    if (s.cacheHit !== undefined && s.cacheHit < CACHE_WARN_PCT) {
      alarms.push({
        id: "cache",
        text: `cache ${Math.round(s.cacheHit)}%`,
        color: s.cacheHit < CACHE_ERROR_PCT ? "error" : "warning",
      });
    }
    // The editor's top border carries the measurements whenever it is drawn.
    const bordered = state.borderDrawn;
    state.borderDrawn = false;
    const percent = bordered ? undefined : stats.contextFor(ctx, model)?.percent;
    if (percent != null) {
      alarms.push({
        id: "context",
        text: `ctx ${Math.floor(percent)}%`,
        color: contextColor(percent),
      });
    }

    const { cost: costText, speed: speedText } = meterTexts(ctx, model);

    // The kind's ladder decides how alarming the answering model is: a later rung
    // means the preferred one ran out, and the credit-backed ones are a warning in
    // their own right. Neutral for a model reached outside the kinds.
    const tone = model ? stageTone(model.provider, model.id) : "normal";
    const modelColor = tone === "alert" ? "error" : tone === "warn" ? "warning" : "dim";

    // The selection names itself only while its router tracks a phase: that is the
    // one thing about it the routed name cannot say.
    const selection = selected && routedTo && phase ? selected.name || selected.id : undefined;
    const modelText = model ? model.name || model.id : "no model";
    // Before the first answer the selection is the name already on show, so its
    // phase rides along instead of repeating it.
    const phased = !selection && phase !== undefined && model === selected;
    const provider = model ? providerName(model.provider, ctx.modelRegistry) : undefined;

    const statusEntries = [...footerData.getExtensionStatuses()].sort(([a], [b]) =>
      a.localeCompare(b),
    );
    const agentStatus = statusEntries.find(([key]) => key === "subagents")?.[1];
    const badges = agentParts(
      agentStatus === undefined ? undefined : sanitize(agentStatus),
      actions.agents,
    );
    const statuses = statusEntries.flatMap(([key, text], index) => {
      // A wording `agents.ts` cannot read would hide the count altogether, so the
      // package's own text stands in until it learns the new shape.
      if (key === "subagents" && badges.length > 0) return badges;
      const plain = sanitize(text);
      return plain ? [{ id: `status-${index}`, text: plain, color: "dim" as const }] : [];
    });

    const path = splitPath(ctx.cwd);

    const result = layoutFooter(
      width,
      theme,
      {
        // One phrase, one target: every part opens the picker and lights together.
        selection:
          selected && selection
            ? {
                id: "model",
                text: selection,
                color: "text",
                bold: true,
                action: actions.model,
              }
            : undefined,
        phase:
          selection && phase
            ? { id: "model", text: `(${phase})`, color: "dim", tight: true, action: actions.model }
            : undefined,
        provider:
          provider === undefined
            ? undefined
            : {
                id: "model",
                text: provider,
                short: providerShortName(provider),
                color: "dim",
                action: actions.model,
              },
        model: {
          id: "model",
          text: phased ? `${modelText} (${phase})` : modelText,
          short: model ? modelAlias(model) : undefined,
          color: modelColor,
          bold: true,
          styled: phased
            ? (t) => t.bold(t.fg(modelColor, modelText)) + t.fg("dim", ` (${phase})`)
            : undefined,
          action: actions.model,
        },
        // The effort wears the colour of the editor border, which is keyed to the same level.
        effort:
          model?.reasoning && thinking
            ? {
                id: "effort",
                text: `${ICON_EFFORT} ${thinking}`,
                color: "muted",
                styled: (t) => t.getThinkingBorderColor(thinking)(`${ICON_EFFORT} ${thinking}`),
                action: actions.effort,
              }
            : undefined,
        statuses,
        alarms,
        path: {
          id: "path",
          text: path.parent + path.name,
          color: "dim",
          // The last segment names the worktree or checkout, so it is the part that reads.
          styled: (t) => t.fg("dim", path.parent) + t.fg("text", path.name),
          action: actions.openFolder,
        },
        cost:
          costText && !bordered
            ? { id: "cost", text: costText, color: "dim", action: actions.cost }
            : undefined,
        speed: speedText && !bordered ? { id: "speed", text: speedText, color: "dim" } : undefined,
        git: git.view,
      },
      state.hover,
    );
    regions = result.regions;
    return result.line;
  };

  const mountFooter = (ctx: ExtensionContext) => {
    ctx.ui.setFooter((tui, theme, footerData) => {
      state.tui = tui;
      const unsubscribe = footerData.onBranchChange(() => {
        git.schedule(0);
        tui.requestRender();
      });
      git.schedule(0);
      git.startPolling();
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
    if (!state.live) return;
    git.start(ctx.cwd);
    mountFooter(ctx);
    usage.refresh();
  });

  const repaint = () => {
    if (!state.live) return;
    usage.refresh();
    state.tui?.requestRender();
  };
  const repaintAndGit = () => {
    if (!state.live) return;
    repaint();
    git.schedule();
  };
  const rescan = () => {
    stats.reset();
    repaint();
  };

  pi.on("model_select", repaint);
  pi.on("thinking_level_select", repaint);
  pi.on("message_end", repaint);
  pi.on("agent_start", repaint);
  pi.on("session_info_changed", repaint);
  pi.on("turn_end", repaintAndGit);
  pi.on("agent_end", repaintAndGit);
  pi.on("session_compact", rescan);
  pi.on("session_tree", rescan);

  // Once the command is done: a lookup while `gh pr create` still runs finds nothing.
  pi.on("tool_result", (event) => {
    const command = event.toolName === "bash" ? event.input.command : undefined;
    if (typeof command === "string" && PR_COMMAND.test(command)) git.markPrDirty();
  });
  pi.on("tool_execution_end", repaintAndGit);

  // user_bash fires before a `!command` runs and nothing fires after it, so the
  // refresh rides on the operations that run it. These are pi's default when no
  // shellPath is set; returning them ends pi's user_bash chain.
  const bash = createLocalBashOperations();
  pi.on("user_bash", (event) => {
    if (!state.live) return;
    const prCommand = PR_COMMAND.test(event.command);
    return {
      operations: {
        exec: async (command, cwd, options) => {
          try {
            return await bash.exec(command, cwd, options);
          } finally {
            if (prCommand) git.markPrDirty();
            repaint();
            git.schedule(0);
          }
        },
      },
    };
  });

  return { measurements };
};
