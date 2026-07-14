# Pi coding agent via pi.nix; the package roster is based on the lazypi
# catalog (https://lazypi.org).
#
# The packages array is authoritative: pi.nix jq-merges settings into
# ~/.pi/agent/settings.json on every launch and arrays replace wholesale —
# imperative `pi install`/`pi remove` edits revert at next start, and entries
# removed here stop loading but leave their download in ~/.pi/agent/{npm,git}.
{
  flake.modules.homeManager.pi = {
    config,
    lib,
    inputs,
    ...
  }: {
    imports = [inputs.pi.homeModules.default];

    config = lib.mkIf config.fireproof.dev.pi.enable {
      programs.pi.coding-agent = {
        enable = true;
        # Shared with claude-code and copilot (agents.nix); keep it agent-agnostic.
        rules = builtins.readFile ./agent-context.md;
        skills = [
          # pi parses any root-level *.md as a skill, so the repo README would warn.
          (builtins.path {
            name = "pi-skills";
            path = ../../skills;
            filter = path: _type: baseNameOf path != "README.md";
          })
        ];
        # Nix-built pi can't self-update; extension-update notices still show.
        environment.PI_SKIP_VERSION_CHECK = "1";
        settings.packages = [
          # extension-settings must load before powerbar (its settings panel).
          "npm:@juanibiapina/pi-extension-settings"
          # core
          "npm:pi-subagents"
          "npm:pi-ask-user"
          "npm:pi-mcp-adapter"
          "npm:pi-web-access"
          "git:github.com/VandeeFeng/pi-memory-md@2c6e1948f0a594bf904c5f9dcd92a16be96710d9"
          "npm:@devkade/pi-plan"
          "npm:pi-simplify"
          # Claude Code CLI login as model provider — no API key in the flake.
          "npm:pi-claude-cli"
          # guardrails
          "npm:@gotgenes/pi-permission-system"
          # feedback + context diet
          "npm:pi-lens"
          "npm:@hypabolic/pi-hypa"
          # ui
          "npm:pi-slopchop"
          "npm:@juanibiapina/pi-powerbar"
          "npm:@tmustier/pi-usage-extension"
          "npm:@tmustier/pi-raw-paste"
          "npm:@juicesharp/rpiv-todo"
          "npm:@ayulab/pi-rewind"
        ];
      };

      # Nix-owned (read-only), so pi's "persist globally" approval won't stick;
      # session approvals still work.
      home.file.".pi/agent/extensions/pi-permission-system/config.json".text = builtins.toJSON {
        permission = {
          "*" = "allow";
          path = {
            "*.env" = "deny";
            "*.env.*" = "deny";
            "*.env.example" = "allow";
          };
          bash = {
            "rm -rf /" = "deny";
            "sudo rm *" = "deny";
            "rm -rf *" = "ask";
            "sudo *" = "ask";
            "git push --force*" = "ask";
          };
        };
      };
    };
  };
}
