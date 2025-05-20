{pkgsUnstable, ...}: {
  environment.systemPackages = [
    pkgsUnstable.ferdium
  ];
}
