import Bar from "./bar/Bar";
import SecondaryBar from "./bar/SecondaryBar";
import NotificationPopups from "./notification/NotificationPopups";
import { getMonitors } from "./utils/monitors";

export default function main() {
  const { main, secondary } = getMonitors();

  // Notify
  NotificationPopups(main);

  // Set bars
  Bar(main);
  for (const monitor of secondary) {
    SecondaryBar(monitor, monitor.relation);
  }
  // const bars = new Map<Gdk.Monitor, Gtk.Widget>()

  // bars.set(main, Bar(main))
  // for (const monitor of secondary) {
  //     bars.set(monitor, SecondaryBar(monitor, monitor.relation))
  // }

  // App.connect("monitor-added", (_, gdkmonitor) => {
  //     bars.set(gdkmonitor, Bar(gdkmonitor))
  // })

  // App.connect("monitor-removed", (_, gdkmonitor) => {
  //     bars.get(gdkmonitor)?.destroy()
  //     bars.delete(gdkmonitor)
  // })
}
