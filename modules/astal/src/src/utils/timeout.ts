import { GLib, type Time, timeout } from "astal";

const runningTimeouts: Map<string, Time> = new Map();
export const cancelTimeout = (id: string) => {
  const runningTimeout = runningTimeouts.get(id);
  if (runningTimeout) {
    runningTimeout.cancel();
    runningTimeouts.delete(id);
  }
};
export const cancelableTimeout = (
  callback: () => void,
  id: string,
  delay: number,
) => {
  cancelTimeout(id);
  runningTimeouts.set(
    id,
    timeout(delay, () => {
      callback();
      runningTimeouts.delete(id);
    }),
  );
};
