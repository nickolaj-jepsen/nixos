#!/usr/bin/env node
// Usage: capture.mjs <base-url> <out-dir> <steps.json>. Drives a throwaway headless chromium over CDP.
// Steps, in order: {"goto":"/path"}, {"wait":"text"}, {"set":"css selector","value":"text"},
// {"click":"button label","in":"optional css selector"}, {"shot":"name","text":"must be on the page"}.
// Exits 1 if text never appears or a click is ambiguous, so a blank page can't pass as a capture.
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [base, out, stepsFile] = process.argv.slice(2);
if (!stepsFile) {
  console.error("usage: capture.mjs <base-url> <out-dir> <steps.json>");
  process.exit(2);
}
const steps = JSON.parse(readFileSync(stepsFile, "utf8"));
const TIMEOUT_MS = Number(process.env.CAPTURE_TIMEOUT_MS ?? 60_000);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const profile = mkdtempSync(join(tmpdir(), "onboard-capture-"));
// LD_LIBRARY_PATH from a dev shell can crash chromium
const chrome = spawn(
  "chromium",
  [
    "--headless",
    "--disable-gpu",
    "--no-first-run",
    "--remote-debugging-port=0",
    `--user-data-dir=${profile}`,
    "--window-size=1000,1200",
    "about:blank",
  ],
  { env: { ...process.env, LD_LIBRARY_PATH: "" }, stdio: "ignore" },
);

async function poll(what, read) {
  const end = Date.now() + TIMEOUT_MS;
  for (;;) {
    const value = await read();
    if (value) return value;
    if (Date.now() > end) throw new Error(`timed out: ${what}`);
    await sleep(200);
  }
}

let socket;
let code = 0;
try {
  const port = await poll("chromium's debug port", () => {
    try {
      return readFileSync(join(profile, "DevToolsActivePort"), "utf8").split("\n")[0];
    } catch {
      return undefined;
    }
  });
  const pages = await poll("a page", () =>
    fetch(`http://127.0.0.1:${port}/json`)
      .then((r) => r.json())
      .then((list) => list.filter((t) => t.type === "page"))
      .then((list) => (list.length ? list : undefined))
      .catch(() => undefined),
  );
  socket = new WebSocket(pages[0].webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    socket.onopen = resolve;
    socket.onerror = reject;
  });
  let seq = 0;
  const pending = new Map();
  socket.onmessage = (message) => {
    const data = JSON.parse(message.data);
    pending.get(data.id)?.(data);
    pending.delete(data.id);
  };
  const send = (method, params = {}) =>
    new Promise((resolve) => {
      const id = ++seq;
      pending.set(id, resolve);
      socket.send(JSON.stringify({ id, method, params }));
    });
  const js = async (expression) => {
    const { result } = await send("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
    });
    if (result.exceptionDetails)
      throw new Error(JSON.stringify(result.exceptionDetails).slice(0, 400));
    return result.result.value;
  };
  const hasText = (text) => js(`document.body.innerText.includes(${JSON.stringify(text)})`);
  const waitText = (text) =>
    poll(`"${text}" on the page`, () => hasText(text)).catch(async (error) => {
      throw new Error(
        `${error.message}\npage text: ${(await js("document.body.innerText")).slice(0, 500)}`,
      );
    });

  await send("Page.enable");
  await send("Runtime.enable");
  for (const step of steps) {
    if (step.goto !== undefined) {
      await send("Page.navigate", { url: new URL(step.goto, base).href });
    } else if (step.wait !== undefined) {
      await waitText(step.wait);
    } else if (step.set !== undefined) {
      const selector = JSON.stringify(step.set);
      await poll(`${step.set} to exist`, () => js(`!!document.querySelector(${selector})`));
      // the native setter and event are what React and similar frameworks listen to
      await js(`(() => {
        const el = document.querySelector(${selector});
        const proto = Object.getPrototypeOf(el);
        Object.getOwnPropertyDescriptor(proto, "value").set.call(el, ${JSON.stringify(step.value)});
        el.dispatchEvent(new Event(el.tagName === "SELECT" ? "change" : "input", { bubbles: true }));
      })()`);
    } else if (step.click !== undefined) {
      const root = step.in ? `document.querySelector(${JSON.stringify(step.in)})` : "document";
      const found = `[...(${root}?.querySelectorAll("button, a") ?? [])].filter((el) => el.innerText.trim() === ${JSON.stringify(step.click)} && !el.disabled)`;
      const count = await poll(`a "${step.click}" control`, () => js(`${found}.length`));
      if (count > 1)
        throw new Error(
          `${count} controls named "${step.click}": each may be its own route, so name one with "in"`,
        );
      await js(`${found}[0].click()`);
    } else if (step.shot !== undefined) {
      if (step.text !== undefined) await waitText(step.text);
      const { result } = await send("Page.captureScreenshot", { format: "png" });
      writeFileSync(join(out, `${step.shot}.png`), Buffer.from(result.data, "base64"));
      console.log(`${step.shot}.png`);
    } else {
      throw new Error(`unknown step ${JSON.stringify(step)}`);
    }
  }
} catch (error) {
  console.error(error.message);
  code = 1;
} finally {
  socket?.close();
  chrome.kill("SIGTERM");
  await sleep(300);
  rmSync(profile, { recursive: true, force: true });
}
process.exit(code);
