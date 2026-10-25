{
  lib,
  writeShellApplication,
  coreutils,
  findutils,
  gawk,
  jq,
  git,
  wt,
  newt,
  ...
}: let
  # Concatenated rather than sourced so shellcheck sees the whole program.
  text = lib.concatMapStrings (file: builtins.readFile file) [
    ./head.sh
    ./tmp.sh
    ./repo.sh
  ];
in
  writeShellApplication {
    name = "janitor";
    inherit text;
    runtimeInputs = [coreutils findutils gawk jq git wt newt];
    meta = {
      description = "Reclaim what agents and dev tools leave behind";
      platforms = lib.platforms.unix;
    };
  }
