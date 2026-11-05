{
  flake.modules.homeManager.just = {pkgs, ...}: {
    home.packages =
      [
        pkgs.unstable.just
      ]
      # `just try` sandboxes one program under an overlay of $HOME; bubblewrap is Linux-only.
      ++ pkgs.lib.optionals pkgs.stdenv.isLinux [pkgs.bubblewrap];
  };
}
