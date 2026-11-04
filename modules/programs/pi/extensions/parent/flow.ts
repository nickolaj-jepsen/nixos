/**
 * /flow: the command that turns the current session into the start of a
 * multi-step workflow (brief → plan → approve → run → guide), the tools the
 * flow's skills call, and the footer segment that names the current step.
 *
 * G0 ships this stub so the flake's type-check reaches `parent/flow/` and a
 * scenario can load the package: `/flow` reports every step after the brief as
 * PENDING. A1 replaces the body with the conductor.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { STEPS } from "./flow/contracts.ts";
import { registerTour } from "./flow/tour.ts";

export default function (pi: ExtensionAPI) {
  registerTour(pi);
  pi.registerCommand("flow", {
    description: "Flow steps: /flow <slug> starts one, /flow status, /flow resume, /flow next",
    handler: async (args, ctx) => {
      const slug = args.trim() || "(no slug yet)";
      const pending = STEPS.filter((step) => step !== "brief").map((step) => `${step} PENDING`);
      ctx.ui.notify(`flow ${slug}: brief done · ${pending.join(" · ")}`, "info");
    },
  });
}
