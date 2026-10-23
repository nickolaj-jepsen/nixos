/**
 * Claude Code's same-machine cross-session protocol, as read out of the
 * Claude Code 2.1.308 binary: a session registry under `<config dir>/sessions`
 * (`~/.claude` on a plain install, `~/.claude-work` for the work wrapper),
 * one Unix socket per session under `cc-socks`, and newline-delimited JSON
 * frames on it. Undocumented upstream, so any Claude Code release may change it.
 *
 * Node built-ins only, so it can run outside pi for protocol tests.
 */
import { createHash, randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  readlinkSync,
  realpathSync,
} from "node:fs";
import { access, open, readdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
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
  /** pi-only: prompt tokens of the session's last turn; Claude Code ignores unknown fields. */
  contextTokens?: number;
  [key: string]: unknown;
}

export interface Peer extends RegistryEntry {
  messagingSocketPath: string;
  name: string;
}

/**
 * Claude config dirs this machine uses: the one CLAUDE_CONFIG_DIR names,
 * `~/.claude`, and sibling profiles such as `~/.claude-work` that already hold
 * a registry. Each profile keeps its own registry, so one without the others
 * hides every session belonging to a different login.
 */
function configDirs(): string[] {
  const home = homedir();
  const dirs = [process.env.CLAUDE_CONFIG_DIR, path.join(home, ".claude")].filter(
    (dir): dir is string => !!dir,
  );
  for (const name of entries(home).sort())
    if (/^\.claude-[^.]+$/.test(name) && existsSync(path.join(home, name, "sessions")))
      dirs.push(path.join(home, name));
  return [...new Set(dirs)];
}

function real(dir: string): string {
  try {
    return realpathSync(dir);
  } catch {
    return dir;
  }
}

function entries(dir: string): string[] {
  try {
    return readdirSync(dir);
  } catch {
    return [];
  }
}

/** Every session registry on this machine; profiles symlinked together count once. */
export function registryDirs(): string[] {
  return [...new Set(configDirs().map((dir) => real(path.join(dir, "sessions"))))];
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

/** Live, messageable sessions from every Claude registry, newest first. */
export async function listPeers(excludeSocket?: string): Promise<Peer[]> {
  const domain = pidDomain();
  // A pi session registers in every registry, so the socket path is the key.
  const candidates = new Map<string, Peer>();
  for (const dir of registryDirs()) {
    let files: string[];
    try {
      files = await readdir(dir);
    } catch {
      continue;
    }
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
      if (candidates.has(sock)) continue;
      if ((entry.peerProtocol ?? 0) < PEER_PROTOCOL) continue;
      if (entry.pidDomain !== undefined && domain !== undefined && entry.pidDomain !== domain)
        continue;
      if (!pidAlive(entry.pid)) continue;
      if (entry.procStart !== undefined && procStart(entry.pid) !== entry.procStart) continue;
      candidates.set(sock, {
        ...entry,
        messagingSocketPath: sock,
        name: entry.name || `pid ${entry.pid}`,
      });
    }
  }
  const peers = [...candidates.values()];
  const reachable = await Promise.all(peers.map((p) => socketReachable(p.messagingSocketPath)));
  return peers.filter((_, i) => reachable[i]).sort((a, b) => b.startedAt - a.startedAt);
}

/**
 * Claude's own `[ref]` for a session, so an id read off either harness resolves
 * in both: the first 6 hex digits of sha256(`session:<socket path>`). Claude
 * lengthens a ref only while two collide, so match refs as a prefix of the full
 * digest. Its tengu_session_stable_address flag would hash
 * `session:sid:<sessionId>` instead.
 */
export function shortId(peer: Pick<Peer, "messagingSocketPath">): string {
  return refHash(peer).slice(0, 6);
}

function refHash(peer: Pick<Peer, "messagingSocketPath">): string {
  return createHash("sha256").update(`session:${peer.messagingSocketPath}`).digest("hex");
}

/**
 * When the session last did anything: now while it is not idle, otherwise when
 * it went idle. Claude Code stamps `statusUpdatedAt` on each status change.
 */
export function lastActive(peer: Peer, now = Date.now()): number {
  if (peer.status !== "idle") return now;
  return peer.statusUpdatedAt ?? peer.updatedAt ?? peer.startedAt;
}

/** "busy", or how long ago the session went idle, coarsely ("idle 3h"). */
export function activityLabel(peer: Peer, now = Date.now()): string {
  if (peer.status !== "idle") return peer.status ?? "unknown";
  const mins = Math.floor((now - lastActive(peer, now)) / 60_000);
  if (mins < 1) return "idle <1m";
  if (mins < 60) return `idle ${mins}m`;
  if (mins < 48 * 60) return `idle ${Math.floor(mins / 60)}h`;
  return `idle ${Math.floor(mins / (24 * 60))}d`;
}

const TRANSCRIPT_TAIL_BYTES = 2 * 1024 * 1024;

const exists = (file: string) =>
  access(file).then(
    () => true,
    () => false,
  );

async function claudeTranscript(peer: Peer): Promise<string | undefined> {
  const file = `${peer.sessionId}.jsonl`;
  for (const dir of registryDirs()) {
    const projects = path.join(path.dirname(dir), "projects");
    const guess = path.join(projects, peer.cwd.replace(/[^A-Za-z0-9-]/g, "-"), file);
    if (await exists(guess)) return guess;
    // Claude shortens long project dir names; fall back to a scan.
    for (const project of await readdir(projects).catch(() => [])) {
      if (await exists(path.join(projects, project, file)))
        return path.join(projects, project, file);
    }
  }
  return undefined;
}

/**
 * Tokens a peer's next turn will read: pi peers publish `contextTokens`; for
 * Claude Code it is the prompt size of the last assistant entry in its
 * transcript. Undefined when neither is available.
 */
export async function contextTokens(peer: Peer): Promise<number | undefined> {
  if (typeof peer.contextTokens === "number") return peer.contextTokens;
  if (peer.entrypoint === "pi") return undefined;
  const transcript = await claudeTranscript(peer);
  if (!transcript) return undefined;
  const handle = await open(transcript);
  try {
    const { size } = await handle.stat();
    const length = Math.min(size, TRANSCRIPT_TAIL_BYTES);
    const buf = Buffer.alloc(length);
    await handle.read(buf, 0, length, size - length);
    const lines = buf.toString("utf8").split("\n").reverse();
    for (const line of lines) {
      if (!line.includes('"usage"') || !line.includes('"assistant"')) continue;
      try {
        const u = JSON.parse(line).message?.usage;
        const total = u
          ? (u.input_tokens ?? 0) +
            (u.cache_read_input_tokens ?? 0) +
            (u.cache_creation_input_tokens ?? 0)
          : 0;
        // Synthetic entries (API errors, usage-limit notices) carry all-zero usage.
        if (total > 0) return total;
      } catch {
        // The first line of the tail is usually cut mid-entry.
      }
    }
  } finally {
    await handle.close();
  }
  return undefined;
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
    peers.filter((p) => p.sessionId === id || refHash(p).startsWith(id.toLowerCase()));
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

/** Register in every Claude profile's registry, so each login sees this session. */
export async function writeRegistryEntry(entry: RegistryEntry): Promise<void> {
  const body = JSON.stringify(entry);
  await Promise.allSettled(
    registryDirs().map(async (dir) => {
      mkdirSync(dir, { recursive: true, mode: 0o700 });
      const file = path.join(dir, `${entry.pid}.json`);
      const tmp = `${file}.${randomUUID().slice(0, 8)}.tmp`;
      await writeFile(tmp, body, { mode: 0o644 });
      await rename(tmp, file);
    }),
  );
}

export async function removeRegistryEntry(pid: number): Promise<void> {
  await Promise.all(
    registryDirs().map((dir) => unlink(path.join(dir, `${pid}.json`)).catch(() => {})),
  );
}
