import Hyprland from "gi://AstalHyprland";
import Tray from "gi://AstalTray";
import Pango from "gi://Pango?version=1.0";
import { GLib, Variable, bind } from "astal";
import { App, Astal, type Gdk, Gtk } from "astal/gtk4";
import config from "../config";
import { getHyprlandMonitor } from "../utils/monitors";
import { Calendar } from "../widgets";
import { connectDropdown } from "./sections/Dropdown";
import Media from "./sections/Media";
import { Playback } from "./sections/Playback";
import { Workspaces } from "./sections/Workspace";

function SysTray() {
  const tray = Tray.get_default();
  const item = bind(tray, "items").as((items) =>
    items.filter((item) => config.tray.ignore.every((re) => !re.test(item.id))),
  );

  return (
    <box
      cssClasses={["SysTray"]}
      visible={bind(item).as((items) => items.length > 0)}
    >
      {bind(item).as((items) =>
        items.map((item) => (
          <menubutton
            tooltipMarkup={bind(item, "tooltipMarkup")}
            // popover={false}
            // actionGroup={bind(item, "actionGroup").as((ag) => ["dbusmenu", ag])}
            menuModel={bind(item, "menuModel")}
          >
            <image gicon={bind(item, "gicon")} />
          </menubutton>
        )),
      )}
    </box>
  );
}

function FocusedClient() {
  const hypr = Hyprland.get_default();
  const focused = bind(hypr, "focusedClient");

  return (
    <box cssClasses={["Focused"]} visible={focused.as(Boolean)}>
      {focused.as((client) => {
        if (!client) {
          return;
        }
        return (
          <label
            label={bind(client, "title").as(String)}
            ellipsize={Pango.EllipsizeMode.MIDDLE}
            maxWidthChars={120}
          />
        );
      })}
    </box>
  );
}

function Time(props: { monitor: Gdk.Monitor }) {
  const datetime = Variable<GLib.DateTime>(GLib.DateTime.new_now_local()).poll(
    1000,
    () => {
      return GLib.DateTime.new_now_local();
    },
  );
  const date = bind(datetime).as((dt) => dt.format("%Y-%m-%d") ?? "");
  const time = bind(datetime).as((dt) => dt.format("%H:%M") ?? "");

  return (
    <box
      cssClasses={["DateTime"]}
      spacing={10}
      setup={(self) => {
        connectDropdown(self, <Calendar showWeekNumbers />, props.monitor);
      }}
    >
      <label label={date} cssClasses={["Date"]} />
      <label label={time} cssClasses={["Time"]} />
    </box>
  );
}

export default function Bar(monitor: Gdk.Monitor) {
  const { TOP, LEFT, RIGHT } = Astal.WindowAnchor;
  const hyprlandMonitor = getHyprlandMonitor(monitor);

  return (
    <window
      visible
      name={"Bar"}
      // window lags hard if css classes with padding border ect are used so we apply them to a child instead
      //   cssClasses={["Bar"]}
      gdkmonitor={monitor}
      exclusivity={Astal.Exclusivity.EXCLUSIVE}
      layer={Astal.Layer.OVERLAY}
      anchor={TOP | LEFT | RIGHT}
      application={App}
    >
      <centerbox cssClasses={["Bar"]}>
        <box halign={Gtk.Align.START} cssClasses={["Left"]}>
          <Time monitor={monitor} />
          <Workspaces
            monitor={hyprlandMonitor}
            selectedWorkspaces={[1, 2, 3, 4, 5]}
          />
        </box>
        <box halign={Gtk.Align.CENTER}>
          <FocusedClient />
        </box>
        <box halign={Gtk.Align.END} cssClasses={["Right"]}>
          <Media monitor={monitor} />
          <Playback monitor={monitor} />
          <SysTray />
        </box>
      </centerbox>
    </window>
  );
}
