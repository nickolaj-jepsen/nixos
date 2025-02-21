{pkgsUnstable, ...}: {
  environment.systemPackages = [
    pkgsUnstable.slack
  ];
}
