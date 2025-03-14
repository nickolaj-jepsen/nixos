{pkgsUnstable, ...}: {
  environment.systemPackages = [
    pkgsUnstable.obsidian
  ];
}
