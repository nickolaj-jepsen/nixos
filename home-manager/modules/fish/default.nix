{
  pkgs,
  config,
  ...
}: {
  home.file."${config.home.homeDirectory}/.config/fish/conf.d/" = { source = ./conf.d; recursive = true;};

  programs.fish = {
    enable = true;
    plugins = with pkgs.fishPlugins; [
      {
        name = "fzf";
        src = fzf.src;
      }
      {
        name = "bobthefish";
        src = bobthefish.src;
      }
      {
        name = "to";
        src = pkgs.fetchFromGitHub {
          owner = "joehillen";
          repo = "to-fish";
          rev = "52b151cfe67c00cb64d80ccc6dae398f20364938";
          hash = "sha256-DfDsU/qY2XdYlkLISIOv02ggHfKEpb+YompNWWjs5/A=";
        };
      }
    ];
  };

  # Init fish from bash
  programs.bash = {
    enable = true;
    initExtra = ''
      if [[ $(${pkgs.procps}/bin/ps --no-header --pid=$PPID --format=comm) != "fish" && -z ''${BASH_EXECUTION_STRING} ]]
      then
        shopt -q login_shell && LOGIN_OPTION='--login' || LOGIN_OPTION=""
        exec ${pkgs.fish}/bin/fish $LOGIN_OPTION
      fi
    '';
  };
}