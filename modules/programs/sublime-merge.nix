{
  flake.modules.darwin.sublime-merge = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
      homebrew.casks = ["sublime-merge"];
    };
  };

  flake.modules.homeManager.sublime-merge = {
    config,
    lib,
    pkgs,
    ...
  }: let
    userDir =
      if pkgs.stdenv.isDarwin
      then "${config.home.homeDirectory}/Library/Application Support/Sublime Merge/Packages/User"
      else "${config.xdg.configHome}/sublime-merge/Packages/User";

    # The built-in Open Repository in Terminal substitutes $dir into a command
    # string, not an argv element, so it needs quoting against spaces.
    terminal =
      if pkgs.stdenv.isDarwin
      then "/usr/bin/open -na kitty.app --args"
      else lib.getExe config.programs.kitty.package;

    gitCommand = caption: argv: {
      inherit caption;
      command = "git";
      args = {inherit argv;};
    };

    git = config.programs.git.package;
    gh = config.programs.gh.package;
    wt = lib.getExe pkgs.wt;
    # wt and gh run other commands; a GUI launch may have no HM profile on PATH.
    toolPath = lib.makeBinPath ([git gh pkgs.openssh] ++ lib.optional pkgs.stdenv.isLinux pkgs.xdg-utils);
    setupPath = ''export PATH="${toolPath}:$PATH"'';

    commands = [
      (gitCommand "Stack: Submit (auto titles)" ["sm-submit"])
      (gitCommand "Stack: Sync" ["sm-sync"])
      (gitCommand "PR: Open in Browser" ["sm-pr"])
    ];

    worktreeMenu = [
      (gitCommand "Land $worktree_name with wt" ["sm-land" "$worktree_path"])
      (gitCommand "Close $worktree_name with wt (keeps work on the branch)" ["sm-close" "$worktree_path"])
      {
        caption = "Open $worktree_name in Terminal";
        command = "open_terminal";
        args.dir = "$worktree_path";
      }
    ];

    settings = {
      font_face = config.fireproof.theme.font.monoFamily;
      font_size = 10;
      git_binary = lib.getExe git;
      terminal_command = ''${terminal} --directory="$dir"'';
    };
  in {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
      home.packages = lib.optional pkgs.stdenv.isLinux pkgs.unstable.sublime-merge;

      home.file = {
        # Sublime Merge may create its own preferences on first run.
        "${userDir}/Preferences.sublime-settings" = {
          force = true;
          text = builtins.toJSON settings;
        };
        "${userDir}/Default.sublime-commands".text = builtins.toJSON commands;
        "${userDir}/Worktree.sublime-menu".text = builtins.toJSON worktreeMenu;
      };

      programs.git.settings.alias = {
        # Git appends the menu's argument itself, so a plain alias takes no $1.
        # Close has to leave the target before wt will close it.
        sm-land = ''!${setupPath}; exec ${wt} land --'';
        sm-close = ''!f() { ${setupPath}; cd / && exec ${wt} close -- "$1"; }; f'';
        sm-submit = "!${setupPath}; exec ${lib.getExe gh} stack submit --auto";
        sm-sync = "!${setupPath}; exec ${lib.getExe gh} stack sync";
        sm-pr = "!${setupPath}; exec ${lib.getExe gh} pr view --web";
      };
    };
  };
}
