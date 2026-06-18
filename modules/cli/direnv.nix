{
  flake.modules.homeManager.direnv = {config, ...}: {
    config = {
      programs.direnv = {
        enable = true;
        nix-direnv.enable = true;
        config = {
          global = {
            hide_env_diff = true;
            warn_timeout = "1m";
          };
          whitelist.prefix = ["${config.home.homeDirectory}/nixos"];
        };
      };
      # Silence the per-load "direnv: loading…/export N vars" banner (complements
      # hide_env_diff) so cd-ing into whitelisted dirs stays quiet.
      home.sessionVariables.DIRENV_LOG_FORMAT = "";
    };
  };
}
