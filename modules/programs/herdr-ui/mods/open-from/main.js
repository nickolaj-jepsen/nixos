// "Open from" for a repo: one of its worktrees (open or closed), branches (local or on
// origin) or open PRs, opened as a worktree with `wt new` and shown in a new space.
// Empty, it offers worktrees, PRs and recent branches; typing ranks every match
// (prefix, then word start, then anywhere, then the letters in order). Up/Down pick,
// Tab completes the field to the picked branch, Enter opens it.

import { View, div, svg } from "gpui-kit";
import { h_flex, v_flex, InputState, Input } from "gpui-base";
import { theme, props, run, exec, closeOverlay } from "herdr";

const LIMIT = 40;
// Shown before anything is typed: how many of each.
const FIRST = { worktree: 8, pr: 8, branch: 6, remote: 4 };
const HEADS = {
  worktree: "Worktrees",
  pr: "Pull requests",
  branch: "Recent branches",
  remote: "On origin",
};

// How well `item` matches `f` (lower is better), or null.
function score(item, f) {
  const hay = [item.branch.toLowerCase(), item.name.toLowerCase(), item.hint.toLowerCase()];
  if (hay.some((h) => h.startsWith(f))) return 0;
  if (hay.some((h) => h.split(/[^a-z0-9]+/).some((w) => w.startsWith(f)))) return 1;
  if (hay.some((h) => h.includes(f))) return 2;
  const inOrder = (h) => {
    let i = 0;
    for (const ch of h) if (ch === f[i]) i++;
    return i === f.length;
  };
  return hay.some(inOrder) ? 3 : null;
}

export default class OpenFrom extends View {
  init(_props, cx) {
    const p = props() ?? {};
    this.p = p;
    this.filter = "";
    this.items = [];
    this.loading = true;
    this.busy = null;
    this.error = null;
    this.input = InputState.new({ placeholder: "Worktree, branch or PR…" });
    this.at = 0; // the picked row among shown()
    this.input.on("change", (_e, cx) => {
      this.filter = this.input.value();
      this.at = 0;
      cx.notify();
    });
    this.input.on("submit", (_e, cx) => {
      const item = this.shown()[this.at];
      if (item) this.open(item, cx);
    });
    this.input.focus();
    cx.timer.after(300, () => this.input.focus());
    cx.spawn(async (cx) => {
      try {
        this.items = await this.load();
      } catch (e) {
        this.error = String(e.message ?? e);
      }
      this.loading = false;
      cx.notify();
    });
  }

  sh(cmd, args, timeout = 20000) {
    return exec(cmd, args, { cwd: this.p.folder, on: this.p.machine, timeout });
  }

  // Worktrees first, then PRs, then branches by last commit; each name once, as the
  // kind that says the most about it.
  async load() {
    const [list, local, remote, prs] = await Promise.all([
      this.sh("wt", ["list", "--json"]).catch(() => null),
      this.sh("git", [
        "for-each-ref",
        "--sort=-committerdate",
        "--format=%(refname:short)",
        "refs/heads",
      ]),
      this.sh("git", [
        "for-each-ref",
        "--sort=-committerdate",
        "--format=%(refname:short)",
        "refs/remotes/origin",
      ]),
      this.sh("gh", [
        "pr",
        "list",
        "--limit",
        String(LIMIT),
        "--json",
        "number,title,headRefName,isDraft",
      ]).catch(() => null),
    ]);
    const items = [];
    const taken = new Set();
    let main = null;
    if (list?.code === 0) {
      const repo = JSON.parse(list.stdout).repos?.[0];
      main = repo?.defaultBranch ?? null;
      for (const w of repo?.worktrees ?? []) {
        if (!w.branch) continue;
        taken.add(w.branch);
        items.push({
          kind: "worktree",
          name: w.name,
          branch: w.branch,
          path: w.open ? w.path : null,
          hint: w.open ? "open" : w.wip ? "closed · wip" : "closed",
        });
      }
    }
    if (prs?.code === 0)
      for (const pr of JSON.parse(prs.stdout || "[]")) {
        if (taken.has(pr.headRefName)) continue;
        taken.add(pr.headRefName);
        items.push({
          kind: "pr",
          name: pr.title,
          branch: pr.headRefName,
          number: pr.number,
          hint: `#${pr.number}${pr.isDraft ? " draft" : ""}`,
        });
      }
    const locals = local.code === 0 ? local.stdout.split("\n").filter(Boolean) : [];
    const localSet = new Set(locals);
    for (const b of locals) {
      if (taken.has(b) || b === main) continue;
      taken.add(b);
      items.push({ kind: "branch", name: b, branch: b, hint: "local" });
    }
    if (remote.code === 0)
      for (const ref of remote.stdout.split("\n").filter(Boolean)) {
        const b = ref.replace(/^origin\//, "");
        if (b === "HEAD" || ref === "origin" || taken.has(b) || b === main || localSet.has(b))
          continue;
        taken.add(b);
        items.push({ kind: "remote", name: b, branch: b, hint: "origin" });
        if (items.length > LIMIT * 4) break;
      }
    return items;
  }

  shown() {
    const f = this.filter.trim().toLowerCase();
    if (!f) {
      const seen = {};
      return this.items.filter((i) => (seen[i.kind] = (seen[i.kind] ?? 0) + 1) <= FIRST[i.kind]);
    }
    return this.items
      .map((item, i) => ({ item, i, s: score(item, f) }))
      .filter((m) => m.s !== null)
      .sort((x, y) => x.s - y.s || x.i - y.i)
      .slice(0, LIMIT)
      .map((m) => m.item);
  }

  // The picked branch completes what is typed (Tab); null when it wouldn't add anything.
  completion() {
    const item = this.shown()[this.at];
    return item && item.branch !== this.filter ? item.branch : null;
  }

  // The worktree's folder, made or reopened by wt; a PR's head is fetched into a local
  // branch first (forks too), a branch only on origin starts from origin's copy.
  async folderFor(item) {
    if (item.path) return item.path;
    const ok = (r, what) => {
      if (r.code !== 0)
        throw new Error((r.stderr || r.stdout || `${what} failed`).trim().split("\n").pop());
      return r;
    };
    const has = async (b) =>
      (await this.sh("git", ["rev-parse", "--verify", "--quiet", `refs/heads/${b}`])).code === 0;
    let args = [item.branch];
    if (item.kind === "pr" && !(await has(item.branch)))
      ok(
        await this.sh(
          "git",
          ["fetch", "--quiet", "origin", `pull/${item.number}/head:${item.branch}`],
          60000,
        ),
        "git fetch",
      );
    if (item.kind === "remote" && !(await has(item.branch))) {
      ok(await this.sh("git", ["fetch", "--quiet", "origin", item.branch], 60000), "git fetch");
      args = [item.branch, `origin/${item.branch}`];
    }
    const r = ok(await this.sh("wt", ["new", ...args], 120000), "wt new");
    return r.stdout.trim().split("\n").pop();
  }

  open(item, cx) {
    if (this.busy) return;
    this.busy = item;
    this.error = null;
    cx.notify();
    cx.spawn(async (cx) => {
      try {
        const folder = await this.folderFor(item);
        run("space.new", { machine: this.p.machine ?? "", folder });
        closeOverlay(this.p.overlay);
      } catch (e) {
        this.error = String(e.message ?? e);
        this.busy = null;
        cx.notify();
      }
    });
  }

  render() {
    const t = theme();
    const rows = this.shown();
    const typed = Boolean(this.filter.trim());
    const complete = this.completion();
    const icon = {
      worktree: "folder",
      pr: "git-compare",
      branch: "git-branch",
      remote: "git-branch",
    };
    const list = [];
    rows.forEach((item, i) => {
      if (!typed && item.kind !== rows[i - 1]?.kind)
        list.push(
          div()
            .px(6)
            .pt(i ? 8 : 2)
            .pb(2)
            .text_size(10.5)
            .font_semibold()
            .text_color(t.dim)
            .child(HEADS[item.kind]),
        );
      list.push(
        h_flex()
          .id(`open-from-${i}`)
          .h(28)
          .flex_none()
          .px(6)
          .gap(8)
          .items_center()
          .rounded(5)
          .when(i === this.at, (el) => el.bg(t.hover))
          .cursor_pointer()
          .hover((el) => el.bg(t.hover))
          .tooltip(item.branch)
          .on_click((_e, cx) => this.open(item, cx))
          .child(
            svg(`mods/workspace-chrome/${icon[item.kind]}.svg`)
              .size(12)
              .flex_none()
              .text_color(item.kind === "remote" ? t.dim : t.muted),
          )
          .child(
            div()
              .flex_1()
              .min_w(0)
              .truncate()
              .text_color(item.kind === "remote" ? t.muted : t.foreground)
              .child(this.busy === item ? `${item.name}\u2026` : item.name),
          )
          .child(div().flex_none().text_size(10.5).text_color(t.dim).child(item.hint)),
      );
    });
    return v_flex()
      .id("open-from")
      .w_full()
      .h(380)
      .p(6)
      .gap(4)
      .bg(t.popover)
      .text_size(12)
      .on_key_down((e, cx) => {
        if (e.key === "down" && rows.length) this.at = (this.at + 1) % rows.length;
        else if (e.key === "up" && rows.length) this.at = (this.at + rows.length - 1) % rows.length;
        else if (e.key === "tab" && complete) {
          this.input.set_value(complete);
          this.filter = complete;
          this.at = 0;
        } else return;
        cx.stop_propagation();
        cx.notify();
      })
      .child(
        div()
          .px(6)
          .pt(2)
          .text_size(10.5)
          .text_color(t.dim)
          .child(`Open in ${this.p.repo ?? "this repo"} as a worktree`),
      )
      .child(
        h_flex()
          .h(30)
          .flex_none()
          .px(8)
          .gap(6)
          .items_center()
          .rounded(6)
          .border_1()
          .border_color(t.input)
          .bg(t.background)
          .child(svg("mods/workspace-chrome/search.svg").size(13).flex_none().text_color(t.dim))
          .child(Input.new(this.input).flex_1().h_full().text_size(12).text_color(t.foreground))
          .when(typed && Boolean(complete), (el) =>
            el.child(
              h_flex()
                .flex_none()
                .max_w(140)
                .gap(4)
                .items_center()
                .text_size(10.5)
                .text_color(t.dim)
                .child(div().min_w(0).truncate().child(complete))
                .child(div().px(4).rounded(3).border_1().border_color(t.border).child("Tab")),
            ),
          ),
      )
      .child(
        v_flex()
          .id("open-from-list")
          .flex_1()
          .min_h(0)
          .overflow_y_scrollbar()
          .children(list)
          .when(this.loading, (el) =>
            el.child(
              div()
                .px(6)
                .py(6)
                .text_color(t.dim)
                .child("Loading worktrees, branches and PRs\u2026"),
            ),
          )
          .when(!this.loading && !rows.length, (el) =>
            el.child(
              div()
                .px(6)
                .py(6)
                .text_color(t.dim)
                .child(typed ? "Nothing matches." : "No worktrees, PRs or branches."),
            ),
          ),
      )
      .when(Boolean(this.error), (el) =>
        el.child(div().px(6).py(4).text_size(11).text_color(t.blocked).child(this.error)),
      );
  }
}
