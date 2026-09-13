# Built from HA's own python: nixpkgs' requiredPythonModules filter silently drops
# a library built for any other python derivation from HA's PYTHONPATH.
{pkgs}: let
  ha = pkgs.unstable.home-assistant;
  zwift-client = ha.python3Packages.buildPythonPackage {
    pname = "zwift-client";
    version = "0.2.0";
    pyproject = true;
    src = pkgs.fetchFromGitHub {
      owner = "nickolaj-jepsen";
      repo = "zwift-client";
      rev = "fb8ec414ef8447b86881ce60da2bacb0c951d1b2";
      hash = "sha256-c6v/D7JxF0xdg5YiHig6DZA2tcZdEUI2UIKZc22CDFY=";
    };
    doCheck = false;
    build-system = [ha.python3Packages.hatchling];
    dependencies = with ha.python3Packages; [
      requests
      protobuf
    ];
  };
in
  pkgs.unstable.buildHomeAssistantComponent rec {
    owner = "snicker";
    domain = "zwift";
    version = "v4.1.0";
    src = pkgs.fetchFromGitHub {
      inherit owner;
      repo = "zwift_hass";
      rev = version;
      hash = "sha256-oQzbkrHSeHKo0I+5nc/z1DQI1VWxrbUHSywOHPM7chI=";
    };
    propagatedBuildInputs = [zwift-client];
  }
