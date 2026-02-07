_: {
  perSystem = {pkgs, ...}: let
    zwift-client = pkgs.python313.pkgs.buildPythonPackage {
      pname = "zwift-client";
      version = "0.2.0";
      pyproject = true;
      src = pkgs.fetchFromGitHub {
        owner = "nickolaj-jepsen";
        repo = "zwift-client";
        rev = "882fb881f1271dc104fd0250cab4ceb6e3710a59";
        hash = "sha256-4gOlWG+QVwODlIhiNH7rhiD0rzNv2WxY2ty9o/51eHU=";
      };
      doCheck = false;
      propagatedBuildInputs = with pkgs.python313.pkgs; [
        hatchling
        requests
        protobuf
      ];
    };
  in {
    overlayAttrs = {
      homeAssistantCustomComponents = {
        bambu_lab = pkgs.buildHomeAssistantComponent rec {
          owner = "greghesp";
          domain = "bambu_lab";
          version = "v2.2.20";
          src = pkgs.fetchFromGitHub {
            inherit owner;
            repo = "ha-bambulab";
            rev = version;
            hash = "sha256-lKKfPWWcri2OUM9nkdY2iltvIaoFhnUP4HGBGDUnEww=";
          };
          propagatedBuildInputs = with pkgs.python313.pkgs; [
            beautifulsoup4
          ];
        };
        switch_manager = pkgs.buildHomeAssistantComponent rec {
          owner = "Sian-Lee-SA";
          domain = "switch_manager";
          version = "v2.0.4b";
          src = pkgs.fetchFromGitHub {
            inherit owner;
            repo = "Home-Assistant-Switch-Manager";
            rev = version;
            hash = "sha256-W9xO3JjnRKHk/dlXMA6y5nEJl/KsGzPvJoumGw+nohw=";
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
