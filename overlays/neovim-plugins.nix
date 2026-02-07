_: {
  perSystem = {pkgs, ...}: {
    overlayAttrs = {
      vimPlugins =
        pkgs.vimPlugins
        // {
          darcula-nvim = pkgs.vimUtils.buildVimPlugin {
            pname = "darcula";
            version = "2024-10-01";
            src = pkgs.fetchFromGitHub {
              owner = "doums";
              repo = "darcula";
              rev = "faf8dbab27bee0f27e4f1c3ca7e9695af9b1242b";
              sha256 = "sha256-Gn+lmlYxSIr91Bg3fth2GAQou2Nd1UjrLkIFbBYlmF8=";
            };
          };
        };
    };
  };
}
