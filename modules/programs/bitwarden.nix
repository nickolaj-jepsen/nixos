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
    # On Linux `unlock` caches the session key in the kernel user keyring:
    # RAM-only, gone on reboot, and expired after 8h, so one unlock serves
    # every terminal. Other commands only pick up a cached key.
    keyring = profile: ''
      key=bw:${profile}
      stored() { keyctl search @u user "$key" 2>/dev/null; }
      raw=false check=false
      for arg in "$@"; do
        case "$arg" in
          --raw) raw=true ;;
          --check) check=true ;;
        esac
      done
      if [ "''${1:-}" = unlock ] && ! $check; then
        # padd replaces the cached key, which this unlock just invalidated.
        if $raw; then BW_SESSION=$(${bw} "$@"); else BW_SESSION=$(${bw} "$@" --raw); fi
        # Without a tty the prompt yields nothing yet still exits 0.
        [ -n "$BW_SESSION" ] || exit 1
        id=$(printf %s "$BW_SESSION" | keyctl padd user "$key" @u)
        keyctl timeout "$id" 28800
        if $raw; then printf %s "$BW_SESSION"; else echo "Vault unlocked for 8 hours." >&2; fi
        exit 0
      fi
      case "''${1:-}" in
        lock | logout)
          if id=$(stored); then keyctl unlink "$id" @u >/dev/null; fi
          ;;
        *)
          if [ -z "''${BW_SESSION:-}" ] && id=$(stored); then
            BW_SESSION=$(keyctl pipe "$id")
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
    # Each extra account needs its own data dir; BW_SESSION_<PROFILE> keeps its
    # session key apart from the personal vault's BW_SESSION.
    mkExtraBw = profile: server:
      mkBw {
        name = "bw-${profile}";
        inherit profile server;
        env = let
          var = "BW_SESSION_${lib.toUpper profile}";
        in ''
          export BITWARDENCLI_APPDATA_DIR="${config.xdg.configHome}/bitwarden-cli-${profile}"
          unset BW_SESSION
          if [ -n "''${${var}:-}" ]; then export BW_SESSION="''$${var}"; fi
        '';
      };
    bwWork = mkExtraBw "work" "https://vault.bitwarden.com";
    bwPersonal = mkBw {
      name = "bw";
      profile = "personal";
      server = "https://vault.bitwarden.com";
    };
    # New saves always land unfiled (Bitwarden has no default folder), so
    # "No folder" is the inbox. Prints item names only, never secrets.
    bwTidy = pkgs.writeShellApplication {
      name = "bw-tidy";
      runtimeInputs = [pkgs.jq];
      text = ''
        ${lib.getExe bwPersonal} sync >/dev/null
        ${lib.getExe bwPersonal} list items | jq -r '
          def host: sub("^[a-z]+://"; "") | (split("/")[0] // "") | sub("^www\\."; "") | ascii_downcase;
          def section($title; $names):
            if ($names | length) > 0 then "\($title) (\($names | length))", ($names[] | "  \(.)"), "" else empty end;
          [.[] | select(.type == 1)] as $logins
          | section("Unfiled"; [.[] | select(.folderId == null) | .name]),
            section("Named after a domain"; [.[] | select(.name | test("^(https?://)?[a-z0-9-]+(\\.[a-z0-9-]+)+(/.*)?$")) | .name]),
            section("Logins without a URI"; [$logins[] | select((.login.uris // []) == []) | .name]),
            section("Logins holding a key (make it an SSH key or note)"; [$logins[] | select(.notes // "" | test("PRIVATE KEY")) | .name]),
            section("Probable duplicates"; [$logins[] | select(.login.username // "" | length > 0)
                | {k: "\(.login.uris // [] | .[0].uri // "" | host)|\(.login.username | ascii_downcase)", name}]
                | map(select(.k | startswith("|") | not)) | group_by(.k) | map(select(length > 1) | map(.name) | join(" = ")))
        '
      '';
    };
  in {
    config = lib.mkIf config.fireproof.desktop.enable (lib.mkMerge [
      {
        home.packages = [
          bwPersonal
          bwTidy
          # Old self-hosted vault, kept while migrating to the cloud.
          (mkExtraBw "self" "https://bitwarden.${config.fireproof.homelab.domain}")
        ];
      }
      (lib.mkIf config.fireproof.work.enable {
        home.packages = [bwWork];
        home.sessionVariables.DS_BW_BIN = lib.getExe bwWork;
      })
    ]);
  };
}
