# Self-contained nix-on-droid config for a phone.
#
# This is a proof of concept. It deliberately does NOT import anything from
# `modules/` — those are NixOS modules wired into the `fireproof.*` option tree
# (systemd, users.users, system-level agenix) and cannot evaluate under
# nix-on-droid. Instead we hand-pick a small set of portable CLI tools and a
# lightweight home-manager config, mirroring a subset of `modules/programs/`.
#
# Secrets (agenix) are scaffolded but INERT until you add the phone's public key
# at `secrets/hosts/phone/id_ed25519.pub` and rekey on your desktop with the
# YubiKey. See ../README.md for the full workflow.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  # The phone is treated as a rekey recipient, like the hosts under
  # `secrets/hosts/`. Until you generate a key on-device and drop its public
  # half here, the whole agenix block stays disabled so the PoC builds as a pure
  # CLI environment.
  phonePubkey = ../../secrets/hosts/phone/id_ed25519.pub;
  secretsEnabled = builtins.pathExists phonePubkey;

  # Where nix-on-droid puts the user home. The on-device private key (generated
  # with `ssh-keygen` inside the app) lives here and is used as the agenix
  # decryption identity. Never commit this private key.
  droidHome = "/data/data/com.termux.nix/files/home";
in {
  # Curated portable CLI packages (cf. modules/programs/core.nix).
  environment.packages = with pkgs; [
    # shell + navigation
    fish
    starship
    zoxide
    fzf
    # editors
    neovim
    # version control
    git
    gh
    delta
    # modern CLI replacements
    bat
    fd
    ripgrep
    eza
    # data wrangling / misc
    jq
    tree
    htop
    curl
    wget
    rsync
    unzip
    openssh
  ];

  # Back up clobbered /etc files instead of failing activation.
  environment.etcBackupExtension = ".bak";

  # Read the nix-on-droid changelog before bumping this.
  system.stateVersion = "24.05";

  # Flakes, so `nix-on-droid switch --flake .#phone` works on-device.
  nix.extraOptions = ''
    experimental-features = nix-command flakes
  '';

  user.shell = "${pkgs.fish}/bin/fish";

  home-manager = {
    useGlobalPkgs = true;
    backupFileExtension = "hm-bak";
    # Make `inputs` available to the HM config (used for the agenix modules).
    extraSpecialArgs = {inherit inputs;};

    config = {
      config,
      lib,
      pkgs,
      inputs,
      ...
    }:
      {
        home.stateVersion = "24.05";

        programs.fish.enable = true;

        programs.starship.enable = true;

        programs.zoxide.enable = true;

        programs.fzf.enable = true;

        programs.bat.enable = true;

        programs.neovim = {
          enable = true;
          defaultEditor = true;
          viAlias = true;
          vimAlias = true;
        };

        programs.git = {
          enable = true;
          settings = {
            user.email = "nickolaj@fireproof.website";
            user.name = "Nickolaj Jepsen";
            init.defaultBranch = "main";
            push.autosetupremote = "true";
            pull.rebase = "true";
          };
        };

        programs.gh = {
          enable = true;
          settings.git_protocol = "ssh";
        };
      }
      # --- agenix secrets scaffold (inert until the phone pubkey exists) -------
      // lib.optionalAttrs secretsEnabled {
        imports = [
          inputs.agenix.homeManagerModules.default
          inputs.agenix-rekey.homeManagerModules.default
        ];

        # Decryption identity: the key you generate ON THE PHONE. agenix uses it
        # at activation to decrypt the rekeyed secrets below.
        age.identityPaths = ["${droidHome}/.ssh/id_ed25519"];

        age.rekey = {
          storageMode = "local";
          hostPubkey = builtins.readFile phonePubkey;
          # Same master key as the rest of the flake (modules/base/secrets.nix):
          # rekeying still happens on your desktop with the YubiKey.
          masterIdentities = [
            {
              identity = ../../secrets/yubikey-identity.pub;
            }
          ];
          extraEncryptionPubkeys = [
            "age1pzrfw28f8qvsk9g8p2stundf4ph466jut0g6q47sse76zljtqy9q2w32zr" # Backup key (bitwarden)
          ];
          localStorageDir = ../../secrets/hosts/phone/.rekey;
          generatedSecretsDir = ../../secrets/hosts/phone;
        };

        # Example user-level secret to prove the path end to end. Add more as
        # needed, then rerun the rekey workflow from ../README.md.
        age.secrets.ssh-key-ao = {
          rekeyFile = ../../secrets/ssh-key-ao.age;
          path = "${droidHome}/.ssh/id_ao";
          mode = "0600";
        };
      };
  };
}
