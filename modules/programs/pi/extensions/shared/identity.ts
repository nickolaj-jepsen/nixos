/**
 * The identity record agent-hub's label reading used to persist on a session's
 * branch. Nothing writes it any more; memory still searches the old ones.
 */

/** Session entries the identity feature appends; the last one on a branch is current. */
export const IDENTITY_ENTRY = "identity_label";

/** One persisted identity record; any field may be missing in an old one. */
export type IdentityRecord = {
  /** The label agent-hub's reading wrote. */
  text?: string;
  calls?: number;
  summary?: string;
  tags?: string[];
  /** The session name identity wrote from the label. */
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
