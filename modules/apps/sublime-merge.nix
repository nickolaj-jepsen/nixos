{pkgsUnstable, ...}: {
  environment.systemPackages = [
    pkgsUnstable.sublime-merge
  ];
}
