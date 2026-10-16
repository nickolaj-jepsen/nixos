# `ai-usage [--json]`: quota windows for the AI agent subscriptions listed in
# ~/.config/ai-usage/config.json (written by modules/programs/ai-usage.nix).
{writers}:
writers.writePython3Bin "ai-usage" {
  flakeIgnore = ["E501" "W503"];
} (builtins.readFile ./ai_usage.py)
