{
  lib,
  stdenv,
  writeShellApplication,
  coreutils,
  findutils,
  gawk,
  jq,
  git,
  newt,
  libnotify,
  ...
}: let
  # Concatenated rather than sourced so shellcheck sees the whole program.
  text = lib.concatMapStrings (file: builtins.readFile file) [
    ./head.sh
    ./tmp.sh
    ./gcroots.sh
    ./repo.sh
  ];
in
  writeShellApplication {
    name = "janitor";
    inherit text;
    # whiptail and notify-send are what only a Linux desktop needs: the checklist
    # and the toasts. On darwin the wrappers still need `dir`, and the
    # rest degrades to "not available" instead of a build on packages that may not be.
    runtimeInputs = [coreutils findutils gawk jq git] ++ lib.optionals stdenv.isLinux [newt libnotify];
    meta = {
      description = "Reclaim what agents and dev tools leave behind";
      platforms = lib.platforms.unix;
    };
  }
