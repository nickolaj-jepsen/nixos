# Arize's Claude Code tracing plugin: the `claude-code-tracing` marketplace plugin,
# pinned as a plugin directory so `--plugin-dir` loads it without a runtime clone
# (docs/agents.md, "Agent tracing"). Upstream cuts no releases -- only rc tags -- so
# this follows a main commit: bump `rev` and `hash` together, and re-read
# `tracing/claude_code/hooks/hooks.json` for the events Claude Code now gets.
{
  lib,
  runCommand,
  writeShellScript,
  fetchFromGitHub,
  python3,
}: let
  rev = "6c37507e3c92ab7531e07731baf477e31947965c";
  src = fetchFromGitHub {
    owner = "Arize-ai";
    repo = "coding-harness-tracing";
    inherit rev;
    hash = "sha256-Qx2siUaqXXecslgh68NV/5xuBRxV8k1FtjhkhUefv+4=";
  };
  plugin = "${src}/tracing/claude_code";

  # Replaces upstream's scripts/run-hook, which creates a Python venv per plugin data
  # dir on first use. Every handler imports only the stdlib from the plugin tree
  # (`hooks.*` and `core.*`, per upstream's own standing invariant), so the pinned
  # interpreter runs them directly: no venv, no network, nothing mutable but the
  # harness's own state and log dirs under ~/.arize.
  runHook = writeShellScript "claude-tracing-run-hook" ''
    set -eu

    hook=''${1:?usage: run-hook arize-hook-<event>}
    root=$(cd -P -- "$(dirname -- "$0")/.." && pwd)

    # The key reaches this hook process and nothing else: the wrapper exports the
    # path, not the secret, so a session's Bash tool cannot read it from its own env.
    if [ -n "''${CLAUDE_TRACING_KEY_FILE:-}" ] && [ -s "$CLAUDE_TRACING_KEY_FILE" ]; then
      PHOENIX_API_KEY=$(cat -- "$CLAUDE_TRACING_KEY_FILE")
      export PHOENIX_API_KEY
    fi

    # Only the handlers upstream registers, so a stale hooks.json can't run anything else.
    case "''${hook#arize-hook-}" in
      session-start) handler=session_start ;;
      session-end) handler=session_end ;;
      stop) handler=stop ;;
      stop-failure) handler=stop_failure ;;
      subagent-start) handler=subagent_start ;;
      subagent-stop) handler=subagent_stop ;;
      notification) handler=notification ;;
      permission-request) handler=permission_request ;;
      permission-denied) handler=permission_denied ;;
      pre-tool-use) handler=pre_tool_use ;;
      post-tool-use) handler=post_tool_use ;;
      post-tool-use-failure) handler=post_tool_use_failure ;;
      user-prompt-submit) handler=user_prompt_submit ;;
      user-prompt-expansion) handler=user_prompt_expansion ;;
      pre-compact) handler=pre_compact ;;
      post-compact) handler=post_compact ;;
      *) exit 0 ;;
    esac

    export PYTHONPATH="$root''${PYTHONPATH:+:$PYTHONPATH}"
    exec ${lib.getExe python3} -c "from hooks.handlers import $handler; $handler()"
  '';
in
  runCommand "claude-code-tracing-${lib.substring 0 7 rev}" {} ''
    mkdir -p $out/.claude-plugin $out/scripts
    install -Dm644 ${plugin}/.claude-plugin/plugin.json $out/.claude-plugin/plugin.json
    # hooks/hooks.json is upstream's, so the registered events stay upstream's too.
    cp -r ${plugin}/hooks $out/hooks
    # core/ is a symlink to the repo root's copy; take the real tree.
    cp -r ${src}/core $out/core
    install -Dm755 ${runHook} $out/scripts/run-hook
  ''
