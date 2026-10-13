# Registers language servers into the fireproof.agents.lspServers registry, so
# agents get real go-to-definition/find-references/diagnostics instead of grep.
# Gated on neovim's full tier (modules/programs/neovim.nix), which already
# carries nil/pyrefly/tsserver.
{
  flake.modules.homeManager.agent-lsp = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.neovim.full.enable {
      fireproof.agents.lspServers = {
        nix = {
          command = lib.getExe pkgs.nil;
          extensionToLanguage.".nix" = "nix";
        };
        python = {
          command = lib.getExe pkgs.pyrefly;
          args = ["lsp"];
          extensionToLanguage = {
            ".py" = "python";
            ".pyi" = "python";
          };
        };
        typescript = {
          command = lib.getExe pkgs.typescript-language-server;
          args = ["--stdio"];
          extensionToLanguage = {
            ".ts" = "typescript";
            ".mts" = "typescript";
            ".cts" = "typescript";
            ".tsx" = "typescriptreact";
            ".js" = "javascript";
            ".mjs" = "javascript";
            ".cjs" = "javascript";
            ".jsx" = "javascriptreact";
          };
        };
        rust = {
          command = lib.getExe pkgs.rust-analyzer;
          extensionToLanguage.".rs" = "rust";
        };
      };
    };
  };
}
