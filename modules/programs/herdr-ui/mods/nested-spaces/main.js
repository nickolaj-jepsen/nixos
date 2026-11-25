// The sidebar: a New space button, then every host's repos. A repo is its name over a rail;
// each checkout on it, main or worktree, is a card with its branch, git counters, PR
// and an open-in menu, its agents inside. Rows keep their place whatever their status;
// ctrl-shift-j shows the agent that has needed you longest.

import { View, div, svg, image } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { monitorRow, clean } from "./monitor-row.js";
import { agentName } from "./agent-name.js";
import {
  agents,
  terminals,
  focused,
  setAgentOrder,
  spaces,
  machines,
  panes,
  run,
  openOverlay,
  exec,
  hc,
  theme,
  watchFolder,
  settings,
  window,
  layout,
  nextCommand,
  shared,
  setShared,
} from "herdr";

const ICON = (name) => `mods/workspace-chrome/${name}.svg`;

function find(node, id) {
  if (node?.id === id) return node;
  for (const child of node?.children ?? []) {
    const found = find(child, id);
    if (found) return found;
  }
  return null;
}

// The sidebar's rail goes by its width, not a flag: the header's toggle narrows it.
const narrow = () => (find(layout(), "sidebar")?.size?.px ?? Infinity) < 160;

// Where a space is now: its first terminal's live folder, else where it was made.
// `ps`: panes(), read once by the caller (each read copies every pane).
function place(s, ps) {
  const tabs = new Set((s.tabs ?? []).map((c) => c.id));
  return ps.find((p) => tabs.has(p.tab) && p.cwd)?.cwd || s.folder;
}
const where = (s, ps) => JSON.stringify([s.machine ?? null, place(s, ps)]);
const base = (path) => (path ?? "").replace(/\/+$/, "").split("/").pop();
// Changes made outside Herdr (an editor's save, a commit in another app): looked
// for this often, in repos the list shows, while the window is in front.
const FALLBACK = 10000;
// A space waits this long for its git before it shows, so a worktree appears on its
// repo's rail instead of jumping there.
const SETTLE_IN = 1500;

const STATES = ["blocked", "done", "working", "idle"];
const statusOf = (s) => (s === "error" ? "blocked" : STATES.includes(s) ? s : "idle");
// Hosts get a muted color each, for their tile and their repos' rails: enough to tell
// them apart at a glance, quiet next to status colors.
const HUES = ["#7F9A96", "#A48E9A", "#8E96AB", "#A3967E", "#8FA27F"];

// bg tasks and Pi's child monitors are helpers: a chip on the agent that started them.
const isBg = (k) =>
  (k?.report?.app ?? k?.app ?? k?.agent) === "bg" || k?.labels?.["bg-herdr"] !== undefined;
const isMonitor = (k) => k?.labels?.["fireproof.pi-agent-monitor"] === "true";
const isHelper = (k) => isBg(k) || isMonitor(k);
// A bg task's monitor stays open after the task ends. Finished (exit 0: done,
// stopped or already seen: idle), it has nothing left to show; failures (error) stay.
const finishedBg = (k) => isBg(k) && (k.status === "done" || k.status === "idle");
const failedBg = (k) => isBg(k) && k.status === "error";
// How long a failed bg task stays listed, from when this sidebar first saw it fail.
const FAILED_FOR = 60000;

const PR_EVERY = 120000;
const NO_PR = new Set(["main", "master", "(detached)"]);

// Sorts `list` in place by where each item's key is in `order`; unlisted items keep
// their order after the listed ones.
function ranked(list, order, key) {
  if (!order?.length) return list;
  const at = new Map(order.map((k, i) => [k, i]));
  const rank = (x) => at.get(key(x)) ?? order.length;
  const index = new Map(list.map((x, i) => [x, i]));
  return list.sort((a, b) => rank(a) - rank(b) || index.get(a) - index.get(b));
}

function ago(ms) {
  const m = Math.floor(ms / 60000);
  if (m < 1) return "now";
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  return h < 24 ? `${h}h` : `${Math.floor(h / 24)}d`;
}

const gitTip = (g) =>
  g?.dirty === true
    ? "Uncommitted changes (including untracked files)"
    : g?.dirty === false
      ? "Working tree clean"
      : "Git status unavailable";

// Agents per state, most urgent first, as colored dots and counts.
function summary(t, counts) {
  const present = STATES.filter((s) => s !== "idle" && counts[s]);
  return h_flex()
    .flex_none()
    .gap(7)
    .items_center()
    .text_size(10.5)
    .font_normal()
    .tooltip(
      STATES.filter((s) => counts[s])
        .map((s) => `${counts[s]} ${s}`)
        .join(", ") || "No agents",
    )
    .children(
      present.map((s) =>
        h_flex()
          .gap(3)
          .items_center()
          .text_color(t.muted)
          .child(div().size(6).rounded(3).bg(t[s]))
          .child(String(counts[s])),
      ),
    );
}

// A checkout's diff against HEAD, as +added −removed.
function lineBits(g, t) {
  const lines = g?.lines;
  return h_flex()
    .flex_none()
    .gap(4)
    .items_center()
    .text_size(10.5)
    .font_normal()
    .when(lines?.added > 0, (el) => el.child(div().text_color(t.ansi2).child(`+${lines.added}`)))
    .when(lines?.removed > 0, (el) =>
      el.child(div().text_color(t.ansi1).child(`\u2212${lines.removed}`)),
    );
}

// Its commits ahead of and behind upstream, beside the branch they belong to.
function commitBits(g, t) {
  return h_flex()
    .flex_none()
    .gap(3)
    .items_center()
    .text_size(10.5)
    .font_semibold()
    .when(g?.ahead > 0, (el) =>
      el.child(
        div().text_color(t.ansi2).tooltip("Commits ahead of upstream").child(`\u2191${g.ahead}`),
      ),
    )
    .when(g?.behind > 0, (el) =>
      el.child(
        div().text_color(t.ansi1).tooltip("Commits behind upstream").child(`\u2193${g.behind}`),
      ),
    );
}

function prChip(pr, t) {
  const state =
    pr.state === "MERGED" ? "merged" : pr.failing ? "failing" : pr.draft ? "draft" : "open";
  const color = { merged: t.ansi5, failing: t.ansi9, draft: t.dim, open: t.ansi2 }[state];
  return div()
    .id(`pr-${pr.url}`)
    .flex_none()
    .px(5)
    .rounded(4)
    .bg(color + "22")
    .text_size(10.5)
    .font_semibold()
    .text_color(color)
    .cursor_pointer()
    .tooltip(`#${pr.number} · ${state}\n${pr.title}`)
    .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
    .on_click((_e, cx) => {
      cx.stop_propagation();
      cx.open_url(pr.url);
    })
    .child(`#${pr.number}`);
}

function mark(t, status, size) {
  const color = t[status] ?? t.dim;
  if (status === "working")
    return svg(ICON("spinner"))
      .size(size + 4)
      .spin(900)
      .text_color(color);
  return status === "idle"
    ? div()
        .size(size)
        .rounded(size / 2)
        .border(1)
        .border_color(color)
    : div()
        .size(size)
        .rounded(size / 2)
        .bg(color);
}

function pic(t, a, size) {
  if (isBg(a))
    return svg(ICON("terminal"))
      .size(size - 1)
      .text_color(t.dim);
  const program = a.program;
  if (program?.icon)
    return (program.tint ? svg(program.icon).text_color(t.muted) : image(program.icon)).size(size);
  return svg(ICON("terminal")).size(size).text_color(t.dim);
}

export default class Spaces extends View {
  init(_props, cx) {
    this.git = {}; // where() -> { top, name, branch, ahead, behind, lines, dirty, repo, linked }, null: not a repo
    this.checked = {}; // where() -> when it was last looked at
    this.unsure = new Set(); // where()s git couldn't answer for (a machine away)
    this.pending = new Set(); // where()s to look at next
    this.busy = {}; // pane -> an agent working or a program in front of its shell
    this.ready = {}; // machine -> its layout was readable at the last look
    this.at = {}; // space -> its where() at the last look
    this.watching = new Set(); // local repos' git folders
    this.seen = Object.fromEntries(spaces().map((s) => [s.id, 0])); // space -> first seen
    this.machines = [];
    this.reconnecting = JSON.parse(localStorage.getItem("machines.reconnecting") ?? "{}");
    for (const state of Object.values(this.reconnecting)) state.busy = false;
    this.folded = new Set(JSON.parse(localStorage.getItem("machines.folded") ?? "[]"));
    this.foldedRepos = new Set(JSON.parse(localStorage.getItem("repos.folded") ?? "[]"));
    // Repos with no agents fold by themselves; these were opened anyway.
    this.openedRepos = new Set(JSON.parse(localStorage.getItem("repos.opened") ?? "[]"));
    this.failedAt = JSON.parse(localStorage.getItem("bg.failedAt") ?? "{}"); // address -> ms
    this.expired = new Set(); // failed bg tasks past FAILED_FOR
    // address -> { s, at }: the status an agent is in and since when (Herdr doesn't say).
    this.since = JSON.parse(localStorage.getItem("status.since") ?? "{}");
    this.prs = {}; // checkout key -> PR or null
    this.prChecked = {};
    this.prQueue = [];
    this.visible = []; // checkouts drawn last, for PR lookups
    this.open = new Set(); // chips, shells and settled lines shown open
    this.hover = null; // the repo under the pointer
    // Drag order: repo ids, and per repo its checkout keys; new ones go after.
    this.repoOrder = JSON.parse(localStorage.getItem("order.repos") ?? "[]");
    this.checkoutOrder = JSON.parse(localStorage.getItem("order.checkouts") ?? "{}");
    this.drag = null; // { kind: "repo" | "checkout", scope, id, over }
    this.needs = [];
    this.tick = Date.now();
    this.refreshMachines(cx);
    cx.timer.every(15000, (cx) => this.refreshMachines(cx));
    // Refresh only when the refs could have changed (see `due`).
    cx.timer.every(250, (cx) => this.checkNew(cx));
    cx.spawn(async (cx) => {
      for (;;) {
        const command = await nextCommand();
        if (command === "next-needs") this.nextNeeds();
        cx.notify();
      }
    });
  }

  checkNew(cx) {
    const now = Date.now();
    const sp = spaces();
    let waiting = false;
    for (const s of sp) {
      this.seen[s.id] ??= now;
      if (now - this.seen[s.id] < SETTLE_IN + 250) waiting = true;
    }
    const due = this.due(now, sp, panes());
    if (due.size) this.refreshGit(due, cx);
    this.trackFailures(now, cx);
    this.trackSince(now);
    this.duePrs(now, cx);
    // Ages on blocked and finished rows count up by the minute.
    if (waiting || now - this.tick > 30000) {
      this.tick = now;
      cx.notify();
    }
  }

  // bg doesn't say when a task ended, so time a failure from when it was first seen here.
  trackFailures(now, cx) {
    const all = terminals();
    if (!all.length) return; // not loaded yet: keep the clocks
    const failed = new Set(
      all.filter((k) => k.state === "live" && failedBg(k)).map((k) => k.address),
    );
    let changed = false;
    for (const address of Object.keys(this.failedAt))
      if (!failed.has(address)) {
        delete this.failedAt[address];
        changed = true;
      }
    for (const address of failed)
      if (!(address in this.failedAt)) {
        this.failedAt[address] = now;
        changed = true;
      }
    if (changed) localStorage.setItem("bg.failedAt", JSON.stringify(this.failedAt));
    const expired = [...failed].filter((address) => now - this.failedAt[address] >= FAILED_FOR);
    if (expired.length !== this.expired.size || expired.some((a) => !this.expired.has(a))) {
      this.expired = new Set(expired);
      cx.notify();
    }
  }

  // Herdr gives an agent's status, not since when: start a clock at each change.
  trackSince(now) {
    const list = agents();
    if (!list.length) return; // not loaded yet: keep the clocks
    let changed = false;
    const live = new Set();
    for (const a of list) {
      live.add(a.address);
      const s = statusOf(a.status);
      if (this.since[a.address]?.s !== s) {
        this.since[a.address] = { s, at: now };
        changed = true;
      }
    }
    for (const address of Object.keys(this.since))
      if (!live.has(address)) {
        delete this.since[address];
        changed = true;
      }
    if (changed) localStorage.setItem("status.since", JSON.stringify(this.since));
  }

  // Places whose git could have changed: new ones (a new space, a cd), where a
  // command or an agent's turn just ended (a checkout, a commit, edits), those on
  // a machine that is back, and repos in view whose fallback is due.
  due(now, sp, ps) {
    const at = {};
    for (const s of sp) at[s.id] = where(s, ps);
    const keys = new Set(Object.values(at).filter((k) => JSON.parse(k)[1]));
    const spaceByTab = new Map(sp.flatMap((s) => s.tabs.map((tab) => [tab.id, s])));
    for (const p of ps) {
      const s = spaceByTab.get(p.tab);
      if (s && p.cwd) keys.add(JSON.stringify([s.machine ?? null, p.cwd]));
    }
    const due = new Set([...keys].filter((k) => !(k in this.git)));
    for (const [id, k] of Object.entries(at))
      if (this.at[id] && this.at[id] !== k && keys.has(k)) due.add(k);
    this.at = at;
    const busy = {};
    for (const p of ps) {
      const s = spaceByTab.get(p.tab);
      if (!p.terminal || !s) continue;
      busy[p.pane] = p.status === "working" || !(p.program?.shell || p.program?.agent);
      if (this.busy[p.pane] && !busy[p.pane]) {
        const key = p.cwd ? JSON.stringify([s.machine ?? null, p.cwd]) : at[s.id];
        this.sameRepo(key, keys).forEach((k) => due.add(k));
      }
    }
    this.busy = busy;
    for (const m of machines()) {
      const ready = m.layout === "ready";
      if (ready && this.ready[m.name] === false)
        for (const k of keys) if (JSON.parse(k)[0] === m.name) due.add(k);
      this.ready[m.name] = ready;
    }
    if (window().active) {
      for (const k of keys) {
        const asks = this.git[k] || this.unsure.has(k);
        if (asks && !this.folded.has(JSON.parse(k)[0]) && now - (this.checked[k] ?? 0) > FALLBACK)
          due.add(k);
      }
    }
    return due;
  }

  // `key` and the other places in its repo (a commit there moves their ahead/behind).
  sameRepo(key, keys) {
    const repo = this.git[key]?.repo;
    return [key, ...(repo ? [...keys].filter((k) => this.git[k]?.repo === repo) : [])];
  }

  refreshMachines(cx) {
    cx.spawn(async (cx) => {
      try {
        const r = await hc(["machine", "ls", "--json"]);
        if (r.code === 0)
          this.machines = (JSON.parse(r.stdout).machines ?? []).filter((m) => !m.temporary);
      } catch {}
      cx.notify();
    });
  }

  rebuilt(machine) {
    return (
      machine?.state === "unreachable" &&
      /^a different core answers there \("[^"]+"\)$/.test(machine.why ?? "")
    );
  }

  reconnect(machine, cx) {
    const name = machine.name;
    if (this.reconnecting[name]?.busy) return;
    const state = (this.reconnecting[name] ??= { machine, removed: false });
    state.busy = true;
    state.error = null;
    localStorage.setItem("machines.reconnecting", JSON.stringify(this.reconnecting));
    cx.notify();
    cx.spawn(async (cx) => {
      try {
        const ask = async (args) => {
          const r = await hc([...args, "--json"]);
          if (r.code !== 0) {
            let error;
            try {
              error = JSON.parse(r.stdout || r.stderr).error?.message;
            } catch {}
            throw new Error(error || r.stderr || r.stdout || "Couldn't connect.");
          }
        };
        if (!state.removed) {
          await ask(["machine", "rm", name]);
          state.removed = true;
          localStorage.setItem("machines.reconnecting", JSON.stringify(this.reconnecting));
        }
        const args = ["machine", "add"];
        if (machine.via) args.push("--via", machine.target);
        else args.push(machine.target);
        args.push("--name", name);
        if (machine.session) args.push("--session", machine.session);
        if (machine.temporary) args.push("--temp");
        await ask(args);
        this.folded.delete(name);
        localStorage.setItem("machines.folded", JSON.stringify([...this.folded]));
        delete this.reconnecting[name];
      } catch (e) {
        state.error = String(e.message ?? e);
        state.busy = false;
      }
      localStorage.setItem("machines.reconnecting", JSON.stringify(this.reconnecting));
      this.refreshMachines(cx);
      cx.notify();
    });
  }

  // One look at a time, each place once however often it was asked for meanwhile.
  refreshGit(keys, cx) {
    for (const k of keys) this.pending.add(k);
    if (this.refreshing) return;
    this.refreshing = true;
    cx.spawn(async (cx) => {
      while (this.pending.size) {
        const keys = [...this.pending];
        this.pending.clear();
        await Promise.all(keys.map((key) => this.check(key, cx)));
      }
      const used = new Set(
        Object.values(this.git)
          .filter(Boolean)
          .map((g) => JSON.parse(g.repo))
          .filter(([on]) => !on)
          .map(([, repo]) => repo),
      );
      for (const repo of this.watching) if (!used.has(repo)) this.watching.delete(repo);
      this.refreshing = false;
      cx.notify();
    });
  }

  // One place's git: branch, ahead/behind, diff, its repo.
  async check(key, cx) {
    const [on, cwd] = JSON.parse(key);
    this.checked[key] = Date.now();
    this.unsure.delete(key);
    try {
      // Keep path reads separate: a folder name may itself contain a newline.
      const [r, common] = await Promise.all([
        exec("git", ["rev-parse", "--path-format=absolute", "--show-toplevel"], { cwd, on }),
        exec("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], { cwd, on }),
      ]);
      if (r.code !== 0 || common.code !== 0) {
        // Only git's own "no" is remembered as no repo; anything else is asked again.
        if (!/not a git repository/i.test(r.code !== 0 ? r.stderr : common.stderr))
          this.unsure.add(key);
        this.git[key] = null;
        return;
      }
      // The repo's own .git folder names it; a worktree's top differs from it.
      const top = r.stdout.replace(/\n$/, ""),
        repo = common.stdout.replace(/\n$/, "");
      const [branch, counts, status, diff] = await Promise.all([
        exec("git", ["symbolic-ref", "-q", "HEAD"], { cwd, on }),
        exec("git", ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], { cwd, on }),
        exec("git", ["--no-optional-locks", "status", "--porcelain", "--untracked-files=normal"], {
          cwd,
          on,
        }),
        exec("git", ["diff", "--no-ext-diff", "--no-textconv", "--numstat", "HEAD", "--"], {
          cwd,
          on,
        }),
      ]);
      const name = repo.endsWith("/.git")
        ? base(repo.slice(0, -5))
        : base(repo).replace(/\.git$/, "");
      const [ahead, behind] =
        counts.code === 0 ? counts.stdout.trim().split(/\s+/).map(Number) : [0, 0];
      // HEAD compares the combined staged + unstaged result, without double-counting.
      // An unborn branch has no HEAD: all tracked content is still in its index.
      const diffResult =
        diff.code === 0
          ? diff
          : await exec(
              "git",
              ["diff", "--no-ext-diff", "--no-textconv", "--numstat", "--cached", "--"],
              { cwd, on },
            );
      const lines =
        diffResult.code === 0
          ? diffResult.stdout.split("\n").reduce(
              (total, line) => {
                const [added, removed] = line.split("\t");
                if (/^\d+$/.test(added)) total.added += Number(added);
                if (/^\d+$/.test(removed)) total.removed += Number(removed);
                return total;
              },
              { added: 0, removed: 0 },
            )
          : null;
      this.git[key] = {
        top,
        name,
        lines,
        dirty: status.code === 0 ? Boolean(status.stdout.trim()) : null,
        branch:
          branch.code === 0 ? branch.stdout.trim().replace(/^refs\/heads\//, "") : "(detached)",
        ahead,
        behind,
        repo: JSON.stringify([on, repo]),
        linked: repo !== `${top}/.git`,
      };
      if (!on) this.watch(repo, cx);
    } catch {
      // Couldn't ask (the machine is away): keep what it showed, look again later.
      this.git[key] ??= null;
      this.unsure.add(key);
    }
  }

  watch(repo, cx) {
    if (this.watching.has(repo)) return;
    this.watching.add(repo);
    cx.spawn(async (cx) => {
      try {
        while (this.watching.has(repo)) {
          await watchFolder(repo);
          const mine = JSON.stringify([null, repo]);
          if (this.watching.has(repo))
            this.refreshGit(
              Object.keys(this.git).filter((k) => this.git[k]?.repo === mine),
              cx,
            );
        }
      } catch {
        this.watching.delete(repo);
      }
    });
  }

  // Each drawn checkout's PR, through gh on its machine, every PR_EVERY while in front.
  duePrs(now, cx) {
    if (!window().active) return;
    for (const c of this.visible)
      if (
        !this.prQueue.some((q) => q.key === c.key) &&
        now - (this.prChecked[c.key] ?? 0) > PR_EVERY
      ) {
        this.prChecked[c.key] = now;
        this.prQueue.push(c);
      }
    if (!this.prQueue.length || this.prBusy) return;
    this.prBusy = true;
    cx.spawn(async (cx) => {
      while (this.prQueue.length) {
        const c = this.prQueue.shift();
        try {
          const r = await exec(
            "gh",
            ["pr", "view", c.branch, "--json", "number,state,isDraft,title,url,statusCheckRollup"],
            { cwd: c.top, on: c.on, timeout: 20000 },
          );
          if (r.code !== 0) this.prs[c.key] = null;
          else {
            const p = JSON.parse(r.stdout);
            const bad = ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED"];
            this.prs[c.key] =
              p.state === "CLOSED"
                ? null
                : {
                    number: p.number,
                    state: p.state,
                    draft: p.isDraft,
                    title: clean(p.title),
                    url: p.url,
                    failing: (p.statusCheckRollup ?? []).some((k) =>
                      bad.includes(k.conclusion || k.state),
                    ),
                  };
          }
        } catch {} // no gh there, or the machine is away: keep what it showed
        cx.notify();
      }
      this.prBusy = false;
    });
  }

  nextNeeds() {
    const f = focused();
    const next = this.needs.find((n) => n.a.address !== f?.agent && n.a.address !== f?.terminal);
    const pick = next ?? this.needs[0];
    if (pick) run("agent.focus", { terminal: pick.a.address });
  }

  toggle(set, storageKey, key) {
    set.has(key) ? set.delete(key) : set.add(key);
    if (storageKey) localStorage.setItem(storageKey, JSON.stringify([...set]));
  }

  // Drag to reorder: repos within their host, checkouts within their repo. A press on
  // the handle (a repo's name line, a card's branch line) picks it up; the line shows
  // where it lands.
  dragSource(el, kind, scope, id) {
    return el.on_mouse_down("left", () => {
      this.drag = { kind, scope, id, over: null };
    });
  }

  dropTarget(el, kind, scope, id, ids, t) {
    const d = this.drag?.kind === kind && this.drag.scope === scope ? this.drag : null;
    return el
      .when(Boolean(d) && d.id === id && Boolean(d.over) && d.over !== id, (el) => el.opacity(0.5))
      .on_mouse_move((_e, cx) => {
        const d = this.drag;
        if (d?.kind !== kind || d.scope !== scope || d.over === id) return;
        if (!d.over && id === d.id) return; // still on itself: a click so far
        d.over = id;
        cx.notify();
      })
      .on_mouse_up("left", (_e, cx) => {
        const d = this.drag;
        if (d?.kind !== kind || d.scope !== scope) return;
        this.drag = null;
        if (d.over === id && d.id !== id) this.reorder(kind, scope, ids, d.id, id);
        cx.notify();
      });
  }

  // The drop line, in the list itself rather than over it, so nothing covers it.
  marked(kind, scope, ids, els, t) {
    const d = this.drag?.kind === kind && this.drag.scope === scope ? this.drag : null;
    if (!d?.over || d.over === d.id) return els;
    const from = ids.indexOf(d.id),
      at = ids.indexOf(d.over);
    if (from < 0 || at < 0) return els;
    const out = [...els];
    out.splice(from < at ? at + 1 : at, 0, div().h(2).mx(2).flex_none().rounded(1).bg(t.accent));
    return out;
  }

  reorder(kind, scope, ids, from, to) {
    const next = ids.filter((k) => k !== from);
    const at = next.indexOf(to) + (ids.indexOf(from) < ids.indexOf(to) ? 1 : 0);
    next.splice(at, 0, from);
    if (kind === "repo") {
      const shown = new Set(next);
      this.repoOrder = [...next, ...this.repoOrder.filter((k) => !shown.has(k))];
      localStorage.setItem("order.repos", JSON.stringify(this.repoOrder));
    } else {
      this.checkoutOrder[scope] = next;
      localStorage.setItem("order.checkouts", JSON.stringify(this.checkoutOrder));
    }
  }

  hovering(id) {
    return (hovered, cx) => {
      if (hovered) this.hover = id;
      else if (this.hover === id) this.hover = null;
      cx.notify();
    };
  }

  // Everything drawn, in order: hosts, their repos, each repo's checkouts, each
  // checkout's agent trees, shells and settled agents; and who needs you.
  model(now) {
    const sp = spaces(),
      ps = panes(),
      list = agents(),
      all = terminals();
    const listed = new Map(list.map((a) => [a.address, a]));
    const term = new Map(all.map((k) => [k.address, k]));
    const tabs = new Map(sp.flatMap((s) => s.tabs.map((tab) => [tab.id, tab])));
    const children = new Map();
    for (const k of all) {
      if (k.state !== "live" || !k.parent || finishedBg(k) || this.expired.has(k.address)) continue;
      if (!children.has(k.parent)) children.set(k.parent, []);
      children.get(k.parent).push(k);
    }
    const nested = new Set();
    const markNested = (address, seen = new Set()) => {
      if (seen.has(address)) return;
      seen.add(address);
      for (const k of children.get(address) ?? []) {
        nested.add(k.address);
        markNested(k.address, seen);
      }
    };
    list.forEach((a) => markNested(a.address));

    const repos = new Map();
    const placeOf = new Map(); // address -> { repo, checkout }
    const visited = new Set();
    const tree = (a, depth) => {
      visited.add(a.address);
      const node = {
        a: { ...a, labels: term.get(a.address)?.labels ?? a.labels },
        depth,
        helpers: [],
        kids: [],
      };
      for (const k of children.get(a.address) ?? []) {
        if (visited.has(k.address)) continue;
        const kid = { ...k, ...(listed.get(k.address) ?? {}), labels: k.labels };
        if (isHelper(kid)) {
          visited.add(k.address);
          node.helpers.push(kid);
        } else node.kids.push(tree(kid, depth + 1));
      }
      return node;
    };
    const slot = (s, cwd) => {
      const g = this.git[JSON.stringify([s.machine ?? null, cwd])] ?? null;
      const id = g?.repo ?? JSON.stringify([s.machine ?? null, cwd || s.id]);
      if (!repos.has(id))
        repos.set(id, {
          id,
          name: g?.name ?? (base(cwd) || s.name),
          machine: s.machine ?? null,
          target: s.id,
          checkouts: new Map(),
        });
      const repo = repos.get(id);
      const key = g?.top ?? cwd ?? "";
      if (!repo.checkouts.has(key))
        repo.checkouts.set(key, {
          key: JSON.stringify([s.machine ?? null, key]),
          top: key,
          git: g,
          space: s.id,
          rows: [],
          shells: [],
          settled: [],
        });
      return { repo, checkout: repo.checkouts.get(key) };
    };
    let waiting = false;
    for (const s of sp) {
      const home = place(s, ps);
      if (!(where(s, ps) in this.git) && now - (this.seen[s.id] ?? 0) < SETTLE_IN) {
        waiting = true;
        continue;
      }
      const ids = new Set(s.tabs.map((tab) => tab.id));
      for (const a of list) {
        if (a.space !== s.id || nested.has(a.address) || visited.has(a.address)) continue;
        const cwd = ps.find((p) => p.terminal === a.address)?.cwd || home;
        const at = slot(s, cwd);
        if (tabs.get(a.tab)?.settled) at.checkout.settled.push(a);
        else {
          const node = tree(a, 1);
          at.checkout.rows.push(node);
          const walk = (n) => {
            placeOf.set(n.a.address, at);
            n.kids.forEach(walk);
          };
          walk(node);
        }
        placeOf.set(a.address, at);
      }
      for (const p of ps) {
        if (!ids.has(p.tab) || !p.terminal || listed.has(p.terminal)) continue;
        slot(s, p.cwd || home).checkout.shells.push({ ...p, space: s.id });
      }
    }
    this.waiting = waiting;

    const hosts = new Map();
    for (const repo of repos.values()) {
      const checkouts = [...repo.checkouts.values()];
      // As dragged, else the main checkout first, then worktrees as they first appear.
      checkouts.sort((a, b) => Number(Boolean(a.git?.linked)) - Number(Boolean(b.git?.linked)));
      ranked(checkouts, this.checkoutOrder[repo.id], (c) => c.key);
      repo.checkouts = checkouts;
      const counts = {};
      const count = (n) => {
        const s = statusOf(n.a.status);
        counts[s] = (counts[s] ?? 0) + 1;
        n.kids.forEach(count);
      };
      for (const c of checkouts) c.rows.forEach(count);
      repo.counts = counts;
      repo.agents = checkouts.reduce((sum, c) => sum + c.rows.length, 0);
      if (!hosts.has(repo.machine)) hosts.set(repo.machine, []);
      hosts.get(repo.machine).push(repo);
    }
    for (const list of hosts.values()) ranked(list, this.repoOrder, (r) => r.id);

    const needs = list
      .filter((a) => {
        const s = statusOf(a.status);
        const k = term.get(a.address) ?? a;
        return (
          (s === "blocked" || s === "done") &&
          !isHelper(k) &&
          !isHelper(a) &&
          !tabs.get(a.tab)?.settled
        );
      })
      .map((a) => ({
        a: { ...a, labels: term.get(a.address)?.labels },
        s: statusOf(a.status),
        at: this.since[a.address]?.at ?? now,
        place: placeOf.get(a.address),
      }))
      .sort((x, y) => (x.s === y.s ? x.at - y.at : x.s === "blocked" ? -1 : 1));
    this.needs = needs;
    return { hosts, needs };
  }

  // Each repo's last time open, for New space to offer, newest first: stamped when it
  // opens and again when it closes.
  recordRecent(m, now) {
    const open = new Set();
    for (const repos of m.hosts.values())
      for (const r of repos) {
        const dir = r.checkouts.find((c) => c.git)?.git.repo;
        if (!dir) continue;
        const common = JSON.parse(dir)[1];
        if (common.endsWith("/.git")) open.add(JSON.stringify([r.machine, common.slice(0, -5)]));
      }
    const key = [...open].sort().join("\n");
    if (key === this.openKey || !spaces().length) return;
    const before = new Set(this.openKey ? this.openKey.split("\n") : []);
    this.openKey = key;
    const list = (shared("repos.recent") ?? []).filter((r) => r && r.folder);
    const byKey = new Map(list.map((r) => [JSON.stringify([r.machine ?? null, r.folder]), r]));
    for (const k of new Set([...open, ...before])) {
      if (!k) continue;
      const [machine, folder] = JSON.parse(k);
      byKey.set(k, { machine, folder, at: now, open: open.has(k) });
    }
    for (const [k, r] of byKey) if (!open.has(k) && r.open) byKey.set(k, { ...r, open: false });
    const next = [...byKey.values()].sort((a, b) => b.at - a.at).slice(0, 60);
    setShared("repos.recent", next);
  }

  render() {
    const t = theme();
    const now = Date.now();
    const m = this.model(now);
    this.recordRecent(m, now);
    const names = [
      ...new Set([
        ...m.hosts.keys(),
        ...this.machines.map((k) => k.name),
        ...Object.keys(this.reconnecting),
      ]),
    ]
      .filter(Boolean)
      .sort();
    const hostList = [null, ...names];
    const hue = (name) => HUES[name === null ? 0 : 1 + (names.indexOf(name) % (HUES.length - 1))];
    const visible = [];
    const order = [];
    const body = narrow()
      ? this.rail(m, hostList, hue, t, order)
      : this.full(m, hostList, hue, t, now, visible, order);
    this.visible = visible;
    setAgentOrder(order);
    return body;
  }

  full(m, hostList, hue, t, now, visible, order) {
    return v_flex()
      .size_full()
      .min_h(0)
      .gap(8)
      .text_size(13)
      .child(
        v_flex()
          .id("sidebar-scroll")
          .flex_1()
          .min_h(0)
          .gap(14)
          .overflow_y_scrollbar()
          .on_mouse_up("left", (_e, cx) => {
            if (!this.drag) return;
            this.drag = null;
            cx.notify();
          })
          .on_hover((hovered, cx) => {
            if (hovered || !this.drag) return;
            this.drag = null;
            cx.notify();
          })
          .child(this.newSpace(t))
          .children(
            hostList.map((name) =>
              this.host(name, m.hosts.get(name) ?? [], hue(name), t, now, visible, order),
            ),
          ),
      )
      .child(this.footer(t, false));
  }

  openNewSpace() {
    openOverlay({
      mod: "new-space",
      kind: "popup",
      width: 320,
      height: 420,
      props: {
        machines: this.machines.filter((k) => k.state === "connected").map((k) => k.name),
      },
    });
  }

  newSpace(t) {
    return h_flex()
      .id("new-space")
      .h(32)
      .flex_none()
      .px(10)
      .gap(8)
      .rounded(8)
      .border(1)
      .border_color(t.selected)
      .bg(t.background)
      .items_center()
      .text_size(12.5)
      .font_medium()
      .text_color(t.foreground)
      .cursor_pointer()
      .hover((el) => el.bg(t.hover))
      .tooltip("New space: a recent repo, a project or home, on any host")
      .on_click(() => this.openNewSpace())
      .child(svg(ICON("plus")).size(14).text_color(t.muted))
      .child("New space")
      .child(div().flex_1())
      .child(svg(ICON("chevron-down")).size(11).text_color(t.dim));
  }

  host(name, repos, hue, t, now, visible, order) {
    const folded = this.folded.has(name);
    const repair = this.reconnecting[name];
    const machine = this.machines.find((k) => k.name === name) ?? repair?.machine;
    const connected = !name || machine?.state === "connected";
    const rebuilt = Boolean(name) && (this.rebuilt(machine) || Boolean(repair));
    const login = machine?.state === "needs_login" ? `hc machine login ${name}` : null;
    const state = (machine?.state ?? "asleep").replace(/_/g, " ");
    const label = name ?? "This computer";
    const key = name ?? "local";
    const loading = machines().find((k) => k.name === name)?.layout === "loading";
    const counts = {};
    for (const r of repos)
      for (const [s, n] of Object.entries(r.counts)) counts[s] = (counts[s] ?? 0) + n;
    const header = h_flex()
      .id(`host-${key}`)
      .h(30)
      .flex_none()
      .px(4)
      .gap(8)
      .items_center()
      .rounded(7)
      .text_color(t.foreground)
      .cursor_pointer()
      .hover((h) => h.bg(t.selected))
      .on_click((_e, cx) => {
        this.toggle(this.folded, "machines.folded", name);
        cx.notify();
      })
      .child(
        h_flex()
          .size(22)
          .flex_none()
          .rounded(6)
          .bg(hue + "2E")
          .items_center()
          .justify_center()
          .child(
            svg(ICON(name ? "server" : "monitor"))
              .size(13)
              .text_color(hue),
          ),
      )
      .child(div().flex_shrink(1).min_w(0).truncate().text_size(13.5).font_semibold().child(label))
      .child(div().flex_1())
      .when(!connected && !rebuilt, (el) =>
        el.child(div().flex_none().text_size(11).text_color(t.dim).child(state)),
      )
      .when(rebuilt, (el) =>
        el.child(
          div()
            .id(`host-connect-${key}`)
            .flex_none()
            .max_w(140)
            .truncate()
            .text_size(11)
            .text_color(repair?.error ? t.blocked : t.muted)
            .hover((s) => s.text_color(t.foreground))
            .tooltip(
              repair?.error ||
                "This machine was rebuilt or replaced. Click to connect to the new one.",
            )
            .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
            .on_click((_e, cx) => {
              cx.stop_propagation();
              this.reconnect(machine, cx);
            })
            .child(repair?.busy ? "Connecting…" : repair?.error || "Connect"),
        ),
      )
      .child(summary(t, counts))
      .child(
        svg(ICON(folded ? "chevron-right" : "chevron-down"))
          .size(11)
          .flex_none()
          .text_color(t.dim),
      );
    const guidance = login
      ? v_flex()
          .px(6)
          .gap(3)
          .child(div().text_size(11).text_color(t.blocked).child("needs a login: run"))
          .child(
            h_flex()
              .gap(5)
              .items_center()
              .child(
                div().flex_1().min_w(0).truncate().text_size(11).text_color(t.muted).child(login),
              )
              .child(
                div()
                  .id(`host-login-copy-${key}`)
                  .flex_none()
                  .px(5)
                  .py(2)
                  .rounded(4)
                  .text_size(11)
                  .bg(t.raised)
                  .cursor_pointer()
                  .hover((s) => s.bg(t.hover))
                  .on_click((_e, cx) => {
                    cx.write_to_clipboard(login);
                    this.copiedLogin = login;
                    cx.notify();
                  })
                  .child(this.copiedLogin === login ? "Copied" : "Copy"),
              ),
          )
      : null;
    const ids = repos.map((r) => r.id);
    return v_flex()
      .id(`host-box-${key}`)
      .flex_none()
      .gap(6)
      .child(header)
      .when(Boolean(guidance), (el) => el.child(guidance))
      .when(!folded, (el) =>
        el
          .children(
            this.marked(
              "repo",
              name ?? "",
              ids,
              repos.map((r) => this.repo(r, hue, t, now, visible, order, ids)),
              t,
            ),
          )
          .when(!repos.length && loading, (el) =>
            el.child(div().px(8).h(24).text_size(12).text_color(t.dim).child("Loading…")),
          ),
      );
  }

  repo(r, hue, t, now, visible, order, ids) {
    const folded = this.foldedRepos.has(r.id) || (!r.agents && !this.openedRepos.has(r.id));
    const hovered = this.hover === `repo-${r.id}`;
    const shells = r.checkouts.reduce((n, c) => n + c.shells.length, 0);
    const settled = r.checkouts.reduce((n, c) => n + c.settled.length, 0);
    const main = r.checkouts[0];
    // The primary checkout, where wt runs: the folder above the shared .git.
    const gitDir = r.checkouts.find((c) => c.git)?.git.repo;
    const common = gitDir ? JSON.parse(gitDir)[1] : "";
    const mainFolder = common.endsWith("/.git") ? common.slice(0, -5) : main?.top;
    const scope = r.machine ?? "";
    const header = h_flex()
      .id(`repo-${r.id}`)
      .h(26)
      .flex_none()
      .pl(4)
      .pr(4)
      .gap(6)
      .items_center()
      .rounded(6)
      .cursor_pointer()
      .hover((el) => el.bg(t.selected))
      .on_hover(this.hovering(`repo-${r.id}`))
      .tooltip(main?.top || r.name)
      .on_click((_e, cx) => {
        if (folded) {
          this.foldedRepos.delete(r.id);
          this.openedRepos.add(r.id);
        } else {
          this.foldedRepos.add(r.id);
          this.openedRepos.delete(r.id);
        }
        localStorage.setItem("repos.folded", JSON.stringify([...this.foldedRepos]));
        localStorage.setItem("repos.opened", JSON.stringify([...this.openedRepos]));
        cx.notify();
      })
      .child(svg(ICON("folder")).size(13).flex_none().text_color(t.dim))
      .child(
        div()
          .flex_shrink(1)
          .min_w(0)
          .truncate()
          .text_size(13)
          .font_semibold()
          .text_color(r.agents ? t.foreground : t.dim)
          .child(r.name),
      )
      .child(div().flex_1())
      .when(folded && r.agents > 0, (el) => el.child(summary(t, r.counts)))
      .when(folded && !r.agents, (el) =>
        el.child(
          div()
            .flex_none()
            .text_size(11)
            .text_color(t.dim)
            .child(
              [
                shells && `${shells} shell${shells === 1 ? "" : "s"}`,
                settled && `${settled} settled`,
              ]
                .filter(Boolean)
                .join(" · "),
            ),
        ),
      )
      .when(Boolean(gitDir), (el) =>
        el.child(
          div()
            .id(`repo-from-${r.id}`)
            .size(18)
            .flex_none()
            .flex()
            .items_center()
            .justify_center()
            .rounded(4)
            .bg(t.selected)
            .text_color(t.muted)
            .opacity(hovered ? 1 : 0)
            .hover((b) => b.text_color(t.foreground))
            .tooltip("Open a worktree, branch or PR")
            .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
            .on_click((_e, cx) => {
              cx.stop_propagation();
              openOverlay({
                mod: "open-from",
                kind: "popup",
                width: 300,
                height: 380,
                props: { machine: r.machine, folder: mainFolder, repo: r.name },
              });
            })
            .child(svg(ICON("git-branch")).size(11)),
        ),
      )
      .child(
        div()
          .id(`repo-add-${r.id}`)
          .size(18)
          .flex_none()
          .flex()
          .items_center()
          .justify_center()
          .rounded(4)
          .bg(t.selected)
          .text_color(t.muted)
          .opacity(hovered ? 1 : 0)
          .hover((b) => b.text_color(t.foreground))
          .tooltip("Open agent or shell")
          .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
          .on_click((_e, cx) => {
            cx.stop_propagation();
            openOverlay({
              mod: "repo-agent-menu",
              kind: "popup",
              width: 280,
              height: 320,
              props: { space: r.target, folder: main?.top, repo: r.name },
            });
          })
          .child(svg(ICON("plus")).size(11)),
      );
    const handle = this.dragSource(header, "repo", scope, r.id);
    if (folded) return this.dropTarget(handle, "repo", scope, r.id, ids, t);
    const keys = r.checkouts.map((c) => c.key);
    return this.dropTarget(v_flex(), "repo", scope, r.id, ids, t)
      .id(`repo-box-${r.id}`)
      .flex_none()
      .gap(2)
      .child(handle)
      .child(
        v_flex()
          .ml(5)
          .pl(5)
          .gap(4)
          .border_l(2)
          .border_color(hue + "73")
          .children(
            this.marked(
              "checkout",
              r.id,
              keys,
              r.checkouts.map((c) => this.card(r, c, t, now, visible, order, keys)),
              t,
            ),
          ),
      );
  }

  card(r, c, t, now, visible, order, keys) {
    const g = c.git;
    const id = `card-${c.key}`;
    const pr = g ? this.prs[c.key] : null;
    if (g && !NO_PR.has(g.branch))
      visible.push({ key: c.key, on: r.machine, top: g.top, branch: g.branch });
    const folder = g?.linked && base(g.top) !== g.branch ? base(g.top) : "";
    const line = h_flex()
      .id(`line-${c.key}`)
      .h(24)
      .flex_none()
      .pl(4)
      .pr(2)
      .gap(6)
      .items_center()
      .tooltip(
        g
          ? `${g.branch} · ${g.linked ? g.top : `${r.name} (main checkout)`}\n${gitTip(g)}\nLine counts compare tracked files against HEAD, including staged and unstaged changes.`
          : c.top || r.name,
      )
      .child(
        svg(ICON(g ? "git-branch" : "folder"))
          .size(11)
          .flex_none()
          .text_color(t.dim),
      )
      .child(
        div()
          .flex_shrink(1)
          .min_w(0)
          .truncate()
          .text_size(12)
          .font_semibold()
          .text_color(t.foreground)
          .child(g ? g.branch : c.top.replace(/^\/home\/[^/]+|^\/Users\/[^/]+/, "~") || r.name),
      )
      .when(Boolean(folder), (el) =>
        el.child(
          div().flex_shrink(4).min_w(0).truncate().text_size(11).text_color(t.dim).child(folder),
        ),
      )
      .when(Boolean(g) && (g.ahead > 0 || g.behind > 0), (el) => el.child(commitBits(g, t)))
      .child(div().flex_1())
      .when(Boolean(g), (el) => el.child(lineBits(g, t)))
      .when(Boolean(pr), (el) => el.child(prChip(pr, t)))
      .child(
        div()
          .id(`open-${c.key}`)
          .size(20)
          .flex_none()
          .flex()
          .items_center()
          .justify_center()
          .rounded(5)
          .text_color(t.dim)
          .hover((b) => b.bg(t.selected).text_color(t.foreground))
          .tooltip("Open in…")
          .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
          .on_click((_e, cx) => {
            cx.stop_propagation();
            const machine = this.machines.find((k) => k.name === r.machine);
            openOverlay({
              mod: "open-in",
              kind: "popup",
              width: 230,
              height: 230,
              props: {
                machine: r.machine,
                host: machine?.host ?? machine?.target ?? r.machine,
                folder: c.top,
                branch: g?.branch ?? null,
                space: c.space,
                pr: pr ? { number: pr.number, url: pr.url } : null,
              },
            });
          })
          .child(svg("mods/nested-spaces/open.svg").size(11)),
      );
    const rows = [];
    const add = (n) => {
      order.push(n.a.address);
      rows.push(this.agentRow(n, t, now));
      if (n.helpers.length && this.open.has(`chip-${n.a.address}`))
        for (const k of n.helpers) rows.push(this.helperRow(k, n.depth + 1, t));
      n.kids.forEach(add);
    };
    c.rows.forEach(add);
    const extra = (kind, count, label, icon, items) => {
      const key = `${kind}-${c.key}`;
      const open = this.open.has(key);
      return [
        h_flex()
          .id(key)
          .h(22)
          .flex_none()
          .pl(6)
          .pr(6)
          .gap(8)
          .items_center()
          .rounded(6)
          .text_size(11)
          .text_color(t.dim)
          .cursor_pointer()
          .hover((el) => el.bg(t.hover).text_color(t.muted))
          .on_click((_e, cx) => {
            this.toggle(this.open, null, key);
            cx.notify();
          })
          .child(
            h_flex()
              .w(14)
              .flex_none()
              .justify_center()
              .child(svg(ICON(icon)).size(11)),
          )
          .child(`${count} ${label}`)
          .child(div().flex_1())
          .child(svg(ICON(open ? "chevron-down" : "chevron-right")).size(10)),
        ...(open ? items() : []),
      ];
    };
    return this.dropTarget(v_flex(), "checkout", r.id, c.key, keys, t)
      .id(id)
      .flex_none()
      .px(4)
      .pt(3)
      .pb(4)
      .gap(1)
      .rounded(8)
      .bg(t.background)
      .child(this.dragSource(line, "checkout", r.id, c.key))
      .children(rows)
      .when(c.shells.length > 0, (el) => el.children(c.shells.map((p) => this.shellRow(p, t))))
      .when(c.settled.length > 0, (el) =>
        el.children(
          extra("settled", c.settled.length, "settled", "check", () =>
            c.settled.map((a) =>
              this.agentRow({ a, depth: 1, helpers: [], kids: [], settled: true }, t, now),
            ),
          ),
        ),
      );
  }

  agentRow(n, t, now) {
    const { a, depth, helpers } = n;
    const on = focused()?.terminal === a.address || focused()?.agent === a.address;
    const monitor = monitorRow(a, a);
    const status = statusOf(a.status);
    const tone = monitor?.tone ?? status;
    const sub = depth > 1;
    const runner = a.program?.name || a.app || "Agent";
    const name = monitor?.name ?? (agentName(a) || runner);
    const label =
      monitor?.label ??
      { blocked: "Needs you", done: "Finished", working: "Working", idle: "Idle" }[status];
    const since = this.since[a.address];
    const showAge = !n.settled && (status === "blocked" || status === "done") && since;
    const failed = helpers.filter(
      (k) => failedBg(k) || k.labels?.["fireproof.pi-agent-state"] === "failed",
    );
    const running = helpers.some(
      (k) => k.status === "working" || k.labels?.["fireproof.pi-agent-state"] === "working",
    );
    const bgs = helpers.filter(isBg).length;
    const mons = helpers.length - bgs;
    const chipKey = `chip-${a.address}`;
    return h_flex()
      .id(`agent-${a.address}`)
      .h(sub ? 24 : 28)
      .flex_none()
      .pl(sub ? 4 + (depth - 1) * 14 : 4)
      .pr(6)
      .gap(8)
      .items_center()
      .rounded(6)
      .when(on, (el) => el.bg(t.selected))
      .when(!on && status === "blocked", (el) => el.bg(t.blocked + "1A"))
      .hover((el) => el.bg(on ? t.selected : t.hover))
      .cursor_pointer()
      .tooltip(monitor?.tooltip ?? `${[...new Set([runner, name])].join(" · ")} · ${label}`)
      .on_click(() => run(monitor ? "terminal.peek" : "agent.focus", { terminal: a.address }))
      .when(Boolean(a.pane), (el) =>
        el.on_mouse_down("right", () =>
          openOverlay({
            mod: "menu",
            kind: "popup",
            width: 220,
            height: 260,
            props: { tab: "pane", target: { pane: a.pane, terminal: a.address } },
          }),
        ),
      )
      .child(
        div()
          .flex_none()
          .tooltip(runner)
          .child(pic(t, a, sub ? 12 : 14)),
      )
      .child(
        div()
          .flex_1()
          .min_w(0)
          .truncate()
          .text_size(sub || n.settled ? 11.5 : 12.5)
          .when(on, (el) => el.font_medium())
          .text_color(sub || n.settled ? t.muted : t.foreground)
          .child(name),
      )
      .when(helpers.length > 0, (el) =>
        el.child(
          h_flex()
            .id(chipKey)
            .flex_none()
            .h(16)
            .px(6)
            .gap(4)
            .items_center()
            .rounded(8)
            .bg(failed.length ? t.ansi9 + "1F" : t.selected)
            .text_size(10)
            .text_color(failed.length ? t.ansi9 : t.dim)
            .tooltip(
              helpers
                .map((k) => monitorRow(k, k)?.name ?? (clean(k.title) || k.address))
                .join("\n"),
            )
            .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
            .on_click((_e, cx) => {
              cx.stop_propagation();
              this.toggle(this.open, null, chipKey);
              cx.notify();
            })
            .when(running, (el) => el.child(svg(ICON("spinner")).size(9).spin(900)))
            .child(
              [
                bgs && `${bgs} bg`,
                mons && `${mons} ${mons === 1 ? "agent" : "agents"}`,
                failed.length && `${failed.length} failed`,
              ]
                .filter(Boolean)
                .join(" · "),
            ),
        ),
      )
      .when(Boolean(showAge), (el) =>
        el.child(
          div()
            .flex_none()
            .text_size(10.5)
            .text_color(status === "blocked" ? t.blocked : t.dim)
            .child(ago(now - since.at)),
        ),
      )
      .child(
        h_flex()
          .flex_none()
          .w(14)
          .justify_center()
          .when(sub && tone !== "blocked", (m) => m.opacity(0.55))
          .tooltip(label ?? "")
          .child(mark(t, tone, sub ? 6 : 7)),
      );
  }

  // A bg task or monitor, shown when its parent's chip is open: a command, so monospace.
  helperRow(k, depth, t) {
    const monitor = monitorRow(k, k);
    const status = monitor?.tone ?? statusOf(k.status);
    return h_flex()
      .id(`helper-${k.address}`)
      .h(22)
      .flex_none()
      .pl(4 + (depth - 1) * 14)
      .pr(6)
      .gap(8)
      .items_center()
      .rounded(6)
      .hover((el) => el.bg(t.hover))
      .cursor_pointer()
      .tooltip(monitor?.tooltip ?? (clean(k.title) || k.address))
      .on_click(() => run("terminal.peek", { terminal: k.address }))
      .child(svg(ICON("terminal")).size(11).flex_none().text_color(t.dim))
      .child(
        div()
          .flex_1()
          .min_w(0)
          .truncate()
          .text_size(11)
          .font_family(settings().font_family ?? "JetBrains Mono")
          .text_color(t.dim)
          .child(monitor?.name ?? (clean(k.title) || k.address)),
      )
      .child(
        h_flex()
          .flex_none()
          .w(14)
          .justify_center()
          .when(status !== "blocked", (m) => m.opacity(0.55))
          .child(mark(t, status, 5)),
      );
  }

  shellRow(p, t) {
    const on = focused()?.terminal === p.terminal;
    return h_flex()
      .id(`shell-${p.terminal}`)
      .h(24)
      .flex_none()
      .pl(4)
      .pr(4)
      .gap(8)
      .items_center()
      .rounded(6)
      .when(on, (el) => el.bg(t.selected))
      .hover((el) => el.bg(on ? t.selected : t.hover))
      .cursor_pointer()
      .tooltip(p.cwd ?? "")
      .on_click(() => run("pane.focus", { terminal: p.terminal }))
      .on_mouse_down("right", () =>
        openOverlay({
          mod: "menu",
          kind: "popup",
          width: 220,
          height: 260,
          props: { tab: "pane", target: { pane: p.pane, terminal: p.terminal } },
        }),
      )
      .child(
        div()
          .flex_none()
          .child(pic(t, p, 12)),
      )
      .child(
        div()
          .flex_1()
          .min_w(0)
          .truncate()
          .text_size(11.5)
          .text_color(t.muted)
          .child(clean(p.title) || p.program?.name || "Shell"),
      )
      .child(
        div()
          .id(`shell-close-${p.terminal}`)
          .size(18)
          .flex()
          .items_center()
          .justify_center()
          .rounded(4)
          .text_color(t.dim)
          .hover((b) => b.bg(t.selected).text_color(t.foreground))
          .tooltip("Close")
          .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
          .on_click((_e, cx) => {
            cx.stop_propagation();
            run("pane.close", { pane: p.pane });
          })
          .child(svg(ICON("x")).size(10)),
      );
  }

  // The narrow sidebar: a cell per agent under each host's tile, a dot for its state.
  rail(m, hostList, hue, t, order) {
    const cell = (a, sub) => {
      const on = focused()?.terminal === a.address || focused()?.agent === a.address;
      const status = statusOf(a.status);
      return h_flex()
        .id(`rail-${a.address}`)
        .relative()
        .w(32)
        .h(sub ? 24 : 28)
        .flex_none()
        .rounded(6)
        .justify_center()
        .items_center()
        .when(on, (el) => el.bg(t.selected))
        .when(!on, (el) => el.hover((s) => s.bg(t.hover)))
        .tooltip(agentName(a) || a.program?.name || a.address)
        .on_click(() => run("agent.focus", { terminal: a.address }))
        .child(pic(t, a, sub ? 11 : 14))
        .child(
          div()
            .absolute()
            .right(3)
            .bottom(3)
            .size(6)
            .rounded(3)
            .bg(t[status] ?? t.dim),
        );
    };
    const cells = [];
    for (const name of hostList) {
      const repos = m.hosts.get(name) ?? [];
      if (!repos.length) continue;
      cells.push(
        h_flex()
          .size(22)
          .mt(6)
          .flex_none()
          .rounded(6)
          .bg(hue(name) + "2E")
          .items_center()
          .justify_center()
          .tooltip(name ?? "This computer")
          .child(
            svg(ICON(name ? "server" : "monitor"))
              .size(12)
              .text_color(hue(name)),
          ),
      );
      const add = (n) => {
        order.push(n.a.address);
        cells.push(cell(n.a, n.depth > 1));
        n.kids.forEach(add);
      };
      for (const r of repos) for (const c of r.checkouts) c.rows.forEach(add);
    }
    return v_flex()
      .size_full()
      .min_h(0)
      .gap(8)
      .items_center()
      .child(
        div()
          .id("rail-new-space")
          .size(30)
          .flex_none()
          .flex()
          .items_center()
          .justify_center()
          .rounded(7)
          .border(1)
          .border_color(t.selected)
          .bg(t.background)
          .text_color(t.muted)
          .hover((s) => s.text_color(t.foreground))
          .tooltip("New space")
          .on_click(() => this.openNewSpace())
          .child(svg(ICON("plus")).size(14)),
      )
      .child(
        v_flex()
          .id("rail-scroll")
          .flex_1()
          .min_h(0)
          .gap(2)
          .items_center()
          .overflow_y_scrollbar()
          .children(cells),
      )
      .child(this.footer(t, true));
  }

  footer(t, collapsed) {
    return (collapsed ? v_flex() : h_flex())
      .flex_none()
      .h(collapsed ? 76 : 52)
      .p(collapsed ? 4 : 10)
      .gap(8)
      .rounded(10)
      .bg(t.background)
      .border(1)
      .border_color(t.border)
      .children(
        [
          {
            id: "sidebar-settings",
            icon: "settings",
            label: "Settings",
            action: () => run("app.settings"),
          },
          {
            id: "sidebar-add-machine",
            icon: "plus",
            label: "Add machine",
            action: () => run("mod.open", { name: "machine-add" }),
          },
        ].map((item) =>
          h_flex()
            .id(item.id)
            .h(32)
            .flex_none()
            .px(collapsed ? 0 : 6)
            .gap(8)
            .items_center()
            .rounded(6)
            .when(collapsed, (el) => el.justify_center())
            .text_size(12)
            .text_color(t.muted)
            .hover((el) => el.bg(t.hover).text_color(t.foreground))
            .cursor_pointer()
            .tooltip(item.label)
            .on_click(item.action)
            .child(svg(ICON(item.icon)).size(14).flex_none())
            .when(!collapsed, (el) => el.child(item.label)),
        ),
      );
  }
}
