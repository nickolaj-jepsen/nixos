import { register } from "astal";
import { Gtk, astalify } from "astal/gtk4";

export const Separator = astalify<
  Gtk.Separator,
  Gtk.Separator.ConstructorProps
>(Gtk.Separator, {});

export const Expander = astalify<Gtk.Expander, Gtk.Expander.ConstructorProps>(
  Gtk.Expander,
  {
    getChildren(self) {
      const child = self.get_child();
      if (child) return [child];
      return [];
    },

    setChildren(self, children) {
      if (children.length === 0) self.set_child(null);
      if (children.length > 1) {
        console.error("Expander can only have one child.");
        return;
      }
      self.set_child(children[0]);
    },
  },
);

export const Calendar = astalify<Gtk.Calendar, Gtk.Calendar.ConstructorProps>(
  Gtk.Calendar,
  {
    getChildren(self) {
      return [];
    },

    setChildren(self, children) {},
  },
);

export const ScrolledWindow = astalify<
  Gtk.ScrolledWindow,
  Gtk.ScrolledWindow.ConstructorProps
>(Gtk.ScrolledWindow, {
  getChildren(self) {
    const child = self.get_child();
    if (child) return [child];
    return [];
  },

  setChildren(self, children) {
    if (children.length === 0) self.set_child(null);
    if (children.length > 1) {
      console.error("ScrolledWindow can only have one child.");
      return;
    }
    self.set_child(children[0]);
  },
});

export const Viewport = astalify<Gtk.Viewport, Gtk.Viewport.ConstructorProps>(
  Gtk.Viewport,
  {
    getChildren(self) {
      const child = self.get_child();
      if (child) return [child];
      return [];
    },

    setChildren(self, children) {
      if (children.length === 0) self.set_child(null);
      if (children.length > 1) {
        console.error("Viewport can only have one child.");
        return;
      }
      self.set_child(children[0]);
    },
  },
);

export const FlowBox = astalify<Gtk.FlowBox, Gtk.FlowBox.ConstructorProps>(
  Gtk.FlowBox,
  {
    setChildren(self, children) {
      self.remove_all();
      for (const child of children) {
        self.append(child);
      }
    },
  },
);
