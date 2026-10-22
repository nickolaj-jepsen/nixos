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
      ++ lib.optional fp.dev.pi.enable {
        id = "anthropic";
        kind = "anthropic-credits";
        name = "Anthropic";
        short = "A";
        icon = "anthropic";
        sessionKeyFile = config.age.secrets.anthropic-console-session.path;
        orgId = "16cf6a94-7fae-421d-9ea6-29787833a032";
      }
      ++ lib.optional hasOpencodeGo {
        id = "opencode-go";
        kind = "opencode-go";
        name = "OpenCode Go";
        short = "OC";
        icon = "opencode";
        keyFile = config.age.secrets.opencode-go-api-key.path;
        # The 7d window moves with the 5h one; the monthly cap is the one that bites.
        windows = ["rolling" "monthly"];
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

      # The Console's browser `sessionKey` cookie (sk-ant-sid…), the only auth its
      # credit balance endpoint takes. Expires about monthly or on Console logout;
      # refresh with `just secret-write <file> force=1`. Literal path: the default
      # secretsDir spelling holds an unexpanded variable, and config.json is literal.
      age.secrets.anthropic-console-session = lib.mkIf fp.dev.pi.enable {
        rekeyFile = ../../secrets/anthropic-console-session.age;
        path = "${config.xdg.configHome}/ai-usage/anthropic-console-session";
        mode = "0600";
      };
    };
  };
}
