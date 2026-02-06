{
  pkgs,
  pkgsUnstable,
  lib,
  config,
  ...
}: {
  config = lib.mkIf config.fireproof.dev.enable {
    environment.systemPackages = with pkgsUnstable; [
      opencode
      github-copilot-cli
      (claude-code.overrideAttrs
        (_oldAttrs: rec {
          version = "2.1.32";
          src = pkgs.fetchzip {
            url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${version}.tgz";
            hash = "sha256-oN+Pl/SpMpI4JiU+x73Z9lNYwaz2mJpYnc4ssAG+oAo=";
          };
        }))
    ];
  };
}
