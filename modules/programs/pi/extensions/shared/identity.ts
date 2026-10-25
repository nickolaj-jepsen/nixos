/**
 * The session identity contract: what parent/identity.ts persists on the branch
 * and broadcasts on `pi.events`. Readers in either package parse it through
 * here, never by the field names.
 */
import type { SessionEntry } from "@earendil-works/pi-coding-agent";

/** Session entries the identity feature appends; the last one on a branch is current. */
export const IDENTITY_ENTRY = "identity_label";

/** `pi.events` channel for each sidecar answer, so other extensions can use it without asking again. */
export const SIDECAR_CHANNEL = "fireproof:sidecar";

/** How a finished turn ended: it did the work, it needs the person, or it could not finish. */
export type TurnState = "done" | "blocked" | "failed";

/** One persisted identity record; any field may be missing in an old one. */
export type IdentityRecord = {
  /** The model-written label; absent until the first call landed. */
  text?: string;
  calls?: number;
  summary?: string;
  tags?: string[];
  /** The session name identity wrote; any other name is the user's `/name`. */
  autoName?: string;
};

/**
 * One sidecar outcome. `settle` fires once per finished turn even when no call
 * was made (`asked: false`), so a listener waiting on the turn never has to time out.
 */
export type SidecarUpdate = {
  sessionId: string;
  moment: "start" | "settle";
  asked: boolean;
  label?: string;
  summary?: string;
  doing?: string;
  state?: TurnState;
  ask?: string;
};

const str = (value: unknown) => (typeof value === "string" && value !== "" ? value : undefined);

/** The identity record an entry holds, typed field by field; undefined for any other entry. */
export const readIdentity = (entry: unknown): IdentityRecord | undefined => {
  const row = entry as { type?: unknown; customType?: unknown; data?: unknown } | undefined;
  if (row?.type !== "custom" || row.customType !== IDENTITY_ENTRY) return undefined;
  const data = (row.data ?? {}) as Record<string, unknown>;
  return {
    text: str(data.text),
    calls: typeof data.calls === "number" ? data.calls : undefined,
    summary: str(data.summary),
    tags: Array.isArray(data.tags)
      ? data.tags.filter((tag): tag is string => typeof tag === "string")
      : undefined,
    autoName: str(data.autoName),
  };
};

/** The last identity record on `branch`. */
export const latestIdentity = (branch: readonly SessionEntry[]): IdentityRecord | undefined => {
  for (let i = branch.length - 1; i >= 0; i--) {
    const record = readIdentity(branch[i]);
    if (record) return record;
  }
  return undefined;
};
