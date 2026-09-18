# CUDA llama.cpp for the dev.llm hosts. nixpkgs ships llama-cpp CPU-only and
# the CUDA variant isn't in the binary cache, so this compiles locally (~10 min).
#
# Pinned ahead of nixpkgs (b11018, Sep 17): Qwen3.8 MTP speculative
# decoding matured and --reasoning-effort merged (PR #26941) on Aug 14, one day
# after b10425. nixpkgs is still pinned to buildNumber 10809 (v0.4.0), which
# trails this pin. Drop the overrideAttrs once nixpkgs catches up past b11018.
{
  inputs,
  lib,
  ...
}: {
  perSystem = {system, ...}:
    lib.optionalAttrs (system == "x86_64-linux") {
      # `.override {cudaCapabilities = ["8.9"];}` retargets it per GPU.
      overlayAttrs.llama-cpp-cuda = lib.makeOverridable ({cudaCapabilities ? ["12.0"]}: let
        pkgs = import inputs.nixpkgs-unstable {
          inherit system;
          config = {
            allowUnfree = true;
            # Building the one capability instead of all nine is the
            # difference between ~10 minutes and most of an hour.
            inherit cudaCapabilities;
            cudaForwardCompat = false;
          };
        };
      in
        (pkgs.llama-cpp.override {cudaSupport = true;}).overrideAttrs (_old: {
          version = "11018";
          src = pkgs.fetchFromGitHub {
            owner = "ggml-org";
            repo = "llama.cpp";
            tag = "b11018";
            hash = "sha256-+3KSknDeEsBcESKj/jPqfm4K8rQ8v12+iw0c7T7rWug=";
          };
        })) {};
    };
}
