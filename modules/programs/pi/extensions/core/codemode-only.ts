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
 * list `direct` tools, so the guidelines name what is hidden, with its required
 * arguments, since a guessed name fails validation. How to
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
import { isLeanModel } from "../shared/lean-model.ts";
import { isExpensiveModel } from "./lib/model-tier.ts";
import { createRouted } from "../shared/routed-model.ts";
import { isSubagentSession } from "../shared/subagent-session.ts";

const NAME = "codemode_only";
const CODEMODE = "codemode";
const SUBAGENT = "subagent";
// Each name maps to its required arguments. Delegation is here on every model:
// the agent tool's declaration is the second largest in the roster, and a run
// that does not delegate should not pay for it.
const HIDDEN: Record<string, string> = {
  [SUBAGENT]: "{ subagent_type, description, prompt }",
  get_subagent_result: "{ agent_id }",
  steer_subagent: "{ agent_id, message }",
};
const HIDDEN_NAMES = Object.keys(HIDDEN);

// Lean models get this too: it is how `/delegate` and `/workflow` run their children.
const JOIN =
  "Pass `subagent` `run_in_background: true` and join with `get_subagent_result({ agent_id, wait: true })`. A background launch resolves to text, not the id: take it from its `Agent ID:` line, as `/Agent ID: (\\S+)/.exec(launched)[1]`. Without the flag each call blocks until its agent finishes, so several in one script run one after another. A few run at once and the rest queue.";
const DELEGATING = [
  "Reach for a subagent when the work can't be scoped in one guess: a sweep over many files, a search you would otherwise read the whole tree to answer, a second opinion on a change. Not for a path you already know. Hand over the question, not a step list, and say what you want back.",
  "A subagent's result is not shown to the user: summarise it, and check an agent's claimed edits before reporting them done.",
  "Fanning out over many items is scripted orchestration and needs an explicit ask, such as `/delegate` or `/workflow`; a task that would merely benefit from parallelism is not one.",
];
const LEAN =
  "Don't delegate on this model: it serves one request at a time, so a subagent would only queue behind you. Do the work yourself; call `subagent` only when the user explicitly asks for it, as `/delegate` and `/workflow` do.";
// Every file read here is paid for again on each later turn, so volume work
// belongs on a cheap child and judgment stays put.
const EXPENSIVE =
  "This model costs several times a cheap subagent's: hand the wide reads and multi-file searches to `Explore` and independent second opinions to `reviewer`, and keep design, review and small edits here. What you read into this context is paid for again on every later turn.";

const list = (items: string[]) => {
  const quoted = items.map((item) => `\`${item}\``);
  return quoted.length < 2
    ? quoted.join("")
    : `${quoted.slice(0, -1).join(", ")} and ${quoted.at(-1)}`;
};

const guidelines = (active: Set<string>, lean: boolean, expensive: boolean) => {
  const reachable = HIDDEN_NAMES.filter((name) => active.has(name));
  const lines: string[] = [];
  if (reachable.length > 0) {
    const calls = reachable.map((name) => `tools.${name}(${HIDDEN[name]})`);
    lines.push(
      `${list(calls)} ${reachable.length === 1 ? "is" : "are"} left out of your tool list but stay callable from codemode, with the required arguments shown; \`await describeTool("<name>")\` for the optional ones.`,
    );
  }
  if (!active.has(SUBAGENT)) return lines;
  lines.push(JOIN);
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
    const missing = HIDDEN_NAMES.filter((name) => !registered.has(name));
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
        ? [NAME, ...HIDDEN_NAMES]
        : [NAME],
    }),
    async execute() {
      return { content: [{ type: "text", text: "Nothing to do." }], details: undefined };
    },
  });
}
