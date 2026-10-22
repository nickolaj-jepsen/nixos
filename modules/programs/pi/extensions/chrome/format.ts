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

/** A moment as the shortest unambiguous text: `14:30` within a day, `Fri` within a week, else `31 Oct`. */
export const formatWhen = (at: Date, now = new Date()) => {
  const ms = at.getTime() - now.getTime();
  if (ms < 24 * HOUR) return at.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
  if (ms < 7 * 24 * HOUR) return at.toLocaleDateString("en-GB", { weekday: "short" });
  return at.toLocaleDateString("en-GB", { day: "numeric", month: "short" });
};
