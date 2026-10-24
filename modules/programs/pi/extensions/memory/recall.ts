/**
 * Recall bookkeeping. A search is a read, so it only counts hits in memory;
 * the counts reach disk in one batch, and only for stores this session may
 * write. Writing on every search raced concurrent sessions and touched
 * read-only stores.
 */
import { updateEntryFile, type Entry, type Store } from "./store.ts";

type Pending = { store: Store; hits: number; last: string };

const pending = new Map<string, Pending>();

/** Counts one recall of `entry`; ignored for stores this session cannot write. */
export function noteRecall(entry: Entry) {
  if (!entry.store.writable) return;
  const known = pending.get(entry.file);
  pending.set(entry.file, {
    store: entry.store,
    hits: (known?.hits ?? 0) + 1,
    last: new Date().toISOString(),
  });
}

/** Writes the pending counts to their entry files. */
export async function flushRecalls() {
  const batch = [...pending];
  pending.clear();
  for (const [file, { store, hits, last }] of batch)
    await updateEntryFile(file, store, (current) => {
      current.recallCount += hits;
      current.lastRecalled = last;
    });
}
