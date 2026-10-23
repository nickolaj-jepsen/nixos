/**
 * Appends language-server errors to `edit`/`write` results, like Claude Code's
 * LSP integration: no tools are declared, so it costs no context until an edit
 * actually breaks something.
 *
 * Servers come from the fireproof.agents.lspServers registry, written to the
 * JSON file `PI_LSP_SERVERS` names. One server per (name, repo root) starts on
 * the first edit to a matching file and lives until the session ends.
 */
import { type ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, extname, relative, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

interface ServerConfig {
  command: string;
  args?: string[];
  extensionToLanguage: Record<string, string>;
}

interface Diagnostic {
  range: { start: { line: number; character: number } };
  severity?: number;
  message: string;
  source?: string;
}

// Servers don't publish for a document that is and stays clean (nil, tsserver), so silence
// past this means clean and is paid on every clean edit. Warm tsserver publishes in ~400ms.
const FIRST_PUBLISH_MS = 800;
// An open also waits for the server to load the project; longer until it has published once.
const FIRST_PUBLISH_ON_OPEN_MS = 1_500;
const FIRST_PUBLISH_COLD_MS = 3_000;
// More publishes can follow the first; collect until they stop.
const SETTLE_MS = 300;
// A cold server that is still starting misses this and reports nothing, which is fine.
const START_MS = 5_000;
const MAX_LINES = 10;

class Server {
  private proc: ChildProcessWithoutNullStreams;
  private buffer = Buffer.alloc(0);
  private nextId = 1;
  private pending = new Map<number, (result: unknown) => void>();
  private versions = new Map<string, number>();
  private texts = new Map<string, string>();
  private diagnostics = new Map<string, Diagnostic[]>();
  private listeners = new Set<(uri: string) => void>();
  readonly ready: Promise<void>;
  private readonly died: Promise<void>;
  dead = false;
  private warm = false;

  constructor(config: ServerConfig, root: string) {
    this.proc = spawn(config.command, config.args ?? [], { cwd: root, stdio: "pipe" });
    this.died = new Promise((done) => {
      const die = () => {
        this.dead = true;
        done();
      };
      this.proc.on("error", die);
      this.proc.on("exit", die);
      this.proc.stdin.on("error", die);
    });
    this.proc.stderr.resume();
    this.proc.stdout.on("data", (chunk: Buffer) => this.receive(chunk));
    const rootUri = pathToFileURL(root).href;
    this.ready = this.request("initialize", {
      processId: process.pid,
      rootUri,
      workspaceFolders: [{ uri: rootUri, name: root }],
      capabilities: {
        textDocument: { publishDiagnostics: { versionSupport: true }, synchronization: {} },
        workspace: { configuration: true, workspaceFolders: true },
      },
    }).then(() => this.notify("initialized", {}));
  }

  /** Syncs `text` for `path` and resolves with its diagnostics once they settle, or undefined. */
  async check(path: string, languageId: string, text: string): Promise<Diagnostic[] | undefined> {
    // A server that died or is still starting never answers `initialize`; don't hang the edit on it.
    const started = await Promise.race([
      this.ready.then(() => true),
      this.died.then(() => false),
      new Promise<false>((done) => setTimeout(() => done(false), START_MS).unref()),
    ]);
    if (!started || this.dead) return undefined;
    const uri = pathToFileURL(path).href;
    // Servers don't republish for an unchanged document, so waiting would only hit the deadline.
    if (this.texts.get(uri) === text) return this.diagnostics.get(uri);
    this.texts.set(uri, text);
    const version = (this.versions.get(uri) ?? 0) + 1;
    this.versions.set(uri, version);
    this.diagnostics.delete(uri);

    const settled = new Promise<Diagnostic[] | undefined>((done) => {
      let quiet: NodeJS.Timeout | undefined;
      const finish = (result: Diagnostic[] | undefined) => {
        clearTimeout(quiet);
        clearTimeout(deadline);
        this.listeners.delete(onPublish);
        done(result);
      };
      const onPublish = (published: string) => {
        if (published !== uri) return;
        clearTimeout(deadline);
        clearTimeout(quiet);
        quiet = setTimeout(() => finish(this.diagnostics.get(uri)), SETTLE_MS);
      };
      const deadline = setTimeout(
        () => finish(this.diagnostics.get(uri)),
        !this.warm
          ? FIRST_PUBLISH_COLD_MS
          : version === 1
            ? FIRST_PUBLISH_ON_OPEN_MS
            : FIRST_PUBLISH_MS,
      );
      this.listeners.add(onPublish);
    });

    if (version === 1) {
      this.notify("textDocument/didOpen", { textDocument: { uri, languageId, version, text } });
    } else {
      // A change without a range replaces the whole document, which every server accepts.
      this.notify("textDocument/didChange", {
        textDocument: { uri, version },
        contentChanges: [{ text }],
      });
    }
    return settled;
  }

  stop() {
    if (this.dead) return;
    this.request("shutdown", null).then(() => this.notify("exit", null));
    setTimeout(() => this.proc.kill(), 1_000).unref();
  }

  private send(message: object) {
    if (this.dead) return;
    const body = Buffer.from(JSON.stringify({ jsonrpc: "2.0", ...message }));
    this.proc.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
    this.proc.stdin.write(body);
  }

  private request(method: string, params: unknown): Promise<unknown> {
    const id = this.nextId++;
    return new Promise((done) => {
      this.pending.set(id, done);
      this.send({ id, method, params });
    });
  }

  private notify(method: string, params: unknown) {
    this.send({ method, params });
  }

  private receive(chunk: Buffer) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    for (;;) {
      const headerEnd = this.buffer.indexOf("\r\n\r\n");
      if (headerEnd < 0) return;
      const length = Number(
        /Content-Length: (\d+)/i.exec(this.buffer.subarray(0, headerEnd).toString())?.[1],
      );
      const start = headerEnd + 4;
      if (this.buffer.length < start + length) return;
      const body = this.buffer.subarray(start, start + length).toString();
      this.buffer = this.buffer.subarray(start + length);
      try {
        this.dispatch(JSON.parse(body));
      } catch {
        // A malformed message only loses that message.
      }
    }
  }

  private dispatch(message: { id?: number; method?: string; params?: any; result?: unknown }) {
    if (message.method === undefined) {
      this.pending.get(message.id!)?.(message.result);
      this.pending.delete(message.id!);
      return;
    }
    if (message.id !== undefined) {
      // Server-to-client requests: answer neutrally so the server never blocks on us.
      const items =
        message.method === "workspace/configuration" ? message.params?.items : undefined;
      this.send({ id: message.id, result: items ? items.map(() => null) : null });
      return;
    }
    if (message.method === "textDocument/publishDiagnostics") {
      const { uri, version, diagnostics } = message.params;
      if (version !== undefined && version !== this.versions.get(uri)) return;
      this.warm = true;
      this.diagnostics.set(uri, diagnostics);
      for (const listener of this.listeners) listener(uri);
    }
  }
}

function repoRoot(file: string, fallback: string): string {
  for (let dir = dirname(file); dir !== dirname(dir); dir = dirname(dir)) {
    if (existsSync(resolve(dir, ".git"))) return dir;
  }
  return fallback;
}

function loadConfig(): Record<string, ServerConfig> {
  const path = process.env.PI_LSP_SERVERS;
  if (!path) return {};
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return {};
  }
}

export default function (pi: ExtensionAPI) {
  const configs = loadConfig();
  const servers = new Map<string, Server>();
  if (Object.keys(configs).length === 0) return;

  pi.on("tool_result", async (event, ctx) => {
    if ((event.toolName !== "edit" && event.toolName !== "write") || event.isError) return;
    const { path } = event.input as { path?: unknown };
    if (typeof path !== "string") return;
    const file = resolve(ctx.cwd, path);
    const ext = extname(file);
    const match = Object.entries(configs).find(([, config]) => ext in config.extensionToLanguage);
    if (!match) return;
    const [name, config] = match;

    const root = repoRoot(file, ctx.cwd);
    const key = `${name}\0${root}`;
    let server = servers.get(key);
    if (!server || server.dead) {
      server = new Server(config, root);
      servers.set(key, server);
    }

    let diagnostics: Diagnostic[] | undefined;
    try {
      diagnostics = await server.check(
        file,
        config.extensionToLanguage[ext],
        readFileSync(file, "utf8"),
      );
    } catch {
      return;
    }
    const errors = (diagnostics ?? []).filter((d) => d.severity === 1);
    if (errors.length === 0) return;

    const lines = errors.slice(0, MAX_LINES).map((d) => {
      const { line, character } = d.range.start;
      const source = d.source ? ` [${d.source}]` : "";
      return `${line + 1}:${character + 1} ${d.message.split("\n")[0]}${source}`;
    });
    if (errors.length > MAX_LINES) lines.push(`… ${errors.length - MAX_LINES} more`);
    const text = `\n\nLSP errors in ${relative(ctx.cwd, file) || file}:\n${lines.join("\n")}`;
    return { content: [...event.content, { type: "text", text }] };
  });

  pi.on("session_shutdown", () => {
    for (const server of servers.values()) server.stop();
    servers.clear();
  });
}
