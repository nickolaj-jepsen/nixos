{
  # macOS preference defaults tuned to feel closer to a Linux desktop. Darwin-only
  # leaf, so it lands on every darwin host (just macbook) with no gate needed.
  flake.modules.darwin.darwin-defaults = {
    config,
    fpLib,
    ...
  }: let
    c = config.fireproof.theme.colors;
  in {
    system.defaults = {
      NSGlobalDomain = {
        # Native macOS chrome can only take the dark/light flag from the palette;
        # the Flexoki theme is dark. Accent/highlight color live in
        # CustomUserPreferences below (no typed option in this nix-darwin).
        AppleInterfaceStyle = "Dark";

        # Fast repeat + kill the press-and-hold accent popup, so holding a key
        # repeats it (vim motions, arrow keys) instead of offering diacritics.
        KeyRepeat = 2;
        InitialKeyRepeat = 15;
        ApplePressAndHoldEnabled = false;

        # Tab moves focus through every control, not just text fields (keyboard-driven nav).
        AppleKeyboardUIMode = 3;

        "com.apple.mouse.tapBehavior" = 1; # tap-to-click (also applies at the login window)

        # Stop macOS rewriting what you type — mangles code and commit messages.
        NSAutomaticCapitalizationEnabled = false;
        NSAutomaticSpellingCorrectionEnabled = false;
        NSAutomaticDashSubstitutionEnabled = false;
        NSAutomaticQuoteSubstitutionEnabled = false;
        NSAutomaticPeriodSubstitutionEnabled = false;
        NSAutomaticInlinePredictionEnabled = false;

        AppleShowAllExtensions = true;
        NSWindowResizeTime = 0.001;
        NSAutomaticWindowAnimationsEnabled = false;
        NSNavPanelExpandedStateForSaveMode = true;
        PMPrintingExpandedStateForPrint = true;
        NSDocumentSaveNewDocumentsToCloud = false; # default save target is disk, not iCloud

        # Locale — set for Denmark; flip if the Mac should follow a different region.
        AppleICUForce24HourTime = true;
        AppleMeasurementUnits = "Centimeters";
        AppleMetricUnits = 1;
        AppleTemperatureUnit = "Celsius";
      };

      finder = {
        AppleShowAllFiles = true; # show dotfiles
        ShowPathbar = true;
        ShowStatusBar = true;
        FXPreferredViewStyle = "Nlsv"; # list view
        _FXShowPosixPathInTitle = true;
        FXEnableExtensionChangeWarning = false;
        _FXSortFoldersFirst = true;
        FXDefaultSearchScope = "SCcf"; # search the current folder, not the whole Mac
      };

      dock = {
        autohide = true;
        autohide-delay = 0.0;
        autohide-time-modifier = 0.2;
        show-recents = false;
        minimize-to-application = true; # minimized windows fold into the app's Dock icon
        mru-spaces = false; # never auto-reorder Spaces — required for any workspace/tiling habit
        tilesize = 40;
        wvous-bl-corner = 1; # hot corners off (1 = no-op)
        wvous-br-corner = 1;
        wvous-tl-corner = 1;
        wvous-tr-corner = 1;
      };

      WindowManager.GloballyEnabled = false; # Stage Manager off

      trackpad = {
        Clicking = true; # tap to click
        TrackpadThreeFingerDrag = true;
      };

      CustomUserPreferences = {
        "com.apple.desktopservices" = {
          DSDontWriteNetworkStores = true; # no .DS_Store litter on network/USB shares
          DSDontWriteUSBStores = true;
        };

        # Auto-hide the menu bar everywhere (2 = Always). No typed option for this.
        "com.apple.controlcenter".AutoHideMenuBarOption = 2;

        # The only theme colors macOS exposes for native UI. AppleAccentColor is a
        # fixed enum (control tint) — 1 = Orange, nearest to Flexoki coral, matching
        # the GTK/libadwaita "orange" choice. AppleHighlightColor (text selection)
        # takes a free-form "R G B name" and gets the real accent hex.
        NSGlobalDomain = {
          AppleAccentColor = 1;
          AppleHighlightColor = "${fpLib.hexToRgbFloat c.accent} Coral";

          # Keep the menu bar hidden in fullscreen too, and don't minimize a window
          # when its title bar is double-clicked (neither has a typed option).
          AppleMenuBarVisibleInFullscreen = false;
          AppleMiniaturizeOnDoubleClick = false;
        };
      };
    };

    # Touch ID (and Apple Watch) for sudo; add `.reattach = true` to also work under tmux.
    security.pam.services.sudo_local.touchIdAuth = true;
  };
}
