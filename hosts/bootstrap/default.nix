{
  config.fireproof.hostname = "bootstrap";
  config.fireproof.username = "nickolaj";

  imports = [
    ./configuration.nix
    ./disk-configuration.nix
  ];
}
