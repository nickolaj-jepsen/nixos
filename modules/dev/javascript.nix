{
  pkgs,
  ...
}: {
  environment.systemPackages = [
    pkgs.nodejs_22
  ];

}
