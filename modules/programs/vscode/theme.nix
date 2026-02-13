{
  config,
  lib,
  ...
}: let
  c = config.fireproof.theme.colors;
in {
  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
    fireproof.home-manager.programs.vscode.profiles.default.userSettings = {
      # Keep Darcula for syntax highlighting
      "workbench.colorTheme" = "Darcula Theme from IntelliJ";
      "window.titleBarStyle" = "custom";

      # Font
      "editor.fontFamily" = "'Hack Nerd Font', 'Hack', 'monospace', monospace";
      "editor.fontSize" = 14;
      "editor.lineHeight" = 1.5;

      # Workbench color overrides using Flexoki palette
      "workbench.colorCustomizations" = {
        # Title bar
        "titleBar.activeBackground" = "#${c.bg}";
        "titleBar.activeForeground" = "#${c.fg}";
        "titleBar.inactiveBackground" = "#${c.bg}";
        "titleBar.inactiveForeground" = "#${c.muted}";

        # Activity bar
        "activityBar.background" = "#${c.bg}";
        "activityBar.foreground" = "#${c.fg}";
        "activityBar.inactiveForeground" = "#${c.muted}";
        "activityBar.activeBorder" = "#${c.accent}";
        "activityBarBadge.background" = "#${c.accent}";
        "activityBarBadge.foreground" = "#${c.black}";

        # Sidebar
        "sideBar.background" = "#${c.bg}";
        "sideBar.foreground" = "#${c.fg}";
        "sideBar.border" = "#${c.ui}";
        "sideBarTitle.foreground" = "#${c.fg}";
        "sideBarSectionHeader.background" = "#${c.bg}";
        "sideBarSectionHeader.foreground" = "#${c.fg}";

        # Editor
        "editor.background" = "#${c.bg}";
        "editor.foreground" = "#${c.fg}";
        "editor.lineHighlightBackground" = "#${c.bgAlt}";
        "editor.selectionBackground" = "#${c.accent}44";
        "editor.selectionHighlightBackground" = "#${c.accent}22";
        "editorCursor.foreground" = "#${c.accent}";
        "editorLineNumber.foreground" = "#${c.muted}";
        "editorLineNumber.activeForeground" = "#${c.fg}";
        "editorIndentGuide.background1" = "#${c.ui}";
        "editorIndentGuide.activeBackground1" = "#${c.uiAlt}";
        "editorGroupHeader.tabsBackground" = "#${c.bg}";
        "editorWidget.background" = "#${c.bgAlt}";
        "editorWidget.border" = "#${c.ui}";
        "editorGutter.addedBackground" = "#${c.green}";
        "editorGutter.modifiedBackground" = "#${c.blue}";
        "editorGutter.deletedBackground" = "#${c.red}";

        # Tabs
        "tab.activeBackground" = "#${c.bgAlt}";
        "tab.activeForeground" = "#${c.fg}";
        "tab.inactiveBackground" = "#${c.bg}";
        "tab.inactiveForeground" = "#${c.fg}";
        "tab.activeBorderTop" = "#${c.accent}";
        "tab.border" = "#${c.bg}";

        # Status bar
        "statusBar.background" = "#${c.accent}";
        "statusBar.foreground" = "#${c.black}";
        "statusBar.debuggingBackground" = "#${c.orange}";
        "statusBar.debuggingForeground" = "#${c.black}";
        "statusBar.noFolderBackground" = "#${c.purple}";
        "statusBar.noFolderForeground" = "#${c.black}";
        "statusBarItem.hoverBackground" = "#${c.orangeAlt}";
        "statusBarItem.remoteBackground" = "#${c.green}";
        "statusBarItem.remoteForeground" = "#${c.black}";

        # Terminal
        "terminal.background" = "#${c.bg}";
        "terminal.foreground" = "#${c.fg}";
        "terminal.ansiBlack" = "#${c.black}";
        "terminal.ansiRed" = "#${c.red}";
        "terminal.ansiGreen" = "#${c.green}";
        "terminal.ansiYellow" = "#${c.yellow}";
        "terminal.ansiBlue" = "#${c.blue}";
        "terminal.ansiMagenta" = "#${c.magenta}";
        "terminal.ansiCyan" = "#${c.cyan}";
        "terminal.ansiWhite" = "#${c.fg}";
        "terminal.ansiBrightBlack" = "#${c.muted}";
        "terminal.ansiBrightRed" = "#${c.red}";
        "terminal.ansiBrightGreen" = "#${c.green}";
        "terminal.ansiBrightYellow" = "#${c.yellow}";
        "terminal.ansiBrightBlue" = "#${c.blue}";
        "terminal.ansiBrightMagenta" = "#${c.magenta}";
        "terminal.ansiBrightCyan" = "#${c.cyan}";
        "terminal.ansiBrightWhite" = "#${c.whiteAlt}";

        # Panel (bottom: terminal, problems, output)
        "panel.background" = "#${c.bg}";
        "panel.border" = "#${c.ui}";
        "panelTitle.activeForeground" = "#${c.fg}";
        "panelTitle.activeBorder" = "#${c.accent}";
        "panelTitle.inactiveForeground" = "#${c.muted}";

        # Input fields
        "input.background" = "#${c.bgAlt}";
        "input.foreground" = "#${c.fg}";
        "input.border" = "#${c.ui}";
        "input.placeholderForeground" = "#${c.muted}";

        # Dropdown
        "dropdown.background" = "#${c.bgAlt}";
        "dropdown.foreground" = "#${c.fg}";
        "dropdown.border" = "#${c.ui}";

        # Buttons
        "button.background" = "#${c.accent}";
        "button.foreground" = "#${c.black}";
        "button.hoverBackground" = "#${c.orangeAlt}";

        # Lists and trees
        "list.activeSelectionBackground" = "#${c.uiAlt}";
        "list.activeSelectionForeground" = "#${c.fg}";
        "list.inactiveSelectionBackground" = "#${c.ui}";
        "list.hoverBackground" = "#${c.bgAlt}";
        "list.highlightForeground" = "#${c.accent}";

        # Scrollbar
        "scrollbarSlider.background" = "#${c.ui}80";
        "scrollbarSlider.hoverBackground" = "#${c.uiAlt}";
        "scrollbarSlider.activeBackground" = "#${c.muted}80";

        # Badges
        "badge.background" = "#${c.accent}";
        "badge.foreground" = "#${c.black}";

        # Notifications
        "notifications.background" = "#${c.bgAlt}";
        "notifications.foreground" = "#${c.fg}";
        "notificationCenter.border" = "#${c.ui}";

        # Breadcrumbs
        "breadcrumb.foreground" = "#${c.muted}";
        "breadcrumb.focusForeground" = "#${c.fg}";
        "breadcrumb.activeSelectionForeground" = "#${c.fg}";

        # Git decorations (matching default VSCode conventions)
        "gitDecoration.addedResourceForeground" = "#${c.green}";
        "gitDecoration.modifiedResourceForeground" = "#${c.yellow}";
        "gitDecoration.deletedResourceForeground" = "#${c.red}";
        "gitDecoration.renamedResourceForeground" = "#${c.cyan}";
        "gitDecoration.untrackedResourceForeground" = "#${c.green}";
        "gitDecoration.ignoredResourceForeground" = "#${c.muted}";
        "gitDecoration.conflictingResourceForeground" = "#${c.magenta}";
        "gitDecoration.submoduleResourceForeground" = "#${c.blue}";
        "gitDecoration.stageModifiedResourceForeground" = "#${c.yellow}";
        "gitDecoration.stageDeletedResourceForeground" = "#${c.red}";

        # Peek view
        "peekView.border" = "#${c.accent}";
        "peekViewEditor.background" = "#${c.bgAlt}";
        "peekViewResult.background" = "#${c.bg}";
        "peekViewTitle.background" = "#${c.bgAlt}";

        # Merge conflicts
        "merge.currentHeaderBackground" = "#${c.green}44";
        "merge.incomingHeaderBackground" = "#${c.blue}44";

        # Debug toolbar
        "debugToolBar.background" = "#${c.bgAlt}";

        # Minimap
        "minimap.findMatchHighlight" = "#${c.accent}";
        "minimap.selectionHighlight" = "#${c.accent}44";
        "minimap.errorHighlight" = "#${c.red}";

        # Command palette / quick input
        "quickInput.background" = "#${c.bgAlt}";
        "quickInput.foreground" = "#${c.fg}";
        "quickInputTitle.background" = "#${c.ui}";

        # Diff editor
        "diffEditor.insertedTextBackground" = "#${c.green}22";
        "diffEditor.removedTextBackground" = "#${c.red}22";

        # Focus borders
        "focusBorder" = "#${c.accent}88";
      };
    };
  };
}
