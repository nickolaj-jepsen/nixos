# A pocketnix guest: the pocketnix module owns the AVF contract (Google's guest
# kernel, the disk image, first boot, the agent); this leaf wires the user,
# forwards and the terminal's look to the rest of the config.
# `nix build .#nixosConfigurations.<h>.config.system.build.pocketnixImage.<build-system>`.
{inputs, ...}: {
  flake.modules.nixos.pocketnix = {
    config,
    lib,
    pkgs,
    ...
  }: let
    c = config.fireproof.theme.colors;
    inherit (config.fireproof.theme) font;
    # The app takes one font file; find monoFamily's regular face in the theme's package.
    monoFontFile = pkgs.runCommand "pocketnix-terminal-font" {nativeBuildInputs = [pkgs.fontconfig];} ''
      export FONTCONFIG_FILE=${pkgs.makeFontsConf {fontDirectories = [font.package];}} HOME=$TMPDIR
      file=$(fc-match -f '%{file}' '${font.monoFamily}:style=Regular')
      case $file in ${font.package}/*) ;; *) echo "no '${font.monoFamily}' in ${font.package}" >&2; exit 1 ;; esac
      cp "$file" $out
    '';
  in {
    imports = [inputs.pocketnix.nixosModules.default];

    config = lib.mkIf config.fireproof.pocketnix.enable {
      pocketnix.guest = {
        enable = true;
        user = config.fireproof.username;
        # Bound on the phone's 127.0.0.1: reach it with `adb forward tcp:2222 tcp:2222`.
        forwards.ssh = {
          guestPort = 22;
          hostPort = 2222;
        };
        terminal = {
          profiles = {
            shell = {};
            # Its server outlives the app's tabs, which die with the app process.
            zellij.command = "zellij attach --create main";
          };
          # The same palette as ghostty's fireproof theme.
          theme.colors = lib.mapAttrs (_: v: "#${v}") {
            background = c.bg;
            foreground = c.fg;
            cursor = c.fg;
            color0 = c.black;
            color1 = c.redAlt;
            color2 = c.greenAlt;
            color3 = c.yellowAlt;
            color4 = c.blueAlt;
            color5 = c.magentaAlt;
            color6 = c.cyanAlt;
            color7 = c.fg;
            color8 = c.muted;
            color9 = c.red;
            color10 = c.green;
            color11 = c.yellow;
            color12 = c.blue;
            color13 = c.magenta;
            color14 = c.cyan;
            color15 = c.whiteAlt;
          };
          theme.font = monoFontFile;
        };
      };
    };
  };
}
