/** One model call made beside the conversation, billed to the session's ledger under `source`, failed replies included. */
import type { SimpleStreamOptions } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { recordSideCall } from "./usage-ledger.ts";

/** The default side model: the flash ladder, so a side call falls back the way the session does. */
export const SIDE_MODEL = "vm/flash";

export type SideCall = {
  /** The ledger's name for the call, as /cost lists it. */
  source: string;
  system: string;
  prompt: string;
  /** "provider/model"; there is no fallback to the session's model, which can cost thirty times more. */
  model?: string;
  maxTokens: number;
  timeoutMs: number;
  /** 0 unless set; null leaves it to the model, for one that rejects any but its own. */
  temperature?: number | null;
  reasoning?: SimpleStreamOptions["reasoning"];
  signal?: AbortSignal;
};

/** The reply's text blocks joined by newlines, or why there is none; `cost` is what it was billed. */
export type SideResult = { text: string; cost: number } | { error: string; cost: number };

/** Asks the model once; never throws. */
export const sideCall = async (
  pi: ExtensionAPI,
  ctx: ExtensionContext,
  { source, system, prompt, model = SIDE_MODEL, temperature = 0, ...options }: SideCall,
): Promise<SideResult> => {
  const slash = model.indexOf("/");
  const found =
    slash > 0 ? ctx.modelRegistry.find(model.slice(0, slash), model.slice(slash + 1)) : undefined;
  if (!found) return { error: `${model} is not in the catalog`, cost: 0 };
  try {
    const response = await ctx.modelRegistry
      .streamSimple(
        found,
        {
          systemPrompt: system,
          messages: [
            { role: "user", content: [{ type: "text", text: prompt }], timestamp: Date.now() },
          ],
        },
        {
          ...options,
          temperature: temperature ?? undefined,
          // The opencode gateway routes on `x-opencode-session`, which pi derives
          // from this; without it the request fails with 400.
          sessionId: ctx.sessionManager.getSessionId(),
        },
      )
      .result();
    recordSideCall(pi, source, response);
    const cost = response.usage?.cost?.total ?? 0;
    if (response.stopReason === "error" || response.stopReason === "aborted") {
      return { error: response.errorMessage ?? response.stopReason, cost };
    }
    const text = response.content
      .flatMap((block) => (block.type === "text" ? [block.text] : []))
      .join("\n");
    return { text, cost };
  } catch (error) {
    return { error: error instanceof Error ? error.message : String(error), cost: 0 };
  }
};
