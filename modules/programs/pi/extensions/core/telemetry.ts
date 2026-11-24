/**
 * Loads `@amaster.ai/pi-telemetry` when Phoenix tracing is enrolled (docs/agents.md).
 *
 * It lives in core/ rather than on the launcher's command line because
 * pi-subagents runs subagent sessions inside this process, and a child session
 * loads only what settings.json lists: `pi -e` flags are not propagated, and
 * `childExcludedPackages` can only subtract. `PI_PHOENIX_TELEMETRY` carries the
 * package path, so an unenrolled session imports nothing at all.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type TelemetryFactory = (pi: ExtensionAPI) => void | Promise<void>;

export default async function telemetry(pi: ExtensionAPI) {
  const entry = process.env.PI_PHOENIX_TELEMETRY;
  if (!entry || process.env.PI_OTEL_DISABLED === "1") return;
  const module = (await import(entry)) as { default: TelemetryFactory };
  await module.default(pi);
}
