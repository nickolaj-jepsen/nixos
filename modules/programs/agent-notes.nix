# Agent notes (docs/notes.md). The CLI is pkgs/agent-notes; this leaf puts it on
# PATH, and the agent wrappers and git hook call it by that path.
#
# The store sits under the agents' data directory, so it is gated by dev.enable
# rather than a feature of its own: every agent writes notes.
{
  flake.modules.homeManager.agent-notes = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.dev.enable {
      home.packages = [pkgs.agent-notes];

      # Session scratch (`tmp/<repo>/<pid>`) untouched for 3 days goes on the daily
      # systemd-tmpfiles-clean run. The `<repo>` level is the glob, so it survives
      # and a checkout's `.agents/tmp` link never dangles.
      systemd.user.tmpfiles.rules = lib.mkIf pkgs.stdenv.isLinux [
        "e %h/.local/state/agents/tmp/* - - - 3d"
      ];
    };
  };
}
