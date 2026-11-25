// New space: pick a host, then a folder there. Offered: home, the repos last open
// (newest first, as the sidebar recorded them), then ~/nixos, ~/dev/* and
// ~/dev/devenv-tilt/projects/*; anything open now is left out. Typing ranks the
// matches (prefix, word start, anywhere, letters in order) and a typed ~/ or / path
// can be opened as is. Up/Down pick, Tab completes the field, Enter opens.

import { View, div, svg } from "gpui-kit";
import { h_flex, v_flex, InputState, Input } from "gpui-base";
import { theme, props, run, exec, home, closeOverlay, shared, spaces, panes } from "herdr";

const LIMIT = 40;
// Folders worth offering on every host, as globs under its home.
const LISTING = `printf '%s\\n' "$HOME"
for d in "$HOME/nixos" "$HOME"/dev/*/ "$HOME"/dev/devenv-tilt/projects/*/; do
  [ -d "$d" ] && printf '%s\\n' "\${d%/}"
done`;
const HEADS = { home: "", recent: "Recent", dir: "Projects", path: "" };

const base = (path) => path.replace(/\/+$/, "").split("/").pop();

function ago(ms) {
  const m = Math.floor(ms / 60000);
  if (m < 60) return `${Math.max(m, 1)}m`;
  const h = Math.floor(m / 60);
  return h < 24 ? `${h}h` : `${Math.floor(h / 24)}d`;
}

// How well `item` matches `f` (lower is better), or null.
function score(item, f) {
  const hay = [item.name.toLowerCase(), item.folder.toLowerCase()];
  if (hay[0].startsWith(f)) return 0;
  if (hay.some((h) => h.split(/[^a-z0-9]+/).some((w) => w.startsWith(f)))) return 1;
  if (hay.some((h) => h.includes(f))) return 2;
  const inOrder = (h) => {
    let i = 0;
    for (const ch of h) if (ch === f[i]) i++;
    return i === f.length;
  };
  return inOrder(hay[0]) ? 3 : null;
}

export default class NewSpace extends View {
  init(_props, cx) {
    this.p = props() ?? {};
    this.host = null; // null: this computer
    this.filter = "";
    this.at = 0;
    this.busy = false;
    this.listed = {}; // host -> { home, dirs } once asked
    this.input = InputState.new({ placeholder: "Folder or repo…" });
    this.input.on("change", (_e, cx) => {
      this.filter = this.input.value();
      this.at = 0;
      cx.notify();
    });
    this.input.on("submit", (_e, cx) => {
      const item = this.shown()[this.at];
      if (item) this.open(item);
    });
    this.input.focus();
    cx.timer.after(300, () => this.input.focus());
    this.list(null, cx);
  }

  list(host, cx) {
    if (this.listed[host ?? ""]) return;
    this.listed[host ?? ""] = { home: host ? null : home(), dirs: [], loading: true };
    cx.spawn(async (cx) => {
      const entry = this.listed[host ?? ""];
      try {
        const r = await exec("sh", ["-c", LISTING], { on: host, timeout: 10000 });
        if (r.code === 0) {
          const [h, ...dirs] = r.stdout.split("\n").filter(Boolean);
          entry.home = h;
          entry.dirs = dirs;
        }
      } catch {} // the machine is away: home and recent only
      entry.loading = false;
      cx.notify();
    });
  }

  // Folders open on the host now: its spaces' terminals' folders.
  openFolders() {
    const tabs = new Set(
      spaces()
        .filter((s) => (s.machine ?? null) === this.host)
        .flatMap((s) => s.tabs.map((t) => t.id)),
    );
    return panes()
      .filter((p) => tabs.has(p.tab) && p.cwd)
      .map((p) => p.cwd);
  }

  items() {
    const entry = this.listed[this.host ?? ""] ?? { home: null, dirs: [] };
    const homeDir = entry.home ?? (this.host ? null : home());
    const open = this.openFolders();
    const recent = (shared("repos.recent") ?? []).filter((r) => (r.machine ?? null) === this.host);
    const isOpen = (folder) =>
      recent.some((r) => r.folder === folder && r.open) ||
      open.some((cwd) => cwd === folder || cwd.startsWith(`${folder}/`));
    const short = (path) =>
      homeDir && path.startsWith(homeDir) ? `~${path.slice(homeDir.length)}` : path;
    const items = [];
    const taken = new Set();
    items.push({ kind: "home", name: "~", folder: homeDir ?? "", hint: "home" });
    const now = Date.now();
    for (const r of [...recent].sort((a, b) => b.at - a.at)) {
      if (taken.has(r.folder) || isOpen(r.folder) || r.folder === homeDir) continue;
      taken.add(r.folder);
      items.push({ kind: "recent", name: base(r.folder), folder: r.folder, hint: ago(now - r.at) });
    }
    for (const d of entry.dirs) {
      if (taken.has(d) || isOpen(d)) continue;
      taken.add(d);
      items.push({
        kind: "dir",
        name: base(d),
        folder: d,
        hint: short(d.slice(0, d.lastIndexOf("/"))),
      });
    }
    return items;
  }

  shown() {
    const f = this.filter.trim().toLowerCase();
    const items = this.items();
    if (!f) return items.slice(0, LIMIT);
    const matches = items
      .map((item, i) => ({ item, i, s: score(item, f) }))
      .filter((m) => m.s !== null)
      .sort((x, y) => x.s - y.s || x.i - y.i)
      .slice(0, LIMIT)
      .map((m) => m.item);
    // A typed path opens as is.
    const typed = this.filter.trim();
    if (/^[~/]/.test(typed)) {
      const homeDir = this.listed[this.host ?? ""]?.home ?? (this.host ? null : home());
      const folder = typed.startsWith("~") && homeDir ? homeDir + typed.slice(1) : typed;
      matches.unshift({ kind: "path", name: typed, folder, hint: "open this folder" });
    }
    return matches;
  }

  completion() {
    const item = this.shown()[this.at];
    return item && item.kind !== "path" && item.name !== this.filter ? item.name : null;
  }

  open(item) {
    if (this.busy) return;
    this.busy = true;
    run("space.new", { machine: this.host ?? "", ...(item.folder ? { folder: item.folder } : {}) });
    closeOverlay(this.p.overlay);
  }

  render() {
    const t = theme();
    const rows = this.shown();
    const typed = Boolean(this.filter.trim());
    const complete = this.completion();
    const hosts = [null, ...(this.p.machines ?? [])];
    const loading = this.listed[this.host ?? ""]?.loading;
    const icon = { home: "monitor", recent: "clock", dir: "folder", path: "folder-plus" };
    const list = [];
    rows.forEach((item, i) => {
      if (!typed && HEADS[item.kind] && item.kind !== rows[i - 1]?.kind)
        list.push(
          div()
            .px(6)
            .pt(8)
            .pb(2)
            .text_size(10.5)
            .font_semibold()
            .text_color(t.dim)
            .child(HEADS[item.kind]),
        );
      list.push(
        h_flex()
          .id(`new-space-${i}`)
          .h(28)
          .flex_none()
          .px(6)
          .gap(8)
          .items_center()
          .rounded(5)
          .when(i === this.at, (el) => el.bg(t.hover))
          .cursor_pointer()
          .hover((el) => el.bg(t.hover))
          .tooltip(item.folder || "Home")
          .on_click(() => this.open(item))
          .child(
            svg(`mods/workspace-chrome/${icon[item.kind]}.svg`)
              .size(12)
              .flex_none()
              .text_color(t.muted),
          )
          .child(div().flex_1().min_w(0).truncate().text_color(t.foreground).child(item.name))
          .child(
            div()
              .flex_none()
              .max_w(140)
              .truncate()
              .text_size(10.5)
              .text_color(t.dim)
              .child(item.hint),
          ),
      );
    });
    return v_flex()
      .id("new-space")
      .w_full()
      .h(420)
      .p(6)
      .gap(6)
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
        h_flex()
          .flex_none()
          .gap(4)
          .children(
            hosts.map((h) =>
              h_flex()
                .id(`new-space-host-${h ?? "local"}`)
                .h(24)
                .px(8)
                .gap(5)
                .items_center()
                .rounded(5)
                .text_size(11.5)
                .cursor_pointer()
                .when(h === this.host, (el) => el.bg(t.selected).text_color(t.foreground))
                .when(h !== this.host, (el) =>
                  el.text_color(t.dim).hover((s) => s.bg(t.hover).text_color(t.muted)),
                )
                .on_click((_e, cx) => {
                  this.host = h;
                  this.at = 0;
                  this.list(h, cx);
                  this.input.focus();
                  cx.notify();
                })
                .child(svg(`mods/workspace-chrome/${h ? "server" : "monitor"}.svg`).size(11))
                .child(h ?? "This computer"),
            ),
          ),
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
                .max_w(120)
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
          .id("new-space-list")
          .flex_1()
          .min_h(0)
          .overflow_y_scrollbar()
          .children(list)
          .when(Boolean(loading), (el) =>
            el.child(div().px(6).py(6).text_color(t.dim).child("Looking for projects…")),
          )
          .when(typed && !rows.length, (el) =>
            el.child(div().px(6).py(6).text_color(t.dim).child("Nothing matches.")),
          ),
      )
      .child(
        h_flex()
          .id("new-space-add-machine")
          .h(26)
          .flex_none()
          .px(6)
          .gap(8)
          .items_center()
          .rounded(5)
          .text_size(11.5)
          .text_color(t.dim)
          .cursor_pointer()
          .hover((el) => el.bg(t.hover).text_color(t.muted))
          .on_click(() => {
            run("mod.open", { name: "machine-add" });
            closeOverlay(this.p.overlay);
          })
          .child(svg("mods/workspace-chrome/plus.svg").size(12))
          .child("Add machine…"),
      );
  }
}
