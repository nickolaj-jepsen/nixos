{
  pkgs,
  ...
}: {
  home.packages = with pkgs; [ 
    nodejs_20
	kitty
	alacritty
	wofi
	vscode
	xfce.thunar
	xterm
	foot
	firefox
  ];
  programs.kitty = {
    enable = true;
  };
  wayland.windowManager.hyprland = {
    enable = true;
    package = pkgs.hyprland;
    systemd.enable = true;
	settings = {
	  "$mod" = "SUPER";
      bind = [
	  	"$mod, RETURN, exec, kitty"
	  	"$mod, SPACE, exec, wofi --show drun"
	  ];
	};
  };
}
