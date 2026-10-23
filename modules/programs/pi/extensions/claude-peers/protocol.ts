/**
 * Claude Code's same-machine cross-session protocol, as read out of the
 * Claude Code 2.1.308 binary: a session registry under `~/.claude/sessions`,
 * one Unix socket per session under `cc-socks`, and newline-delimited JSON
 * frames on it. Undocumented upstream, so any Claude Code release may change it.
 *
 * Node built-ins only, so it can run outside pi for protocol tests.
 */
import { createHash, randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { chmodSync, lstatSync, mkdirSync, readFileSync, readlinkSync } from "node:fs";
import { readdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
import { connect, createServer, type Server } from "node:net";
import { homedir, tmpdir } from "node:os";
import path from "node:path";

export const PEER_PROTOCOL = 1;
export const FEATURE_NOTIFY_IDLE = "notify_idle";
const TAG = "cross-session-message";
// Claude drops a connection once this much arrives without a newline.
export const MAX_FRAME_BYTES = 1024 * 1024;
// AF_UNIX path limit Claude applies before falling back to /tmp/cc-socks-<uid>.
const MAX_SOCKET_PATH = 103;

export type PermissionClass = "bypass" | "prompting";

export interface RegistryEntry {
  pid: number;
  sessionId: string;
  cwd: string;
  startedAt: number;
  procStart?: string;
  version?: string;
  peerProtocol?: number;
  peerFeatures?: string[];
  kind: string;
  entrypoint?: string;
  pidDomain?: string;
  messagingSocketPath?: string;
  name?: string;
  nameSource?: string;
  nameSince?: number;
  updatedAt?: number;
  status?: string;
  statusUpdatedAt?: number;
  [key: string]: unknown;
}

export interface Peer extends RegistryEntry {
  messagingSocketPath: string;
  name: string;
}

export function registryDir(): string {
  return path.join(process.env.CLAUDE_CONFIG_DIR || path.join(homedir(), ".claude"), "sessions");
}

/** Socket directory Claude itself binds in; reply addresses outside it are refused. */
export function socketDir(): string {
  const base = process.env.XDG_RUNTIME_DIR || process.env.CLAUDE_CODE_TMPDIR || tmpdir();
  const dir = path.join(base, "cc-socks");
  const longest = path.join(dir, `${2 ** 22}-ffffffff.sock`);
  return longest.length <= MAX_SOCKET_PATH ? dir : `/tmp/cc-socks-${process.getuid?.() ?? 0}`;
}

/** Create the socket dir 0700, refusing one owned by another user like Claude does. */
export function ensureSocketDir(dir: string): void {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const st = lstatSync(dir);
  if (!st.isDirectory()) throw new Error(`${dir} is not a directory`);
  if (process.getuid && st.uid !== process.getuid())
    throw new Error(`${dir} is owned by another user`);
  if ((st.mode & 0o077) !== 0) chmodSync(dir, 0o700);
}

/**
 * Process start token Claude stores as `procStart` to tell a live owner from a
 * recycled PID: field 22 of /proc/<pid>/stat on Linux, `ps lstart` elsewhere.
 */
export function procStart(pid: number): string | undefined {
  try {
    if (process.platform === "linux") {
      const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
      // comm (field 2) may contain spaces and parens; fields resume after the last ')'.
      return stat.slice(stat.lastIndexOf(")") + 2).split(" ")[19];
    }
    const out = execFileSync("ps", ["-o", "lstart=", "-p", String(pid)], {
      env: { ...process.env, LC_ALL: "C", TZ: "UTC" },
      timeout: 1000,
    });
    return out.toString().trim() || undefined;
  } catch {
    return undefined;
  }
}

/** Identifies the PID namespace; Claude treats entries from another domain as foreign. */
export function pidDomain(): string | undefined {
  if (process.platform !== "linux") return undefined;
  try {
    const machineId = readFileSync("/etc/machine-id", "utf8").trim();
    return `linux:${machineId}:${readlinkSync("/proc/self/ns/pid")}`;
  } catch {
    return undefined;
  }
}

/** `uds:` address with every byte outside `A-Za-z0-9:_/.-` percent-encoded. */
export function encodeAddress(socketPath: string): string {
  const enc = new TextEncoder();
  return `uds:${socketPath.replace(/[^A-Za-z0-9:_/.\-]/gu, (ch) =>
    Array.from(enc.encode(ch), (b) => `%${b.toString(16).toUpperCase().padStart(2, "0")}`).join(""),
  )}`;
}

/** Socket path of a `uds:` address, or undefined for any other address kind. */
export function decodeAddress(address: string): string | undefined {
  if (!address.startsWith("uds:")) return undefined;
  try {
    return decodeURIComponent(address.slice(4));
  } catch {
    return address.slice(4);
  }
}

function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === "EPERM";
  }
}

export function socketReachable(socketPath: string, timeoutMs = 300): Promise<boolean> {
  return new Promise((resolve) => {
    const c = connect({ path: socketPath });
    const done = (ok: boolean) => {
      c.destroy();
      resolve(ok);
    };
    c.setTimeout(timeoutMs, () => done(false));
    c.on("connect", () => done(true));
    c.on("error", () => done(false));
  });
}

/** Live, messageable sessions from Claude's registry, newest first. */
export async function listPeers(excludeSocket?: string): Promise<Peer[]> {
  const dir = registryDir();
  let files: string[];
  try {
    files = await readdir(dir);
  } catch {
    return [];
  }
  const domain = pidDomain();
  const candidates: Peer[] = [];
  for (const file of files) {
    if (!/^\d+\.json$/.test(file)) continue;
    let entry: RegistryEntry;
    try {
      entry = JSON.parse(await readFile(path.join(dir, file), "utf8"));
    } catch {
      continue;
    }
    const sock = entry.messagingSocketPath;
    if (typeof sock !== "string" || !sock || sock === excludeSocket) continue;
    if ((entry.peerProtocol ?? 0) < PEER_PROTOCOL) continue;
    if (entry.pidDomain !== undefined && domain !== undefined && entry.pidDomain !== domain)
      continue;
    if (!pidAlive(entry.pid)) continue;
    if (entry.procStart !== undefined && procStart(entry.pid) !== entry.procStart) continue;
    candidates.push({
      ...entry,
      messagingSocketPath: sock,
      name: entry.name || `pid ${entry.pid}`,
    });
  }
  const reachable = await Promise.all(
    candidates.map((p) => socketReachable(p.messagingSocketPath)),
  );
  return candidates.filter((_, i) => reachable[i]).sort((a, b) => b.startedAt - a.startedAt);
}

/**
 * Short id shown next to names to tell same-named sessions apart. Hashed because
 * pi's UUIDv7 session ids share their leading timestamp digits. Not Claude's own
 * `[ref]`, which it derives internally.
 */
export function shortId(peer: Pick<Peer, "sessionId">): string {
  return createHash("sha256").update(peer.sessionId).digest("hex").slice(0, 6);
}

export type Resolution = { peer: Peer } | { error: string };

/**
 * Find one peer by `uds:` address, session id (or its short-id prefix),
 * `name [shortid]`, or name. Prefix matches only when unambiguous.
 */
export function resolvePeer(peers: Peer[], to: string): Resolution {
  const query = to
    .trim()
    .replace(/^@/, "")
    .replace(/^"(.*)"$/, "$1");
  const bracket = /^(.*?)\s*\[([0-9a-f]{4,})\]$/i.exec(query);
  const byId = (id: string) =>
    peers.filter((p) => p.sessionId === id || shortId(p).startsWith(id.toLowerCase()));
  const tries: Array<() => Peer[]> = [
    () =>
      peers.filter(
        (p) =>
          encodeAddress(p.messagingSocketPath) === query ||
          p.messagingSocketPath === decodeAddress(query),
      ),
    () => (bracket ? byId(bracket[2]).filter((p) => !bracket[1] || p.name === bracket[1]) : []),
    () => peers.filter((p) => p.sessionId === query),
    () => peers.filter((p) => p.name === query),
    () => peers.filter((p) => p.name.toLowerCase() === query.toLowerCase()),
    () => (/^[0-9a-f]{4,}$/i.test(query) ? byId(query) : []),
    () => peers.filter((p) => p.name.toLowerCase().startsWith(query.toLowerCase())),
  ];
  for (const attempt of tries) {
    const hits = attempt();
    if (hits.length === 1) return { peer: hits[0] };
    if (hits.length > 1)
      return {
        error: `"${to}" matches several sessions: ${hits.map((p) => `${p.name} [${shortId(p)}]`).join(", ")}`,
      };
  }
  const known = peers.map((p) => `${p.name} [${shortId(p)}]`).join(", ") || "none";
  return { error: `no live session matches "${to}". Reachable: ${known}` };
}

// Claude neutralizes a closing tag in the body as `<\/…`; it also folds
// lookalike characters, which this simpler escape does not.
const tagInBody = new RegExp(`<(?=\\s*/?\\s*${TAG})`, "giu");
const escapedTagInBody = new RegExp(`<\\\\(?=\\s*/?\\s*${TAG})`, "giu");

function attr(value: string): string {
  const clean = value
    .replace(/["<>]/g, "")
    .replace(/[\p{Cf}\p{Cc}\p{Cs}\p{Zl}\p{Zp}]/gu, "")
    .trim();
  const chars = [...clean];
  return chars.length > 64 ? `${chars.slice(0, 64).join("")}…` : clean;
}

export interface Envelope {
  from?: string;
  fromSession?: string;
  fromName?: string;
  fromMode?: PermissionClass;
  body: string;
}

/** Attribute order is fixed: Claude re-serializes what it parses and drops a mismatch. */
export function buildEnvelope(e: Envelope): string {
  const attrs: string[] = [];
  if (e.from) attrs.push(`from="${e.from}"`);
  if (e.fromSession && /^[A-Za-z0-9_-]{1,80}$/.test(e.fromSession))
    attrs.push(`from-session="${e.fromSession}"`);
  const name = e.fromName === undefined ? "" : attr(e.fromName);
  if (name) attrs.push(`from-name="${name}"`);
  if (e.fromMode) attrs.push(`from-mode="${e.fromMode}"`);
  return `<${TAG}${attrs.map((a) => ` ${a}`).join("")}>\n${e.body.replace(tagInBody, "<\\")}\n</${TAG}>`;
}

/** Parse an inbound envelope; content without one comes back as the body. */
export function parseEnvelope(content: string): Envelope {
  const m = new RegExp(`^<${TAG}((?:\\s+[a-z-]+="[^"]*")*)>\\n([\\s\\S]*)\\n</${TAG}>$`).exec(
    content,
  );
  if (!m) return { body: content };
  const attrs = Object.fromEntries(
    [...m[1].matchAll(/([a-z-]+)="([^"]*)"/g)].map((a) => [a[1], a[2]]),
  );
  const mode = attrs["from-mode"];
  return {
    from: attrs.from,
    fromSession: attrs["from-session"],
    fromName: attrs["from-name"],
    fromMode: mode === "bypass" || mode === "prompting" ? mode : undefined,
    body: m[2].replace(escapedTagInBody, "<"),
  };
}

export interface UserFrame {
  msgV: 1;
  msg_id: string;
  type: "user";
  message: { role: "user"; content: string };
  priority: "now" | "next" | "later";
  from?: string;
  session_id?: string;
}

export function userFrame(o: { content: string; from?: string; sessionId?: string }): UserFrame {
  return {
    msgV: 1,
    msg_id: randomUUID(),
    type: "user",
    message: { role: "user", content: o.content },
    priority: "next",
    ...(o.from && { from: o.from }),
    ...(o.sessionId && { session_id: o.sessionId }),
  };
}

export function controlFrame(
  action: string,
  fields: Record<string, unknown>,
): Record<string, unknown> {
  return { msgV: 1, msg_id: randomUUID(), type: "control", action, ...fields };
}

/**
 * Write one frame and wait for the receiver to close. Resolves once the frame
 * left this process, which says nothing about whether the receiver delivered it.
 */
export function sendFrame(socketPath: string, frame: object, timeoutMs = 5000): Promise<void> {
  const line = `${JSON.stringify(frame)}\n`;
  if (Buffer.byteLength(line) > MAX_FRAME_BYTES)
    return Promise.reject(new Error("message is over the 1 MiB frame limit"));
  return new Promise((resolve, reject) => {
    const c = connect({ path: socketPath });
    let written = false;
    c.setTimeout(timeoutMs, () => c.destroy(new Error(`timed out sending to ${socketPath}`)));
    c.on("error", reject);
    c.on("connect", () => c.end(line, () => (written = true)));
    c.on("close", (hadError) => (written && !hadError ? resolve() : undefined));
    // The receiver may answer on this connection; nothing in v1 needs it.
    c.on("data", () => {});
  });
}

/**
 * Bind a 0600 listening socket that hands each parsed frame to `onFrame`.
 * Node exposes no SO_PEERCRED, so unlike Claude it cannot verify the sender's pid.
 */
export async function bindInbox(
  socketPath: string,
  onFrame: (frame: Record<string, unknown>) => void,
): Promise<Server> {
  ensureSocketDir(path.dirname(socketPath));
  if (await socketReachable(socketPath)) throw new Error(`${socketPath} is already in use`);
  await unlink(socketPath).catch(() => {});
  const server = createServer((conn) => {
    conn.setEncoding("utf8");
    let buf = "";
    conn.setTimeout(30_000, () => conn.destroy());
    conn.on("data", (chunk: string) => {
      buf += chunk;
      if (Buffer.byteLength(buf) > MAX_FRAME_BYTES && !buf.includes("\n")) {
        conn.destroy();
        return;
      }
      for (let i = buf.indexOf("\n"); i !== -1; i = buf.indexOf("\n")) {
        const line = buf.slice(0, i);
        buf = buf.slice(i + 1);
        if (!line.trim()) continue;
        try {
          const frame = JSON.parse(line);
          if (frame && typeof frame === "object") onFrame(frame);
        } catch {
          // Malformed lines are dropped, as Claude does.
        }
      }
    });
    // Claude's sender resolves only once the socket fully closes.
    conn.on("end", () => conn.end());
    conn.on("error", () => {});
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, () => {
      server.off("error", reject);
      resolve();
    });
  });
  chmodSync(socketPath, 0o600);
  return server;
}

export async function writeRegistryEntry(entry: RegistryEntry): Promise<void> {
  const dir = registryDir();
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const file = path.join(dir, `${entry.pid}.json`);
  const tmp = `${file}.${randomUUID().slice(0, 8)}.tmp`;
  await writeFile(tmp, JSON.stringify(entry), { mode: 0o644 });
  await rename(tmp, file);
}

export async function removeRegistryEntry(pid: number): Promise<void> {
  await unlink(path.join(registryDir(), `${pid}.json`)).catch(() => {});
}
