// Workspace spaces: stable colored avatars, worktrees under their checkout,
// grouped by machine when more than one is known. After a space's name, the repo
// its first terminal is in now, only where unusual: branch, ahead/behind. Agents nest below their space. Click to
// switch, right-click for its menu, drag to reorder.

import { View, div, svg, image } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { agents, terminals, focused, setAgentOrder, spaces, machines, panes, run, openOverlay, exec, hc, theme, shared, setShared, watchFolder, window, layout } from "herdr";

function find(node, id) {
  if (node?.id === id) return node;
  for (const child of node?.children ?? []) {
    const found = find(child, id);
    if (found) return found;
  }
  return null;
}

// The sidebar's rail goes by its width, not a flag: dragging its edge narrows it too.
const narrow = () => (find(layout(), "sidebar")?.size?.px ?? Infinity) < 160;

// Where a space is now: its first terminal's live folder, else where it was made.
// `ps`: panes(), read once by the caller (each read copies every pane).
function place(s, ps) {
  const tabs = new Set((s.tabs ?? []).map((c) => c.id));
  return ps.find((p) => tabs.has(p.tab) && p.cwd)?.cwd || s.folder;
}
const rowHeight = ({ tree }) => (tree ? 28 : 30);
const RAIL_CELL = 32;
const railCell = (el) => h_flex().flex_none().justify_center().child(el);
const where = (s, ps) => JSON.stringify([s.machine ?? null, place(s, ps)]);
const base = (path) => path.replace(/\/+$/, "").split("/").pop();
// Changes made outside Herdr (an editor's save, a commit in another app): looked
// for this often, in repos the list shows, while the window is in front.
const FALLBACK = 10000;

// What a stored color name looks like on an avatar (the same in every mod
// that draws space avatars): one strong color per hue, light and dark alike.
const MARK = { ansi6: "#22a99a", ansi3: "#e3814f", ansi4: "#5b8def", ansi5: "#8b7cf6", ansi2: "#3fae6a", ansi1: "#d9649a" };

// A space speaks up only when something in it needs you.
export function glyph(status) {
  return status === "blocked" || status === "done" ? "●" : "·";
}

export function tone(t, status) {
  return t[status] ?? t.unknown;
}

export default class Spaces extends View {
  init(_props, cx) {
    this.git = {}; // where() -> { name, branch, ahead, behind, repo, linked }, null: not a repo
    this.checked = {}; // where() -> when it was last looked at
    this.unsure = new Set(); // where()s git couldn't answer for (a machine away)
    this.pending = new Set(); // where()s to look at next
    this.busy = {}; // pane -> an agent working or a program in front of its shell
    this.ready = {}; // machine -> its layout was readable at the last look
    this.at = {}; // space -> its where() at the last look
    this.watching = new Set(); // local repos' git folders
    // Spaces made while this runs wait (at most a moment) for their git, so a
    // worktree appears under its repo instead of jumping there.
    this.shown = new Set(spaces().map((s) => s.id));
    this.born = {};
    this.pressed = null;
    this.over = null;
    this.machines = [];
    this.reconnecting = JSON.parse(localStorage.getItem("machines.reconnecting") ?? "{}");
    for (const state of Object.values(this.reconnecting)) state.busy = false;
    this.folded = new Set(JSON.parse(localStorage.getItem("machines.folded") ?? "[]"));
    this.refreshMachines(cx);
    cx.timer.every(15000, cx => this.refreshMachines(cx));
    // Refresh only when the refs could have changed (see `due`).
    cx.timer.every(250, (cx) => this.checkNew(cx));
  }

  checkNew(cx) {
    const now = Date.now();
    const sp = spaces();
    for (const s of sp) if (!this.shown.has(s.id)) this.born[s.id] ??= now;
    const due = this.due(now, sp, panes());
    if (due.size) this.refreshGit(due, cx);
    if (sp.some((s) => !this.shown.has(s.id)) || this.orderingDue(now)) cx.notify();
  }

  // Places whose git could have changed: new ones (a new space, a cd), where a
  // command or an agent's turn just ended (a checkout, a commit, edits), those on
  // a machine that is back, and repos in view whose fallback is due.
  due(now, sp, ps) {
    // Moved there: what it knew of that place may be old.
    const at = {};
    for (const s of sp) at[s.id] = where(s, ps);
    const keys = new Set(Object.values(at).filter((k) => JSON.parse(k)[1]));
    const spaceByTab = new Map(sp.flatMap(s => s.tabs.map(tab => [tab.id, s])));
    for (const p of ps) {
      const s = spaceByTab.get(p.tab);
      if (s && p.cwd) keys.add(JSON.stringify([s.machine ?? null, p.cwd]));
    }
    const due = new Set([...keys].filter((k) => !(k in this.git)));
    for (const [id, k] of Object.entries(at)) if (this.at[id] && this.at[id] !== k && keys.has(k)) due.add(k);
    this.at = at;
    const spaceOf = {};
    for (const s of sp) for (const t of s.tabs ?? []) spaceOf[t.id] = s;
    const busy = {};
    for (const p of ps) {
      if (!p.terminal || !spaceOf[p.tab]) continue;
      busy[p.pane] = p.status === "working" || !(p.program?.shell || p.program?.agent);
      if (this.busy[p.pane] && !busy[p.pane]) this.sameRepo(at[spaceOf[p.tab].id], keys).forEach((k) => due.add(k));
    }
    this.busy = busy;
    for (const m of machines()) {
      const ready = m.layout === "ready";
      if (ready && this.ready[m.name] === false) for (const k of keys) if (JSON.parse(k)[0] === m.name) due.add(k);
      this.ready[m.name] = ready;
    }
    if (window().active) {
      for (const k of keys) {
        const asks = this.git[k] || this.unsure.has(k);
        if (asks && !this.folded.has(JSON.parse(k)[0]) && now - (this.checked[k] ?? 0) > FALLBACK) due.add(k);
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
    cx.spawn(async cx => {
      try { const r = await hc(["machine", "ls", "--json"]); if (r.code === 0) this.machines = (JSON.parse(r.stdout).machines ?? []).filter((m) => !m.temporary); } catch {}
      cx.notify();
    });
  }

  rebuilt(machine) {
    return machine?.state === "unreachable" && /^a different core answers there \("[^"]+"\)$/.test(machine.why ?? "");
  }

  reconnect(machine, cx) {
    const name = machine.name;
    if (this.reconnecting[name]?.busy) return;
    const state = this.reconnecting[name] ??= { machine, removed: false };
    state.busy = true;
    state.error = null;
    localStorage.setItem("machines.reconnecting", JSON.stringify(this.reconnecting));
    cx.notify();
    cx.spawn(async cx => {
      try {
        const ask = async args => {
          const r = await hc([...args, "--json"]);
          if (r.code !== 0) {
            let error;
            try { error = JSON.parse(r.stdout || r.stderr).error?.message; } catch {}
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
      const used = new Set(Object.values(this.git).filter(Boolean).map((g) => JSON.parse(g.repo)).filter(([on]) => !on).map(([, repo]) => repo));
      for (const repo of this.watching) if (!used.has(repo)) this.watching.delete(repo);
      this.refreshing = false;
      cx.notify();
    });
  }

  // One place's git: branch, ahead/behind, its repo.
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
        if (!/not a git repository/i.test(r.code !== 0 ? r.stderr : common.stderr)) this.unsure.add(key);
        this.git[key] = null;
        return;
      }
      // The repo's own .git folder names it; a worktree's top differs from it.
      const top = r.stdout.replace(/\n$/, ""), repo = common.stdout.replace(/\n$/, "");
      const [branch, counts, status, diff] = await Promise.all([
        exec("git", ["symbolic-ref", "-q", "HEAD"], { cwd, on }),
        exec("git", ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], { cwd, on }),
        exec("git", ["--no-optional-locks", "status", "--porcelain", "--untracked-files=normal"], { cwd, on }),
        exec("git", ["diff", "--no-ext-diff", "--no-textconv", "--numstat", "HEAD", "--"], { cwd, on }),
      ]);
      const name = repo.endsWith("/.git") ? base(repo.slice(0, -5)) : base(repo).replace(/\.git$/, "");
      const [ahead, behind] = counts.code === 0 ? counts.stdout.trim().split(/\s+/).map(Number) : [0, 0];
      // HEAD compares the combined staged + unstaged result, without double-counting.
      // An unborn branch has no HEAD: all tracked content is still in its index.
      const diffResult = diff.code === 0 ? diff : await exec("git", ["diff", "--no-ext-diff", "--no-textconv", "--numstat", "--cached", "--"], { cwd, on });
      const lines = diffResult.code === 0 ? diffResult.stdout.split("\n").reduce((total, line) => {
        const [added, removed] = line.split("\t");
        if (/^\d+$/.test(added)) total.added += Number(added);
        if (/^\d+$/.test(removed)) total.removed += Number(removed);
        return total;
      }, { added: 0, removed: 0 }) : null;
      const info = { top, name, lines, dirty: status.code === 0 ? Boolean(status.stdout.trim()) : null, branch: branch.code === 0 ? branch.stdout.trim().replace(/^refs\/heads\//, "") : "(detached)", ahead, behind, repo: JSON.stringify([on, repo]), linked: repo !== `${top}/.git` };
      this.git[key] = info;
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
          if (this.watching.has(repo)) this.refreshGit(Object.keys(this.git).filter((k) => this.git[k]?.repo === mine), cx);
        }
      } catch { this.watching.delete(repo); }
    });
  }

  menu(w) {
    // A popup is as tall as its items; height is only the most.
    openOverlay({ mod: "menu", kind: "popup", width: 200, height: 260, props: { tab: "space", target: { id: w.id } } });
  }

  orderingDue(now) {
    return this.ordering && now - this.ordering.at >= 1000
      && this.ordering.machines.every(name => machines().some(m => m.name === name && m.layout === "ready"));
  }

  // Spaces in order, each worktree space moved under its main checkout's.
  ordered() {
    const sp = spaces(), ps = panes();
    const ready = (w) => this.shown.has(w.id) || where(w, ps) in this.git || Date.now() - (this.born[w.id] ??= Date.now()) > 1500;
    for (const w of sp) if (!this.shown.has(w.id) && ready(w)) this.shown.add(w.id);
    const list = sp.map((w, i) => ({ w, i, g: this.git[where(w, ps)] ?? null }));
    const mains = new Set(list.filter((r) => r.g && !r.g.linked).map((r) => r.g.repo));
    const nested = (r) => r.g?.linked && mains.has(r.g.repo);
    const out = [];
    const placed = new Set(); // repos whose worktrees are listed (under the first of its spaces)
    for (const r of list) {
      if (nested(r)) continue;
      out.push({ ...r, tree: null });
      if (!r.g || r.g.linked || placed.has(r.g.repo)) continue;
      placed.add(r.g.repo);
      const kids = list.filter((k) => nested(k) && k.g.repo === r.g.repo);
      kids.forEach((k, n) => out.push({ ...k, tree: n === kids.length - 1 ? "└─" : "├─" }));
    }
    // Simulate the batch so later indexes include earlier moves. An attempted
    // write can lose a sync conflict: allow the echo to settle before retrying.
    const order = sp.map(w => w.id);
    const target = out.map(r => r.w.id);
    const key = JSON.stringify([order, target, machines()]);
    if (order.every((id, i) => id === target[i])) {
      this.ordering = null;
    } else if (this.ordering?.key !== key || this.orderingDue(Date.now())) {
      const moved = new Set();
      this.ordering = { key, at: Date.now(), machines: [] };
      for (let i = 0; i < out.length; i++) {
        const from = order.indexOf(out[i].w.id);
        if (from === i) continue;
        run("space.move", { id: out[i].w.id, index: i + 1 });
        moved.add(out[i].w.machine ?? null);
        order.splice(i, 0, order.splice(from, 1)[0]);
      }
      this.ordering.machines = [...moved];
    }
    return out.filter(r => this.shown.has(r.w.id));
  }

  // Group by the actual shared Git directory, not by a space's display name.
  grouped(t, collapsed) {
    const sp = spaces(), ps = panes(), list = agents(), all = terminals();
    const agentAddresses = new Set(list.map(a => a.address));
    const spaceByTab = new Map(sp.flatMap(s => s.tabs.map(tab => [tab.id, s])));
    for (const p of ps) {
      const s = spaceByTab.get(p.tab);
      if (!s || !p.terminal || agentAddresses.has(p.terminal)) continue;
      list.push({ address: p.terminal, pane: p.pane, space: s.id, tab: p.tab,
        program: p.program, status: null, plain: true });
    }
    const groups = new Map();
    const groupFor = (s, cwd) => {
      const key = JSON.stringify([s.machine ?? null, cwd]);
      const g = this.git[key];
      const id = g?.repo ?? JSON.stringify([s.machine ?? null, cwd || s.id]);
      if (!groups.has(id)) groups.set(id, { id, name: g?.name ?? s.name, machine: s.machine, target: s.id, folder: g?.top || cwd || s.folder, rows: [], addresses: [], spaces: [] });
      return { group: groups.get(id), git: g };
    };
    const listed = new Map(list.map(a => [a.address, a]));
    const children = new Map();
    for (const k of all) {
      if (k.state !== "live" || !k.parent) continue;
      if (!children.has(k.parent)) children.set(k.parent, []);
      children.get(k.parent).push(k);
    }
    const nested = new Set();
    const mark = (address, seen = new Set()) => {
      if (seen.has(address)) return;
      seen.add(address);
      for (const k of children.get(address) ?? []) { nested.add(k.address); mark(k.address, seen); }
    };
    list.forEach(a => mark(a.address));
    const visited = new Set();
    const rank = a => ({ blocked: 4, error: 4, done: 3, working: 2, idle: 1 }[a.status] ?? 0);
    let rootIndex = 0;
    const add = (group, a, worktree, git, depth = 1, root = rootIndex++, priority = rank(a)) => {
      if (visited.has(a.address)) return;
      visited.add(a.address);
      group.rows.push({ a: { ...a, worktree, git }, depth, root, priority });
      for (const k of children.get(a.address) ?? []) add(group, listed.get(k.address) ?? k, worktree, git, depth + 1, root, priority);
    };
    for (const s of sp) {
      const mine = list.filter(a => a.space === s.id);
      if (!mine.length) {
        const { group } = groupFor(s, place(s, ps));
        group.spaces.push(s);
      }
      for (const a of mine.filter(a => !nested.has(a.address))) {
        const cwd = ps.find(p => p.terminal === a.address)?.cwd || place(s, ps);
        const { group, git } = groupFor(s, cwd);
        // Branch is useful for a checkout; the folder disambiguates worktrees
        // whose folder name differs from the branch.
        const folder = git?.top ? base(git.top) : base(cwd || s.folder || "~");
        const worktree = folder !== group.name && folder !== git?.branch ? folder : "";
        add(group, a, worktree, git);
      }
    }
    for (const group of groups.values()) {
      // Keep sub-agents attached to their runner; urgent children lift the whole card tree.
      const priorities = new Map();
      for (const row of group.rows) priorities.set(row.root, Math.max(priorities.get(row.root) ?? 0, rank(row.a)));
      group.rows.sort((a, b) => priorities.get(b.root) - priorities.get(a.root) || a.root - b.root);
    }
    setAgentOrder([...groups.values()].flatMap(group => group.rows.map(row => row.a.address)));
    return [...groups.values()].map(group => {
      const title = group.name + (group.machine ? ` · ${group.machine}` : "");
      const header = h_flex().id(`repo-${group.id}`).h(36).flex_none().px(8).gap(8).items_center().rounded(7)
        .text_color(t.foreground).font_semibold().tooltip(title).cursor_pointer().hover(row => row.bg(t.hover))
        .on_click(() => run("space.select", { id: group.target }))
        .child(svg("mods/workspace-chrome/folder.svg").size(15).text_color(t.muted))
        .child(div().flex_1().min_w(0).truncate().child(collapsed ? group.name.slice(0, 1).toUpperCase() : title))
        .when(!collapsed && group.rows.length > 0, el => el.child(div().text_size(10).text_color(t.dim).child(String(group.rows.length))))
        .when(!collapsed, el => el.child(div().id(`repo-create-agent-${group.id}`).size(24).flex_none().flex().items_center().justify_center().rounded(5)
          .text_color(t.muted).hover(button => button.bg(t.raised).text_color(t.foreground)).tooltip("Open agent or shell")
          .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
          .on_click((_e, cx) => {
            cx.stop_propagation();
            openOverlay({ mod: "repo-agent-menu", kind: "popup", width: 280, height: 320,
              props: { space: group.target, folder: group.folder, repo: group.name } });
          })
          .child(svg("mods/workspace-chrome/plus.svg").size(13))));
      return v_flex().flex_none().pb(8).child(header)
        .when(!collapsed, el => el.child(v_flex().ml(15).pl(10).border_l(1).border_color(t.border)
          .children(group.rows.map(row => this.agentRow(row.a, row.depth, t, listed.has(row.a.address)))).children(group.spaces.map(s =>
          h_flex().id(`empty-space-${s.id}`).h(28).pl(32).pr(6).gap(6).items_center().rounded(7)
            .when(s.active, row => row.bg(t.selected)).hover(row => row.bg(t.hover))
            .on_click(() => run("space.select", { id: s.id }))
            .child(svg("mods/workspace-chrome/terminal.svg").size(13).text_color(t.dim))
            .child(div().flex_1().min_w(0).truncate().text_color(t.muted).text_size(12).child(s.name))
            .child(div().id(`close-space-${s.id}`).size(22).flex().items_center().justify_center().rounded(5)
              .text_color(t.dim).hover(b => b.bg(t.raised).text_color(t.foreground)).tooltip("Close workspace")
              .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
              .on_click((_e, cx) => { cx.stop_propagation(); run("space.close", { id: s.id }); })
              .child(svg("mods/workspace-chrome/x.svg").size(12)))
        ))));
    });
  }

  // Only what's unusual, after the name: "herdr \u00b7 spike \u21912 \u21931". The repo or
  // branch goes when the name already says it (a worktree is named after its branch),
  // and master/main go: nearly every space is on one.
  gitTail(g, tree, name, t) {
    const raw = g.branch ?? "detached";
    const same = (a) => a.toLowerCase() === name.toLowerCase();
    const branch = same(raw) || raw === "master" || raw === "main" ? "" : raw;
    const repo = tree || same(g.name) ? "" : g.name;
    const where = [repo, branch].filter(Boolean).join(" \u00b7 ");
    return h_flex()
      .flex_1()
      .min_w(0)
      .gap(5)
      .justify_end()
      .items_center()
      .text_size(11.5)
      .text_color(t.dim)
      .when(Boolean(where), (el) => el.child(div().min_w(0).truncate().child(where)))
      .when(g.ahead > 0, (el) => el.child(div().flex_none().text_color(t.ansi2).child(`\u2191${g.ahead}`)))
      .when(g.behind > 0, (el) => el.child(div().flex_none().text_color(t.ansi1).child(`\u2193${g.behind}`)));
  }

  row({ w, i, g, tree }, t) {
    const on = w.active;
    const fromIndex = this.pressed === null ? -1 : spaces().findIndex(s => s.id === this.pressed);
    const colors = shared("space.colors") ?? {};
    const color = colors[w.id] ?? "ansi6";
    const fill = color.startsWith("#") ? color : (MARK[color] ?? t[color]);
    return v_flex()
      .relative()
      .id(`space-${w.id}`)
      .px(8)
      .h(rowHeight({ tree }))
      .flex_none()
      .justify_center()
      .rounded(8)
      .when(on, (el) => el.bg(t.selected))
      .when(!on, (el) => el.hover((s) => s.bg(t.hover)))
      .when(this.pressed === w.id && this.over !== w.id, (el) => el.opacity(0.5))
      .when(this.pressed !== null && this.over === w.id && this.pressed !== w.id, (el) => el.child(
        div().absolute().left(0).right(0).h(2).bg(t.accent)
          .when(fromIndex < i, line => line.bottom(0))
          .when(fromIndex > i, line => line.top(0)),
      ))
      .on_mouse_down("left", () => {
        this.pressed = w.id;
        this.over = w.id;
      })
      .on_mouse_move((_e, cx) => {
        const source = spaces().find(s => s.id === this.pressed);
        const over = source && (source.machine ?? null) === (w.machine ?? null) ? w.id : null;
        if (this.pressed !== null && this.over !== over) {
          this.over = over;
          cx.notify();
        }
      })
      .on_mouse_up("left", (_e, cx) => {
        const from = this.pressed;
        const over = this.over;
        this.pressed = null;
        this.over = null;
        if (from !== null && over === w.id && from !== w.id) {
          const index = spaces().findIndex(s => s.id === w.id);
          if (index !== -1) run("space.move", { id: from, index: index + 1 });
        } else if (from === w.id) run("space.select", { id: w.id });
        cx.notify();
      })
      .on_mouse_down("right", () => this.menu(w))
      .child(
        h_flex()
          .gap(9)
          .items_center()
          .when(Boolean(tree), el => el.pl(22).child(svg("mods/workspace-chrome/branch.svg").size(13).text_color(t.dim)))
          .when(!tree, el => el.child(h_flex().size(18).flex_none().rounded(5).bg(fill).items_center().justify_center().text_size(10.5).font_bold().text_color("#ffffff").child([...w.name][0]?.toUpperCase() ?? "?")))
          .child(div().flex_shrink(0).max_w(150).truncate().text_color(t.foreground).child(w.name))
          .child(g ? this.gitTail(g, tree, w.name, t) : div().flex_1()),
      );
  }

  compact({ w, i }, t) {
    return railCell(h_flex()
      .id(`space-${w.id}`)
      .relative()
      .w(RAIL_CELL)
      .h(26)
      .rounded(6)
      .justify_center()
      .items_center()
      .when(w.active, (el) => el.bg(t.selected))
      .when(!w.active, (el) => el.hover((s) => s.bg(t.hover)))
      .on_click(() => run("space.select", { id: w.id }))
      .child(div().text_color(w.active ? t.foreground : t.muted).child(String(i + 1)))
      .child(div().absolute().right(5).text_color(tone(t, w.status)).child(glyph(w.status))));
  }

  agentRow(a, depth, t, listed) {
    const on = focused()?.terminal === a.address || focused()?.agent === a.address;
    const status = a.status === "error" ? "blocked" : a.status;
    const color = t[status] ?? t.dim;
    const program = a.program;
    const runner = program?.name || a.app || "Agent";
    const branch = a.git?.branch ?? a.worktree ?? "Terminal";
    const name = [branch, a.worktree && a.worktree !== branch ? a.worktree : ""].filter(Boolean).join(" · ");
    const label = a.plain ? runner : ({ blocked: "Needs you", done: "Finished", working: "Working", idle: "Idle" }[status] ?? "Unknown");
    const dirty = a.git?.dirty;
    const gitTip = dirty === true ? "Uncommitted changes (including untracked files)" : dirty === false ? "Working tree clean" : "Git status unavailable";
    const pic = program?.icon ? (program.tint ? svg(program.icon).text_color(t.muted) : image(program.icon)).size(13) : svg("mods/workspace-chrome/terminal.svg").size(13);
    const lines = a.git?.lines;
    return h_flex().id(`nested-agent-${a.address}`).h(30).flex_none()
      .ml(depth > 1 ? (depth - 1) * 10 : 0).px(6).gap(6).items_center().rounded(6)
      .when(on, el => el.bg(t.selected)).hover(s => s.bg(on ? t.selected : t.hover)).cursor_pointer()
      .tooltip(`${runner} · ${name} · ${label}\n${gitTip}`)
      .on_click(() => run(a.plain ? "pane.focus" : listed ? "agent.focus" : "terminal.peek", { terminal: a.address }))
      .when(Boolean(a.pane), el => el.on_mouse_down("right", () => openOverlay({ mod: "menu", kind: "popup", width: 220, height: 260,
        props: { tab: "pane", target: { pane: a.pane, terminal: a.address } } })))
      .child(div().flex_none().tooltip(runner).child(pic))
      .child(div().flex_shrink(1).min_w(0).truncate().text_size(12).text_color(on ? t.foreground : t.muted).child(name))
      .child(h_flex().flex_none().gap(3).items_center().text_size(10)
        .tooltip(`${gitTip}\nLine counts compare tracked files against HEAD, including staged and unstaged changes; binary and untracked contents are excluded.`)
        .when(lines?.added > 0, el => el.child(div().text_color(t.ansi2).child(`+${lines.added}`)))
        .when(lines?.removed > 0, el => el.child(div().text_color(t.ansi1).child(`−${lines.removed}`))))
      .child(div().flex_1().min_w(0))
      .when(a.git?.ahead > 0 || a.git?.behind > 0, el => el.child(
        h_flex().flex_none().gap(3).items_center().text_size(10).font_semibold()
          .when(a.git?.ahead > 0, badge => badge.child(h_flex().h(18).gap(3).items_center().text_color(t.ansi2).tooltip("Commits ahead of upstream").child("↑").child(String(a.git.ahead))))
          .when(a.git?.behind > 0, badge => badge.child(h_flex().h(18).gap(3).items_center().text_color(t.ansi1).tooltip("Commits behind upstream").child("↓").child(String(a.git.behind))))))
      .when(!a.plain, el => el.child(h_flex().flex_none().h(20).px(6).gap(4).rounded(5)
        .bg(color + "20").items_center().text_size(10).font_semibold().text_color(color).tooltip(label)
        .child(status === "working" ? svg("mods/workspace-chrome/spinner.svg").size(11).spin(900)
          : status === "idle" ? div().size(6).rounded(3).border(1).border_color(color)
          : div().size(7).rounded(4).bg(color))
        ));
  }

  render() {
    const t = theme();
    const collapsed = narrow();
    const palette = ["ansi6", "ansi3", "ansi4", "ansi5", "ansi2", "ansi1"];
    const sp = spaces();
    const ids = new Set(sp.map(p => p.id));
    const kept = Object.fromEntries(Object.entries(shared("space.colors") ?? {}).filter(([id]) => ids.has(id)));
    let changed = Object.keys(kept).length !== Object.keys(shared("space.colors") ?? {}).length;
    for (const p of sp) {
      if (kept[p.id] || p.name === "~") continue;
      const uses = c => Object.values(kept).filter(v => v === c).length;
      kept[p.id] = palette.reduce((best, c) => uses(c) < uses(best) ? c : best);
      changed = true;
    }
    if (changed) setShared("space.colors", kept);
    return v_flex().size_full().min_h(0).rounded(10).overflow_hidden().bg(t.background).border(1).border_color(t.border).text_size(13)
      .child(h_flex().h(42).flex_none().px(14).items_center().justify_between().border_b(1).border_color(t.border).text_size(12.8).text_color(t.foreground)
        .when(collapsed, el => el.pl(0).pr(0).justify_center())
        .when(!collapsed, el => el.child("Repositories"))
        .child(div().id("space-new").size(26).flex_none().flex().items_center().justify_center().rounded(6).hover(s => s.bg(t.hover).text_color(t.foreground))
          .on_click(() => run("space.new")).child(svg("mods/workspace-chrome/plus.svg").size(14))))
      .child(v_flex().flex_1().min_h(0).px(collapsed ? 0 : 8).py(8).overflow_y_scrollbar().mode("always")
        .on_mouse_up("left", (_e, cx) => { this.pressed = null; cx.notify(); })
        .children(this.grouped(t, collapsed)))
      .child((collapsed ? v_flex() : h_flex()).flex_none().h(collapsed ? 76 : 52).p(collapsed ? 4 : 10).gap(8).border_t(1).border_color(t.border)
        .children([
          { id: "sidebar-settings", icon: "settings", label: "Settings", action: () => run("app.settings") },
          { id: "sidebar-add-machine", icon: "plus", label: "Add machine", action: () => run("mod.open", { name: "machine-add" }) },
        ].map(item => h_flex().id(item.id).h(32).flex_none().px(collapsed ? 0 : 6).gap(8).items_center().rounded(6)
          .when(collapsed, el => el.justify_center())
          .text_size(12).text_color(t.muted).hover(el => el.bg(t.hover).text_color(t.foreground)).cursor_pointer().tooltip(item.label)
          .on_click(item.action)
          .child(svg(`mods/workspace-chrome/${item.icon}.svg`).size(14).flex_none())
          .when(!collapsed, el => el.child(item.label)))));
  }
}
