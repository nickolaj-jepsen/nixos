# Local inference endpoint. Homebrew rather than nixpkgs: nixpkgs' darwin
# llama-cpp ships a broken Metal build (its embed step passes the renamed
# LLAMA_METAL_EMBED_LIBRARY flag, so ggml falls back to compiling shaders at
# runtime and fails) — verified against both b9190 and b10063. The brew bottle
# initialises Metal cleanly. Rationale and measurements: docs/local-llm-plan.md.
{
  flake.modules.darwin.llama-server = {
    config,
    lib,
    ...
  }: let
    cfg = config.fireproof.llm;
    inherit (config.fireproof) username;
    llamaServer = "/opt/homebrew/bin/llama-server";
  in {
    config = lib.mkIf cfg.enable {
      homebrew.brews = ["llama.cpp"];

      launchd.user.agents.llama-server = {
        command = lib.concatStringsSep " " ([
            llamaServer
            "-m ${cfg.modelPath}"
            "-a ${cfg.modelAlias}"
            "-c ${toString cfg.contextSize}"
            "-ctk ${cfg.cacheType}"
            "-ctv ${cfg.cacheType}"
            "-ngl 99"
            "--host ${cfg.host}"
            "--port ${toString cfg.port}"
            # Thinking is on by default upstream. At ~13 tok/s a 2k-token thought
            # is minutes before the first visible word; opt in per request instead.
            "--reasoning-budget 0"
          ]
          ++ lib.optional cfg.mlock "--mlock"
          ++ lib.optional (cfg.apiKeyFile != null) "--api-key-file ${cfg.apiKeyFile}");
        serviceConfig = {
          RunAtLoad = true;
          KeepAlive = true;
          StandardOutPath = "/Users/${username}/Library/Logs/llama-server.out.log";
          StandardErrorPath = "/Users/${username}/Library/Logs/llama-server.err.log";
        };
      };

      system.activationScripts.postActivation.text = lib.mkAfter ''
        # Metal's default wired limit (~75% of RAM) is below what a 17.9 GB model
        # needs once KV and compute buffers land; without this the first decode
        # dies with kIOGPUCommandBufferCallbackErrorOutOfMemory. Not persistent
        # across reboot, so it is re-applied on every activation.
        /usr/sbin/sysctl -w iogpu.wired_limit_mb=${toString cfg.wiredLimitMb} || true

        # An unattended launchd agent cannot answer the firewall's
        # "accept incoming connections?" dialog, and silently answers nobody.
        /usr/libexec/ApplicationFirewall/socketfilterfw --add ${llamaServer} >/dev/null 2>&1 || true
        /usr/libexec/ApplicationFirewall/socketfilterfw --unblock ${llamaServer} >/dev/null 2>&1 || true
      '';
    };
  };
}
