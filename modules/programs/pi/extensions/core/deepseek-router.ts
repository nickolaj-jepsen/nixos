/**
 * auto/deepseek-v4.1-flash: pick the subscription with the most quota left.
 *
 * The first request on a session branch compares the smallest remaining
 * percentage across the 5-hour, weekly and monthly windows. Pi then keeps that
 * choice in branch state; previous responses also pin retries, continuations
 * and direct calls such as compaction to the same physical model.
 */
import { execFile } from "node:child_process";
import type { ExtensionAPI, ExtensionContext, ModelRoute } from "@earendil-works/pi-coding-agent";
import {
  forgetDeepSeekRoute,
  rememberDeepSeekRoute,
  selectedDeepSeekProvider,
  type DeepSeekProvider,
} from "../shared/deepseek-route.ts";

const MODEL_ID = "deepseek-v4.1-flash";
const WINDOWS = ["5h", "7d", "month"] as const;
const TARGETS = {
  "opencode-go": MODEL_ID,
  "command-code": "deepseek/deepseek-v4.1-flash",
} as const;

type Provider = DeepSeekProvider;

interface RouterState {
  provider: Provider;
}

interface UsageWindow {
  label: string;
  usedPct: number;
}

interface UsageProvider {
  id: string;
  stale: boolean;
  error: string | null;
  windows: UsageWindow[];
}

interface UsageResult {
  providers: UsageProvider[];
}

export function remainingHeadroom(provider: UsageProvider | undefined): number {
  // A failed fetch with no last-good windows must not look like an empty plan.
  if (!provider || (provider.error && !provider.stale)) return 0;
  const windows = new Map(provider.windows.map((w) => [w.label, w.usedPct]));
  // Command Code omits untouched rolling windows (their resetAt is zero).
  return Math.min(...WINDOWS.map((label) => Math.max(0, 100 - (windows.get(label) ?? 0))));
}

export function providerWithMostHeadroom(providers: UsageProvider[]): Provider {
  const score = (id: Provider) => remainingHeadroom(providers.find((p) => p.id === id));
  // OpenCode wins ties, and is the fallback when neither provider has usable data.
  return score("command-code") > score("opencode-go") ? "command-code" : "opencode-go";
}

function routeTo(
  provider: Provider,
  thinkingLevel: ModelRoute["thinkingLevel"],
  ctx: ExtensionContext,
  state?: RouterState,
): ModelRoute<RouterState> {
  const model = ctx.modelRegistry.find(provider, TARGETS[provider]);
  if (!model) throw new Error(`${provider}/${TARGETS[provider]} is not in the catalog`);
  rememberDeepSeekRoute(ctx.sessionManager.getSessionId(), provider);
  return { model, thinkingLevel, state };
}

async function chooseProvider(command: string, signal: AbortSignal | undefined): Promise<Provider> {
  const stdout = await new Promise<string>((resolve, reject) => {
    execFile(
      command,
      ["--json", "--provider", "opencode-go", "--provider", "command-code"],
      { signal, timeout: 25_000, maxBuffer: 4 * 1024 * 1024 },
      (error, stdout) => (error ? reject(error) : resolve(stdout)),
    );
  });
  return providerWithMostHeadroom((JSON.parse(stdout) as UsageResult).providers);
}

export default function (pi: ExtensionAPI) {
  const usageCommand = process.env.PI_AI_USAGE_COMMAND;

  pi.registerVirtualModel<RouterState>({
    provider: "auto",
    id: MODEL_ID,
    name: "DeepSeek V4.1 Flash",
    thinkingLevels: ["low", "medium", "high", "xhigh"],
    contextWindow: 1_000_000,
    maxTokens: 32_768,
    input: ["text"],
    async route(request, ctx) {
      // A manual switch from either physical model to auto keeps that model.
      // Retries stay put too, even when their failure was a rate limit.
      const sticky = request.failed ?? request.previous;
      if (sticky?.model.provider === "opencode-go" || sticky?.model.provider === "command-code") {
        const provider = sticky.model.provider;
        if (sticky.model.id === TARGETS[provider]) {
          return routeTo(
            provider,
            sticky.thinkingLevel ?? request.thinkingLevel,
            ctx,
            request.state ?? { provider },
          );
        }
      }
      if (request.state) return routeTo(request.state.provider, request.thinkingLevel, ctx);
      // Direct calls have no branch state in pi. Keep guardian, title and
      // compaction side calls on the choice the session already made.
      const remembered = selectedDeepSeekProvider(ctx.sessionManager.getSessionId());
      if (request.reason === "direct" && remembered) {
        return routeTo(remembered, request.thinkingLevel, ctx);
      }

      let provider: Provider = "opencode-go";
      if (usageCommand) {
        try {
          provider = await chooseProvider(usageCommand, request.signal);
        } catch {
          // A new session must still start when the usage service is unavailable.
        }
      }
      return routeTo(provider, request.thinkingLevel, ctx, { provider });
    },
  });

  pi.on("session_shutdown", (_event, ctx) => {
    forgetDeepSeekRoute(ctx.sessionManager.getSessionId());
  });
}
