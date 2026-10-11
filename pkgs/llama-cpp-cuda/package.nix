# nixpkgs' CUDA llama.cpp, unmodified so it substitutes from cache.nixos-cuda.org.
# Any change here (capabilities, src pin) means a CUDA compile, and the update bot
# then holds nixpkgs-cuda back for good (CACHE_GATED in update_bot.py).
{
  inputs,
  stdenv,
}:
(import inputs.nixpkgs-cuda {
  inherit (stdenv.hostPlatform) system;
  # Not the host's config: hosts and the bot's cache check must evaluate the same store path.
  config.allowUnfree = true;
}).llama-cpp.override {cudaSupport = true;}
