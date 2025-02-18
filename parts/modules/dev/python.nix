{
  pkgs,
  pkgsUnstable,
  ...
}: {
  environment.systemPackages = [
    pkgsUnstable.uv
    pkgs.python3
  ];
}
