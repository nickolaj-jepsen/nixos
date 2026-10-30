# Bitwarden desktop on darwin: a Homebrew cask. The vault is account-synced, so
# there's no declarative HM half beyond the CLI.
{
  flake.modules.darwin.bitwarden = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      homebrew.casks = ["bitwarden"];
    };
  };
  flake.modules.homeManager.bitwarden = {
    config,
    lib,
    pkgs,
    ...
  }: let
    bw = lib.getExe pkgs.bitwarden-cli;
    # On Linux the session key is cached in the kernel user keyring: RAM-only,
    # gone on reboot, and expired after 8h, so one unlock serves every terminal.
    keyring = profile: ''
      key=bw:${profile}
      stored() { keyctl search @u user "$key" 2>/dev/null; }
      case "''${1:-}" in
        # unlock mints a new session key, which invalidates the stored one.
        lock | logout | unlock)
          if id=$(stored); then keyctl unlink "$id" @u >/dev/null; fi
          ;;
        "" | login | config | status | update | completion | generate | encode | help | -h | --help | -v | --version) ;;
        *)
          if [ -z "''${BW_SESSION:-}" ]; then
            if id=$(stored); then
              BW_SESSION=$(keyctl pipe "$id")
            else
              BW_SESSION=$(${bw} unlock --raw)
              # Without a tty the prompt yields nothing yet still exits 0.
              [ -n "$BW_SESSION" ] || exit 1
              id=$(printf %s "$BW_SESSION" | keyctl padd user "$key" @u)
              keyctl timeout "$id" 28800
            fi
            export BW_SESSION
          fi
          ;;
      esac
    '';
    # The server URL lives in data.json beside the login state, and bw only
    # accepts a change while logged out, so set it right before each login.
    mkBw = {
      name,
      profile,
      server,
      env ? "",
    }:
      pkgs.writeShellApplication {
        inherit name;
        runtimeInputs = lib.optional pkgs.stdenv.isLinux pkgs.keyutils;
        text = ''
          ${env}
          if [ "''${1:-}" = login ]; then ${bw} config server ${server} >/dev/null; fi
          ${lib.optionalString pkgs.stdenv.isLinux (keyring profile)}
          exec ${bw} "$@"
        '';
      };
    # A second account needs its own data dir; BW_SESSION_WORK keeps its
    # session key apart from the personal vault's BW_SESSION.
    bwWork = mkBw {
      name = "bw-work";
      profile = "work";
      server = "https://vault.bitwarden.com";
      env = ''
        export BITWARDENCLI_APPDATA_DIR="${config.xdg.configHome}/bitwarden-cli-work"
        unset BW_SESSION
        if [ -n "''${BW_SESSION_WORK:-}" ]; then export BW_SESSION="$BW_SESSION_WORK"; fi
      '';
    };
  in {
    config = lib.mkIf config.fireproof.desktop.enable (lib.mkMerge [
      {
        home.packages = [
          (mkBw {
            name = "bw";
            profile = "personal";
            server = "https://bitwarden.${config.fireproof.homelab.domain}";
          })
        ];
      }
      (lib.mkIf config.fireproof.work.enable {
        home.packages = [bwWork];
        home.sessionVariables.DS_BW_BIN = lib.getExe bwWork;
      })
    ]);
  };
}
