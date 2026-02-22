{inputs, ...}: {
  perSystem = {system, ...}: let
    pkgsUnstable = import inputs.nixpkgs-unstable {
      inherit system;
    };
  in {
    overlayAttrs = {
      gh-aw = pkgsUnstable.buildGoModule rec {
        pname = "gh-aw";
        version = "0.48.4";

        src = pkgsUnstable.fetchFromGitHub {
          owner = "github";
          repo = "gh-aw";
          tag = "v${version}";
          hash = "sha256-nQGOQg+T7x7JFYM4AX/aNP8cU7scBFgC6rodoUsdaV4=";
        };

        vendorHash = "sha256-+ZHxdKuQDyJhWVykdC3LwuC7UT5ra6yoNmIkpI53k+E=";

        ldflags = [
          "-s"
          "-w"
          "-X main.version=${version}"
        ];

        subPackages = ["cmd/gh-aw"];

        meta = {
          description = "GitHub Agentic Workflows";
          homepage = "https://github.com/github/gh-aw";
        };
      };
    };
  };
}
