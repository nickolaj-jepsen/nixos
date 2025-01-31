import { type Binding, Variable, bind } from "astal";
import { App, Astal, type Gdk, Gtk, hook } from "astal/gtk4";
import { cancelTimeout, cancelableTimeout } from "../../utils/timeout";

const ANIMATION_DURATION = 500;

/**
 * Calculate the offset and width of the parent widget
 *
 * @returns [offset, width]
 */
const calculateParentSize = (widget: Gtk.Widget): [number, number] => {
  const [_, x, __] = widget.translate_coordinates(widget.root, 0, 0);

  // These properties are apparently deprecated, but I can't find a better way to get them
  const padding = widget.get_style_context().get_padding().left;
  const margin = widget.get_style_context().get_margin().left;
  const borderWidth = widget.get_style_context().get_border().left;

  const offset = x - padding - margin - borderWidth;

  // Get allocated width doesn't include border width, so we have to add it back
  const width = widget.get_allocated_width() + borderWidth;

  return [offset, width];
};

interface ConnectDropdownProps {
  fullWidth?: boolean;
}

export function connectDropdown(
  widget: Gtk.Widget,
  child: JSX.Element | Binding<JSX.Element | null> | null,
  gdkmonitor: Gdk.Monitor,
  options: ConnectDropdownProps = {},
) {
  const hoverTrigger = Variable(false);
  const hoverOverlay = Variable(false);
  const offsetX = Variable(0);
  const width = Variable(-1);
  const isHovering = Variable.derive(
    [hoverTrigger, hoverOverlay],
    // (trigger, overlay) => trigger || overlay,
    (trigger, overlay) => trigger || overlay,
  );

  const box = (
    <box
      widthRequest={bind(width)}
      marginStart={bind(offsetX)}
      cssClasses={["Dropdown"]}
      onHoverEnter={() => hoverOverlay.set(true)}
      onHoverLeave={() => hoverOverlay.set(false)}
    >
      {child}
    </box>
  );

  const dropdown = (
    <window
      cssClasses={["DropdownWindow"]}
      gdkmonitor={gdkmonitor}
      layer={Astal.Layer.OVERLAY}
      anchor={Astal.WindowAnchor.TOP | Astal.WindowAnchor.LEFT}
      application={App}
    >
      <revealer
        transitionDuration={ANIMATION_DURATION}
        transitionType={Gtk.RevealerTransitionType.SLIDE_DOWN}
        valign={Gtk.Align.START}
        setup={(self) => {
          bind(self, "child_revealed").subscribe(is_revealed => {
			if (!is_revealed) {
					dropdown.hide();
			}
		  });
		}}
      >
        {box}
      </revealer>
    </window>
  ) as Gtk.Window;

  isHovering.subscribe((hovering) => {
    if (hovering) {
      dropdown.show();
      (dropdown.get_first_child() as Gtk.Revealer).set_reveal_child(true);
    } else {
      (dropdown.get_first_child() as Gtk.Revealer).set_reveal_child(false);
    }
  });

  const hoverController = new Gtk.EventControllerMotion();
  widget.add_controller(hoverController);

  hoverController.connect("enter", () => {
    cancelableTimeout(
      () => {
        const [offset, parentWidth] = calculateParentSize(widget);

        if (options.fullWidth) {
          width.set(parentWidth);
        }
        const dropdownWidth =
          (box.get_preferred_size()[1]?.width ?? 0) - offsetX.get();

        const centerOffset = dropdownWidth / 2 - parentWidth / 2;
        const totalOffset = offset - centerOffset;

        // Ensure the dropdown doesn't go off the screen
        const maxOffset = gdkmonitor.get_geometry().width - dropdownWidth;
        offsetX.set(Math.max(Math.min(totalOffset, maxOffset), 0));
        hoverTrigger.set(true);
      },
      "showDropdown",
      100,
    );
  });

  hoverController.connect("leave", () => {
    cancelTimeout("showDropdown");
    hoverTrigger.set(false);
  });

  widget.connect("destroy", () => {
    isHovering.drop();
    hoverOverlay.drop();
    hoverTrigger.drop();
    offsetX.drop();
    widget.remove_controller(hoverController);
  });
}
