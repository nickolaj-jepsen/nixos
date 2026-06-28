# Tells Claude Code when you're at this desktop, so it suppresses mobile push
# notifications while you're actively using the machine.
{
  flake.modules.homeManager.claude-presence = {
    pkgs,
    config,
    lib,
    ...
  }: let
    # Claude Code reads this (existence only, contents ignored). Driven by input
    # activity on desktop hosts; absent on headless hosts, which therefore always notify.
    presenceFile = "${config.xdg.cacheHome}/claude-code/presence";

    # Idle past this many seconds (no keyboard/mouse) counts as "away". niri's
    # idle-inhibit keep-awake bind pauses this, so video playback stays present.
    presenceIdleSeconds = 300;

    presenceSet = pkgs.writeShellScript "claude-presence-set" ''
      mkdir -p "$(dirname ${presenceFile})" && touch ${presenceFile}
    '';
    presenceClear = pkgs.writeShellScript "claude-presence-clear" ''
      rm -f ${presenceFile}
    '';
  in {
    programs.claude-code.settings.env.CLAUDE_CLIENT_PRESENCE_FILE = presenceFile;

    # Drive the marker from input activity via swayidle (niri's ext-idle-notify-v1),
    # independent of lock state. Present at login and on any activity; cleared after
    # the idle threshold, before sleep, and at logout.
    systemd.user.services.claude-presence = lib.mkIf (config.fireproof.desktop.enable && pkgs.stdenv.isLinux) {
      Unit = {
        Description = "Mark Claude Code client presence from input activity";
        PartOf = ["graphical-session.target"];
        After = ["graphical-session.target"];
      };
      Service = {
        ExecStartPre = presenceSet;
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.swayidle}/bin/swayidle -w"
          "timeout ${toString presenceIdleSeconds} ${presenceClear}"
          "resume ${presenceSet}"
          "before-sleep ${presenceClear}"
        ];
        ExecStopPost = presenceClear;
        Restart = "on-failure";
      };
      Install.WantedBy = ["graphical-session.target"];
    };
  };
}
