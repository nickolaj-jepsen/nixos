# Home Assistant integration; not in nixpkgs, and print notifications need it.
{
  unstable,
  fetchFromGitHub,
}:
unstable.buildHomeAssistantComponent rec {
  owner = "greghesp";
  domain = "bambu_lab";
  version = "v2.3.0";
  src = fetchFromGitHub {
    inherit owner;
    repo = "ha-bambulab";
    rev = version;
    hash = "sha256-FqN+CKS17fv3f3AoqUxEGhjLXvTIWRcDPmrOHWLEpiI=";
  };
  dependencies = with unstable.home-assistant.python3Packages; [beautifulsoup4];
}
