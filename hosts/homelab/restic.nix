{
  pkgs,
  config,
  ...
}: {
  environment.systemPackages = with pkgs; [
    restic
  ];

  age.secrets.restic-password.rekeyFile = ../../secrets/hosts/homelab/restic-password.age;
  age.secrets.restic-env.rekeyFile = ../../secrets/hosts/homelab/restic-env.age;

  services.restic.backups.server = {
    repository = "b2:fireproof-backup";
    timerConfig = null;
    passwordFile = "${config.age.secrets.restic-password.path}";
    environmentFile = "${config.age.secrets.restic-env.path}";
  };
}
