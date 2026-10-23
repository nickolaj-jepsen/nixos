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
  if (cost < 0.01) return `$${cost.toFixed(3)}`;
  return `$${cost.toFixed(2)}`;
};

/** Whole dollars once cents stop mattering. */
export const formatCredit = (usd: number) =>
  usd >= 10 ? `$${Math.round(usd)}` : `$${usd.toFixed(2)}`;

const HOUR = 3_600_000;

/** A moment as the shortest unambiguous text: `14:30` today, `Fri 09:00` within a week, else `31 Oct`. */
export const formatWhen = (at: Date, now = new Date()) => {
  const time = at.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
  if (at.toDateString() === now.toDateString()) return time;
  if (Math.abs(at.getTime() - now.getTime()) < 7 * 24 * HOUR) {
    return `${at.toLocaleDateString("en-GB", { weekday: "short" })} ${time}`;
  }
  return at.toLocaleDateString("en-GB", { day: "numeric", month: "short" });
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
