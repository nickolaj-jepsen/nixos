{pkgsUnstable, ...}: {
  environment.systemPackages = [
    pkgsUnstable.natscli
  ];
}
