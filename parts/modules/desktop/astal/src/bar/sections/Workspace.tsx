import Hyprland from "gi://AstalHyprland";
import { bind } from "astal";
import { Gdk, Gtk } from "astal/gtk4";

type WorkspacesProps = {
  monitor: Hyprland.Monitor;
  reverse?: boolean;
  selectedWorkspaces?: number[];
};

const hypr = Hyprland.get_default();

const ICON_MAP = {
  terminal: ["kitty", "com.mitchellh.ghostty"],
  "firefox-custom": ["firefox", "firefox-developer-edition"],
  "chrome-custom": ["google-chrome", "chromium"],
  python: ["jetbrains-pycharm"],
  "vscode-custom": ["Code", "code-oss"],
  "git-symbolic": ["smerge", "sublime_merge"],
};

function Workspace(workspace: Hyprland.Workspace) {
  const focused = bind(hypr, "focusedWorkspace").as((fw) => fw === workspace);

  const icon = bind(workspace, "clients").as((clients) => {
    if (clients.length === 0) {
      return "circle";
    }

    const icons = clients
      .map((client) => {
        for (const [name, classes] of Object.entries(ICON_MAP)) {
          if (classes.includes(client.get_class())) {
            return name;
          }
        }
      })
      .filter(Boolean) as string[];

    const count = icons.reduce(
      (acc, cur) => {
        acc[cur] = (acc[cur] || 0) + 1;
        return acc;
      },
      {} as Record<string, number>,
    );

    // Don't return on a tie
    if (
      Object.values(count).filter((x) => x === count[Object.keys(count)[0]])
        .length > 1
    ) {
      return "circle-filled";
    }

    return Object.keys(count)[0] ?? "circle-filled";
  });

  return (
    <button
      cssClasses={focused.as((focused) =>
        focused ? ["workspace", "focused"] : ["workspace"],
      )}
      cursor={Gdk.Cursor.new_from_name("pointer", null)}
      onClicked={() => workspace.focus()}
      valign={Gtk.Align.CENTER}
    >
      <image
        iconName={bind(icon).as((icon) => `${icon}-symbolic`)}
        pixelSize={18}
      />
    </button>
  );
}

export function Workspaces({
  reverse,
  monitor,
  selectedWorkspaces,
}: WorkspacesProps) {
  const workspaces = bind(hypr, "workspaces")
    .as((workspaces) => workspaces.filter((ws) => ws.monitor === monitor))
    .as((workspaces) => {
      if (!selectedWorkspaces) {
        return workspaces;
      }

      return selectedWorkspaces.map((id) => {
        return (
          workspaces.find((ws) => ws.get_id() === id) ??
          Hyprland.Workspace.dummy(id, monitor)
        );
      });
    })
    .as((x) => (reverse ? x.reverse() : x));

  return (
    <box cssClasses={["Workspaces"]} valign={Gtk.Align.CENTER} spacing={10}>
      {workspaces.as((ws) => ws.map(Workspace))}
    </box>
  );
}
