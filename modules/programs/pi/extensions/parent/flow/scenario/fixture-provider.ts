// @ts-nocheck — jiti strips types and no tsconfig reaches this file.
/**
 * The flow scenarios' replay provider: the pi-plugin-dev asset's turns, with
 * two models that both claim to reason.
 *
 * Both claim reasoning on purpose: a non-reasoning model clamps every thinking
 * level to `off`, and a flow step's level could then never be asserted on the
 * cheap model (notes/testing.md §3). `fixture/replay` stands in for a flash
 * step, `fixture/deep` for a deep one.
 *
 * FIXTURE names the turns file; the cursor is per process, and a flow's
 * `newSession` keeps the process, so turns are consumed in global order across
 * every session of one run.
 */

import {
  type Api,
  type AssistantMessage,
  type AssistantMessageEventStream,
  createAssistantMessageEventStream,
  type Model,
} from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";

interface Turn {
  text?: string;
  thinking?: string;
  toolCall?: { name: string; arguments: unknown };
  error?: string;
}

let cursor = 0;

function loadTurns(): Turn[] {
  const path = process.env.FIXTURE;
  if (!path) throw new Error("fixture-provider: set FIXTURE to a JSON file of turns");
  const turns = JSON.parse(readFileSync(path, "utf8")) as Turn[];
  if (!Array.isArray(turns) || turns.length === 0)
    throw new Error(`fixture-provider: ${path} holds no turns`);
  return turns;
}

function streamFixture(model: Model<Api>): AssistantMessageEventStream {
  const stream = createAssistantMessageEventStream();

  (async () => {
    const turns = loadTurns();
    const index = cursor++;
    const turn = turns[index];
    const output: AssistantMessage = {
      role: "assistant",
      content: [],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: {
        input: 0,
        output: 0,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 0,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
      },
      stopReason: "pending",
      timestamp: Date.now(),
    };

    try {
      if (!turn)
        throw new Error(`fixture-provider: turn ${index} requested but ${turns.length} exist`);
      if (turn.error) throw new Error(turn.error);

      stream.push({ type: "start", partial: output });

      if (turn.thinking) {
        const at = output.content.length;
        stream.push({ type: "thinking_start", contentIndex: at, partial: output });
        stream.push({
          type: "thinking_delta",
          contentIndex: at,
          delta: turn.thinking,
          partial: output,
        });
        output.content.push({ type: "thinking", thinking: turn.thinking });
        stream.push({
          type: "thinking_end",
          contentIndex: at,
          content: turn.thinking,
          partial: output,
        });
      }

      if (turn.text) {
        const at = output.content.length;
        stream.push({ type: "text_start", contentIndex: at, partial: output });
        stream.push({ type: "text_delta", contentIndex: at, delta: turn.text, partial: output });
        output.content.push({ type: "text", text: turn.text });
        stream.push({ type: "text_end", contentIndex: at, content: turn.text, partial: output });
      }

      if (turn.toolCall) {
        const at = output.content.length;
        const toolCall = {
          type: "toolCall" as const,
          id: `fixture-${index}`,
          name: turn.toolCall.name,
          arguments: turn.toolCall.arguments,
        };
        stream.push({ type: "toolcall_start", contentIndex: at, partial: output });
        stream.push({
          type: "toolcall_delta",
          contentIndex: at,
          delta: JSON.stringify(toolCall.arguments),
          partial: output,
        });
        output.content.push(toolCall);
        stream.push({ type: "toolcall_end", contentIndex: at, toolCall, partial: output });
      }

      output.stopReason = turn.toolCall ? "toolUse" : "stop";
      stream.push({ type: "done", reason: output.stopReason, message: output });
      stream.end();
    } catch (error) {
      output.stopReason = "error";
      output.errorMessage = error instanceof Error ? error.message : JSON.stringify(error);
      stream.push({ type: "error", reason: "error", error: output });
      stream.end();
    }
  })();

  return stream;
}

const model = (id: string, name: string, reasoning: boolean) => ({
  id,
  name,
  reasoning,
  input: ["text"] as ("text" | "image")[],
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  contextWindow: 200000,
  maxTokens: 8192,
});

export default function (pi: ExtensionAPI) {
  pi.registerProvider("fixture", {
    baseUrl: "http://fixture.invalid",
    apiKey: "fixture",
    api: "fixture-api",
    models: [model("replay", "Replay (fixture)", true), model("deep", "Deep (fixture)", true)],
    streamSimple: streamFixture,
  });
}
