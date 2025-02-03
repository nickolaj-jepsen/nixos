import { Gdk, Gtk } from "astal/gtk4";

import { Gio } from "astal";

export const hasIcon = (name: string): boolean => {
  if (!name) {
    return false;
  }
  const display = Gdk.Display.get_default();
  if (!display) {
    return false;
  }

  return Gtk.IconTheme.get_for_display(display).has_icon(name);
};
