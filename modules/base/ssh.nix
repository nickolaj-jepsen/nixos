{
  config,
  username,
  hostname,
  lib,
  ...
}: let
  # Load all public keys from ../../secrets/hosts/*/id_ed25519.pub
  allHosts = lib.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ../../secrets/hosts));
  publicKeys = map (x: builtins.readFile (../../secrets/hosts + ("/" + x) + "/id_ed25519.pub")) allHosts;
in {
  age.secrets.ssh-key = {
    rekeyFile = ../../secrets/hosts + ("/" + hostname) + /id_ed25519.age;
    path = "/home/" + username + "/.ssh/id_ed25519";
    mode = "0600";
    owner = username;
  };
  age.secrets.ssh-key-ao = {
    rekeyFile = ../../secrets/ssh-key-ao.age;
    mode = "0600";
    owner = username;
  };
  fireproof.home-manager = {
    home.file.".ssh/id_ed25519.pub".source = ../../secrets/hosts + ("/" + hostname) + "/id_ed25519.pub";
    programs.ssh = {
      enable = true;
      forwardAgent = true;
      matchBlocks = {
        "*" = {
          identityFile = "${config.age.secrets.ssh-key.path}";
        };
        server = {
          hostname = "x.nickolaj.com";
          user = "server";
        };
        # Work hostnames definded in ./networking.nix
        "bastion.ao" = {
          user = "nij";
          identityFile = "${config.age.secrets.ssh-key-ao.path}";
        };
        "clickhouse.ao" = {
          user = "ubuntu";
          proxyJump = lib.mkDefault "bastion.ao";
          identityFile = "${config.age.secrets.ssh-key-ao.path}";
        };
        "flex.ao" = {
          user = "nij";
          hostname = "192.168.2.5";
          proxyJump = "bastion.ao";
          identityFile = "${config.age.secrets.ssh-key-ao.path}";
        };
        "scw.ao" = {
          user = "nij";
          proxyJump = lib.mkDefault "dev.ao";
          identityFile = "${config.age.secrets.ssh-key-ao.path}";
        };
        "dev.ao" = {
          user = "nij";
          proxyJump = lib.mkDefault "bastion.ao";
          identityFile = "${config.age.secrets.ssh-key-ao.path}";
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
