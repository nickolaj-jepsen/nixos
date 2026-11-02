/**
 * The session identity record parent/identity.ts persists on the branch.
 * Readers in either package parse it through here, never by the field names.
 */

/** Session entries the identity feature appends; the last one on a branch is current. */
export const IDENTITY_ENTRY = "identity_label";

/** One persisted identity record; any field may be missing in an old one. */
export type IdentityRecord = {
  /** The label agent-hub's reading wrote; absent until the first one landed. */
  text?: string;
  calls?: number;
  summary?: string;
  tags?: string[];
  /** The session name identity wrote; any other name is the user's `/name`. */
  autoName?: string;
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
