import { View, div, svg, image } from "gpui-kit";
import { h_flex, v_flex } from "gpui-base";
import { theme, props, knownAgents, run, closeOverlay, spaces } from "herdr";

export default class RepoAgentMenu extends View {
  init(_props, cx) {
    this.agents = [];
    this.loading = true;
    const context = props() ?? {};
    const target = spaces().find((s) => (context.space ? s.id === context.space : s.active));
    this.target = { space: target?.id, folder: target?.folder, repo: target?.name, ...context };
    cx.spawn(async (cx) => {
      try {
        if (!target) throw new Error("Workspace is no longer available");
        this.agents = (await knownAgents({ on: target.machine })).filter((a) => a.installed);
      } catch (error) {
        this.error = String(error.message ?? error);
      }
      this.loading = false;
      cx.notify();
    });
  }

  start(agent) {
    const { space, folder } = this.target;
    const overlay = props()?.overlay;
    run("tab.new", { space, folder, ...(agent ? { name: agent.name, argv: agent.run } : {}) });
    closeOverlay(overlay);
  }

  render() {
    const t = theme();
    const target = this.target;
    return v_flex()
      .w_full()
      .h(320)
      .min_h(0)
      .p(6)
      .gap(3)
      .bg(t.popover)
      .text_size(12)
      .child(div().px(8).pt(5).text_color(t.foreground).font_semibold().child("New session"))
      .child(
        div()
          .px(8)
          .pb(6)
          .truncate()
          .text_size(11)
          .text_color(t.dim)
          .tooltip(target.folder || "")
          .child(target.repo || "Repository"),
      )
      .child(
        h_flex()
          .id("start-shell")
          .h(34)
          .flex_none()
          .px(8)
          .gap(9)
          .items_center()
          .rounded(6)
          .text_color(t.foreground)
          .hover((row) => row.bg(t.hover))
          .cursor_pointer()
          .on_click(() => this.start(null))
          .child(svg("icons/shell.svg").size(16).text_color(t.muted))
          .child("Shell"),
      )
      .child(div().h(1).flex_none().mx(8).my(4).bg(t.border))
      .child(div().px(8).text_size(11).text_color(t.dim).child("Agents"))
      .child(
        v_flex()
          .flex_1()
          .min_h(0)
          .overflow_y_scrollbar()
          .children(
            this.agents.map((agent) =>
              h_flex()
                .id(`start-${agent.key}`)
                .h(34)
                .flex_none()
                .px(8)
                .gap(9)
                .items_center()
                .rounded(6)
                .text_color(t.foreground)
                .hover((row) => row.bg(t.hover))
                .cursor_pointer()
                .on_click(() => this.start(agent))
                .child(
                  agent.icon
                    ? (agent.tint ? svg(agent.icon).text_color(t.muted) : image(agent.icon)).size(
                        16,
                      )
                    : div().size(16).child("›"),
                )
                .child(div().flex_1().child(agent.name)),
            ),
          ),
      )
      .when(this.loading || this.error || !this.agents.length, (el) =>
        el.child(
          div()
            .px(8)
            .py(8)
            .text_color(t.muted)
            .child(
              this.loading
                ? "Checking installed agents…"
                : this.error || "No installed agents found on this machine.",
            ),
        ),
      );
  }
}
