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
          hash = "sha256-wap0L0tK/hWtBAXk03n/HoSDoVk8abc1bKH7MaAZT8Y=";
        };
        aarch64-linux = {
          dir = "linux-arm64";
          hash = "sha256-+Fyfn39ESn9G3Lyk+TXjdp2DBVwFrnRBUuYs7ZWdCD8=";
        };
        x86_64-darwin = {
          dir = "darwin-x64";
          hash = "sha256-G07r7jRujfUgvH4IfKcvYszFN8uslCWG6a1Druo4xx8=";
        };
        aarch64-darwin = {
          dir = "darwin-arm64";
          hash = "sha256-bviakVJFgut0OxeDBXHcf+BCvB3fKO1f1gSqxgCWO1A=";
        };
      }
      .${
        system
      } or (throw "github-copilot-cli overlay: unsupported system ${system}");
  in {
    overlayAttrs = {
      github-copilot-cli = pkgsUnstable.github-copilot-cli.overrideAttrs (finalAttrs: old: {
        version = "1.0.75";
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
