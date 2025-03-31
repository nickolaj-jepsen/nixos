{pkgsUnstable, ...}: {
  environment.systemPackages = [
    pkgsUnstable.clickhouse
    pkgsUnstable.envsubst
  ];
}
