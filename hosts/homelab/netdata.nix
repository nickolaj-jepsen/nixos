{
  config,
  pkgsUnstable,
  ...
}: {
  age.secrets.netdata-claim-token.rekeyFile = ../../secrets/netdata-claim-token.age;

  services.netdata = {
    enable = true;
    package = pkgsUnstable.netdataCloud;
    claimTokenFile = "${config.age.secrets.netdata-claim-token.path}";
  };
}
