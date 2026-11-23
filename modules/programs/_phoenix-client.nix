# Enroll a Phoenix system API key with
# `just secret-edit secrets/phoenix-client-key.age`, then `just secret-rekey`.
# Personal/work traces contain prompts and tool content and are backed up on the
# homelab; send work data only where the employer permits it.
{config}: let
  secret = ../../secrets/phoenix-client-key.age;
  baseUrl = "https://phoenix.${config.fireproof.homelab.domain}";
in {
  inherit secret baseUrl;
  # Never substitute a placeholder key: unenrolled means off.
  enabled = config.fireproof.dev.phoenix.enable && builtins.pathExists secret;
  path = "${config.xdg.configHome}/phoenix/api-key";
  endpoint = "${baseUrl}/v1/traces";
  clear = ''
    unset "''${!OTEL_@}" "''${!PHOENIX_@}" CLAUDE_CODE_ENABLE_TELEMETRY \
      CLAUDE_CODE_ENHANCED_TELEMETRY_BETA ENABLE_ENHANCED_TELEMETRY_BETA \
      BETA_TRACING_ENDPOINT PI_OTEL_ENABLE \
      CLAUDE_TRACING_KEY_FILE ARIZE_TRACE_ENABLED ARIZE_LOG_PROMPTS \
      ARIZE_LOG_TOOL_DETAILS ARIZE_LOG_TOOL_CONTENT
  '';
}
