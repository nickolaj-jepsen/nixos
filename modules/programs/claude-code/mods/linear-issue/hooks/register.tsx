import { atom, read, update } from "claude-code";
import type { EngineInterface, Register, RenderElement, RenderNode } from "claude-code";

import type { Duplicate, Filed, Form, Last, Option } from "../types";

// The built-in's card has no extension point, so the button is spliced into the
// tree it draws, found by these labels. A rename only hides the button (see warnDrift).
const YSK = "cc-plugin-you-should-know";
const LEARN_MORE = "Learn more";
const ANCHOR = "Chat in main session";
const PANE = "linear-draft";
const FALLBACK_TEAM = "MSC";
const RECENT_MESSAGES = 8;
const MESSAGE_CHARS = 2000;
// Issues each search term finds, and candidates the duplicate check weighs at most.
const SEARCH_HITS = 10;
const CANDIDATES = 20;
const CANDIDATE_CHARS = 300;
// How long hasLinear trusts its last answer; a missing server is looked for again sooner.
const LINEAR_SEEN_MS = 60_000;
const LINEAR_MISSING_MS = 5_000;
// Digits the button may take, first free wins; 8 and 9 belong to the draft chip.
const HOTKEYS = ["3", "4", "5", "6", "7"];
const CLOSED = ["completed", "canceled", "duplicate"];
const SERVER_WAIT_S = 10;
// A Select takes 1 to 64 options; labels are filtered by typing instead.
const SELECT_MAX = 64;
const COMPACT_ROWS = 18;
const TITLE_LABEL = "Title: ";
// The "⏎ submit" a focused one-row Input draws after its text.
const HINT_WIDTH = 10;
const DISCARD_ARM_MS = 5000;
// An open Select shows 8 options and a "… n more" row.
const OPEN_LIST_ROWS = 9;
const HINTS = "Tab/Shift+Tab move · ↑↓ pick · Esc hide";
const LINEAR_TOOL = /^mcp__(.*linear.*)__([^_].*)$/i;
const PRIORITIES: Option[] = [
  { value: "1", label: "Urgent" },
  { value: "2", label: "High" },
  { value: "3", label: "Medium" },
  { value: "4", label: "Low" },
  { value: "0", label: "No priority" },
];

// The card the button was pressed on, drawn as nothing until another replaces it.
const hidden = atom({ plugin: "linear-issue", key: "hidden" } as const, null);
const form = atom({ plugin: "linear-issue", key: "form" } as const, null);
const filed = atom({ plugin: "linear-issue", key: "filed" } as const, []);
const isPaneOpen = atom({ plugin: "linear-issue", key: "isPaneOpen" } as const, false);
const focused = atom({ plugin: "linear-issue", key: "focused" } as const, null);
const isDiscardArmed = atom({ plugin: "linear-issue", key: "isDiscardArmed" } as const, false);

// Set by a Learn more press, cleared once the expanded card has been checked.
let isExpanding = false;
let linearSeen: { at: number; isSeen: boolean } | undefined;
// Per team key: its statuses, labels and projects, fetched once a session.
const teamOptions = new Map<string, Promise<TeamOptions>>();

type TeamOptions = { statuses: Option[]; labels: Option[]; projects: Option[]; todo: string };

/** What the drafting model answers, before names are resolved to Linear ids. */
type Draft = {
  team: string;
  title: string;
  description: string;
  priority: number;
  labels?: string[];
  search?: string[];
};

/** What the duplicate check answers. */
type Verdict = { duplicate: { issue: string; comment: string } | null };

type Issue = { id: string; title: string; statusType: string; team: string; description?: string };

// No tools and no subagent: a subagent's report would land in the session and start a turn.
const SYSTEM = `You draft a Linear issue for the user to deal with later, from one of two seeds: an <insight> that Claude Code's "You should know" side agent flagged while it watched their session, or a <note> the user typed with /linear. The seed is what to file; the recent conversation is context for it. An empty <note> means: file what the recent conversation is about. The user reviews and edits your draft before it is created.

- team: the key of the team from <teams> that the repository and topic belong to; when unsure, the <defaults> team.
- title: short and specific, imperative, under 80 characters.
- description: Linear markdown that reads at a glance. Prefer structure to prose: one sentence saying what to do and why, then the details as bullets, never as a paragraph. Use the richer forms only when the content has that shape:
  - a table when comparing options, listing items that share attributes, or mapping before to after
  - a checklist (- [ ]) when the work splits into separate steps
  No diagrams: the draft pane cannot draw them.
  Then, leaving out a line you have nothing concrete for:
  **Where:** the file paths, symbols or commands named in the seed or conversation, in backticks
  **Done when:** one line saying how to tell it is finished
  No headings, no story of the session, no restating the title; about 120 words at most, a table not counted. Do not add a source or session line; it is appended for you.
- priority: 1 urgent, 2 high, 3 medium, 4 low. Reserve 1 for things that are breaking now; when unsure, the <defaults> priority.
- labels: names from <labels> that clearly fit, usually none.
- search: two or three short phrases, one to three words each, that an existing issue about the same problem would contain in its title or description; used to look for duplicates.
- Never copy secrets, tokens, credentials or .env contents into the draft.

Answer with one JSON object and nothing else:
{"team": "...", "title": "...", "description": "...", "priority": 4, "labels": [], "search": []}`;

const DUPLICATE_SYSTEM = `You check whether an open Linear issue already covers a <draft> the user is about to file. The <candidates> came from a keyword search, so most are unrelated. Only call one a duplicate when it is about the same problem or change, not merely the same area.

When one is, answer its key and a one-or-two-sentence comment for it adding what the draft knows that the issue does not. Never copy secrets, tokens, credentials or .env contents.

Answer with one JSON object and nothing else:
{"duplicate": null} or {"duplicate": {"issue": "KEY-1", "comment": "..."}}`;

type Element = Exclude<RenderNode, string>;

const isElement = (node: RenderNode | undefined): node is Element =>
  typeof node === "object" && node !== null;

const childrenOf = (node: Element): RenderNode[] =>
  "children" in node && Array.isArray(node.children) ? node.children : [];

const isButton = (node: RenderNode, label: string) =>
  isElement(node) && node.type === "Button" && node.props.label === label;

const isDismiss = (node: RenderNode) =>
  isElement(node) && node.type === "Button" && node.props.role === "dismiss";

/** The nodes from `root` down to the first node `match` accepts, both included; undefined when none does. */
function pathTo(root: RenderNode, match: (node: RenderNode) => boolean): RenderNode[] | undefined {
  if (match(root)) return [root];
  if (!isElement(root)) return undefined;
  for (const child of childrenOf(root)) {
    const path = pathTo(child, match);
    if (path) return [root, ...path];
  }
  return undefined;
}

/** `root` with `target` (by identity) swapped for `replacement`. */
function replace(root: RenderNode, target: RenderNode, replacement: RenderNode): RenderNode {
  if (root === target) return replacement;
  if (!isElement(root) || childrenOf(root).length === 0) return root;
  return {
    ...root,
    children: childrenOf(root).map((c) => replace(c, target, replacement)),
  } as Element;
}

/**
 * `tree` with `button` beside the anchor button: in a copy of the anchor's wrapper, before the
 * dismiss button when one shares a row with it. Undefined when the tree holds no anchor.
 */
function insertButton(tree: RenderNode, button: RenderElement): RenderNode | undefined {
  const toAnchor = pathTo(tree, (n) => isButton(n, ANCHOR));
  const anchor = toAnchor?.at(-1);
  if (!toAnchor || !anchor || toAnchor.length < 2) return undefined;
  const toDismiss = pathTo(tree, isDismiss);

  // The row is the deepest node above both buttons; without a dismiss, the anchor's parent.
  let depth = toAnchor.length - 2;
  if (toDismiss) {
    depth = 0;
    while (depth + 2 < toAnchor.length && toAnchor[depth + 1] === toDismiss[depth + 1]) depth++;
  }
  const row = toAnchor[depth] as Element;
  const wrapper = toAnchor[depth + 1] as RenderNode;
  const kids = childrenOf(row);
  const dismissAt =
    toDismiss?.[depth + 1] === undefined ? -1 : kids.indexOf(toDismiss[depth + 1] as RenderNode);
  const at = dismissAt >= 0 ? dismissAt : kids.indexOf(wrapper) + 1;
  const copy = replace(wrapper, anchor, button);
  const newRow = { ...row, children: [...kids.slice(0, at), copy, ...kids.slice(at)] } as Element;
  return replace(tree, row, newRow);
}

/** The card's text, one line per Text, Markdown or Code, buttons left out. */
function cardText(node: RenderNode): string {
  const lines: string[] = [];
  const flat = (n: RenderNode): string =>
    typeof n === "string" ? n : isElement(n) ? childrenOf(n).map(flat).join("") : "";
  const walk = (n: RenderNode) => {
    if (typeof n === "string") lines.push(n);
    else if (!isElement(n) || n.type === "Button") return;
    else if (n.type === "Text") lines.push(flat(n));
    else if (n.type === "Markdown") lines.push(n.props.text);
    else if (n.type === "Code") lines.push(n.props.source);
    else childrenOf(n).forEach(walk);
  };
  walk(node);
  return lines
    .map((l) => l.trim())
    .filter(Boolean)
    .join("\n");
}

const hasButtons = (node: RenderNode) =>
  pathTo(node, (n) => isElement(n) && n.type === "Button") !== undefined;

/**
 * True when any MCP server named like Linear has a tool here, its auth stub included.
 * Remembered for a while, as the band asks on every render.
 */
async function hasLinear($: EngineInterface): Promise<boolean> {
  const now = await $.clock.now();
  const ttl = linearSeen?.isSeen ? LINEAR_SEEN_MS : LINEAR_MISSING_MS;
  if (linearSeen && now - linearSeen.at < ttl) return linearSeen.isSeen;
  const tools = await $.tool.list().catch(() => []);
  linearSeen = { at: now, isSeen: tools.some((t) => /^mcp__.*linear.*__/i.test(t.name)) };
  return linearSeen.isSeen;
}

/** Hotkeys the buttons in `node` already take. */
function hotkeysIn(node: RenderNode): Set<string> {
  const taken = new Set<string>();
  const walk = (n: RenderNode) => {
    if (!isElement(n)) return;
    if (n.type === "Button" && typeof n.props.hotkey === "string") taken.add(n.props.hotkey);
    childrenOf(n).forEach(walk);
  };
  walk(node);
  return taken;
}

/** One toast per Claude Code version, when the expanded card no longer has the anchor. */
async function warnDrift($: EngineInterface) {
  const { version } = await $.session.version();
  if ((await $.store.get("warnedVersion").catch(() => undefined)) === version) return;
  await $.store.set("warnedVersion", version);
  $.ui.toast(
    `linear-issue: the You should know card no longer has "${ANCHOR}", so its Linear button is hidden; update mods/linear-issue`,
  );
}

async function gitBranch($: EngineInterface, cwd: string): Promise<string> {
  try {
    const r = await $.process.run(["git", "-C", cwd, "branch", "--show-current"], {
      timeoutMs: 2000,
    });
    return r.exitCode === 0 ? r.stdout.trim() || "(detached)" : "(none)";
  } catch {
    return "(none)";
  }
}

/** `owner/repo` from a git remote URL, or undefined when it names none. */
const repoName = (remote: string) => /[:/]([^/:]+\/[^/]+?)(?:\.git)?\/?$/.exec(remote)?.[1];

/**
 * The drafter's brief: `seed` (a card's `insight` or a /linear `note`) with where it came
 * from, and the source line the filed description ends with.
 */
async function brief(
  $: EngineInterface,
  kind: "insight" | "note",
  seed: string,
): Promise<{ text: string; source: string }> {
  const cwd = await $.session.cwd();
  const [repo, branch, sessionId, messages] = await Promise.all([
    $.session.repo().catch(() => null),
    gitBranch($, cwd),
    $.session.id(),
    $.session.messages().catch(() => []),
  ]);
  const recent = messages
    .filter((m) => m.text.trim() !== "")
    .slice(-RECENT_MESSAGES)
    .map((m) => {
      const text = m.text.length > MESSAGE_CHARS ? `${m.text.slice(0, MESSAGE_CHARS)}…` : m.text;
      return `<${m.role}>\n${text}\n</${m.role}>`;
    })
    .join("\n");
  const name =
    (repo?.remote && repoName(repo.remote)) ?? (repo?.root ?? cwd).split("/").pop() ?? cwd;
  const text = [
    `<${kind}>\n${seed}\n</${kind}>`,
    `<source>\ndirectory: ${cwd}\nrepository: ${name}\nbranch: ${branch}\n</source>`,
    `<recent_conversation>\n${recent}\n</recent_conversation>`,
  ].join("\n\n");
  return { text, source: `Source: \`${name}\` · ${branch} · session ${sessionId}` };
}

const oneLine = (text: string) => text.replace(/\s*\n\s*/g, " ");

type Block = { kind: "markdown" | "table" | "code"; lines: string[] };

/**
 * The description cut into the blocks the preview draws itself, tables and fenced code,
 * and the markdown between them. Fence markers are dropped; a fence's language is its
 * first line.
 */
function blocks(text: string): Block[] {
  const out: Block[] = [];
  let fence: Block | undefined;
  for (const line of text.split("\n")) {
    const marker = /^\s*```(.*)$/.exec(line);
    if (marker) {
      if (fence) fence = undefined;
      else out.push((fence = { kind: "code", lines: marker[1] ? [marker[1].trim()] : [] }));
      continue;
    }
    if (fence) {
      fence.lines.push(line);
      continue;
    }
    const kind = /^\s*\|.*\|\s*$/.test(line) ? "table" : "markdown";
    const last = out.at(-1);
    if (last?.kind === kind) last.lines.push(line);
    else out.push({ kind, lines: [line] });
  }
  return out;
}

/** A table row's cells, inline emphasis and code marks removed. */
const cells = (line: string) =>
  line
    .trim()
    .replace(/^\||\|$/g, "")
    .split("|")
    .map((c) => c.trim().replace(/\*\*|`/g, ""));

/** Merges `patch` into the open form; nothing when no draft is open. */
const patchForm = ($: EngineInterface, patch: Partial<Form>) =>
  update($, form, (cur) => cur && { ...cur, ...patch });

const errorText = (error: unknown) => (error instanceof Error ? error.message : String(error));

/** The first connected Linear server that can write issues, in tool-name spelling. */
async function linearServer($: EngineInterface): Promise<string | undefined> {
  // MCP servers connect after the session starts, so a /linear right away waits for one.
  for (let attempt = 0; attempt < SERVER_WAIT_S; attempt++) {
    for (const { name } of await $.tool.list()) {
      const m = LINEAR_TOOL.exec(name);
      if (m?.[2] === "save_issue") return m[1];
    }
    await $.clock.sleep(1000);
  }
  return undefined;
}

/** Calls a Linear tool and parses its JSON answer; throws with the server's text on an error. */
async function call<T>(
  $: EngineInterface,
  server: string,
  tool: string,
  args: Record<string, unknown>,
) {
  const result = await $.mcp.call(server, tool, args);
  const text = result.content.map((c) => ("text" in c ? c.text : "")).join("\n");
  if (result.isError) throw new Error(text.slice(0, 200) || `${tool} failed`);
  try {
    return JSON.parse(text) as T;
  } catch {
    return text as unknown as T;
  }
}

function loadTeam($: EngineInterface, server: string, team: string): Promise<TeamOptions> {
  let options = teamOptions.get(team);
  if (!options) {
    options = (async () => {
      type Named = {
        id: string;
        name: string;
        type?: string;
        parent?: string | null;
        archivedAt?: string | null;
      };
      const [statuses, labels, projects] = await Promise.all([
        call<Named[]>($, server, "list_issue_statuses", { team }),
        call<{ labels: Named[] }>($, server, "list_issue_labels", { team, limit: 250 }),
        call<{ projects: Named[] }>($, server, "list_projects", { team, limit: 50 }),
      ]);
      const todo =
        statuses.find((s) => s.name === "Todo") ?? statuses.find((s) => s.type === "unstarted");
      return {
        statuses: statuses.map((s) => ({ value: s.id, label: s.name })),
        labels: labels.labels
          .filter((l) => !l.archivedAt)
          .map((l) => ({ value: l.id, label: l.parent ? `${l.parent}/${l.name}` : l.name })),
        projects: [
          { value: "", label: "No project" },
          ...projects.projects.map((p) => ({ value: p.id, label: p.name })),
        ],
        todo: todo?.id ?? statuses[0]?.id ?? "",
      };
    })();
    teamOptions.set(team, options);
    options.catch(() => teamOptions.delete(team));
  }
  return options;
}

/** Rows that items of `widths` columns, gaps included, take wrapped to `width` columns. */
function wrappedRows(widths: number[], width: number): number {
  let rows = 1;
  let used = 0;
  for (const w of widths) {
    if (used > 0 && used + w > width) {
      rows++;
      used = 0;
    }
    used += w;
  }
  return rows;
}

/** The JSON object in a model reply, which may wrap it in prose or a fence. */
function replyJson<T>(text: string): T {
  return JSON.parse(text.slice(text.indexOf("{"), text.lastIndexOf("}") + 1)) as T;
}

/** Open issues anywhere in the workspace that any of `terms` finds, most hits first. */
async function searchOpen($: EngineInterface, server: string, terms: string[]): Promise<Issue[]> {
  const found = await Promise.all(
    terms.map((query) =>
      call<{ issues: Issue[] }>($, server, "list_issues", {
        query,
        limit: SEARCH_HITS,
        fields: ["title", "statusType", "team", "description"],
      }).then(
        (r) => r.issues,
        () => [] as Issue[],
      ),
    ),
  );
  const hits = new Map<string, { issue: Issue; count: number }>();
  for (const issue of found.flat()) {
    if (CLOSED.includes(issue.statusType)) continue;
    const seen = hits.get(issue.id);
    hits.set(issue.id, { issue, count: (seen?.count ?? 0) + 1 });
  }
  return [...hits.values()]
    .sort((a, b) => b.count - a.count)
    .slice(0, CANDIDATES)
    .map((h) => h.issue);
}

/**
 * Looks for an open issue covering the draft `draftId` and offers commenting on it.
 * Runs after the form is ready, so a slow search never holds up Create; a result for a
 * draft that has since been filed or discarded is dropped.
 */
async function checkDuplicates(
  $: EngineInterface,
  server: string,
  draftId: string,
  draft: Pick<Draft, "title" | "description" | "search">,
) {
  const settle = (duplicate: Duplicate | null) =>
    update($, form, (cur) =>
      cur?.draftId === draftId ? { ...cur, duplicate, isCheckingDuplicates: false } : cur,
    );
  try {
    const terms = (draft.search ?? []).filter((t) => t.trim() !== "").slice(0, 3);
    const candidates = await searchOpen($, server, terms.length > 0 ? terms : [draft.title]);
    if (candidates.length === 0) return await settle(null);
    const reply = await $.model.complete({
      model: "sonnet",
      system: DUPLICATE_SYSTEM,
      maxTokens: 1000,
      prompt: [
        `<draft>\n${draft.title}\n\n${draft.description}\n</draft>`,
        `<candidates>\n${candidates
          .map((i) => {
            const about = oneLine(i.description ?? "").slice(0, CANDIDATE_CHARS);
            return `${i.id} [${i.team}] ${i.title}${about && `\n  ${about}`}`;
          })
          .join("\n")}\n</candidates>`,
      ].join("\n\n"),
    });
    if (!reply.isAnswered) return await settle(null);
    const v = replyJson<Verdict>(reply.text).duplicate;
    const dup = v && candidates.find((i) => i.id === v.issue);
    await settle(dup && v ? { issue: dup.id, title: dup.title, comment: v.comment } : null);
  } catch (error) {
    $.ui.log(`linear-issue: duplicate check failed: ${errorText(error)}`, { to: "debug" });
    await settle(null);
  }
}

/** Drafts from `brief` and fills the open form. */
async function fill($: EngineInterface, brief: string) {
  const fail = (error: string) => patchForm($, { phase: "failed", error });
  try {
    const server = await linearServer($);
    if (!server) return fail("Linear MCP unavailable or signed out, re-authenticate with /mcp");
    type User = { teams: { name: string; key: string }[] };
    const user = await call<User>($, server, "get_user", { query: "me" });
    const teams = user.teams.map((t) => ({ value: t.key, label: `${t.name} (${t.key})` }));
    const last = (await $.store.get("last").catch(() => undefined)) as Last | undefined;
    const fallback =
      [last?.team, FALLBACK_TEAM].find((k) => teams.some((t) => t.value === k)) ??
      teams[0]?.value ??
      "";
    const usual = PRIORITIES.find((p) => p.value === String(last?.priority ?? 4))?.label ?? "Low";
    const guess = await loadTeam($, server, fallback);

    const reply = await $.model.complete({
      model: "sonnet",
      system: SYSTEM,
      maxTokens: 4000,
      prompt: [
        brief,
        `<defaults>\nteam: ${fallback}\npriority: ${usual}\n</defaults>`,
        `<teams>\n${teams.map((t) => t.label).join("\n")}\n</teams>`,
        `<labels>\n${guess.labels.map((l) => l.label).join("\n")}\n</labels>`,
      ].join("\n\n"),
    });
    if (!reply.isAnswered) return fail(`drafting failed: ${reply.reason}`);
    const d = replyJson<Draft>(reply.text);

    const team = teams.some((t) => t.value === d.team) ? d.team : fallback;
    const options = await loadTeam($, server, team);
    const labelIds = (d.labels ?? []).flatMap((name) => {
      const l = options.labels.find((o) => o.label === name || o.label.endsWith(`/${name}`));
      return l ? [l.value] : [];
    });
    const draftId = (await read($, form))?.draftId;
    if (!draftId) return;
    await patchForm($, {
      phase: "ready",
      error: null,
      teams,
      ...options,
      team,
      title: d.title,
      description: d.description,
      priority: PRIORITIES.some((p) => p.value === String(d.priority)) ? d.priority : 0,
      state: options.todo,
      labelIds,
      project: "",
      isCheckingDuplicates: true,
    });
    void checkDuplicates($, server, draftId, d);
  } catch (error) {
    await fail(errorText(error));
  }
}

async function openPane($: EngineInterface) {
  const opened = await $.ui.open({
    id: PANE,
    title: "Linear draft",
    focus: true,
    closeOnEscape: true,
    rows: 30,
  });
  await update($, isPaneOpen, () => true);
  if (!opened.isPlaced) $.ui.toast(`The Linear draft pane can't show yet: ${opened.reason}`);
}

/**
 * Opens the draft pane for `seed` and starts drafting into it; one draft at a time.
 * Call it from the press or command hook itself: a pane opened after that hook returned
 * counts as unasked and stays hidden below 144 columns.
 */
async function start($: EngineInterface, kind: "insight" | "note", seed: string) {
  const open = await read($, form);
  if (open && open.phase !== "failed") {
    await openPane($);
    $.ui.toast("Reopened your Linear draft; Discard it to start another");
    return;
  }
  const f: Form = {
    draftId: `${await $.clock.now()}-${Math.random().toString(36).slice(2)}`,
    phase: "drafting",
    error: null,
    source: "",
    teams: [],
    statuses: [],
    labels: [],
    projects: [],
    team: "",
    title: "",
    titleRevision: 0,
    description: "",
    priority: 0,
    state: "",
    labelIds: [],
    project: "",
    duplicate: null,
    isCheckingDuplicates: false,
  };
  await update($, form, () => f);
  await openPane($);
  // Drafting outlives the hook, so it isn't awaited.
  void brief($, kind, seed)
    .then(async (b) => {
      await patchForm($, { source: b.source });
      await fill($, b.text);
    })
    .catch((error) => patchForm($, { phase: "failed", error: errorText(error) }));
}

async function switchTeam($: EngineInterface, team: string) {
  const server = await linearServer($);
  if (!server) return;
  const options = await loadTeam($, server, team).catch(() => undefined);
  if (!options) return;
  await update($, form, (cur) => {
    if (!cur) return cur;
    const keep = (ids: string[]) =>
      ids.flatMap((id) => {
        const name = cur.labels.find((l) => l.value === id)?.label;
        const same = options.labels.find((l) => l.label === name);
        return same ? [same.value] : [];
      });
    return {
      ...cur,
      team,
      ...options,
      state: options.todo,
      labelIds: keep(cur.labelIds),
      project: "",
    };
  });
}

/**
 * Writes the form to Linear (the issue, or the duplicate's comment) and echoes the result;
 * `open` then opens the filed issue in the browser.
 */
async function submit($: EngineInterface, { asComment = false, open = false } = {}) {
  const f = await read($, form);
  if (!f || f.phase !== "ready") return;
  await patchForm($, { phase: "filing", error: null });
  try {
    const server = await linearServer($);
    if (!server) throw new Error("Linear MCP unavailable or signed out, re-authenticate with /mcp");
    let echo: Filed;
    if (asComment && f.duplicate) {
      const r = await call<unknown>($, server, "save_comment", {
        issueId: f.duplicate.issue,
        body: f.duplicate.comment,
      });
      const url = /https:\/\/linear\.app\/[^"'\s)]+/.exec(JSON.stringify(r))?.[0] ?? "";
      echo = { key: f.duplicate.issue, title: `commented: ${f.duplicate.title}`, url };
    } else {
      const r = await call<{ id?: string; identifier?: string; url?: string }>(
        $,
        server,
        "save_issue",
        {
          team: f.team,
          title: f.title,
          description: f.source ? `${f.description.trimEnd()}\n\n---\n${f.source}` : f.description,
          assignee: "me",
          state: f.state,
          priority: f.priority,
          ...(f.labelIds.length > 0 && { labels: f.labelIds }),
          ...(f.project && { project: f.project }),
        },
      );
      const text = JSON.stringify(r);
      const key = r.identifier ?? r.id ?? /\b[A-Z][A-Z0-9]+-\d+\b/.exec(text)?.[0] ?? "";
      const url = r.url ?? /https:\/\/linear\.app\/[^"'\s)]+/.exec(text)?.[0] ?? "";
      echo = { key, title: f.title, url };
      await $.store.set("last", { team: f.team, priority: f.priority } satisfies Last);
    }
    await update($, filed, (list) => [...list.filter((x) => x.key !== echo.key), echo]);
    await discard($);
    if (open && echo.url) await openUrl($, echo.url);
  } catch (error) {
    await patchForm($, { phase: "ready", error: errorText(error) });
  }
}

/** Drops the draft and closes its pane. */
async function discard($: EngineInterface) {
  await update($, isDiscardArmed, () => false);
  await update($, form, () => null);
  await $.ui.close({ id: PANE });
}

async function openUrl($: EngineInterface, url: string) {
  for (const opener of ["xdg-open", "open"]) {
    try {
      if ((await $.process.run([opener, url], { timeoutMs: 5000 })).exitCode === 0) return;
    } catch {}
  }
  $.ui.toast(`Couldn't open ${url}`);
}

export const register: Register = (on) => {
  on("session.start", async ($, e, next) => {
    await $.command
      .register({
        name: "linear",
        description:
          "Draft a Linear issue from the text after it (or the recent conversation) for approval",
        argumentHint: "[what to file]",
        // Filing a thought shouldn't wait for the running turn; nothing here touches it.
        immediate: true,
      })
      .catch((error) =>
        $.ui.log(`linear-issue: /linear not registered: ${errorText(error)}`, { to: "debug" }),
      );
    return next(e);
  });

  on("command.run", { command: "linear" }, async ($, e) => {
    if (!(await hasLinear($)))
      return { text: "No Linear MCP server is configured in this session." };
    await start($, "note", e.args.trim());
    return { text: "Drafting a Linear issue in the draft pane." };
  });

  // Closing only hides the pane: the draft stays for the chip or /linear to reopen.
  on("ui.close", { id: PANE }, async ($, e, next) => {
    await update($, isPaneOpen, () => false);
    return next(e);
  });

  on("ui.focus", { requestId: PANE }, async ($, e, next) => {
    await update($, focused, () => e.element ?? null);
    return next(e);
  });

  on("ui.press", { plugin: YSK }, async (_$, e, next) => {
    if (e.element === LEARN_MORE) isExpanding = true;
    return next(e);
  });

  on("ui.render", { component: "Pane", requestId: PANE }, async ($, e) => {
    const { Box, Text, Button, Markdown } = $.ui.resolve(e);
    const f = await read($, form);
    const focus = await read($, focused);
    const width = e.props.bodyColumns;
    // Sized to the pane so the footer stays put; the description takes what is left.
    const rows = e.props.scroll.bodyRows;
    // Inline above the prompt a pane gets few rows: drop the title border, rule and source.
    const compact = rows < COMPACT_ROWS;
    const rule = compact ? null : (
      <Text dimColor wrap="truncate-end">
        {`─ ${HINTS} ${"─".repeat(Math.max(width - HINTS.length - 3, 0))}`}
      </Text>
    );
    const discardButton = (
      <Button key="discard" label="Discard" role="dismiss" onPress={() => discard($)} />
    );
    // A button draws "[ label ]", two columns from the next.
    const buttonRows = (buttons: RenderElement[]) =>
      wrappedRows(
        buttons.map((b) => (isElement(b) && b.type === "Button" ? b.props.label : "").length + 6),
        width,
      );
    // Buttons that need more than a row wrap, and the summary gives up its place to them.
    const footer = (buttons: RenderElement[], summary: string) => (
      <Box flexDirection="column">
        {rule}
        {buttonRows(buttons) > 1 ? (
          <Box flexDirection="row" flexWrap="wrap" columnGap={2}>
            {buttons}
          </Box>
        ) : (
          <Box flexDirection="row" justifyContent="space-between">
            <Box flexDirection="row" columnGap={2} flexShrink={0}>
              {buttons}
            </Box>
            <Box flexShrink={1} marginLeft={2}>
              <Text dimColor wrap="truncate-end">
                {summary}
              </Text>
            </Box>
          </Box>
        )}
      </Box>
    );
    const status = (line: RenderNode) => (
      <Box flexDirection="column" height={rows}>
        <Box flexGrow={1}>{line}</Box>
        {footer([discardButton], "Esc hides the draft")}
      </Box>
    );
    if (!f) return <Text dimColor>No Linear draft open.</Text>;
    if (f.phase === "drafting") return status(<Text dimColor>Drafting the issue…</Text>);
    if (f.phase === "failed")
      return status(<Text color="error">Linear draft failed: {f.error}</Text>);

    const set = (patch: Partial<Form>) => patchForm($, patch);
    const priority = PRIORITIES.find((p) => p.value === String(f.priority))?.label ?? "No priority";
    const statusName = f.statuses.find((s) => s.value === f.state)?.label ?? "";
    const summary = [
      f.team,
      statusName,
      priority,
      f.labelIds.length > 0 && `${f.labelIds.length} label${f.labelIds.length === 1 ? "" : "s"}`,
      f.isCheckingDuplicates && "checking for duplicates…",
    ]
      .filter(Boolean)
      .join(" · ");
    const createButton = (
      <Button
        key="create"
        label={f.phase === "filing" ? "Creating…" : "Create"}
        variant="primary"
        onPress={() => submit($)}
      />
    );
    const buttons = [
      createButton,
      <Button key="create-open" label="Create & open" onPress={() => submit($, { open: true })} />,
      f.duplicate && (
        <Button
          key="comment"
          label={`Comment on ${f.duplicate.issue}`}
          onPress={() => submit($, { asComment: true })}
        />
      ),
      discardButton,
    ].filter((b): b is RenderElement => Boolean(b));
    // No fixed height: an Input in a height-capped box stops wrapping when focused and
    // hides what is typed past its width.
    const field = (key: string, child: RenderNode, isBordered: boolean) => (
      <Box
        key={`field-${key}`}
        flexDirection="column"
        paddingX={1}
        {...(isBordered && { borderStyle: "round" })}
        {...(focus?.startsWith(key) ? { borderColor: "claude" } : { borderDimColor: true })}
      >
        {child}
      </Box>
    );

    if (e.surface === "mobile") {
      // No Input or Select here: the draft as written, to create or discard.
      return (
        <Box flexDirection="column">
          <Text weight="semibold">{f.title}</Text>
          <Text dimColor>{summary}</Text>
          <Markdown text={f.description} />
          {f.error && <Text color="error">{f.error}</Text>}
          {footer(buttons, "")}
        </Box>
      );
    }
    const { Input, Select } = $.ui.resolve(e);
    const chosen = f.labels.filter((l) => f.labelIds.includes(l.value));
    const selects: [string, string, string, Option[], (v: string) => unknown][] = [
      ["team", "Team", f.team, f.teams, (team) => switchTeam($, team)],
      ["priority", "Priority", String(f.priority), PRIORITIES, (p) => set({ priority: Number(p) })],
      ["status", "Status", f.state, f.statuses, (state) => set({ state })],
      ["project", "Project", f.project, f.projects, (project) => set({ project })],
    ];
    // Each select draws "Label: value ▾", two columns from the next.
    const selectRows = wrappedRows(
      selects.map(
        ([, label, value, options]) =>
          label.length + (options.find((o) => o.value === value)?.label.length ?? 0) + 6,
      ),
      width,
    );
    // Columns inside a bordered, padded field.
    const inner = Math.max(width - 4, 1);
    // Focused, a title that no longer fits beside the engine's "⏎ submit" hint wraps a row.
    const titleRows =
      focus?.startsWith("title") && TITLE_LABEL.length + f.title.length + HINT_WIDTH > inner
        ? 2
        : 1;
    const fixed =
      (compact ? titleRows : titleRows + 2) + // title field
      selectRows +
      (chosen.length > 0 ? 1 : 0) + // labels
      (f.duplicate ? 2 : 0) +
      1 + // space above the description
      (compact ? 0 : 1) + // source
      (f.error ? 1 : 0) +
      (compact ? 0 : 1) + // footer rule
      buttonRows(buttons);
    // Lines the description wraps to in its box, to say when the box clips it.
    const descriptionLines = f.description
      .split("\n")
      .reduce((n, line) => n + Math.max(1, Math.ceil(line.length / width)), 0);
    // A focused Select draws its option list under its row, pushing everything below it down.
    const openList = Math.min(
      selects.find(([key]) => key === focus)?.[3].length ?? 0,
      OPEN_LIST_ROWS,
    );
    let descriptionRows = Math.max(3, rows - fixed - openList);
    const isClipped = descriptionLines > descriptionRows;
    // Compact has no source row, so the clipped note takes one from the description.
    if (compact && isClipped) descriptionRows = Math.max(3, descriptionRows - 1);

    return (
      <Box flexDirection="column">
        {field(
          "title",
          // Enter empties an Input unless the hook draws a different value, so a submit
          // remounts it under a new key, keeping the text and the focus.
          <Input
            key={`title-${f.titleRevision ?? 0}`}
            label="Title"
            // Keep the default "⏎ submit": with a shorter hint the engine truncates a title just
            // over one line instead of wrapping it, hiding what is typed (Claude Code 2.1.308).
            value={f.title}
            autoFocus
            onInput={(title) => set({ title: oneLine(title) })}
            onSubmit={(title) =>
              set({ title: oneLine(title), titleRevision: (f.titleRevision ?? 0) + 1 })
            }
          />,
          !compact,
        )}
        <Box flexDirection="row" flexWrap="wrap" columnGap={2} paddingX={1}>
          {selects.map(([key, label, value, options, onSelect]) => (
            <Select
              key={key}
              label={label}
              value={value}
              options={options.slice(0, SELECT_MAX)}
              onSelect={onSelect}
            />
          ))}
        </Box>
        {chosen.length > 0 && (
          // The drafter's picks; adding is left to Linear, searching labels here worked poorly.
          <Box flexDirection="row" flexWrap="wrap" columnGap={1} paddingX={1}>
            <Text dimColor>Labels</Text>
            {chosen.map((l) => (
              <Button
                key={`label-${l.value}`}
                label={`× ${l.label}`}
                plain
                onPress={() => set({ labelIds: f.labelIds.filter((id) => id !== l.value) })}
              />
            ))}
          </Box>
        )}
        {f.duplicate && (
          <Box flexDirection="column" paddingX={1}>
            <Text color="warning" wrap="truncate-end">
              {f.duplicate.issue} ({f.duplicate.title}) may already cover this; the comment would
              add:
            </Text>
            <Text dimColor wrap="truncate-end">
              {f.duplicate.comment}
            </Text>
          </Box>
        )}
        {/* Read-only: in Claude Code 2.1.308 a focused multi-line Input collapses to one line
            once a line is wider than the field. Make it an Input again when that is fixed. */}
        {/* Unbordered: borders mark what is editable, and Markdown sizes tables to the pane's
            width, so a border's columns would break every table row. */}
        <Box flexDirection="column" marginTop={1} height={descriptionRows} overflow="hidden">
          {blocks(f.description).map((b) => {
            // Markdown sizes tables and fences to the terminal, not the pane, so those are
            // drawn here to the pane's width; Linear renders the markdown itself.
            if (b.kind === "markdown") return <Markdown text={b.lines.join("\n")} />;
            if (b.kind === "code") {
              return (
                <Box flexDirection="column" paddingLeft={2}>
                  {b.lines.map((l) => (
                    <Text dimColor wrap="truncate-end">
                      {l || " "}
                    </Text>
                  ))}
                </Box>
              );
            }
            const rows = b.lines.map(cells).filter((r) => !r.every((c) => /^:?-+:?$/.test(c)));
            const cols = Math.max(...rows.map((r) => r.length));
            const natural = Array.from({ length: cols }, (_, i) =>
              Math.max(...rows.map((r) => r[i]?.length ?? 0), 1),
            );
            const room = Math.max(width - (cols - 1) * 2, cols);
            const total = natural.reduce((a, n) => a + n, 0);
            const widths = natural.map((n) =>
              total <= room ? n : Math.max(4, Math.floor((room * n) / total)),
            );
            return (
              <Box flexDirection="column" marginY={1}>
                {rows.map((r, ri) => (
                  <Box flexDirection="row" columnGap={2}>
                    {widths.map((w, ci) => (
                      <Box width={w}>
                        <Text
                          wrap="wrap"
                          dimColor={ri > 0 && ci > 0}
                          weight={ri === 0 ? "semibold" : undefined}
                        >
                          {r[ci] ?? ""}
                        </Text>
                      </Box>
                    ))}
                  </Box>
                ))}
              </Box>
            );
          })}
        </Box>
        {(!compact || isClipped) && (
          <Box paddingX={1}>
            <Text dimColor wrap="truncate-end">
              {isClipped
                ? "Description continues; it is filed whole, edit it in Linear."
                : f.source}
            </Text>
          </Box>
        )}
        {f.error && (
          <Box paddingX={1}>
            <Text color="error">{f.error}</Text>
          </Box>
        )}
        {footer(buttons, summary)}
      </Box>
    );
  });

  on("ui.render", { component: "AbovePrompt" }, async ($, e, next) => {
    const tree = await next(e);
    if (e.props.hasSurvey) return tree;
    const { Box, Text, Button } = $.ui.resolve(e);

    const issues = await read($, filed);
    const draft = (await read($, isPaneOpen)) ? null : await read($, form);
    const isArmed = await read($, isDiscardArmed);
    const withBanner = (card: RenderNode) => {
      if (issues.length === 0 && !draft) return card as RenderElement;
      return (
        <Box flexDirection="column">
          {card}
          {draft && (
            <Box key="draft" flexDirection="row">
              <Text color="claude">✎ </Text>
              <Text wrap="truncate-end">
                Linear draft:{" "}
                {draft.phase === "drafting" ? "drafting…" : draft.title || "untitled"}{" "}
              </Text>
              <Box marginLeft={1}>
                <Button
                  key="draft-open"
                  label="Open"
                  hotkey="8"
                  plain
                  onPress={() => openPane($)}
                />
              </Box>
              <Box marginLeft={1}>
                {/* A digit in an empty prompt presses this, so a prompt starting "9" must not discard. */}
                <Button
                  key="draft-discard"
                  label={isArmed ? "Press 9 again to discard" : "Discard"}
                  hotkey="9"
                  plain
                  onPress={async () => {
                    if (await read($, isDiscardArmed)) return discard($);
                    await update($, isDiscardArmed, () => true);
                    $.clock.after(
                      DISCARD_ARM_MS,
                      () => void update($, isDiscardArmed, () => false),
                    );
                  }}
                />
              </Box>
            </Box>
          )}
          {issues.map((i) => (
            <Box key={`filed-${i.key}`} flexDirection="row">
              <Text color="success">✓ </Text>
              <Text wrap="truncate-end">
                {i.key} {i.title}{" "}
              </Text>
              {i.url !== "" && (
                <Box marginLeft={1}>
                  <Button
                    key={`open-${i.key}`}
                    label="Open"
                    plain
                    onPress={() => openUrl($, i.url)}
                  />
                </Box>
              )}
              {i.url !== "" && (
                <Box marginLeft={1}>
                  <Button
                    key={`copy-${i.key}`}
                    label="Copy link"
                    plain
                    onPress={async () => {
                      const r = await $.ui.copy({ text: i.url });
                      $.ui.toast(r.isCopied ? `Copied ${i.url}` : `Couldn't copy: ${r.reason}`);
                    }}
                  />
                </Box>
              )}
              <Box marginLeft={1}>
                <Button
                  key={`dismiss-${i.key}`}
                  label="×"
                  plain
                  onPress={() => update($, filed, (list) => list.filter((x) => x.key !== i.key))}
                />
              </Box>
            </Box>
          ))}
        </Box>
      );
    };

    const card = cardText(tree);
    if (card !== "" && card === (await read($, hidden))) return withBanner(<Box />);

    const anchor = pathTo(tree, (n) => isButton(n, ANCHOR))?.at(-1);
    if (!anchor) {
      // Past the "One moment…" spinner (no buttons), a card without the anchor means it changed.
      if (
        isExpanding &&
        hasButtons(tree) &&
        pathTo(tree, (n) => isButton(n, LEARN_MORE)) === undefined
      ) {
        isExpanding = false;
        await warnDrift($);
      }
      return withBanner(tree);
    }
    isExpanding = false;
    if (!(await hasLinear($))) return withBanner(tree);

    const style = isElement(anchor) && anchor.type === "Button" ? anchor.props : undefined;
    const taken = hotkeysIn(tree);
    const button = (
      <Button
        key="linear-issue"
        label="Linear issue"
        hotkey={HOTKEYS.find((k) => !taken.has(k))}
        plain={style?.plain}
        dimColor={style?.dimColor}
        onPress={async () => {
          await update($, hidden, () => card);
          await start($, "insight", card);
        }}
      />
    );
    return withBanner(insertButton(tree, button) ?? tree);
  });
};
