/**
 * Hides expensive tool declarations from the model while keeping the tools
 * active, so codemode scripts can still call them. Per-tool `exposure` does this
 * at registration, but every tool hidden here belongs to a package that
 * registers itself `direct`; `prepareLoadout` is the other mechanism, and it
 * runs only while a tool is active. The carrier hides its own declaration too,
 * so the model sees none of this.
 *
 * Small-context models (the local ones) get a leaner set. Pi runs the hook
 * before every request, so a model switch takes effect on the next one.
 */
import type { Model } from "@earendil-works/pi-ai";
import { Type } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const NAME = "codemode_only";
// Point the model at each of these some other way, or it won't know they exist.
const HIDDEN = ["get_subagent_result", "steer_subagent"];
const LEAN_MAX_CONTEXT = 131_072;
const HIDDEN_WHEN_LEAN = [
  // llama-swap serves one model at a time, so subagents would only queue behind the parent.
  "Agent",
  // Not that queue, but the room: its declaration alone is ~5k tokens.
  "SubagentWorkflow",
  // pi-background-tasks: bg_run stays declared; its completion notice makes these rarely needed.
  "bg_status",
  "bg_logs",
  "bg_kill",
];

const isLean = (model: Model<any> | undefined) =>
  model?.contextWindow !== undefined && model.contextWindow <= LEAN_MAX_CONTEXT;

export default function (pi: ExtensionAPI) {
  let lean = false;
  pi.on("session_start", (_event, ctx) => {
    lean = isLean(ctx.model);
    // The names are third-party: a package bump that renames one would leave its
    // full declaration in the prompt with nothing to show for it.
    const registered = new Set(pi.getAllTools().map((tool) => tool.name));
    const missing = [...HIDDEN, ...HIDDEN_WHEN_LEAN].filter((name) => !registered.has(name));
    if (missing.length > 0) {
      ctx.ui.notify(
        `codemode_only: not registered, declarations stay visible: ${missing.join(", ")}`,
        "warning",
      );
    }
  });
  pi.on("model_select", (event) => {
    lean = isLean(event.model);
  });

  pi.registerTool({
    name: NAME,
    label: "Codemode only",
    description: "Hides other tools' declarations. Not for calling.",
    parameters: Type.Object({}),
    prepareLoadout: () => ({
      hiddenDeclarations: [NAME, ...HIDDEN, ...(lean ? HIDDEN_WHEN_LEAN : [])],
    }),
    async execute() {
      return { content: [{ type: "text", text: "Nothing to do." }], details: undefined };
    },
  });
}
