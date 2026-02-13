_: {
  perSystem = {pkgs, ...}: {
    overlayAttrs = {
      claude-code =
        pkgs.claude-code.overrideAttrs
        (_oldAttrs: rec {
          version = "2.1.39";
          src = pkgs.fetchzip {
            url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${version}.tgz";
            hash = "sha256-NLLiaJkU91ZnEcQUWIAX9oUTt+C5fnWXFFPelTtWmdo=";
          };
        });
    };
  };
}
