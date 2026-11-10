# Every frame between the bootloader and the desktop is the Flexoki background: Limine in the
# palette, Plymouth's hex dump of the disk unlocking (fireproof.script), and a GDM-style handoff so no text console
# shows between Plymouth and niri.
{
  flake.modules.nixos.boot-splash = {
    config,
    lib,
    pkgs,
    ...
  }: let
    c = config.fireproof.theme.colors;
    font = config.fireproof.theme.font;
    plymouth = lib.getExe' config.boot.plymouth.package "plymouth";

    channels = hex: map (i: toString (lib.fromHexString (builtins.substring i 2 hex) / 255.0)) [0 2 4];
    rgb = name: hex: let
      ch = channels hex;
    in {
      "${name}R" = builtins.elemAt ch 0;
      "${name}G" = builtins.elemAt ch 1;
      "${name}B" = builtins.elemAt ch 2;
    };

    # Every line of the dump as an image, plus data.script, the listing the script walks.
    sprites =
      pkgs.runCommand "boot-hexdump-sprites" {
        nativeBuildInputs = [(pkgs.python3.withPackages (p: [p.pillow]))];
        env = {
          inherit (c) bg bgAlt ui uiAlt muted fgAlt fg accent;
          # walldye's ACCENT_7 and ACCENT_HI: glyph-hexdump's selection band and cursor.
          band = "2E1C19";
          accentHi = "E08A6E";
        };
      } ''
        python3 ${./sprites.py} $out ${pkgs.spleen}/share/fonts/misc/spleen-8x16.bdf
      '';

    script = pkgs.replaceVars ./fireproof.script (
      {font = "${font.monoFamily} 14";}
      // rgb "bg" c.bg
      // rgb "muted" c.muted
    );

    # Plymouth chroots into the real root once it is mounted and the script loads images on
    # first use, so ImageDir has to exist on both sides. NixOS points a path inside the theme
    # dir at an initrd-only copy; the sprites' own store path is in both (initrd storePaths).
    theme = pkgs.runCommand "plymouth-theme-fireproof" {} ''
      dir=$out/share/plymouth/themes/fireproof
      mkdir -p $dir
      cat ${sprites}/data.script ${script} > $dir/fireproof.script
      cat > $dir/fireproof.plymouth <<EOF
      [Plymouth Theme]
      Name=fireproof
      ModuleName=script

      [script]
      ImageDir=${sprites}
      ScriptFile=$dir/fireproof.script
      EOF
    '';

    # The kernel, Plymouth and niri then agree on each mode, so niri's first commit needs no
    # blanking modeset; DRM only matches a whole-number refresh. A disabled output stays dark.
    videoParam = m:
      if !m.enable
      then "video=${m.name}:d"
      else "video=${m.name}:${toString m.resolution.width}x${toString m.resolution.height}@${toString (builtins.floor (m.refreshRateNiri + 0.5))}";
    modedMonitors = lib.filter (m: m.name != null && (!m.enable || (m.resolution.width != null && m.refreshRateNiri != null))) config.fireproof.monitors;

    # Fades the dump out, then lets the greeter's compositor take DRM master while Plymouth's
    # last frame stays on screen.
    handoffStart = pkgs.writeShellScript "plymouth-handoff-start" ''
      ${plymouth} --ping || exit 0
      ${plymouth} update --status=handoff
      sleep 0.5
      ${plymouth} deactivate
    '';
    # Plymouth's framebuffer is freed when it exits, which blanks the screen unless niri has
    # already replaced it; without a niri the plain quit brings the console back.
    handoffFinish = pkgs.writeShellScript "plymouth-handoff-finish" ''
      ${plymouth} --ping || exit 0
      for _ in $(seq 300); do
        if ${lib.getExe' pkgs.procps "pgrep"} -x niri >/dev/null; then
          sleep 2
          exec ${plymouth} quit --retain-splash
        fi
        sleep 0.1
      done
      exec ${plymouth} quit
    '';
  in {
    config = lib.mkIf config.fireproof.desktop.boot-splash.enable {
      boot.plymouth = {
        enable = true;
        theme = "fireproof";
        themePackages = [theme];
        font = "${font.package}/share/fonts/truetype/NerdFonts/Hack/HackNerdFontMono-Regular.ttf";
      };
      boot.initrd.systemd.storePaths = [sprites];

      boot.consoleLogLevel = 3;
      boot.kernelParams =
        [
          "quiet"
          "rd.udev.log_level=3"
          "udev.log_level=3"
          "rd.systemd.show_status=false"
          "systemd.show_status=false"
          "vt.global_cursor_default=0"
        ]
        ++ map videoParam modedMonitors;

      # Colour 0 is the console background, so any console that does show is the same Flexoki.
      console.colors = [c.bg c.red c.green c.yellow c.blue c.magenta c.cyan c.fg c.muted c.red c.green c.yellow c.blue c.magenta c.cyan c.whiteAlt];

      # Any key during the second reveals the menu; reboot-windows bypasses it via BootNext.
      boot.loader.timeout = lib.mkIf config.boot.loader.limine.enable 1;
      boot.loader.limine = {
        extraConfig = "quiet: yes";
        style = {
          wallpapers = [];
          backdrop = c.bg;
          interface = {
            branding = config.fireproof.hostname;
            brandingColor = c.accent;
            helpHidden = true;
          };
          graphicalTerminal = {
            palette = lib.concatStringsSep ";" [c.bg c.red c.green c.yellow c.blue c.magenta c.cyan c.fg];
            brightPalette = lib.concatStringsSep ";" [c.muted c.red c.green c.yellow c.blue c.magenta c.cyan c.whiteAlt];
            background = "00${c.bg}";
            foreground = c.fg;
            brightBackground = c.ui;
            brightForeground = c.whiteAlt;
          };
        };
      };

      # GDM's handoff: deactivate before the greeter starts, quit --retain-splash once niri has
      # drawn. Plymouth's own quit unit would hide the splash before greetd even starts.
      services.greetd.greeterManagesPlymouth = true;
      systemd.services.plymouth-quit.wantedBy = lib.mkForce [];
      systemd.services.greetd = {
        serviceConfig = {
          ExecStartPre = ["-${handoffStart}"];
          # idle holds the greeter until every boot job is dispatched (up to 5 s, usually
          # network-online); it only keeps status lines off a text console, which isn't shown.
          Type = lib.mkForce "simple";
        };
        wants = ["plymouth-handoff.service"];
        onFailure = ["plymouth-quit.service"];
      };
      systemd.services.plymouth-handoff = {
        description = "Hand the Plymouth splash to the compositor";
        after = ["greetd.service"];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = handoffFinish;
        };
      };

      # greetd puts its VT in text mode, which lets the console draw between Plymouth and niri.
      # Every greeter here is graphical, so graphics mode, as GDM does.
      services.greetd.package = pkgs.greetd.overrideAttrs (old: {
        postPatch =
          (old.postPatch or "")
          + ''
            substituteInPlace greetd/src/session/worker.rs \
              --replace-fail "kd_setmode(terminal::KdMode::Text)" "kd_setmode(terminal::KdMode::Graphics)"
          '';
      });
    };
  };
}
