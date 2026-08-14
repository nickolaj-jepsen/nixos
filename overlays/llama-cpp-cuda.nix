# CUDA llama.cpp for desktop's RTX 5070 Ti. nixpkgs ships llama-cpp CPU-only and
# the CUDA variant isn't in the binary cache, so this compiles locally (~10 min).
{
  inputs,
  lib,
  ...
}: {
  perSystem = {system, ...}:
    lib.optionalAttrs (system == "x86_64-linux") {
      overlayAttrs.llama-cpp-cuda =
        (import inputs.nixpkgs-unstable {
          inherit system;
          config = {
            allowUnfree = true;
            # GB203 is sm_120; building the one capability instead of all nine
            # is the difference between ~10 minutes and most of an hour.
            cudaCapabilities = ["12.0"];
            cudaForwardCompat = false;
          };
        })
        .llama-cpp
        .override {cudaSupport = true;};
    };
}
