/**
 * Where each quota window's projected dry-out has got to, kept between sessions
 * so a forecast that moves closer is news while a steady one is not.
 *
 * Chrome's own memory rather than the provider's: `ai-usage --json` stays a pure
 * snapshot of what the provider says, and this file only says what the footer has
 * already told the person about it.
 */
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

/** A window's forecast as last reported: a whole day, so the hour-to-hour drift is not news. */
type Mark = { bucket: string; resetsAt: string };

const FILE = "pi/usage-alarm.json";

const path = () => join(process.env.XDG_STATE_HOME ?? join(homedir(), ".local", "state"), FILE);

const isMark = (value: unknown): value is Mark => {
  const mark = value as Mark | null;
  return (
    typeof mark === "object" &&
    mark !== null &&
    typeof mark.bucket === "string" &&
    typeof mark.resetsAt === "string"
  );
};

const read = (): Record<string, Mark> => {
  try {
    const parsed: unknown = JSON.parse(readFileSync(path(), "utf8"));
    if (typeof parsed !== "object" || parsed === null) return {};
    return Object.fromEntries(Object.entries(parsed).filter(([, mark]) => isMark(mark)));
  } catch {
    // Missing, unreadable or written by another version: a baseline rebuilt from
    // nothing only costs the crossings that happened while the file was gone.
    return {};
  }
};

/** Read-modify-write, so a second session's marks are merged rather than dropped. */
const write = (marks: Record<string, Mark>) => {
  const file = path();
  try {
    mkdirSync(dirname(file), { recursive: true });
    const tmp = `${file}.${process.pid}.tmp`;
    writeFileSync(tmp, `${JSON.stringify(marks)}\n`);
    renameSync(tmp, file);
  } catch {
    // A footer must never fall over for want of a state file.
  }
};

/** A moment as a local calendar day: the resolution a forecast is allowed to have. */
export const bucketOf = (at: Date) =>
  `${at.getFullYear()}-${String(at.getMonth() + 1).padStart(2, "0")}-${String(
    at.getDate(),
  ).padStart(2, "0")}`;

/**
 * Whether a window's dry-out moved a whole day closer than the one last reported
 * under `key`, recording the new mark either way.
 *
 * A window that reset has no history: its `resetsAt` no longer matches the mark,
 * so the first reading of the new cycle becomes the baseline instead of a
 * crossing. A forecast that moves later keeps its mark moving later too, so
 * bouncing back is a real crossing rather than a flap.
 */
export const forecastMovedCloser = (key: string, bucket: string, resetsAt: string) => {
  const marks = read();
  const last = marks[key];
  const moved = last !== undefined && last.resetsAt === resetsAt && bucket < last.bucket;
  if (!last || last.resetsAt !== resetsAt || last.bucket !== bucket) {
    marks[key] = { bucket, resetsAt };
    write(marks);
  }
  return moved;
};
