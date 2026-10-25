# The agent temp janitor (docs/agent-tmp.md): the CLI the agent wrappers get
# their TMPDIR from, the timer that sweeps dead sessions, and the hooks that
# tell a live session when it is the one filling the disk.
#
# agent-notify is called off PATH rather than carried in runtimeInputs: it is a
# Linux-only package (modules/programs/agents.nix installs it only on Linux
# desktops), and the janitor's other subcommands have to build on darwin too.
{
  lib,
  writeShellApplication,
  coreutils,
  findutils,
  gawk,
  jq,
}:
writeShellApplication {
  name = "agent-tmp";
  runtimeInputs = [coreutils findutils gawk jq];
  text = builtins.readFile ./agent-tmp.sh;
  meta = {
    description = "Give coding agents a TMPDIR a sweeper owns, and reclaim dead sessions";
    mainProgram = "agent-tmp";
    platforms = lib.platforms.unix;
  };
}
