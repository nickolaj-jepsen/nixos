# CUDA llama.cpp for desktop's RTX 5070 Ti. nixpkgs ships llama-cpp CPU-only and
# the CUDA variant isn't in the binary cache, so this compiles locally (~10 min).
#
# Pinned ahead of nixpkgs (b10758, Sep 2): Qwen3.8 MTP speculative
# decoding matured and --reasoning-effort merged (PR #26941) on Aug 14, one day
# after b10425. nixpkgs is still pinned to v0.2.0, which trails this pin by
# hundreds of commits. Drop the overrideAttrs once nixpkgs catches up past b10758.
{
  inputs,
  lib,
  ...
}: {
  perSystem = {system, ...}:
    lib.optionalAttrs (system == "x86_64-linux") {
      overlayAttrs.llama-cpp-cuda = let
        pkgs = import inputs.nixpkgs-unstable {
          inherit system;
          config = {
            allowUnfree = true;
            # GB203 is sm_120; building the one capability instead of all nine
            # is the difference between ~10 minutes and most of an hour.
            cudaCapabilities = ["12.0"];
            cudaForwardCompat = false;
          };
        };
      in
        (pkgs.llama-cpp.override {cudaSupport = true;}).overrideAttrs (_old: {
          version = "10758";
          src = pkgs.fetchFromGitHub {
            owner = "ggml-org";
            repo = "llama.cpp";
            tag = "b10758";
            hash = "sha256-1Pk68LSo0mhxH4XuKC6gfKh1DIVQJ9VrEJdReJcruK0=";
          };
        });
    };
}
