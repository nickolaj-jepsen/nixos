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
			"monitor" = ",preferred,auto,1";

				workspace = [
				"1, monitor:eDP-1, default:true"
				"2, monitor:eDP-1"
				"3, monitor:eDP-1"
				"4, monitor:eDP-1"
				"5, monitor:eDP-1"
			]; 

			layerrule = "noanim, wofi";

			input = {
				kb_layout = "dk";
				kb_options = "caps:backspace";
				follow_mouse = "2"; # Cursor focus will be detached from keyboard focus. Clicking on a window will move keyboard focus to that window.

				touchpad = {
					natural_scroll = "no";
				};

				sensitivity = "0"; # -1.0 - 1.0, 0 means no modification.
				accel_profile = "flat";
			};

			general = {
				gaps_in = 5;
				gaps_out = 10;
				border_size = 2;
				#col.active_border = "rgb(cf6a4c)";
				no_cursor_warps = true;
				layout = "dwindle";
			};

			misc = {
				focus_on_activate = true;
			};

			decoration = {
				rounding = 5;
				drop_shadow = true;
				shadow_range = 4;
				shadow_render_power = 3;
				#col.shadow = "rgba(1a1a1aee)";
			};

			"$mod" = "SUPER";
			bind = [
				"$mod, RETURN, exec, kitty"
				"$mod, BACKSPACE, killactive"
				"$mod, SPACE, exec, wofi"

				"$mod, q, workspace, 1"
				"$mod, w, workspace, 2"
				"$mod, e, workspace, 3"
				"$mod, r, workspace, 4"
				"$mod, t, workspace, 5"

				"$mod, left, movefocus, l"
				"$mod, right, movefocus, r"
				"$mod, up, movefocus, u"
				"$mod, down, movefocus, d"
				"$mod, h, movefocus, l"
				"$mod, l, movefocus, r"
				"$mod, k, movefocus, u"
				"$mod, j, movefocus, d"

				"$mod, S, togglefloating," 
				"$mod, A, pseudo," # dwindle
				"$mod, D, fullscreen," # dwindle
				"$mod, BACKSLASH, togglesplit," # dwindle
				"$mod, M, togglegroup," # dwindle

			];
			bindm = [
				"$mod, mouse:272, movewindow"
				"$mod, mouse:273, resizewindow"
			];
		};
  };
}
