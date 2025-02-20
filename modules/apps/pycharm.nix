{pkgsUnstable, ...}: {
  environment.systemPackages = [
    pkgsUnstable.jetbrains.pycharm-professional
  ];
}
