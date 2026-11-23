{config}: let
  secret = ../../secrets/phoenix-client-key.age;
in {
  inherit secret;
  # Never substitute a placeholder key: unenrolled means off.
  enabled = config.fireproof.dev.phoenix.enable && builtins.pathExists secret;
  path = "${config.xdg.configHome}/phoenix/api-key";
  endpoint = "https://phoenix.${config.fireproof.homelab.domain}/v1/traces";
  clear = ''
    unset "''${!OTEL_@}" "''${!PHOENIX_@}" CLAUDE_CODE_ENABLE_TELEMETRY \
      CLAUDE_CODE_ENHANCED_TELEMETRY_BETA ENABLE_ENHANCED_TELEMETRY_BETA \
      BETA_TRACING_ENDPOINT PI_OTEL_ENABLE
  '';
}
