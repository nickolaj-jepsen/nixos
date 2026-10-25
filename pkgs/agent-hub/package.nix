# `agent-hub daemon`: the desktop hub for live coding-agent sessions. Config is
# ~/.config/agent-hub/config.json (written by modules/programs/agent-hub.nix).
{writers}:
writers.writePython3Bin "agent-hub" {
  flakeIgnore = ["E501" "W503"];
} (builtins.readFile ./agent_hub.py)
