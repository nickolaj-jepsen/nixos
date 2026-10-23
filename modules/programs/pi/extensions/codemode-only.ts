/**
 * Hides expensive tool declarations from the model while keeping the tools
 * active, so codemode scripts can still call them. Pi has no per-tool exposure
 * setting, so this rides on a tool's `prepareLoadout` hook, which only runs
 * while that tool is active; the carrier tool hides itself too.
 */
import { Type } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const NAME = "codemode_only";
// Point the model at each of these some other way, or it won't know they exist.
const HIDDEN = [
  "SubagentWorkflow",
  "get_subagent_result",
  "steer_subagent",
  // pi-background-tasks: bg_run stays declared; its completion notice makes these rarely needed.
  "bg_status",
  "bg_logs",
  "bg_kill",
];

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: NAME,
    label: "Codemode only",
    description: "Hides other tools' declarations. Not for calling.",
    parameters: Type.Object({}),
    prepareLoadout: () => ({ hiddenDeclarations: [NAME, ...HIDDEN] }),
    async execute() {
      return { content: [{ type: "text", text: "Nothing to do." }], details: undefined };
    },
  });
}
