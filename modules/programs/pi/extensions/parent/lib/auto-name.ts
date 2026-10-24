/**
 * The session name chrome's identity wrote from a label, per session, so other
 * extensions can tell it from a name the user chose with `/name`.
 */

// Module state starts empty after /reload: identity refills it at session_start.
const names = new Map<string, string>();

/** Record `name` as the automatic name of `sessionId`; `undefined` forgets it. */
export function setAutoName(sessionId: string, name: string | undefined): void {
  if (name === undefined) names.delete(sessionId);
  else names.set(sessionId, name);
}

/** True when `name` is the name identity wrote for `sessionId`, not one the user chose. */
export function isAutoName(sessionId: string, name: string | undefined): boolean {
  return name !== undefined && names.get(sessionId) === name;
}
