# Home Assistant integration; not in nixpkgs, and print notifications need it.
{
  unstable,
  fetchFromGitHub,
}:
unstable.buildHomeAssistantComponent rec {
  owner = "greghesp";
  domain = "bambu_lab";
  version = "v2.4.0";
  src = fetchFromGitHub {
    inherit owner;
    repo = "ha-bambulab";
    rev = version;
    hash = "sha256-en/2UJ19JJ7HRNHIft7QMN8cQVVJ3tFpmyTjnsZRD5I=";
  };
  dependencies = with unstable.home-assistant.python3Packages; [beautifulsoup4];
}
