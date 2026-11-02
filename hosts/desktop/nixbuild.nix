# aarch64-linux only: x86_64 stays local, and binfmt emulation is the fallback when nixbuild.net is unreachable.
# The account must list this host's secrets/hosts/desktop/id_ed25519.pub.
{
  nixos = {config, ...}: {
    nix = {
      distributedBuilds = true;
      settings.builders-use-substitutes = true;
      # phone-vm's agent and compositor; Nix ignores the pocketnix input's own nixConfig.
      settings.substituters = ["https://pocketnix.cachix.org"];
      settings.trusted-public-keys = ["pocketnix.cachix.org-1:KklXzNwjpGzopowh99lwsL3IeaidLtH+Fw7wniLw9Nw="];
      buildMachines = [
        {
          hostName = "eu.nixbuild.net";
          system = "aarch64-linux";
          # nixbuild.net does its own scheduling, so this only caps what Nix submits.
          maxJobs = 100;
          supportedFeatures = ["benchmark" "big-parallel"];
        }
      ];
    };

    # nix-daemon connects as root and can't answer a host-key prompt.
    programs.ssh = {
      knownHosts.nixbuild = {
        hostNames = ["eu.nixbuild.net"];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPIQCZc54poJ8vqawd8TraNryQeJnvH1eLpIDgbiqymM";
      };
      extraConfig = ''
        Host eu.nixbuild.net
          ServerAliveInterval 60
          IdentityFile ${config.age.secrets.ssh-key.path}
      '';
    };
  };
}
