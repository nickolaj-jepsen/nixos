_: {
  perSystem = {pkgs, ...}: let
    zwift-client = pkgs.python314.pkgs.buildPythonPackage {
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
      propagatedBuildInputs = with pkgs.python314.pkgs; [
        hatchling
        requests
        protobuf
      ];
    };
  in {
    overlayAttrs = {
      homeAssistantCustomComponents = {
        switch_manager = pkgs.buildHomeAssistantComponent rec {
          owner = "Sian-Lee-SA";
          domain = "switch_manager";
          version = "v2.0.5";
          src = pkgs.fetchFromGitHub {
            inherit owner;
            repo = "Home-Assistant-Switch-Manager";
            rev = version;
            hash = "sha256-r4jFwcFLBSvE3/nmZ1f+rvK08vMbmZrQZYWMwoewmVc=";
          };
        };
        zwift = pkgs.buildHomeAssistantComponent rec {
          owner = "snicker";
          domain = "zwift";
          version = "v3.3.5";
          src = pkgs.fetchFromGitHub {
            inherit owner;
            repo = "zwift_hass";
            rev = version;
            hash = "sha256-+lJ6Otp8lT+xVtjiQLSQrqT5cVinRTRPTzS+HB1AxB0=";
          };
          propagatedBuildInputs = [
            zwift-client
          ];
        };
      };
    };
  };
}
