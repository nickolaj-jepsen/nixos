import type { Model } from "@earendil-works/pi-ai";
import { type Kind, PROVIDER } from "../routers/kinds.ts";

/** USD per million output tokens; the catalog's clearest signal of which tier a model sits in. */
const EXPENSIVE_OUTPUT = 8;
/** The one kind whose ladder starts on the cheap pool. */
const CHEAP_KIND: Kind = "flash";

/**
 * Whether this model's tokens are the ones worth spending on judgment rather
 * than volume: anything the catalog prices at Opus/Kimi rates.
 *
 * Pass the physical model that answered when there is one (lib/routed-model.ts):
 * a virtual model's own price says nothing, and the architect's build phase runs
 * on flash. Before a virtual model's first answer only its ladder is readable,
 * and every kind but flash starts on an expensive pool.
 */
export const isExpensiveModel = (model: Model<any> | undefined): boolean => {
  if (!model) return false;
  if (model.provider === PROVIDER) return model.id !== CHEAP_KIND;
  return (model.cost?.output ?? 0) >= EXPENSIVE_OUTPUT;
};
