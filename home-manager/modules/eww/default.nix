{
  pkgs,
  config,
  ...
}: {
	home.file."${config.xdg.configHome}/eww" = {
  	source = ./config;
  	recursive = true;
	};

  home.packages = with pkgs; [ 
    socat
    eww
  ];
}