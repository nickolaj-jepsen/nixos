import { type ExtensionContext, VIRTUAL_MODEL_STATE_ENTRY } from "@earendil-works/pi-coding-agent";
import type { ArchitectPhase, ArchitectState } from "./kinds.ts";

type ActiveModel = NonNullable<ExtensionContext["model"]>;
export type Routed = { model: ActiveModel; phase?: ArchitectPhase };

const PHASES: readonly string[] = ["plan", "build"] satisfies ArchitectPhase[];

/**
 * Under a virtual selection (core/routers.ts), the physical model that
 * answered last on the branch, and the router's phase when its state carries
 * one. Undefined for a physical selection or before the first answer. Rescanned
 * only when the leaf or selection moves, so each caller keeps its own instance.
 */
export const createRouted = () => {
  let cache: { leafId: string | null; selected: string; routed: Routed | undefined } | undefined;
  return (ctx: ExtensionContext): Routed | undefined => {
    const selected = ctx.model;
    if (selected?.api !== "pi-virtual") return undefined;
    const leafId = ctx.sessionManager.getLeafId();
    const key = `${selected.provider}/${selected.id}`;
    if (cache && cache.leafId === leafId && cache.selected === key) return cache.routed;
    let model: ActiveModel | undefined;
    let phase: ArchitectPhase | undefined;
    let stateSeen = false;
    const branch = ctx.sessionManager.getBranch();
    for (let i = branch.length - 1; i >= 0 && (!model || !stateSeen); i--) {
      const entry = branch[i];
      // The latest state the router stored for this selection; only a router
      // that keeps a phase has one to read.
      if (entry.type === "custom" && entry.customType === VIRTUAL_MODEL_STATE_ENTRY) {
        if (stateSeen) continue;
        const data = entry.data as
          | { provider?: string; modelId?: string; state?: Partial<ArchitectState> }
          | undefined;
        if (data?.provider !== selected.provider || data.modelId !== selected.id) continue;
        stateSeen = true;
        const read = data.state?.phase;
        phase = read && PHASES.includes(read) ? read : undefined;
        continue;
      }
      if (model || entry.type !== "message" || entry.message.role !== "assistant") continue;
      const { stopReason, provider, model: id } = entry.message;
      if (stopReason !== "error" && stopReason !== "aborted") {
        model = ctx.modelRegistry.find(provider, id);
      }
    }
    const routed = model ? { model, phase } : undefined;
    cache = { leafId, selected: key, routed };
    return routed;
  };
};
