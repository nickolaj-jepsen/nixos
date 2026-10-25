/**
 * The one way to keep state across module copies: pi evaluates every extension
 * entry, and every reload, with its own copy of each module, so module state is
 * per copy. `name` is created once per process, on first use.
 */
export const processGlobal = <T>(name: string, init: () => T): T => {
  const slots = globalThis as { [key: symbol]: unknown };
  const key = Symbol.for(`fireproof.pi.${name}`);
  return (slots[key] ??= init()) as T;
};
