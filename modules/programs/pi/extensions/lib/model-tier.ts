import type { Model } from "@earendil-works/pi-ai";

/** USD per million output tokens; the catalog's clearest signal of which tier a model sits in. */
const EXPENSIVE_OUTPUT = 8;

/**
 * The virtual-model provider. A virtual model's own price says nothing about
 * what answers, and the router picks the physical model per request, so the
 * only thing readable up front is which ladder the session points at.
 */
const VIRTUAL_PROVIDER = "vm";
/** The one kind whose ladder starts on the cheap pool. */
const CHEAP_VIRTUAL = "flash";

/**
 * Whether this model's tokens are the ones worth spending on judgment rather
 * than volume: the strong and planner kinds, the Anthropic credit, the Kimi
 * plan, and anything the catalog prices at Opus/Kimi rates.
 */
export const isExpensiveModel = (model: Model<any> | undefined): boolean => {
  if (!model) return false;
  if (model.provider === VIRTUAL_PROVIDER) return model.id !== CHEAP_VIRTUAL;
  return (model.cost?.output ?? 0) >= EXPENSIVE_OUTPUT;
};
