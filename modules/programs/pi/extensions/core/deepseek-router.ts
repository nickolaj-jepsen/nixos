/**
 * auto/deepseek-v4.1-flash: split new branches 80/20 (Command Code / OpenCode Go)
 * when both have >20% left in their tightest quota window. Otherwise favor the
 * provider with headroom, or pick the one with more quota left.
 *
 * Keep the provider sticky unless a rate-limit retry can switch to the other
 * provider. Switch at most once per retry chain.
 */
import { execFile } from "node:child_process";
import type { ExtensionAPI, ExtensionContext, ModelRoute } from "@earendil-works/pi-coding-agent";

const MODEL_ID = "deepseek-v4.1-flash";
const WINDOWS = ["5h", "7d", "month"] as const;
const HEADROOM_FLOOR = 20;
const COMMAND_CODE_SHARE = 0.8;
const RATE_LIMIT_ERROR = /\b429\b|rate.?limit|too many requests/i;
const TARGETS = {
  "opencode-go": MODEL_ID,
  "command-code": "deepseek/deepseek-v4.1-flash",
} as const;

type Provider = keyof typeof TARGETS;

interface RouterState {
  provider: Provider;
  failedOver?: true;
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

function canTakeTraffic(provider: UsageProvider | undefined): boolean {
  // Last-good data can inform the quota fallback, but cannot justify a split or failover.
  return (
    !!provider && !provider.error && !provider.stale && remainingHeadroom(provider) > HEADROOM_FLOOR
  );
}

function chooseProvider(providers: UsageProvider[]): Provider {
  const go = providers.find((p) => p.id === "opencode-go");
  const command = providers.find((p) => p.id === "command-code");
  const goReady = canTakeTraffic(go);
  const commandReady = canTakeTraffic(command);
  if (goReady && commandReady)
    return Math.random() < COMMAND_CODE_SHARE ? "command-code" : "opencode-go";
  if (commandReady) return "command-code";
  if (goReady) return "opencode-go";
  // OpenCode wins ties, and is the fallback when neither provider has usable data.
  return remainingHeadroom(command) > remainingHeadroom(go) ? "command-code" : "opencode-go";
}

function targetProvider(model: ModelRoute["model"] | undefined): Provider | undefined {
  if (!model) return;
  const { provider, id } = model;
  if ((provider === "opencode-go" || provider === "command-code") && id === TARGETS[provider]) {
    return provider;
  }
}

function routeTo(
  provider: Provider,
  thinkingLevel: ModelRoute["thinkingLevel"],
  ctx: ExtensionContext,
  state?: RouterState,
): ModelRoute<RouterState> {
  const model = ctx.modelRegistry.find(provider, TARGETS[provider]);
  if (!model) throw new Error(`${provider}/${TARGETS[provider]} is not in the catalog`);
  return { model, thinkingLevel, state };
}

async function readUsage(
  command: string | undefined,
  signal: AbortSignal | undefined,
): Promise<UsageProvider[]> {
  if (!command) return [];
  try {
    const stdout = await new Promise<string>((resolve, reject) => {
      execFile(
        command,
        ["--json", "--provider", "opencode-go", "--provider", "command-code"],
        { signal, timeout: 25_000, maxBuffer: 4 * 1024 * 1024 },
        (error, stdout) => (error ? reject(error) : resolve(stdout)),
      );
    });
    const { providers } = JSON.parse(stdout) as UsageResult;
    return Array.isArray(providers) ? providers : [];
  } catch {
    // Usage being unavailable must not block a normal request or retry.
    return [];
  }
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
      const { failed, reason, state, signal } = request;
      // Also keep the physical model when manually switching to auto, and when
      // a direct call (e.g. compaction) carries a previous response but no state.
      const sticky = failed ?? request.previous;
      const stickyProvider = targetProvider(sticky?.model);
      const provider = stickyProvider ?? state?.provider;
      if (provider) {
        const thinkingLevel = (stickyProvider && sticky?.thinkingLevel) ?? request.thinkingLevel;
        // Pi saves routing state before dispatch. Keep the guard through further
        // retries (even if the alternate also returns 429), not the next request.
        const failedOver = reason === "retry" && state?.failedOver === true;
        if (
          reason === "retry" &&
          !failedOver &&
          failed?.message.stopReason === "error" &&
          stickyProvider &&
          RATE_LIMIT_ERROR.test(failed.message.errorMessage ?? "")
        ) {
          const alternate = provider === "opencode-go" ? "command-code" : "opencode-go";
          const model = ctx.modelRegistry.find(alternate, TARGETS[alternate]);
          if (model && ctx.modelRegistry.hasConfiguredAuth(model)) {
            const usage = await readUsage(usageCommand, signal);
            if (canTakeTraffic(usage.find((p) => p.id === alternate))) {
              return { model, thinkingLevel, state: { provider: alternate, failedOver: true } };
            }
          }
        }
        const nextState: RouterState =
          state?.provider === provider && Boolean(state.failedOver) === failedOver
            ? state
            : failedOver
              ? { provider, failedOver: true }
              : { provider };
        return routeTo(provider, thinkingLevel, ctx, nextState);
      }

      const initialProvider = chooseProvider(await readUsage(usageCommand, signal));
      return routeTo(initialProvider, request.thinkingLevel, ctx, { provider: initialProvider });
    },
  });
}
