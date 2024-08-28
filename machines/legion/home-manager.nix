{
  pkgs,
	config,
  ...
}: {

	nixpkgs.config.permittedInsecurePackages = [
    "electron-25.9.0"  # Obsidian
  ];

  home.packages = with pkgs; [ 
		kitty
		wofi
		xfce.thunar
		xterm
		firefox
		obsidian

		# Dev
    nodejs_20
		supabase-cli
		vscode
		jetbrains.pycharm-professional
		jetbrains.rust-rover
		sublime-merge
  ];
  programs.kitty = {
    enable = true;
  };

	programs.vscode = {
		enable = true;
		enableUpdateCheck = true;
		enableExtensionUpdateCheck = true;
		extensions = with pkgs.vscode-extensions; [
			github.copilot
			ms-python.python
			ms-vscode-remote.remote-ssh
			# ms-vscode-remote.remote-ssh-edit
		];
		userSettings = {
			"window.titleBarStyle" = "custom";
			"remote.SSH.useLocalServer" = false;
			"github.copilot.enable" = {
				"*" = true;
			};
		};
	};

  wayland.windowManager.hyprland = {
    enable = true;
    package = pkgs.hyprland;
    systemd.enable = true;
		settings = {
			"monitor" = ",preferred,auto,1";
			"exec-once" = "eww daemon & eww open primary";

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
					natural_scroll = true;
				};

				sensitivity = "0"; # -1.0 - 1.0, 0 means no modification.
				accel_profile = "flat";
			};

			general = {
				gaps_in = 5;
				gaps_out = 10;
				border_size = 2;
				"col.inactive_border" = "rgb(2f2f2f)";
				"col.active_border" = "rgb(cf6a4c)";
				layout = "dwindle";
			};

			cursor = {
				no_warps = true;
			};

			dwindle = {
				pseudotile = true;
				preserve_split = true;
				force_split = 2;
				use_active_for_splits = true;
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
				"$mod, SPACE, exec, wofi --show drun"

				"$mod, q, workspace, 1"
				"$mod, w, workspace, 2"
				"$mod, e, workspace, 3"
				"$mod, r, workspace, 4"
				"$mod, t, workspace, 5"
				"SUPER_SHIFT, q, movetoworkspace, 1"
				"SUPER_SHIFT, w, movetoworkspace, 2"
				"SUPER_SHIFT, e, movetoworkspace, 3"
				"SUPER_SHIFT, r, movetoworkspace, 4"
				"SUPER_SHIFT, t, movetoworkspace, 5"

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
