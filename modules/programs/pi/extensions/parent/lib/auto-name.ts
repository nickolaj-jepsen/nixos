/**
 * The session name chrome's identity wrote from a label, per session, so other
 * extensions can tell it from a name the user chose with `/name`.
 */

// On globalThis because each extension loads its own copy of this module.
const KEY = Symbol.for("fireproof.pi.auto-name");
const store = globalThis as { [KEY]?: Map<string, string> };
const names = (store[KEY] ??= new Map());

/** Record `name` as the automatic name of `sessionId`; `undefined` forgets it. */
export function setAutoName(sessionId: string, name: string | undefined): void {
  if (name === undefined) names.delete(sessionId);
  else names.set(sessionId, name);
}

/** True when `name` is the name identity wrote for `sessionId`, not one the user chose. */
export function isAutoName(sessionId: string, name: string | undefined): boolean {
  return name !== undefined && names.get(sessionId) === name;
}
