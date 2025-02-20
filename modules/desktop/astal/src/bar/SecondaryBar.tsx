import Hyprland from "gi://AstalHyprland";
import { App } from "astal/gtk4";
import { Astal, type Gdk, Gtk } from "astal/gtk4";
import { getHyprlandMonitor } from "../utils/monitors";
import { Workspaces } from "./sections/Workspace";
import { bind, type Binding, Variable } from "astal";

const hypr = Hyprland.get_default();

interface AddWorkspaceButtonProps {
  show: Binding<boolean>;
  cssClasses: string[];
}

const AddWorkspaceButton = ({ show, cssClasses }: AddWorkspaceButtonProps) => {
  return (
    <revealer
      revealChild={show}
      transitionType={Gtk.RevealerTransitionType.SLIDE_RIGHT}
      transitionDuration={500}
    >
      <button
        cssClasses={["workspace", ...cssClasses]}
        visible={show}
        onClicked={() => {
          hypr.dispatch("workspace", "emptynm");
        }}
        valign={Gtk.Align.CENTER}
      >
        <image iconName="plus-symbolic" pixelSize={18} />
      </button>
    </revealer>
  );
};

export default function SecondaryBar(
  monitor: Gdk.Monitor,
  relation: "top" | "bottom" | "left" | "right",
) {
  const { TOP, LEFT, RIGHT, BOTTOM } = Astal.WindowAnchor;
  const hyprlandMonitor = getHyprlandMonitor(monitor);

  const anchor = {
    top: BOTTOM | LEFT,
    left: TOP | RIGHT,
    right: TOP | LEFT,
    bottom: TOP | LEFT,
  }[relation];

  const cssClasses = {
    top: ["SecondaryBar", "top"],
    left: ["SecondaryBar", "left"],
    right: ["SecondaryBar", "right"],
    bottom: ["SecondaryBar", "bottom"],
  }[relation];

  const alignment = {
    top: Gtk.Align.START,
    left: Gtk.Align.END,
    right: Gtk.Align.START,
    bottom: Gtk.Align.START,
  }[relation];

  const showAddWorkspaceButton = Variable(false);
  const monitorFocused = bind(hypr, "focusedMonitor").as(
    (fm) => fm === hyprlandMonitor,
  );

  return (
    <window
      visible
      gdkmonitor={monitor}
      exclusivity={Astal.Exclusivity.EXCLUSIVE}
      layer={Astal.Layer.OVERLAY}
      anchor={anchor}
      application={App}
      halign={alignment}
      defaultWidth={1} // Ensure the window shinks when content is removed
      defaultHeight={26}
      onHoverEnter={() => showAddWorkspaceButton.set(true)}
      onHoverLeave={() => showAddWorkspaceButton.set(false)}
    >
      <box
        halign={alignment}
        spacing={10}
        cssClasses={monitorFocused.as((x) =>
          x ? cssClasses : [...cssClasses, "inactive"],
        )}
      >
        {relation === "left" ? (
          <AddWorkspaceButton
            show={bind(showAddWorkspaceButton)}
            cssClasses={["add-left"]}
          />
        ) : null}
        <Workspaces monitor={hyprlandMonitor} reverse={relation === "left"} />
        {relation !== "left" ? (
          <AddWorkspaceButton
            show={bind(showAddWorkspaceButton)}
            cssClasses={["add-right"]}
          />
        ) : null}
      </box>
    </window>
  );
}
