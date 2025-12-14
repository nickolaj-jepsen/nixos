# Enabled when: desktop
{
  config,
  lib,
  pkgsUnstable,
  inputs,
  pkgs,
  ...
}: let
  nur = inputs.nur.legacyPackages.${pkgs.stdenv.hostPlatform.system};
  extensions = nur.repos.rycee.firefox-addons;
in {
  config = lib.mkIf config.fireproof.desktop.enable {
    programs.firefox = {
      enable = true;
      package = pkgsUnstable.firefox;
    };

    xdg.mime.defaultApplications = {
      "text/html" = "firefox.desktop";
      "x-scheme-handler/http" = "firefox.desktop";
      "x-scheme-handler/https" = "firefox.desktop";
      "x-scheme-handler/about" = "firefox.desktop";
      "x-scheme-handler/unknown" = "firefox.desktop";
    };

    fireproof.home-manager = {
      programs.firefox = {
        enable = true;
        package = pkgsUnstable.firefox;
        profiles.default = {
          extensions.packages = with extensions; [
            # Privacy
            ublock-origin
            clearurls
            libredirect
            smartproxy

            # Security
            bitwarden

            # Media
            dearrow
            sponsorblock

            # Search
            kagi-search

            # Productivity
            new-tab-override

            # Social
            reddit-enhancement-suite

            # Development
            react-devtools
            refined-github
          ];

          settings = {
            "browser.startup.homepage" = "https://glance.nickolaj.com";
          };
        };
      };
    };
  };
}
