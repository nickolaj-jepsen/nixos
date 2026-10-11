# Home Assistant integration; not in nixpkgs, and print notifications need it.
{
  unstable,
  fetchFromGitHub,
}:
unstable.buildHomeAssistantComponent rec {
  owner = "greghesp";
  domain = "bambu_lab";
  version = "v2.2.26";
  src = fetchFromGitHub {
    inherit owner;
    repo = "ha-bambulab";
    rev = version;
    hash = "sha256-9KsIzem7BjImUW+BTnAUYJ7CnU5bFpet7D2HhmOwTbA=";
  };
  dependencies = with unstable.home-assistant.python3Packages; [beautifulsoup4];
}
