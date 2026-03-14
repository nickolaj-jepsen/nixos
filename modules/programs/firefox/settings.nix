# Enabled when: desktop
{
  config,
  lib,
  pkgs,
  ...
}: let
  c = config.fireproof.theme.colors;
in {
  config = lib.mkIf config.fireproof.desktop.enable {
    programs.firefox = {
      enable = true;
      package = pkgs.unstable.firefox;
    };

    xdg.mime.defaultApplications = {
      "text/html" = "firefox.desktop";
      "x-scheme-handler/http" = "firefox.desktop";
      "x-scheme-handler/https" = "firefox.desktop";
      "x-scheme-handler/about" = "firefox.desktop";
      "x-scheme-handler/unknown" = "firefox.desktop";
    };

    fireproof.home-manager.programs.firefox = {
      enable = true;
      package = pkgs.unstable.firefox;

      profiles.default.settings = {
        # Homepage
        "browser.startup.homepage" = "https://glance.nickolaj.com";

        # Telemetry & data collection
        "toolkit.telemetry.enabled" = false;
        "toolkit.telemetry.unified" = false;
        "toolkit.telemetry.shutdownPingSender.enabled" = false;
        "datareporting.policy.dataSubmissionEnabled" = false;
        "datareporting.healthreport.uploadEnabled" = false;
        "app.normandy.enabled" = false;
        "app.shield.optoutstudies.enabled" = false;
        "breakpad.reportURL" = "";
        "browser.newtabpage.activity-stream.telemetry" = false;
        "browser.newtabpage.activity-stream.feeds.telemetry" = false;

        # Pocket
        "extensions.pocket.enabled" = false;

        # HTTPS & security
        "dom.security.https_only_mode" = true;
        "dom.security.https_only_mode_ever_enabled" = true;
        "security.ssl.require_safe_negotiation" = true;

        # WebRTC IP leak prevention
        "media.peerconnection.ice.default_address_only" = true;
        "media.peerconnection.ice.proxy_only_if_behind_proxy" = true;

        # Prefetching & speculative connections
        "network.dns.disablePrefetch" = true;
        "network.prefetch-next" = false;
        "network.predictor.enabled" = false;
        "network.http.speculative-parallel-limit" = 0;

        # Form autofill (redundant with Bitwarden)
        "browser.formfill.enable" = false;
        "signon.autofillForms" = false;
        "signon.rememberSignons" = false;

        # Tracking prevention
        "browser.contentblocking.category" = "strict";
        "browser.send_pings" = false;
        "privacy.fingerprintingProtection" = true;
        "network.IDN_show_punycode" = true;

        # Geolocation
        "geo.enabled" = false;

        # Enable userChrome.css
        "toolkit.legacyUserProfileCustomizations.stylesheets" = true;
      };

      profiles.default.userChrome = ''
        /* Flexoki theme — matches GTK headerbar pattern */

        /* Unified chrome background */
        #navigator-toolbox {
          background: #${c.bgAlt} !important;
          border-bottom: 1px solid #${c.ui} !important;
          --toolbar-bgcolor: #${c.bgAlt} !important;
          --lwt-accent-color: #${c.bgAlt} !important;
          --lwt-toolbarbutton-icon-fill: #${c.fgAlt} !important;
        }

        /* Tab bar */
        #TabsToolbar {
          background: transparent !important;
        }

        /* Tabs — base styling */
        .tabbrowser-tab {
          color: #${c.muted} !important;
        }

        .tabbrowser-tab .tab-background {
          background: transparent !important;
          border-radius: 4px 4px 0 0 !important;
          margin-block: 2px 0 !important;
        }

        /* Selected tab */
        .tabbrowser-tab[selected] .tab-background {
          background: #${c.bg} !important;
        }

        .tabbrowser-tab[selected] {
          color: #${c.fg} !important;
        }

        /* Tab hover */
        .tabbrowser-tab:hover:not([selected]) .tab-background {
          background: #${c.ui} !important;
        }

        .tabbrowser-tab:hover:not([selected]) {
          color: #${c.fgAlt} !important;
        }

        /* Navigation toolbar */
        #nav-bar {
          background: #${c.bgAlt} !important;
          border-top: none !important;
          box-shadow: none !important;
        }

        /* URL bar */
        #urlbar-background {
          background: #${c.bg} !important;
          border: 1px solid #${c.ui} !important;
        }

        #urlbar:hover #urlbar-background {
          border-color: #${c.uiAlt} !important;
        }

        #urlbar[focused] #urlbar-background {
          border-color: #${c.accent} !important;
        }

        #urlbar-input {
          color: #${c.fg} !important;
        }

        /* Toolbar buttons */
        toolbar .toolbarbutton-1:hover:not([disabled]) {
          background: #${c.ui} !important;
        }

        /* Bookmarks bar */
        #PersonalToolbar {
          background: #${c.bgAlt} !important;
          color: #${c.fgAlt} !important;
        }

        /* Sidebar */
        #sidebar-box {
          background: #${c.bg} !important;
          color: #${c.fg} !important;
        }

        #sidebar-header {
          background: #${c.bgAlt} !important;
          border-bottom: 1px solid #${c.ui} !important;
        }

        /* Findbar */
        findbar {
          background: #${c.bgAlt} !important;
          color: #${c.fg} !important;
        }

        /* Remove default separators */
        #navigator-toolbox::after {
          display: none !important;
        }

        #nav-bar-customization-target > .toolbarbutton-1,
        #TabsToolbar-customization-target > .toolbarbutton-1 {
          border-radius: 4px !important;
        }
      '';
    };
  };
}
