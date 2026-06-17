{
  # Screen recording. gpu-screen-recorder streams the framebuffer straight to
  # NVENC via CUDA — the lowest-overhead recorder for this NVIDIA-open box (the
  # wlroots CLI recorders lean on VAAPI, which is weak on NVIDIA). The NixOS
  # module also generates the setcap'd gsr-kms-server wrapper needed for
  # promptless capture.
  flake.modules.nixos.recording = _: {
    config = {
      programs.gpu-screen-recorder.enable = true;
    };
  };
}
