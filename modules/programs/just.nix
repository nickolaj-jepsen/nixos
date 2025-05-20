{pkgsUnstable, ...}: {
  environment.systemPackages = [
    pkgsUnstable.just
  ];
}
