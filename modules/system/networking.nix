{config, ...}: {
  networking = {
    hostName = config.fireproof.hostname;
  };
}
