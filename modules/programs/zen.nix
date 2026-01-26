# Enabled when: desktop
{
  config,
  lib,
  inputs,
  pkgs,
  ...
}: let
  nur = inputs.nur.legacyPackages.${pkgs.stdenv.hostPlatform.system};
  extensions = nur.repos.rycee.firefox-addons;
  c = config.fireproof.theme.colors;
in {
  config = lib.mkIf config.fireproof.desktop.enable {
    fireproof.home-manager = {
      imports = [
        inputs.zen-browser.homeModules.default
      ];

      programs.zen-browser = {
        enable = true;
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
            "zen.urlbar.replace-newtab" = false;
            "zen.theme.accent-color" = "#${c.accent}";
          };
        };
      };
    };
  };
}
