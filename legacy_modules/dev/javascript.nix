{
  pkgs,
  pkgsUnstable,
  ...
}: {
  environment.systemPackages = [
    pkgs.nodejs
    pkgsUnstable.pnpm
    pkgs.turbo-unwrapped
  ];
}
