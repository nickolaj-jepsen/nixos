/**
 * The system temp dir from before tmpdir.ts pointed TMPDIR at pi's private one,
 * for paths that must match what other programs on the machine compute.
 */
import { tmpdir } from "node:os";

// On globalThis because each pi runtime loads its own copy of this module.
const KEY = Symbol.for("fireproof.pi.originalTmpdir");
const store = globalThis as { [KEY]?: string };

/** Record the current tmpdir() as the original; only the first call per process counts. */
export function recordOriginalTmpdir(): void {
  store[KEY] ??= tmpdir();
}

/** The recorded original, or tmpdir() while nothing has overridden it yet. */
export function originalTmpdir(): string {
  return store[KEY] ?? tmpdir();
}
