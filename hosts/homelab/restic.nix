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

  services.restic.backups.homelab = {
    repository = "b2:fireproof-backup";
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
    passwordFile = "${config.age.secrets.restic-password.path}";
    environmentFile = "${config.age.secrets.restic-env.path}";
    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 5"
      "--keep-monthly 12"
      "--keep-yearly 75"
    ];
  };
}
