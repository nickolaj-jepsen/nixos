# `disk-report`: what fills the disk, biggest first, each with the command that
# clears it. Read-only. nix, docker, uv and journalctl come from the caller's PATH.
{
  writeShellApplication,
  coreutils,
  findutils,
  gnused,
  jq,
  kondo,
}:
writeShellApplication {
  name = "disk-report";
  runtimeInputs = [coreutils findutils gnused jq kondo];
  # The clear commands are printed for a person, so their `~` stays literal.
  excludeShellChecks = ["SC2088"];
  text = builtins.readFile ./disk-report.sh;
}
