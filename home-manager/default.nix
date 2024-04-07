{
  pkgs,
  inputs,
  username,
  ...
}: {
  imports = [
    ./modules/fish/default.nix
    ./modules/nixvim/default.nix
  ];

  nixpkgs = {
    config = {
      allowUnfree = true;
      allowUnfreePredicate = _: true;
    };
  };

  home = {
    username = username;
    homeDirectory = "/home/${username}";
  };

  home.packages = with pkgs; [
    fzf
    ripgrep
    fd
    git
    jq
    httpie
    git
    gh
  ];

  programs.git = {
    enable = true;
    userName = "Nickolaj Jepsen";
    userEmail = "nickolaj@fireproof.website";
    extraConfig = {
      push = {
        autoSetupRemote = true;
      };
      pull = {
        rebase = true;
      };
    };
  };

  home.stateVersion = "23.11";
}
