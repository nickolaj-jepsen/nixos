{pkgsUnstable, ...}: {
  environment.systemPackages = [
    pkgsUnstable.claude-code
  ];
}
