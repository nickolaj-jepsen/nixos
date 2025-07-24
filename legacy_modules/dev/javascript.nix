{pkgs, pkgsUnstable, ...}: {
  environment.systemPackages = [
    pkgs.nodejs
    pkgsUnstable.pnpm
    pkgsUnstable.turbo-unwrapped
  ];
}
