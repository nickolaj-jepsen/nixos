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
 * list `direct` tools, so the guidelines name what is hidden instead.
 *
 * Small-context models (the local ones) also lose delegation. Pi runs the hook
 * before every request, so a model switch takes effect on the next one.
 */
import { Type } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isLeanModel } from "./lib/lean-model.ts";

const NAME = "codemode_only";
const CODEMODE = "codemode";
const HIDDEN = [
  "get_subagent_result",
  "steer_subagent",
  // pi-background-tasks: bg_run stays declared; its completion notice makes these rarely needed.
  "bg_status",
  "bg_logs",
  "bg_kill",
];
// Not to be called from codemode either, unless the user asks for it.
const DELEGATION_HIDDEN_WHEN_LEAN = [
  // llama-swap serves one model at a time, so subagents would only queue behind the parent.
  "Agent",
  // Not that queue, but the room: its declaration alone is ~5k tokens.
  "SubagentWorkflow",
];

const hidden = (lean: boolean) => [...HIDDEN, ...(lean ? DELEGATION_HIDDEN_WHEN_LEAN : [])];

const list = (names: string[]) => {
  const quoted = names.map((name) => `\`${name}\``);
  return quoted.length < 2
    ? quoted.join("")
    : `${quoted.slice(0, -1).join(", ")} and ${quoted.at(-1)}`;
};

const guidelines = (lean: boolean, active: Set<string>) => {
  const reachable = HIDDEN.filter((name) => active.has(name));
  const delegation = lean ? DELEGATION_HIDDEN_WHEN_LEAN.filter((name) => active.has(name)) : [];
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
  if (delegation.length > 0) {
    const them = delegation.length === 1 ? "it" : "them";
    lines.push(
      `${list(delegation)} ${delegation.length === 1 ? "is" : "are"} left out of your tool list on this model: it serves one request at a time, so a subagent would only queue behind you. Do the work yourself; call ${them} from codemode only when the user explicitly asks for it, as \`/workflow\` does.`,
    );
  }
  return lines;
};

export default function (pi: ExtensionAPI) {
  let lean = false;
  pi.on("session_start", (_event, ctx) => {
    lean = isLeanModel(ctx.model);
    // The names are third-party: a package bump that renames one would leave its
    // full declaration in the prompt with nothing to show for it.
    const registered = new Set(pi.getAllTools().map((tool) => tool.name));
    const missing = hidden(true).filter((name) => !registered.has(name));
    if (missing.length > 0) {
      ctx.ui.notify(
        `codemode_only: not registered, declarations stay visible: ${missing.join(", ")}`,
        "warning",
      );
    }
  });
  pi.on("model_select", (event) => {
    lean = isLeanModel(event.model);
  });

  // The prompt options are rebuilt for every run, so a model switch drops the old lines.
  pi.on("before_agent_start", (event) => {
    const active = new Set(pi.getActiveTools());
    if (!active.has(NAME) || !active.has(CODEMODE)) return;
    event.systemPromptOptions.promptGuidelines.push(...guidelines(lean, active));
  });

  pi.registerTool({
    name: NAME,
    label: "Codemode only",
    description: "Hides other tools' declarations. Not for calling.",
    parameters: Type.Object({}),
    prepareLoadout: (loadout) => ({
      hiddenDeclarations: loadout.declared.some((tool) => tool.name === CODEMODE)
        ? [NAME, ...hidden(lean)]
        : [NAME],
    }),
    async execute() {
      return { content: [{ type: "text", text: "Nothing to do." }], details: undefined };
    },
  });
}
