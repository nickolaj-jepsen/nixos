{
  flake.modules.nixos.homelab-notify = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.homelab.enable {
      # #sys-info: every in-repo sender reads DISCORD_WEBHOOK_SYS_INFO from this file.
      age.secrets.discord-webhook-sys-info.rekeyFile = ../../secrets/hosts/homelab/discord-webhook-sys-info.age;
    };
  };
}
