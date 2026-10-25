import { homedir } from "node:os";
import { relative, sep } from "node:path";

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

/** Whole dollars once cents stop mattering. */
export const formatCredit = (usd: number) =>
  usd >= 10 ? `$${Math.round(usd)}` : `$${usd.toFixed(2)}`;

const HOUR = 3_600_000;

/** A coarse age: minutes, hours up to two days, then days; `fresh` under a minute. */
export const formatAge = (ms: number, fresh: string) => {
  const minutes = Math.floor(ms / 60_000);
  if (minutes < 1) return fresh;
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  return hours < 48 ? `${hours}h` : `${Math.floor(hours / 24)}d`;
};

/** A moment as the shortest unambiguous text: `14:30` today, `Fri 09:00` within a week, else `31 Oct`. */
export const formatWhen = (at: Date, now = new Date()) => {
  const time = at.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
  if (at.toDateString() === now.toDateString()) return time;
  if (Math.abs(at.getTime() - now.getTime()) < 7 * 24 * HOUR) {
    return `${at.toLocaleDateString("en-GB", { weekday: "short" })} ${time}`;
  }
  return at.toLocaleDateString("en-GB", { day: "numeric", month: "short" });
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
