{
  flake.modules.nixos.docker = {
    config,
    pkgs,
    lib,
    ...
  }: let
    inherit (config.fireproof) username;
  in {
    environment.systemPackages = [
      pkgs.docker
      pkgs.docker-compose
    ];

    virtualisation.docker = {
      enable = true;
      enableOnBoot = lib.mkDefault false;
      storageDriver = "btrfs";
    };
    virtualisation.oci-containers = {
      backend = "docker";
    };

    users.extraGroups.docker.members = [username];
  };

  # macOS has no native Docker engine: Colima runs it in a Lima VM on Apple's
  # Virtualization.framework, and the host gets the docker CLI client only (the
  # daemon lives in the VM). Gated on dev — a Mac without dev tooling shouldn't
  # spin up a Linux VM.
  flake.modules.darwin.docker = {
    config,
    pkgs,
    lib,
    ...
  }: let
    inherit (config.fireproof) username;
  in {
    config = lib.mkIf config.fireproof.dev.enable {
      environment.systemPackages = [
        pkgs.colima
        pkgs.docker-client
        pkgs.docker-compose
      ];

      # `--foreground` keeps colima attached so launchd's KeepAlive owns the VM
      # lifecycle; `colima start` registers and activates the `colima` docker
      # context, so the plain docker CLI finds the socket with no DOCKER_HOST.
      launchd.user.agents.colima = {
        command = "${pkgs.colima}/bin/colima start --foreground";
        # colima shells out to the docker CLI (context setup) and to base macOS
        # tools; lima/qemu are already baked into the colima wrapper's own PATH.
        path = [pkgs.colima pkgs.docker-client "/usr/bin" "/bin" "/usr/sbin" "/sbin"];
        serviceConfig = {
          RunAtLoad = true;
          KeepAlive = true;
          StandardOutPath = "/Users/${username}/Library/Logs/colima.out.log";
          StandardErrorPath = "/Users/${username}/Library/Logs/colima.err.log";
        };
      };
    };
  };
}
