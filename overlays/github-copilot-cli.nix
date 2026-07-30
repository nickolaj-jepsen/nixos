{inputs, ...}: {
  perSystem = {system, ...}: let
    pkgsUnstable = import inputs.nixpkgs-unstable {
      inherit system;
      config.allowUnfree = true;
    };
    # Since 1.0.27 upstream dropped the universal tarball nixpkgs builds from;
    # the release now ships one tgz per platform (same `package/` layout).
    plat =
      {
        x86_64-linux = {
          dir = "linux-x64";
          hash = "sha256-sr/kUeP54o1SXKvfyvpJYASPH44IBxSI3WQ8Nu+t+hc=";
        };
        aarch64-linux = {
          dir = "linux-arm64";
          hash = "sha256-kVMm1rqvoOB6di4RHt0nFCGZo7Q/G2AuoSCeSo/xI+E=";
        };
        x86_64-darwin = {
          dir = "darwin-x64";
          hash = "sha256-Zjbj2DmE7ayDNx2NtNqqAG+uK6M0gR3hEeQH5vrSGJ0=";
        };
        aarch64-darwin = {
          dir = "darwin-arm64";
          hash = "sha256-9E8TnKJjkabKWyNnhl40P1C6mk/TF+j0XfwhlMZhkDI=";
        };
      }
      .${
        system
      } or (throw "github-copilot-cli overlay: unsupported system ${system}");
  in {
    overlayAttrs = {
      github-copilot-cli = pkgsUnstable.github-copilot-cli.overrideAttrs (finalAttrs: old: {
        version = "1.0.76";
        src = pkgsUnstable.fetchurl {
          url = "https://github.com/github/copilot-cli/releases/download/v${finalAttrs.version}/github-copilot-${finalAttrs.version}-${plat.dir}.tgz";
          inherit (plat) hash;
        };
        # 1.0.71 bundles @webviewjs/webview, a GTK/WebKit GUI module irrelevant
        # to CLI use; ignore its deps rather than pull in the heavy closure —
        # same reasoning as upstream's computer.node ignores.
        autoPatchelfIgnoreMissingDeps =
          (old.autoPatchelfIgnoreMissingDeps or [])
          ++ [
            "libcairo.so.2"
            "libdbus-1.so.3"
            "libgdk-3.so.0"
            "libgdk_pixbuf-2.0.so.0"
            "libgtk-3.so.0"
            "libjavascriptcoregtk-4.1.so.0"
            "libsoup-3.0.so.0"
            "libwayland-client.so.0"
            "libwebkit2gtk-4.1.so.0"
            "libxdo.so.3"
          ];
      });
    };
  };
}
