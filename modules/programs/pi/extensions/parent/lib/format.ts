import { homedir } from "node:os";
import { relative, sep } from "node:path";

/** `text` on one line, whitespace collapsed. */
export const oneLine = (text: string) => text.replace(/\s+/g, " ").trim();

/** `text` cut to `max` characters, the last one an ellipsis. */
export const clip = (text: string, max: number) =>
  text.length > max ? `${text.slice(0, max - 1)}…` : text;

export const formatTokens = (count: number) => {
  if (count < 1000) return count.toString();
  if (count < 10000) return `${(count / 1000).toFixed(1)}k`;
  if (count < 1000000) return `${Math.round(count / 1000)}k`;
  if (count < 10000000) {
    const millions = count / 1000000;
    return `${Number.isInteger(millions) ? millions : millions.toFixed(1)}M`;
  }
  return `${Math.round(count / 1000000)}M`;
};

export const formatCost = (cost: number) => {
  if (cost === 0) return "$0.00";
  // Below a tenth of a cent, a rounded figure would read as exactly nothing.
  if (cost < 0.001) return "<$0.001";
  if (cost < 0.01) return `$${cost.toFixed(3)}`;
  return `$${cost.toFixed(2)}`;
};

/** A coarse age: minutes, hours up to two days, then days; `fresh` under a minute. */
export const formatAge = (ms: number, fresh: string) => {
  const minutes = Math.floor(ms / 60_000);
  if (minutes < 1) return fresh;
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  return hours < 48 ? `${hours}h` : `${Math.floor(hours / 24)}d`;
};

/**
 * A directory as its parent prefix and final name, so a footer can dim the road
 * and light the place: the last segment is the worktree or checkout the session
 * is on, which is the one part that has to read.
 */
export const splitPath = (cwd: string) => {
  const home = homedir();
  const shown =
    cwd === home ? "~" : cwd.startsWith(home + sep) ? `~${cwd.slice(home.length)}` : cwd;
  const cut = shown.lastIndexOf("/");
  return cut < 0
    ? { parent: "", name: shown }
    : { parent: shown.slice(0, cut + 1), name: shown.slice(cut + 1) };
};

/** A directory as `~/a/b`, eliding the middle of deep paths. */
export const shortPath = (cwd: string) => {
  const home = homedir();
  if (cwd === home) return "~";
  if (cwd.startsWith(home + sep)) {
    const parts = relative(home, cwd).split(sep).filter(Boolean);
    return parts.length <= 2 ? `~/${parts.join("/")}` : `~/…/${parts[parts.length - 1]}`;
  }
  const parts = cwd.split(sep).filter(Boolean);
  return parts.length <= 2 ? `/${parts.join("/")}` : `/${parts[0]}/…/${parts[parts.length - 1]}`;
};
