# Tested Prism CUDA binary: keep its ggml libraries separate from stock llama.cpp.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  openssl,
  inputs,
}: let
  cudaPkgs = import inputs.nixpkgs-cuda {
    inherit (stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
in
  stdenv.mkDerivation {
    pname = "llama-cpp-prism";
    version = "12232-f702476";
    src = fetchurl {
      url = "https://github.com/PrismML-Eng/llama.cpp/releases/download/prism-b12232-f702476/llama-prism-b12232-f702476-bin-linux-cuda-13.3-x64.tar.gz";
      hash = "sha256-adsBcDRMfVfg9gwUMbxsNqvUOugeAyvgE3h7XkUK1HI=";
    };
    nativeBuildInputs = [autoPatchelfHook];
    buildInputs = [
      stdenv.cc.cc.lib
      openssl
      cudaPkgs.cudaPackages.cuda_cudart
      cudaPkgs.cudaPackages.libcublas
    ];
    # libcuda comes from the running NVIDIA driver, not the build sandbox.
    autoPatchelfIgnoreMissingDeps = ["libcuda.so.1"];
    # autoPatchelf runs after postFixup; append here or it drops the driver RPATH.
    appendRunpaths = ["/run/opengl-driver/lib"];
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out/libexec $out/bin
      cp -a . $out/libexec/prism
      # Do not collide with the stock CLI tools in home.packages.
      ln -s $out/libexec/prism/llama-server $out/bin/llama-server-prism
      ln -s $out/libexec/prism/llama-bench $out/bin/llama-bench-prism
      runHook postInstall
    '';
    meta = {
      description = "PrismML llama.cpp CUDA runtime for PTQ1_0 Bonsai models";
      homepage = "https://github.com/PrismML-Eng/llama.cpp";
      license = lib.licenses.mit;
      platforms = ["x86_64-linux"];
      mainProgram = "llama-server-prism";
    };
  }
