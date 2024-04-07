{
  username,
  pkgs,
  ...
}: {
  programs.nix-ld = {
    enable = true;
  };

  wsl = {
    enable = true;
    defaultUser = username;
  };

  home-manager.users.${username}.imports = [
    ../../home-manager/wsl.nix
  ];

  # Hacks to enable vscode
  services.vscode-server.enable = true;
  wsl.extraBin = with pkgs; [
    { src = "${coreutils}/bin/uname"; }
    { src = "${coreutils}/bin/dirname"; }
    { src = "${coreutils}/bin/readlink"; }
  ];
}
