# Home Assistant integration; not in nixpkgs.
{
  unstable,
  fetchFromGitHub,
  inputs,
}: let
  # Built from HA's own python: nixpkgs' requiredPythonModules filter silently drops
  # a library built for any other python derivation from HA's PYTHONPATH.
  zwift-client = unstable.home-assistant.python3Packages.callPackage ./zwift-client.nix {
    src = inputs.zwift-client;
  };
in
  unstable.buildHomeAssistantComponent rec {
    owner = "snicker";
    domain = "zwift";
    version = "v4.1.0";
    src = fetchFromGitHub {
      inherit owner;
      repo = "zwift_hass";
      rev = version;
      hash = "sha256-oQzbkrHSeHKo0I+5nc/z1DQI1VWxrbUHSywOHPM7chI=";
    };
    propagatedBuildInputs = [zwift-client];
  }
