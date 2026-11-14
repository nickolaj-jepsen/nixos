# One-shot moves of user data; see docs/modules.md "Migrating user data". Runs
# before checkLinkTargets so a migration can clear the way for a new home.file.
{
  flake.modules.homeManager.migrations = {
    config,
    lib,
    pkgs,
    ...
  }: let
    migrate = pkgs.writeShellApplication {
      name = "hm-migrate";
      runtimeInputs = with pkgs; [coreutils findutils git jq python3 agent-notes];
      runtimeEnv = {
        MIGRATIONS = builtins.path {
          path = ../../migrations;
          name = "migrations";
        };
        STAMPS = "${config.xdg.stateHome}/fireproof/migrations";
      };
      text = ''
        mkdir -p "$STAMPS"
        for script in "$MIGRATIONS"/*; do
          name=''${script##*/}
          id=''${name%.*}
          case $name in
            *.py) cmd=(python3 -I "$script") ;;
            *.sh) cmd=(bash "$script") ;;
            *) continue ;;
          esac
          [ -e "$STAMPS/$id" ] && continue
          echo "migration $id"
          if "''${cmd[@]}"; then
            date -Is >"$STAMPS/$id"
          else
            echo "migration $id failed; it runs again on the next activation" >&2
          fi
        done
      '';
    };
  in {
    home.activation.migrations = lib.hm.dag.entryBefore ["checkLinkTargets"] ''
      run ${lib.getExe migrate}
    '';
  };
}
