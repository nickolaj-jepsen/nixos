# Home Assistant integration; not in nixpkgs, and print notifications need it.
{
  unstable,
  fetchFromGitHub,
}:
unstable.buildHomeAssistantComponent rec {
  owner = "greghesp";
  domain = "bambu_lab";
  version = "v2.4.1";
  src = fetchFromGitHub {
    inherit owner;
    repo = "ha-bambulab";
    rev = version;
    hash = "sha256-yMWlv7sjhi5r7ZRKRF4z71VBDVWridMKDrwlW3U5oC4=";
  };
  dependencies = with unstable.home-assistant.python3Packages; [beautifulsoup4];
}
