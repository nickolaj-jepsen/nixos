/**
 * The review tour (C3, D17, D24): seeds the branch's diff as tuicr comments
 * authored `Flow`, so a large change arrives with a reading order instead of a
 * wall of hunks.
 *
 * G0 ships the tool surface so `flow-guide` can be written against it; A6 adds
 * the headless session, the line checks and the ingest filter.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { TOOL_TOUR } from "./contracts.ts";

/** The `flow_tour` tool. Called once from the feature entry (C3). */
export const registerTour = (pi: ExtensionAPI) => {
  pi.registerTool({
    name: TOOL_TOUR,
    label: "Flow tour",
    description:
      "Seed the branch's diff as tuicr review comments under the author Flow: an intro plus one body per stop, each anchored to a line the diff contains. Returns the tuicr session slug and the /rv line that reopens it.",
    promptSnippet: "Seed the branch's diff as a review tour of tuicr comments.",
    parameters: Type.Object({
      intro: Type.String({
        description: "What the reviewer should keep in mind while reading the diff.",
      }),
      stops: Type.Array(
        Type.Object({
          file: Type.Optional(
            Type.String({ description: "Path in the diff, omitted for a review-level stop." }),
          ),
          line: Type.Optional(
            Type.Number({ description: "Line in the new (or old) side of the diff." }),
          ),
          endLine: Type.Optional(Type.Number({ description: "Last line of a ranged stop." })),
          side: Type.Optional(Type.Union([Type.Literal("old"), Type.Literal("new")])),
          type: Type.String({ description: "issue, suggestion, nit, note or praise." }),
          body: Type.String({ description: "What to look for, in one or two sentences." }),
        }),
      ),
    }),
    async execute() {
      return {
        content: [{ type: "text" as const, text: "flow_tour: not implemented yet" }],
        details: undefined,
        isError: true,
      };
    },
  });
};
