import { resolve } from "node:path";
import type { AgentContext } from "./bridge.ts";
const object = (v: unknown): Record<string, unknown> =>
  v !== null && typeof v === "object" ? (v as Record<string, unknown>) : {};
const array = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const text = (v: unknown): string | undefined => (typeof v === "string" && v ? v : undefined);

/** Only public tool inputs/receipts; never read the durable agents' private DB. */
export function createAgentContext(cwd: string) {
  const names = new Map<string, AgentContext>();
  const ids = new Map<string, AgentContext>();
  const pending = new Map<string, unknown>();
  const merge = (name: string, data: AgentContext) => {
    const clean = Object.fromEntries(Object.entries(data).filter(([, v]) => v !== undefined));
    names.set(name, { ...names.get(name), ...clean });
    return names.get(name)!;
  };
  const result = (toolCallId: string, toolName: string, value: unknown) => {
    const args = object(pending.get(toolCallId));
    pending.delete(toolCallId);
    const output = object(value);
    const receipt = object(object(output.details).receipt);
    const receipts = array(receipt.graphs).flatMap((g) => array(object(g).agents));
    const inputs = toolName === "agent_spawn" ? array(args.agents) : [];
    const live = array(object(output.structuredContent).agents);
    for (const [i, entry] of receipts.entries()) {
      const r = object(entry);
      const name = text(r.name);
      if (!name) continue;
      // A count mismatch is not proof of an input/agent pairing.
      const input = receipts.length === inputs.length ? object(inputs[i]) : {};
      const context = merge(name, {
        task: (text(input.job) ?? text(r.job))?.slice(0, 8000),
        model: text(r.model) ?? text(input.model),
        cwd: text(input.cwd) ? resolve(cwd, String(input.cwd)) : undefined,
      });
      const agent = object(live[i]);
      if (agent.name === name && text(agent.id)) ids.set(String(agent.id), context);
    }
    for (const entry of array(receipt.agents)) {
      const r = object(entry);
      if (text(r.name))
        merge(String(r.name), { task: text(r.job)?.slice(0, 8000), model: text(r.model) });
    }
  };
  return {
    start(toolCallId: string, toolName: string, args: unknown) {
      if (toolName === "agent_spawn") pending.set(toolCallId, args);
    },
    result,
    get(id: string, name: string): AgentContext {
      return { ...ids.get(id), ...names.get(name) };
    },
    restore(entries: readonly unknown[]) {
      for (const entry of entries) {
        const message = object(object(entry).message);
        if (message.role === "assistant") {
          for (const block of array(message.content)) {
            const call = object(block);
            if (call.type === "toolCall" && call.name === "agent_spawn" && text(call.id))
              pending.set(String(call.id), call.arguments);
          }
        } else if (message.role === "toolResult" && text(message.toolCallId)) {
          result(String(message.toolCallId), String(message.toolName), message);
        }
      }
      // Interrupted calls must not accumulate or bind an unrelated future result.
      pending.clear();
    },
  };
}
