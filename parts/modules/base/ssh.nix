{
  config,
  username,
  hostname,
  lib,
  ...
}: let
  # Load all public keys from ../../../secrets/hosts/*/id_ed25519.pub
  allHosts = lib.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ../../../secrets/hosts));
  publicKeys = map (x: builtins.readFile (../../../secrets/hosts + ("/" + x) + "/id_ed25519.pub")) allHosts;
in {
  age.secrets.ssh-key = {
    rekeyFile = ../../../secrets/hosts + ("/" + hostname) + /id_ed25519.age;
    mode = "0600";
    owner = username;
  };
  age.secrets.ssh-key-ao = {
    rekeyFile = ../../../secrets/ssh-key-ao.age;
    mode = "0600";
    owner = username;
  };
  fireproof.home-manager = {
    programs.ssh = {
      enable = true;
      forwardAgent = true;
      matchBlocks = {
        "*" = {
          identityFile = "${config.age.secrets.ssh-key.path}";
        };
        # Work hostnames definded in ./networking.nix
        "*.ao" = {
          user = "nij";
          identityFile = "${config.age.secrets.ssh-key-ao.path}";
        };
        "dev.ao,scw.ao".proxyJump = "bastion.ao";
        "clickhouse.ao".user = "ubuntu";
        "flex.ao" = {
          hostname = "192.168.2.5";
          proxyJump = "bastion.ao";
        };
      };
    };
  };

  programs.ssh.startAgent = true;
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
    settings.KbdInteractiveAuthentication = false;
  };

  users.users.${username}.openssh.authorizedKeys.keys = publicKeys;
}
