// "Open in" for a checkout card: its PR or branch on GitHub, Sublime Merge, Zed, a new
// shell tab there, or its path. Remote checkouts open in Zed over ssh; Sublime Merge
// only reaches this computer's.

import { View, div, svg } from "gpui-kit";
import { h_flex, v_flex } from "gpui-base";
import { theme, props, run, exec, closeOverlay } from "herdr";

export default class OpenIn extends View {
  init() {
    this.error = null;
    this.busy = null;
  }

  // Waits for the program's launcher to hand off, then closes; its errors stay here.
  launch(id, cx, work) {
    if (this.busy) return;
    this.busy = id;
    this.error = null;
    cx.notify();
    cx.spawn(async (cx) => {
      try {
        await work(cx);
        closeOverlay(props()?.overlay);
      } catch (e) {
        this.error = String(e.message ?? e);
        this.busy = null;
        cx.notify();
      }
    });
  }

  render() {
    const t = theme();
    const p = props() ?? {};
    const local = !p.machine;
    const ok = (r, what) => {
      if (r.code !== 0) throw new Error((r.stderr || r.stdout || `${what} failed`).trim());
      return r;
    };
    const items = [
      {
        id: "github",
        icon: "git-compare",
        label: "GitHub",
        hint: p.pr ? `PR #${p.pr.number}` : p.branch ? "branch" : "",
        enabled: Boolean(p.pr || p.branch),
        go: (cx) =>
          this.launch("github", cx, async (cx) => {
            let url = p.pr?.url;
            if (!url) {
              const r = ok(
                await exec("gh", ["browse", "--no-browser", "--branch", p.branch], {
                  cwd: p.folder,
                  on: p.machine,
                  timeout: 15000,
                }),
                "gh browse",
              );
              url = r.stdout.trim();
            }
            cx.open_url(url);
          }),
      },
      {
        id: "smerge",
        icon: "git-branch",
        label: "Sublime Merge",
        hint: local ? "" : "this computer only",
        enabled: local,
        go: (cx) =>
          this.launch("smerge", cx, async () =>
            ok(await exec("smerge", [p.folder], { timeout: 15000 }), "smerge"),
          ),
      },
      {
        id: "zed",
        icon: "square-pen",
        label: "Zed",
        hint: local ? "" : "over ssh",
        enabled: true,
        go: (cx) =>
          this.launch("zed", cx, async () =>
            ok(
              await exec("zeditor", [local ? p.folder : `ssh://${p.host}${p.folder}`], {
                timeout: 15000,
              }),
              "zeditor",
            ),
          ),
      },
      {
        id: "shell",
        icon: "terminal",
        label: "Shell",
        hint: "new tab",
        enabled: true,
        go: () => {
          run("tab.new", { space: p.space, folder: p.folder });
          closeOverlay(p.overlay);
        },
      },
      {
        id: "copy",
        icon: "files",
        label: "Copy path",
        hint: "",
        enabled: true,
        go: (cx) => {
          cx.write_to_clipboard(p.folder);
          closeOverlay(p.overlay);
        },
      },
    ];
    return v_flex()
      .w_full()
      .p(4)
      .gap(1)
      .bg(t.popover)
      .text_size(12)
      .child(
        div()
          .px(8)
          .pt(4)
          .pb(3)
          .truncate()
          .text_size(10.5)
          .text_color(t.dim)
          .tooltip(p.folder ?? "")
          .child(`Open ${p.branch ?? p.folder?.split("/").pop() ?? ""} in`),
      )
      .children(
        items.map((item) =>
          h_flex()
            .id(`open-${item.id}`)
            .h(28)
            .flex_none()
            .px(8)
            .gap(9)
            .items_center()
            .rounded(5)
            .text_color(item.enabled ? t.foreground : t.dim)
            .when(item.enabled, (el) =>
              el
                .cursor_pointer()
                .hover((row) => row.bg(t.hover))
                .on_click((_e, cx) => item.go(cx)),
            )
            .child(
              svg(`mods/workspace-chrome/${item.icon}.svg`)
                .size(13)
                .flex_none()
                .text_color(t.muted),
            )
            .child(
              div()
                .flex_1()
                .child(this.busy === item.id ? `${item.label}…` : item.label),
            )
            .child(div().text_size(10.5).text_color(t.dim).child(item.hint)),
        ),
      )
      .when(Boolean(this.error), (el) =>
        el.child(div().px(8).py(4).text_size(11).text_color(t.blocked).child(this.error)),
      );
  }
}
