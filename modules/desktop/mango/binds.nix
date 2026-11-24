# niri/binds.nix in mango's terms; binds niri has and mango lacks are noted where they'd go.
{fpLib, ...}: {
  flake.modules.homeManager.mango-binds = {
    config,
    lib,
    pkgs,
    ...
  }: let
    primary = fpLib.primaryMonitorName config.fireproof.monitors;
    # Opens zed-scratch's note; mango's toggle_named_scratchpad shows and hides it after that.
    scratchFile = "${config.xdg.dataHome}/scratch/scratch.md";
    openScratch = lib.getExe (pkgs.writeShellScriptBin "mango-scratch" ''
      mkdir -p ${dirOf scratchFile}
      touch -a ${scratchFile}
      exec ${app} zeditor ${scratchFile}
    '');
    # niri runs what it spawns in app-niri-<name>-<id>.scope under app.slice (CPU weights, oomd);
    # mango forks into its own service, session.slice.
    app = lib.getExe (pkgs.writeShellScriptBin "mango-app" ''
      exec systemd-run --user --scope --quiet --collect --slice=app.slice \
        --unit="app-mango-$(basename "$1")-$RANDOM$RANDOM" -- "$@"
    '');
    # niri pins workspaces 01-05 to the primary monitor; mango's tags are per monitor.
    workspaceKeys = ["q" "w" "e" "r" "t"];
    workspaceBinds = lib.concatLists (lib.imap1 (n: key:
      if primary != ""
      then [
        "SUPER,${key},viewcrossmon,${toString n},${primary}"
        "SUPER+SHIFT,${key},tagcrossmon,${toString n},${primary}"
      ]
      else [
        "SUPER,${key},view,${toString n}"
        "SUPER+SHIFT,${key},tag,${toString n}"
      ])
    workspaceKeys);
  in {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.desktop.mango.enable && pkgs.stdenv.isLinux) {
      wayland.windowManager.mango.settings = {
        bindl = [
          "NONE,XF86AudioRaiseVolume,spawn,dms ipc audio increment 3"
          "NONE,XF86AudioLowerVolume,spawn,dms ipc audio decrement 3"
          "NONE,XF86AudioMute,spawn,dms ipc audio mute"
          "NONE,XF86AudioMicMute,spawn,dms ipc audio micmute"
          "NONE,XF86MonBrightnessUp,spawn,dms ipc brightness increment 5 \"\""
          "NONE,XF86MonBrightnessDown,spawn,dms ipc brightness decrement 5 \"\""
          "NONE,XF86AudioPlay,spawn,dms ipc mpris playPause"
          "NONE,XF86AudioNext,spawn,dms ipc mpris next"
          "NONE,XF86AudioPrev,spawn,dms ipc mpris previous"
          "NONE,XF86AudioStop,spawn,dms ipc mpris stop"
        ];
        # Pause shares Play's keycode; a keysym bind keeps mango from calling it a conflict.
        bindsl = ["NONE,XF86AudioPause,spawn,dms ipc mpris playPause"];

        bind =
          [
            # A scratch note: zed where there is one, else the DMS notepad.
            (
              if config.fireproof.dev.enable
              then "SUPER,n,toggle_named_scratchpad,^dev\\.zed\\.Zed$,^scratch\\.md( |$),${openScratch}"
              else "SUPER,n,spawn,dms ipc notepad toggle"
            )
            "SUPER+SHIFT,n,spawn,dms ipc notifications toggle"
            "SUPER,v,spawn,dms ipc clipboard toggle"
            "SUPER,space,spawn,dms ipc spotlight toggle"
            "SUPER,semicolon,spawn,dms ipc spotlight toggleQuery :"
            "SUPER,p,spawn,dms ipc powermenu toggle"
            (
              if config.fireproof.dev.agent-hub.enable
              then "SUPER,b,spawn,dms ipc widget toggle agentHub"
              else "SUPER,b,spawn,dms ipc dash toggle \"\""
            )
            # Mod+Shift+B / Mod+Ctrl+B (agent-hub focus-next / toggle) and Mod+D
            # (niri-dynamic-workspaces) read niri's IPC, so they have no mango bind.
            "SUPER+SHIFT,comma,spawn,dms ipc settings focusOrToggle"
            "SUPER+SHIFT,Escape,spawn,dms ipc processlist focusOrToggle"
            "SUPER+SHIFT,i,spawn,dms ipc inhibit toggle"
            "SUPER+ALT,l,spawn,dms ipc lock lock"
            "SUPER+CTRL,n,spawn,dms ipc notifications toggleDoNotDisturb"
            "SUPER+SHIFT,p,spawn,dms ipc color-picker toggle"

            "SUPER,Left,focusdir,left"
            "SUPER,Down,focusdir,down"
            "SUPER,Up,focusdir,up"
            "SUPER,Right,focusdir,right"
            "SUPER,h,focusdir,left"
            "SUPER,j,focusdir,down"
            "SUPER,k,focusdir,up"
            "SUPER,l,focusdir,right"

            "SUPER+SHIFT,Left,move_client,left"
            "SUPER+SHIFT,Down,exchange_client,down"
            "SUPER+SHIFT,Up,exchange_client,up"
            "SUPER+SHIFT,Right,move_client,right"
            "SUPER+SHIFT,h,move_client,left"
            "SUPER+SHIFT,j,exchange_client,down"
            "SUPER+SHIFT,k,exchange_client,up"
            "SUPER+SHIFT,l,move_client,right"
            # Mod+Home/End (first/last column) have no mango dispatcher.

            "SUPER+CTRL,Left,focusmon,left"
            "SUPER+CTRL,Down,focusmon,down"
            "SUPER+CTRL,Up,focusmon,up"
            "SUPER+CTRL,Right,focusmon,right"
            "SUPER+CTRL,h,focusmon,left"
            "SUPER+CTRL,j,focusmon,down"
            "SUPER+CTRL,k,focusmon,up"
            "SUPER+CTRL,l,focusmon,right"

            "SUPER,f,togglemaximizescreen"
            "SUPER+SHIFT,f,togglefullscreen"
            # Mod+M: mango's scroller has no tabbed columns.
            "SUPER,a,toggleworkspaceoverview,scroll_occupied"
            "SUPER,s,togglefloating"
            "SUPER,c,switch_proportion_preset,next"

            # niri's ±5% of a 2560 px monitor.
            "SUPER,x,resizewin,+128,+0"
            "SUPER+SHIFT,x,resizewin,-128,+0"
            "SUPER+CTRL,x,set_proportion,1.0"
            "SUPER,z,resizewin,+0,+72"
            "SUPER+SHIFT,z,resizewin,+0,-72"

            # consume-or-expel-window-left/right
            "SUPER,comma,scroller_stack,left"
            "SUPER,period,scroller_stack,right"

            # Mod+Print: region grab annotated in satty. The others copy to the clipboard only,
            # like niri's built-in screenshots with screenshot-path null.
            "SUPER,Print,spawn,${app} screenshot"
            "NONE,Print,spawn,dms screenshot --no-file"
            "CTRL,Print,spawn,dms screenshot full --no-file"
            "ALT,Print,spawn,dms screenshot window --no-file"

            "SUPER,slash,spawn,dms ipc call keybinds toggle mangowc"

            # niri's built-in recent-windows switcher. mango has no same-app variant (Alt+grave).
            "ALT,Tab,switcher,all_next"
            "ALT+SHIFT,Tab,switcher,all_prev"
            "SUPER,Tab,switcher,all_next"
            "SUPER+SHIFT,Tab,switcher,all_prev"

            "SUPER,Return,spawn,${app} kitty"
            "SUPER,BackSpace,killclient"
            # SIGKILL, what window-kill does under niri.
            "SUPER+SHIFT,BackSpace,killclient,force"
          ]
          ++ workspaceBinds;

        axisbind = [
          "SUPER,DOWN,focusdir,right"
          "SUPER,UP,focusdir,left"
          "SUPER,RIGHT,focusdir,right"
          "SUPER,LEFT,focusdir,left"
          "SUPER+SHIFT,DOWN,viewtoright_have_client"
          "SUPER+SHIFT,UP,viewtoleft_have_client"
          "SUPER+SHIFT,RIGHT,move_client,right"
          "SUPER+SHIFT,LEFT,move_client,left"
        ];

        # niri's default Mod+drag to move and Mod+right-drag to resize.
        mousebind = [
          "SUPER,btn_left,moveresize,curmove"
          "SUPER,btn_right,moveresize,curresize"
        ];
      };
    };
  };
}
