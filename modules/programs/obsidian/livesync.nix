# Self-hosted LiveSync connection per vault. The plugin owns its data.json, so it is
# only seeded once from agenix. Customization Sync is on so the phone (not
# Nix-managed) can pull plugins and settings the Nix hosts publish.
{
  flake.modules.homeManager.obsidian-livesync = {
    config,
    lib,
    pkgs,
    ...
  }: let
    inherit (config.fireproof) hostname;
    vaultCfg = config.programs.obsidian.vaults;
    vaults = lib.attrNames vaultCfg;

    passwordPath = config.age.secrets.obsidian-livesync-password.path;
    passphrasePath = config.age.secrets.obsidian-livesync-passphrase.path;
    serverUri = "https://obsidian.${config.fireproof.homelab.domain}";

    settings = ''
      {
        remoteType: "",
        couchDB_URI: $uri,
        couchDB_USER: $user,
        couchDB_PASSWORD: ($password | rtrimstr("\n")),
        couchDB_DBNAME: $db,
        encrypt: true,
        passphrase: ($passphrase | rtrimstr("\n")),
        usePathObfuscation: true,
        deviceAndVaultName: $user,
        syncInternalFiles: false,
        # Customization Sync; applying on a Nix host would hit the read-only store links, so only the phone pulls.
        usePluginSync: true,
        usePluginSyncV2: true,
        # PREFERRED_SETTING_SELF_HOSTED: the wizard applies it to new vaults, but a flat seed is migrated as an old one.
        syncMaxSizeInMB: 50,
        customChunkSize: 60,
        sendChunksBulkMaxSize: 1,
        concurrencyOfReadChunksOnline: 30,
        minimumIntervalOfReadChunksOnline: 25,
        chunkSplitterVersion: "v3-rabin-karp",
        handleFilenameCaseSensitive: false,
        E2EEAlgorithm: "v2",
        # The "LiveSync" sync-mode preset.
        liveSync: true,
        batchSave: false,
        periodicReplication: false,
        syncOnSave: false,
        syncOnEditorSave: false,
        syncOnStart: false,
        syncOnFileOpen: false,
        syncAfterMerge: false
      }
    '';

    # Writes the connection settings in the pre-1.0 flat form, which the plugin
    # migrates into a remote profile on load. Only when absent: the plugin owns the file after.
    seed = pkgs.writeShellApplication {
      name = "obsidian-livesync-seed";
      runtimeInputs = [pkgs.jq pkgs.coreutils];
      text = ''
        # HM's activation unit may run without a session, and agenix's Linux path uses this.
        : "''${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
        ${lib.concatMapStrings (vault: ''
            vault=${vault}
            file="$HOME/${vaultCfg.${vault}.target}/.obsidian/plugins/obsidian-livesync/data.json"
            if [ ! -e "$file" ]; then
              if [ ! -r "${passwordPath}" ] || [ ! -r "${passphrasePath}" ]; then
                echo "obsidian-livesync-seed: secrets not decrypted yet; rerun obsidian-livesync-seed after login" >&2
                exit 0
              fi
              mkdir -p "$(dirname "$file")"
              jq -n \
                --arg uri ${serverUri} \
                --arg user ${hostname} \
                --arg db "$vault" \
                --rawfile password "${passwordPath}" \
                --rawfile passphrase "${passphrasePath}" \
                ${lib.escapeShellArg settings} >"$file"
              chmod 600 "$file"
              echo "obsidian-livesync-seed: wrote $file"
            fi
          '')
          vaults}
      '';
    };
  in {
    config = lib.mkIf config.fireproof.desktop.enable {
      # Per-device CouchDB login; the homelab provisions the same file as this device's user.
      age.secrets.obsidian-livesync-password = {
        rekeyFile = ../../../secrets/obsidian + "/${hostname}.age";
        generator.script = "alnum";
      };
      # LiveSync's end-to-end encryption passphrase, shared by every device; the server never sees it.
      age.secrets.obsidian-livesync-passphrase = {
        rekeyFile = ../../../secrets/obsidian/passphrase.age;
        generator.script = "passphrase";
      };

      # After reloadSystemd so the first switch has agenix's user unit already decrypted.
      home.activation.obsidianLivesyncSeed = lib.hm.dag.entryAfter ["writeBoundary" "reloadSystemd"] ''
        run ${lib.getExe seed}
      '';

      home.packages = [
        seed
        (pkgs.writeShellApplication {
          name = "obsidian-livesync-creds";
          text = ''
            echo "Server URI:  ${serverUri}"
            echo "Username:    ${hostname}"
            echo "Password:    $(tr -d '\n' <"${passwordPath}")"
            echo "Databases:   ${lib.concatStringsSep ", " vaults} (one per vault)"
            echo "Passphrase:  $(tr -d '\n' <"${passphrasePath}")"
          '';
        })
      ];
    };
  };
}
