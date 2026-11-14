import type { On, ToolInfo } from "claude-code";
import { expect, mock, test } from "claude-code/testing";
import type { Engine, MockClock, Mounted, Plugin } from "claude-code/testing";

const BAND = {
  plugin: "linear-issue",
  component: "AbovePrompt",
  props: {
    hasSurvey: false,
    isWorking: false,
    maxRows: 20,
    bodyColumns: 120,
    scroll: { offset: 0, bodyRows: 20 },
    view: {},
  },
  surface: "terminal",
} as const;

// Stands in for the built-in: a collapsed card, expanded by Learn more, drawn
// as the real one is (each button in a spaced Box, dismiss last).
const YSK: Plugin = {
  name: "cc-plugin-you-should-know",
  tier: "builtin",
  register(on) {
    let view: "collapsed" | "expanded" | "gone" = "collapsed";
    on("ui.render", { component: "AbovePrompt" }, async ($, e) => {
      const { Box, Text, Button } = $.ui.resolve(e);
      const anchor = (await $.env.get("FAKE_ANCHOR")) ?? "Chat in main session";
      // A button a newer card might add, on the digit the Linear button prefers.
      const extra = await $.env.get("FAKE_EXTRA");
      const go = (next: typeof view) => () => {
        view = next;
        $.ui.invalidate("ui.render");
      };
      if (view === "gone") return <Box />;
      if (view === "collapsed") {
        return (
          <Box flexDirection="column">
            <Text>Heads up · Prompt caching makes one-off /ask questions cost more.</Text>
            <Box>
              <Button
                key="Learn more"
                label="Learn more"
                hotkey="1"
                plain
                onPress={go("expanded")}
              />
              <Button
                key="Dismiss"
                label="Dismiss"
                hotkey="0"
                plain
                role="dismiss"
                onPress={go("gone")}
              />
            </Box>
          </Box>
        );
      }
      return (
        <Box flexDirection="column">
          <Text bold>One-off /ask questions now cost more</Text>
          <Text>Saving the cache costs 1.25x, so a question with no follow-up pays 25% more.</Text>
          <Box flexDirection="row">
            <Box marginRight={2}>
              <Button key="Understood" label="Understood" hotkey="1" plain onPress={go("gone")} />
            </Box>
            <Box marginRight={2}>
              <Button key={anchor} label={anchor} hotkey="2" plain onPress={go("gone")} />
            </Box>
            {extra && (
              <Box marginRight={2}>
                <Button key={extra} label={extra} hotkey="3" plain onPress={go("gone")} />
              </Box>
            )}
            <Box marginRight={2}>
              <Button
                key="Dismiss"
                label="Dismiss"
                hotkey="0"
                plain
                role="dismiss"
                onPress={go("collapsed")}
              />
            </Box>
          </Box>
        </Box>
      );
    });
  },
};

const PANE = {
  plugin: "linear-issue",
  component: "Pane",
  requestId: "linear-draft",
  props: {
    title: "Linear draft",
    isFocused: true,
    bodyColumns: 100,
    placement: "inline",
    scroll: { offset: 0, bodyRows: 30 },
    view: {},
  },
  surface: "terminal",
} as const;

const LINEAR_TOOLS: ToolInfo[] = [
  { name: "Read", description: "", mcp: false },
  { name: "mcp__claude_ai_Linear__list_issues", description: "", mcp: true },
  { name: "mcp__claude_ai_Linear__save_issue", description: "", mcp: true },
];

const DRAFT = {
  team: "MSC",
  title: "Cap get_rate outage latency",
  description: "During an outage one call blocks ~16.5 s.",
  priority: 4,
  labels: ["Bug"],
  search: ["exchange rates"],
};

type Call = { tool: string; args: Record<string, unknown> };
type World = {
  clock: MockClock;
  toasts: string[];
  calls: Call[];
  // Drafting prompts, and duplicate-check prompts.
  prompts: string[];
  checks: string[];
  runs: string[][];
  draft: Record<string, unknown>;
  verdict: Record<string, unknown>;
  tools: ToolInfo[];
};

const usage = {
  input_tokens: 0,
  output_tokens: 0,
  cache_read_input_tokens: 0,
  cache_creation_input_tokens: 0,
};

/** Stands in for the engine beneath both plugins: tools, Linear, the model, panes and toasts. */
function world(on: On, tools: ToolInfo[] = LINEAR_TOOLS, env: Record<string, string> = {}): World {
  const w: World = {
    clock: mock.clock(on),
    toasts: [],
    calls: [],
    prompts: [],
    checks: [],
    runs: [],
    draft: DRAFT,
    verdict: { duplicate: null },
    tools,
  };
  mock.store(on);
  mock.env(on, env);
  on("tool.list", () => ({ value: w.tools }));
  on("ui.toast", (_, e) => {
    w.toasts.push(e.text);
    return { value: undefined };
  });
  on("ui.open", () => ({ value: { isPlaced: true } }));
  on("ui.close", () => ({ value: undefined }));
  on("ui.copy", () => ({ value: { isCopied: true } }));
  on("session.cwd", () => ({ value: "/repo" }));
  on("session.id", () => ({ value: "sess-1" }));
  on("session.repo", () => ({
    value: { root: "/repo", remote: "git@github.com:me/repo.git", internal: false, name: null },
  }));
  on("session.version", () => ({ value: { version: "9.9.9" } }));
  on("session.messages", () => ({
    value: [
      { role: "user", text: "make /ask take follow-ups", toolUses: [] },
      { role: "assistant", text: "Adding prompt caching to /ask.", toolUses: [] },
    ],
  }));
  on("process.run", (_, e) => {
    w.runs.push([...e.argv]);
    return {
      value: {
        exitCode: 0,
        stdout: "feat/ask\n",
        stderr: "",
        isStdoutTruncated: false,
        isStderrTruncated: false,
      },
    };
  });
  on("model.complete", (_, e) => {
    const prompt = String(e.prompt);
    const isCheck = prompt.includes("<candidates>");
    (isCheck ? w.checks : w.prompts).push(prompt);
    const answer = isCheck ? w.verdict : w.draft;
    return { value: { isAnswered: true, text: JSON.stringify(answer), usage } };
  });
  on("mcp.call", (_, e) => {
    w.calls.push({ tool: e.tool, args: e.args });
    const team = String(e.args.team ?? "");
    const answers: Record<string, unknown> = {
      get_user: {
        teams: [
          { name: "Misc", key: "MSC" },
          { name: "Webshop", key: "SHP" },
        ],
      },
      list_issues: {
        issues: [
          { id: "SHP-1", title: "Cache exchange rates", statusType: "backlog", team: "Webshop" },
          { id: "SHP-2", title: "Cache rates daily", statusType: "completed", team: "Webshop" },
        ],
      },
      list_issue_statuses: [
        { id: `${team}-backlog`, type: "backlog", name: "Backlog" },
        { id: `${team}-todo`, type: "unstarted", name: "Todo" },
      ],
      list_issue_labels: {
        // More than a Select holds, as real teams have.
        labels: [
          { id: `${team}-bug`, name: "Bug", parent: null, archivedAt: null },
          ...Array.from({ length: 70 }, (_, i) => ({
            id: `${team}-area${i}`,
            name: `area${i}`,
            parent: "Area",
            archivedAt: null,
          })),
        ],
      },
      list_projects: { projects: [{ id: `${team}-p`, name: `${team} project` }] },
      save_issue: { identifier: "MSC-900", url: "https://linear.app/x/issue/MSC-900/cap" },
      save_comment: { id: "c1", url: "https://linear.app/x/issue/SHP-1#comment-c1" },
    };
    return {
      value: {
        content: [{ type: "text", text: JSON.stringify(answers[e.tool] ?? {}) }],
        isError: false,
      },
    };
  });
  return w;
}

const RUN = {
  command: "linear",
  origin: { kind: "composer" },
  presentation: { isFullscreen: false, columns: 120 },
} as const;

async function startSession($: Engine, on: On) {
  on("command.register", () => ({ value: { command: "linear" } }));
  on("session.start", (_, e) => ({ cwd: e.cwd }));
  await $.session.start({ cwd: "/repo", surface: "terminal", isInteractive: true });
}

async function expand(band: Mounted<"terminal", "AbovePrompt">, w: World) {
  await band.press({ plugin: "cc-plugin-you-should-know", key: "Learn more" });
  await w.clock.settle();
}

const saved = (w: World, tool: string) => w.calls.find((c) => c.tool === tool)?.args;

test(
  "the button shows in the expanded card only, before Dismiss",
  { plugins: [YSK] },
  async ($, on) => {
    const w = world(on);
    const band = await $.ui.mount(BAND);
    expect(await band.find({ key: "linear-issue" })).toBeUndefined();

    await expand(band, w);
    const buttons = (await band.findAll({ type: "Button" })).map((b) => b.key);
    expect(buttons).toEqual(["Understood", "Chat in main session", "linear-issue", "Dismiss"]);
    await band.unmount();
  },
);

test("no Linear server, no button", { plugins: [YSK] }, async ($, on) => {
  const w = world(on, [{ name: "Read", description: "", mcp: false }]);
  const band = await $.ui.mount(BAND);
  await expand(band, w);
  expect(await band.find({ key: "linear-issue" })).toBeUndefined();
  expect(await band.find({ key: "Chat in main session" })).toBeDefined();
  await band.unmount();
});

test(
  "a renamed anchor leaves the card as drawn and warns once per version",
  { plugins: [YSK] },
  async ($, on) => {
    const w = world(on, LINEAR_TOOLS, { FAKE_ANCHOR: "Discuss in chat" });
    const band = await $.ui.mount(BAND);
    for (let i = 0; i < 2; i++) {
      await expand(band, w);
      const buttons = (await band.findAll({ type: "Button" })).map((b) => b.key);
      expect(buttons).toEqual(["Understood", "Discuss in chat", "Dismiss"]);
      await band.press({ plugin: "cc-plugin-you-should-know", key: "Dismiss" });
      await w.clock.settle();
    }
    await band.unmount();
    expect(w.toasts.filter((t) => t.includes("linear-issue:"))).toHaveLength(1);
  },
);

test(
  "pressing it hides the card, drafts into the pane, and Create files it and echoes the link",
  { plugins: [YSK] },
  async ($, on) => {
    const w = world(on);
    const band = await $.ui.mount(BAND);
    await expand(band, w);
    await band.press({ key: "linear-issue" });
    await w.clock.settle();
    expect(await band.find({ type: "Button" })).toBeUndefined();
    expect(w.prompts[0]).toContain("One-off /ask questions now cost more");

    const pane = await $.ui.mount(PANE);
    expect((await pane.find({ key: "title-0" }))?.props.value).toBe("Cap get_rate outage latency");
    expect((await pane.find({ key: "status" }))?.props.value).toBe("MSC-todo");
    expect(await pane.find({ key: "label-MSC-bug" })).toBeDefined();

    await pane.select({ key: "priority", value: "2" });
    await pane.input({ key: "title-0", text: "Cap outage latency", kind: "change" });
    await pane.press({ key: "create" });
    await w.clock.settle();
    expect(saved(w, "save_issue")).toEqual({
      team: "MSC",
      title: "Cap outage latency",
      description:
        "During an outage one call blocks ~16.5 s.\n\n---\nSource: `me/repo` · feat/ask · session sess-1",
      assignee: "me",
      state: "MSC-todo",
      priority: 2,
      labels: ["MSC-bug"],
    });
    await pane.unmount();

    expect((await band.find({ type: "Text", text: /MSC-900/ }))?.text).toContain(
      "Cap outage latency",
    );
    await band.press({ key: "open-MSC-900" });
    await w.clock.settle();
    expect(w.runs).toContainEqual(["xdg-open", "https://linear.app/x/issue/MSC-900/cap"]);
    await band.press({ key: "dismiss-MSC-900" });
    expect(await band.find({ key: "open-MSC-900" })).toBeUndefined();
    await band.unmount();
  },
);

test(
  "switching team reloads its statuses and keeps labels by name",
  { plugins: [YSK] },
  async ($, on) => {
    const w = world(on);
    await startSession($, on);
    await $.command.run({ ...RUN, args: "cache rates" });
    await w.clock.settle();

    const pane = await $.ui.mount(PANE);
    await pane.select({ key: "team", value: "SHP" });
    await w.clock.settle();
    expect((await pane.find({ key: "status" }))?.props.value).toBe("SHP-todo");
    expect(await pane.find({ key: "label-SHP-bug" })).toBeDefined();
    await pane.select({ key: "project", value: "SHP-p" });
    await pane.press({ key: "create" });
    await w.clock.settle();
    expect(saved(w, "save_issue")).toMatchObject({
      team: "SHP",
      state: "SHP-todo",
      project: "SHP-p",
      labels: ["SHP-bug"],
    });
    await pane.unmount();
  },
);

test("/linear drafts from the typed note without a subagent", async ($, on) => {
  const w = world(on);
  await startSession($, on);
  const { text } = await $.command.run({ ...RUN, args: " cache rates per day " });
  await w.clock.settle();
  expect(text).toContain("draft pane");
  expect(w.prompts[0]).toContain("<note>\ncache rates per day\n</note>");
  expect(w.prompts[0]).toContain("Adding prompt caching to /ask.");
});

test("an open issue the search finds can be commented on instead", async ($, on) => {
  const w = world(on);
  w.verdict = { duplicate: { issue: "SHP-1", comment: "Seen again in rates.py." } };
  await startSession($, on);
  await $.command.run({ ...RUN, args: "rates" });
  await w.clock.settle();

  const pane = await $.ui.mount(PANE);
  await pane.press({ key: "comment" });
  await w.clock.settle();
  expect(saved(w, "save_comment")).toEqual({ issueId: "SHP-1", body: "Seen again in rates.py." });
  expect(saved(w, "save_issue")).toBeUndefined();
  await pane.unmount();
});

test("/linear without a Linear server says so and drafts nothing", async ($, on) => {
  const w = world(on, [{ name: "Read", description: "", mcp: false }]);
  await startSession($, on);
  const { text } = await $.command.run({ ...RUN, args: "anything" });
  expect(text).toContain("No Linear MCP server");
  expect(w.prompts).toHaveLength(0);
});

test("/linear right after start waits for the Linear server to connect", async ($, on) => {
  const w = world(on, [
    { name: "mcp__claude_ai_Linear__authenticate", description: "", mcp: true },
  ]);
  await startSession($, on);
  await $.command.run({ ...RUN, args: "rates" });
  await w.clock.advance(2000);
  w.tools = LINEAR_TOOLS;
  await w.clock.advance(2000);

  const pane = await $.ui.mount(PANE);
  expect((await pane.find({ key: "title-0" }))?.props.value).toBe("Cap get_rate outage latency");
  await pane.unmount();
});

test("an open draft is reopened by /linear until Discard drops it", async ($, on) => {
  const w = world(on);
  await startSession($, on);
  await $.command.run({ ...RUN, args: "rates" });
  await w.clock.settle();
  await $.command.run({ ...RUN, args: "something else" });
  await w.clock.settle();
  expect(w.prompts).toHaveLength(1);

  const pane = await $.ui.mount(PANE);
  await pane.press({ key: "discard" });
  await w.clock.settle();
  await pane.unmount();
  await $.command.run({ ...RUN, args: "something else" });
  await w.clock.settle();
  expect(w.prompts).toHaveLength(2);
  expect(w.prompts[1]).toContain("something else");
});

test("a pasted multi-line title is filed as one line, without a removed label", async ($, on) => {
  const w = world(on);
  await startSession($, on);
  await $.command.run({ ...RUN, args: "rates" });
  await w.clock.settle();

  const pane = await $.ui.mount(PANE);
  await pane.input({ key: "title-0", text: "Cap outage\nlatency", kind: "change" });
  await pane.press({ key: "label-MSC-bug" });
  expect(await pane.find({ key: "label-MSC-bug" })).toBeUndefined();
  await pane.press({ key: "create" });
  await w.clock.settle();
  expect(saved(w, "save_issue")).toMatchObject({ title: "Cap outage latency" });
  expect(saved(w, "save_issue")).not.toHaveProperty("labels");
  await pane.unmount();
});

test("a description taller than its box says so and is filed whole", async ($, on) => {
  const w = world(on);
  const long = Array.from({ length: 60 }, (_, i) => `Line ${i}`).join("\n");
  w.draft = { ...DRAFT, description: long };
  await startSession($, on);
  await $.command.run({ ...RUN, args: "rates" });
  await w.clock.settle();

  const pane = await $.ui.mount(PANE);
  expect(await pane.find({ type: "Text", text: /Description continues/ })).toBeDefined();
  expect(await pane.find({ key: "create" })).toBeDefined();
  await pane.press({ key: "create" });
  await w.clock.settle();
  expect(String(saved(w, "save_issue")?.description)).toContain("Line 59");
  await pane.unmount();
});

test("the last filed team is the next draft's fallback", async ($, on) => {
  const w = world(on);
  await startSession($, on);
  await $.command.run({ ...RUN, args: "rates" });
  await w.clock.settle();
  const pane = await $.ui.mount(PANE);
  await pane.select({ key: "team", value: "SHP" });
  await w.clock.settle();
  await pane.press({ key: "create" });
  await w.clock.settle();
  await pane.unmount();

  w.draft = { ...DRAFT, team: "nope" };
  await $.command.run({ ...RUN, args: "again" });
  await w.clock.settle();
  expect(w.prompts[1]).toContain("<defaults>\nteam: SHP\npriority: Low\n</defaults>");
  const again = await $.ui.mount(PANE);
  expect((await again.find({ key: "team" }))?.props.value).toBe("SHP");
  await again.unmount();
});

test("Enter in the title keeps its text", async ($, on) => {
  const w = world(on);
  await startSession($, on);
  await $.command.run({ ...RUN, args: "rates" });
  await w.clock.settle();

  const pane = await $.ui.mount(PANE);
  await pane.input({ key: "title-0", text: "Cap outage latency", kind: "submit" });
  expect((await pane.find({ key: "title-1" }))?.props.value).toBe("Cap outage latency");
  await pane.unmount();
});

test("a closed issue is never offered as the duplicate", async ($, on) => {
  const w = world(on);
  w.verdict = { duplicate: { issue: "SHP-2", comment: "Seen again." } };
  await startSession($, on);
  await $.command.run({ ...RUN, args: "rates" });
  await w.clock.settle();

  const pane = await $.ui.mount(PANE);
  expect(await pane.find({ key: "comment" })).toBeUndefined();
  expect(await pane.find({ key: "create" })).toBeDefined();
  await pane.unmount();
});

test("Create & open files the issue and opens it", async ($, on) => {
  const w = world(on);
  await startSession($, on);
  await $.command.run({ ...RUN, args: "rates" });
  await w.clock.settle();

  const pane = await $.ui.mount(PANE);
  await pane.press({ key: "create-open" });
  await w.clock.settle();
  expect(saved(w, "save_issue")).toMatchObject({ title: "Cap get_rate outage latency" });
  expect(w.runs).toContainEqual(["xdg-open", "https://linear.app/x/issue/MSC-900/cap"]);
  await pane.unmount();
});

test(
  "the button takes the next free digit when the card uses 3",
  { plugins: [YSK] },
  async ($, on) => {
    const w = world(on, LINEAR_TOOLS, { FAKE_EXTRA: "Show me" });
    const band = await $.ui.mount(BAND);
    await expand(band, w);
    expect((await band.find({ key: "Show me" }))?.props.hotkey).toBe("3");
    expect((await band.find({ key: "linear-issue" }))?.props.hotkey).toBe("4");
    await band.unmount();
  },
);

test("a Linear server added later shows the button", { plugins: [YSK] }, async ($, on) => {
  const w = world(on, [{ name: "Read", description: "", mcp: false }]);
  const band = await $.ui.mount(BAND);
  await expand(band, w);
  expect(await band.find({ key: "linear-issue" })).toBeUndefined();

  w.tools = LINEAR_TOOLS;
  await w.clock.advance(10_000);
  await band.press({ plugin: "cc-plugin-you-should-know", key: "Dismiss" });
  await expand(band, w);
  expect(await band.find({ key: "linear-issue" })).toBeDefined();
  await band.unmount();
});
