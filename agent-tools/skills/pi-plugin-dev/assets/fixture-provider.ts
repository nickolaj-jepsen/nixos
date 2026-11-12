// @ts-nocheck — jiti strips types and no tsconfig reaches this asset.
/**
 * Replay provider: canned assistant turns, so an extension's tool and error
 * paths run deterministically without a model and without spending tokens.
 *
 * Usage:
 *   FIXTURE=$PWD/turns.json pi \
 *     --extension <skill>/assets/fixture-provider.ts \
 *     --provider fixture --model replay
 *
 * turns.json is a list consumed in order, one entry per assistant turn. A turn
 * carries any of text, thinking, toolCall or error:
 *
 *   [{"text": "Listing files."},
 *    {"toolCall": {"name": "todo", "arguments": {"op": "list"}}},
 *    {"toolCall": {"name": "todo", "arguments": {"wrong": "shape"}}},
 *    {"error": "provider exploded"}]
 *
 * Malformed arguments are the point: they exercise validation and tool error
 * paths. Running past the end of the list is an error that says so, rather
 * than a silent empty reply.
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

export default function (pi: ExtensionAPI) {
  pi.registerProvider("fixture", {
    baseUrl: "http://fixture.invalid",
    apiKey: "fixture",
    api: "fixture-api",
    models: [
      {
        id: "replay",
        name: "Replay (fixture)",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 200000,
        maxTokens: 8192,
      },
    ],
    streamSimple: streamFixture,
  });
}
