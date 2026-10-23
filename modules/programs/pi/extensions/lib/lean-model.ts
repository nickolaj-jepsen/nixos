import type { Model } from "@earendil-works/pi-ai";

/** Below this, a tool declaration's tokens are a real share of the window: the local models. */
const LEAN_MAX_CONTEXT = 131_072;

export const isLeanModel = (model: Model<any> | undefined) =>
  model?.contextWindow !== undefined && model.contextWindow <= LEAN_MAX_CONTEXT;
