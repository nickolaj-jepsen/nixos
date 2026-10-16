{
  flake.modules.homeManager.ai-usage = {
    config,
    lib,
    pkgs,
    ...
  }: let
    fp = config.fireproof;
    home = config.home.homeDirectory;
    # Same condition agents.nix deploys the OpenCode Go key under.
    hasOpencodeGo = fp.dev.pi.enable || fp.dev.opencode.enable;

    providers =
      [
        {
          id = "claude";
          kind = "claude";
          name = "Claude";
          short = "C";
          icon = "claude";
          configDir = "${home}/.claude";
          clientVersion = pkgs.claude-code.version;
        }
      ]
      ++ lib.optional fp.claude-code.work.enable {
        id = "claude-work";
        kind = "claude";
        name = "Claude (work)";
        short = "CW";
        icon = "claude";
        badge = "W";
        configDir = "${home}/.claude-work";
        clientVersion = pkgs.claude-code.version;
      }
      ++ lib.optional hasOpencodeGo {
        id = "opencode-go";
        kind = "opencode-go";
        name = "OpenCode Go";
        short = "OC";
        icon = "opencode";
        keyFile = config.age.secrets.opencode-go-api-key.path;
      }
      ++ lib.optional config.programs.github-copilot-cli.enable {
        id = "copilot";
        kind = "copilot";
        name = "Copilot";
        short = "GH";
        icon = "copilot";
        gh = lib.getExe config.programs.gh.package;
      };
  in {
    config = lib.mkIf fp.dev.ai-usage.enable {
      home.packages = [pkgs.ai-usage];
      xdg.configFile."ai-usage/config.json".text = builtins.toJSON {inherit providers;};
    };
  };
}
