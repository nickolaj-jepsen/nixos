{
  config,
  lib,
  pkgs,
  ...
}: let
  extensions = pkgs.nur.repos.rycee.firefox-addons;
in {
  config = lib.mkIf config.fireproof.desktop.enable {
    fireproof.home-manager.programs.firefox.profiles.default = {
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
    };
  };
}
