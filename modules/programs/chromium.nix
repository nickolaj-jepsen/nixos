{
  flake.modules.homeManager.chromium = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.fireproof.desktop.chromium;

    extensions = [
      "cjpalhdlnbpafiamejdnhcphjbkeiagm" # uBlock Origin
      "nngceckbapebfimnlniiiahkandclblb" # Bitwarden
    ];

    workDataDir = "${config.xdg.configHome}/chromium-work";

    # A separate --user-data-dir is what makes the two instances independent (own
    # profile, cookies, extensions) and lets them run at the same time; --class
    # gives the work windows their own app-id so niri/taskbars can tell them apart.
    chromiumWork = pkgs.writeShellApplication {
      name = "chromium-work";
      runtimeInputs = [config.programs.chromium.package];
      text = ''
        exec chromium --user-data-dir="${workDataDir}" --class=chromium-work "$@"
      '';
    };
  in {
    config = lib.mkIf (cfg.enable && pkgs.stdenv.isLinux) (lib.mkMerge [
      {
        programs.chromium = {
          enable = true;
          package = pkgs.unstable.chromium;
          inherit extensions;
        };
      }

      (lib.mkIf cfg.work.enable {
        home.packages = [chromiumWork];

        # programs.chromium.extensions only seeds the default profile dir, so the
        # work data dir needs its own copy of the external-extension manifests.
        xdg.configFile = lib.listToAttrs (map (id: {
            name = "chromium-work/External Extensions/${id}.json";
            value.text = builtins.toJSON {
              external_update_url = "https://clients2.google.com/service/update2/crx";
            };
          })
          extensions);

        xdg.desktopEntries.chromium-work = {
          name = "Chromium (Work)";
          genericName = "Web Browser";
          exec = "chromium-work %U";
          icon = "chromium";
          terminal = false;
          categories = ["Network" "WebBrowser"];
          mimeType = ["text/html" "text/xml" "x-scheme-handler/http" "x-scheme-handler/https"];
          settings.StartupWMClass = "chromium-work";
        };
      })
    ]);
  };
}
