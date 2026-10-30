# dev-ao — the work dev server (dev.ao / dev-01), a headless home-manager-only
# host and the standalone-HM portability guard (checks.dev-ao-home builds it).
# A shared Debian box where colleagues have sudo: only work material ships, and
# its Nix is a multi-user install that closures are pushed to (`just switch
# dev-ao nij@dev.ao`), never built on. age.identityPaths is the box's own key.
{
  class = "home";

  # Headless: CLI tooling only — no desktop/gui-* toggles, so nothing pulls a GUI.
  shared = {
    fireproof.hostname = "dev-ao";
    fireproof.username = "nij";

    fireproof.sharedHost.enable = true;
    fireproof.dev.enable = true;
    fireproof.dev.clickhouse.enable = false; # headless server: no need for the clickhouse client
    fireproof.dev.copilot.enable = false;
    fireproof.dev.ai-usage.enable = false;
    fireproof.neovim.full.enable = false;
    fireproof.work.enable = true;
    fireproof.work.sshKey.enable = true; # *.ao hops use the AO key here too
    fireproof.claude-code.work.enable = true;
  };

  homeManager = {
    config,
    lib,
    pkgs,
    ...
  }: let
    # The box's existing key: decrypts HM secrets and is the fallback for non-*.ao hosts.
    boxKey = "${config.home.homeDirectory}/.ssh/id_rsa";
  in {
    age.identityPaths = lib.mkForce [boxKey];

    programs.ssh.settings = {
      "*".IdentityFile = lib.mkForce boxKey;
      # dev-01 sits on the AO network: flex and scw are reachable without a jump (staging is not).
      "flex.ao".ProxyJump = lib.mkForce "none";
      "scw.ao".ProxyJump = "none";
    };
    # secrets/hosts/dev-ao/id_ed25519.pub is the box's RSA key; don't plant it under an ed25519 name.
    home.file.".ssh/id_ed25519.pub".enable = false;

    programs.git.settings.user.email = lib.mkForce "nij@ao.dk";
    home.sessionVariables.AO_USER = "nij";

    # Plain `claude` is the work profile here, so the personal account never logs in.
    home.sessionVariables.CLAUDE_CONFIG_DIR = "${config.home.homeDirectory}/.claude-work";
    programs.fish.shellAliases.claude = "claude-work";
    home.file."${config.home.homeDirectory}/.claude/skills/pricerunner".enable = false;

    home.packages = [pkgs.terraform pkgs.tftui];
  };
}
