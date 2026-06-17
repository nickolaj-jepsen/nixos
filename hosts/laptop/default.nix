# Selection (aspects + facts) lives in hosts/default.nix.
{
  config = {
    facter.reportPath = ./facter.json;
  };
}
