/**
 * Loads `@amaster.ai/pi-telemetry` when Phoenix tracing is enrolled (docs/agents.md).
 *
 * It lives in core/ because pi-agents runs child agents on pi-durable inside
 * this process: there is no child Pi session to hand `-e` flags to. The
 * telemetry patch observes their lifecycle through pi-agents' state event. The
 * tool twin loads only its own extensions and never generates, so it does not
 * load telemetry. `PI_PHOENIX_TELEMETRY` carries the package path, so an
 * unenrolled session imports nothing at all.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type TelemetryFactory = (pi: ExtensionAPI) => void | Promise<void>;

export default async function telemetry(pi: ExtensionAPI) {
  const entry = process.env.PI_PHOENIX_TELEMETRY;
  if (!entry || process.env.PI_OTEL_DISABLED === "1") return;
  const module = (await import(entry)) as { default: TelemetryFactory };
  await module.default(pi);
}
