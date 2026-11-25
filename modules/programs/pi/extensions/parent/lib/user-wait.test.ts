import assert from "node:assert/strict";
import { test } from "node:test";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { createUserWait } from "./user-wait.ts";

test("external approval marks are idempotent and do not leak into a replacement session", () => {
  const handlers = new Map<string, (event: unknown, ctx: ExtensionContext) => void>();
  const pi = {
    on: (event: string, handler: (event: unknown, ctx: ExtensionContext) => void) =>
      handlers.set(event, handler),
  };
  let session = "old";
  const ctx = { sessionManager: { getSessionId: () => session } } as ExtensionContext;
  const wait = createUserWait(pi as unknown as ExtensionAPI);
  const end = wait.beginAgentPrompt(ctx);
  assert.equal(wait.waitingOnUser(ctx), false);
  handlers.get("ui_prompt_start")!({}, ctx);
  assert.equal(wait.waitingOnUser(ctx), true);
  handlers.get("session_shutdown")!({}, ctx);
  session = "new";
  handlers.get("ui_prompt_start")!({}, ctx);
  end();
  end();
  assert.equal(wait.waitingOnUser(ctx), false);
  const nextEnd = wait.beginAgentPrompt(ctx);
  assert.equal(wait.waitingOnUser(ctx), true);
  nextEnd();
  assert.equal(wait.waitingOnUser(ctx), false);
});
