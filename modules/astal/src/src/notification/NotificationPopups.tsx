import Notifd from "gi://AstalNotifd";
import { Variable, bind, interval, timeout } from "astal";
import { App, hook } from "astal/gtk4";
import { Astal, type Gdk, Gtk } from "astal/gtk4";
import config from "../config";
import { VarMap } from "../utils/var-map";
import Notification from "./Notification";

class NotificationMap extends VarMap<number, Gtk.Widget> {
  #notifd = Notifd.get_default();

  get() {
    return [...this.map.entries()].sort(([a], [b]) => b - a).map(([_, v]) => v);
  }

  constructor() {
    super();

    this.#notifd.connect("notified", (_, id) => {
      const notification = this.#notifd.get_notification(id);
      if (notification === null) {
        return;
      }

      // Ignore notifications based on the app name
      for (const re of config.notification.ignore) {
        if (re.test(notification.app_name)) {
          notification.dismiss();
          return;
        }
      }
      this.set(id, Notification({ notification }));
    });

    // notifications can be closed by the outside before
    // any user input, which have to be handled too
    this.#notifd.connect("resolved", (_, id) => {
      this.delete(id);
    });
  }
}

export default function NotificationPopups(gdkmonitor: Gdk.Monitor) {
  const { TOP, RIGHT } = Astal.WindowAnchor;
  const notificationsMap = new NotificationMap();
  const offset = new Variable(0);
  const count = bind(notificationsMap).as((map) => map.length);
  const offsetNotifications = Variable.derive(
    [notificationsMap, offset],
    (map, offset) => map.slice(offset),
  );
  const offsetLength = bind(offsetNotifications).as((map) => map.length);

  return (
    <window
      name={"notifications"}
      application={App}
      cssClasses={["NotificationPopups"]}
      gdkmonitor={gdkmonitor}
      layer={Astal.Layer.OVERLAY}
      exclusivity={Astal.Exclusivity.EXCLUSIVE}
      anchor={TOP | RIGHT}
      visible={count.as((n) => n > 0)}
      vexpand={true}
      valign={Gtk.Align.START}
    >
      <box vertical={true} halign={Gtk.Align.END}>
        {bind(offsetNotifications).as((map) => map.slice(0, 5))}
        <box
          cssClasses={["NotificationMenu"]}
          visible={count.as((n) => n > 2)}
          halign={Gtk.Align.END}
          spacing={10}
        >
          <box
            visible={count.as((n) => n > 5)}
            vertical
            spacing={10}
            widthRequest={50}
          >
            {bind(offset).as((n) => (
              <button
                hexpand
                onClicked={() => offset.set(Math.max(offset.get() - 5, 0))}
                cssClasses={n > 0 ? [] : ["disabled"]}
                label={n > 0 ? `▲ ${n}` : "▲ 0"}
              />
            ))}
            {offsetLength.as((n) => (
              <button
                hexpand
                onClicked={() =>
                  offset.set(Math.min(offset.get() + 5, count.get() - 5))
                }
                cssClasses={n > 5 ? [] : ["disabled"]}
                label={n > 5 ? `▼ ${n - 5}` : "▼ 0"}
              />
            ))}
          </box>
          <button
            cssClasses={["large"]}
            onClicked={() => notificationsMap.clear()}
            label={count.as((n) => `Dismiss all (${n})`)}
          />
        </box>
      </box>
    </window>
  );
}
