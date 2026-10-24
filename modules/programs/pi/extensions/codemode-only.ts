/**
 * Hides expensive tool declarations from the model while keeping the tools
 * active, so codemode scripts can still call them. Per-tool `exposure` does this
 * at registration, but every tool hidden here belongs to a package that
 * registers itself `direct`; `prepareLoadout` is the other mechanism, and it
 * runs only while a tool is active. The carrier hides its own declaration too,
 * so the model sees none of this. Without codemode declared only the carrier is
 * hidden, since codemode is the one way left to reach the rest.
 *
 * pi leaves a hidden tool's guidelines out of the prompt and codemode does not
 * list `direct` tools, so the guidelines name what is hidden instead. How to
 * delegate lives here too, not in the rules: those reach every child as project
 * context, and a child holds no agent tools.
 *
 * The delegation lines follow the model that answers, rechecked before every
 * run. A small-context (local) model is told not to delegate: llama-swap serves
 * one request at a time, so a child would only queue behind it. An expensive
 * one is told to hand its volume work to a cheap child, since its own tokens
 * are the scarce ones.
 */
import { Type } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isLeanModel } from "./lib/lean-model.ts";
import { isExpensiveModel } from "./lib/model-tier.ts";
import { createRouted } from "./lib/routed-model.ts";
import { isSubagentSession } from "./lib/subagent-session.ts";

const NAME = "codemode_only";
const CODEMODE = "codemode";
const SUBAGENT = "subagent";
// Delegation is here on every model: the agent tool's declaration is the second
// largest in the roster, and a run that does not delegate should not pay for it.
const HIDDEN = [
  SUBAGENT,
  "get_subagent_result",
  "steer_subagent",
  // pi-background-tasks: bg_run stays declared; its completion notice makes these rarely needed.
  "bg_status",
  "bg_logs",
  "bg_kill",
];

const DELEGATING = [
  "Pass `subagent` `run_in_background: true` and join with `get_subagent_result({ agent_id, wait: true })`. Without the flag each call blocks until its agent finishes, so several in one script run one after another. A few run at once and the rest queue.",
  "Reach for a subagent when the work can't be scoped in one guess: a sweep over many files, a search you would otherwise read the whole tree to answer, a second opinion on a change. Not for a path you already know. Hand over the question, not a step list, and say what you want back.",
  "A subagent's result is not shown to the user: summarise it, and check an agent's claimed edits before reporting them done.",
  "Fanning out over many items is scripted orchestration and needs an explicit ask, such as `/delegate` or `/workflow`; a task that would merely benefit from parallelism is not one.",
];
const LEAN =
  "Don't delegate on this model: it serves one request at a time, so a subagent would only queue behind you. Do the work yourself; call `subagent` only when the user explicitly asks for it, as `/delegate` and `/workflow` do.";
// Every file read here is paid for again on each later turn, so volume work
// belongs on a cheap child and judgment stays put. Plan inherits this model.
const EXPENSIVE =
  "This model costs several times a cheap subagent's: hand the wide reads and multi-file searches to `Explore` and independent second opinions to `reviewer`, and keep design, review and small edits here. What you read into this context is paid for again on every later turn.";

const list = (names: string[]) => {
  const quoted = names.map((name) => `\`${name}\``);
  return quoted.length < 2
    ? quoted.join("")
    : `${quoted.slice(0, -1).join(", ")} and ${quoted.at(-1)}`;
};

const guidelines = (active: Set<string>, lean: boolean, expensive: boolean) => {
  const reachable = HIDDEN.filter((name) => active.has(name));
  const lines: string[] = [];
  if (reachable.length > 0) {
    lines.push(
      `${list(reachable)} ${reachable.length === 1 ? "is" : "are"} left out of your tool list but stay callable: from codemode, call \`tools.<name>\` after \`await describeTool("<name>")\`.`,
    );
  }
  if (reachable.includes("bg_logs") && active.has("bg_run")) {
    lines.push(
      "A background task's output is also at the path `bg_run` returned; `read` it instead.",
    );
  }
  if (!active.has(SUBAGENT)) return lines;
  if (lean) return [...lines, LEAN];
  lines.push(...DELEGATING);
  if (expensive) lines.push(EXPENSIVE);
  return lines;
};

export default function (pi: ExtensionAPI) {
  const routed = createRouted();

  pi.on("session_start", (_event, ctx) => {
    // A child never gets the agent tools, so the warning below would fire on
    // every delegation.
    if (isSubagentSession(ctx)) return;
    // The names are third-party: a package bump that renames one would leave its
    // full declaration in the prompt with nothing to show for it.
    const registered = new Set(pi.getAllTools().map((tool) => tool.name));
    const missing = HIDDEN.filter((name) => !registered.has(name));
    if (missing.length > 0) {
      ctx.ui.notify(
        `codemode_only: not registered, declarations stay visible: ${missing.join(", ")}`,
        "warning",
      );
    }
  });

  // The prompt options are rebuilt for every run, so a model switch drops the old lines.
  pi.on("before_agent_start", (event, ctx) => {
    const active = new Set(pi.getActiveTools());
    if (!active.has(NAME) || !active.has(CODEMODE)) return;
    const answering = routed(ctx)?.model ?? ctx.model;
    event.systemPromptOptions.promptGuidelines.push(
      ...guidelines(active, isLeanModel(ctx.model), isExpensiveModel(answering)),
    );
  });

  pi.registerTool({
    name: NAME,
    label: "Codemode only",
    description: "Hides other tools' declarations. Not for calling.",
    parameters: Type.Object({}),
    prepareLoadout: (loadout) => ({
      hiddenDeclarations: loadout.declared.some((tool) => tool.name === CODEMODE)
        ? [NAME, ...HIDDEN]
        : [NAME],
    }),
    async execute() {
      return { content: [{ type: "text", text: "Nothing to do." }], details: undefined };
    },
  });
}
