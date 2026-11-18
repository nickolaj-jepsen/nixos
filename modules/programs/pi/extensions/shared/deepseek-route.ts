/** The physical provider the DeepSeek virtual model chose for each session. */
import { processGlobal } from "./process-global.ts";

export type DeepSeekProvider = "opencode-go" | "command-code";

const routes = processGlobal("deepseek-router.routes", () => new Map<string, DeepSeekProvider>());

export const rememberDeepSeekRoute = (sessionId: string, provider: DeepSeekProvider) => {
  routes.set(sessionId, provider);
};

export const selectedDeepSeekProvider = (sessionId: string) => routes.get(sessionId);

export const forgetDeepSeekRoute = (sessionId: string) => {
  routes.delete(sessionId);
};
