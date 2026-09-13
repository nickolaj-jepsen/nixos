# Not in nixpkgs; print notifications need it.
{pkgs}:
pkgs.unstable.buildHomeAssistantComponent rec {
  owner = "greghesp";
  domain = "bambu_lab";
  version = "v2.2.26";
  src = pkgs.fetchFromGitHub {
    inherit owner;
    repo = "ha-bambulab";
    rev = version;
    hash = "sha256-9KsIzem7BjImUW+BTnAUYJ7CnU5bFpet7D2HhmOwTbA=";
  };
  dependencies = with pkgs.unstable.home-assistant.python3Packages; [beautifulsoup4];
}
