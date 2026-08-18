_: {
  perSystem = {
    pkgs,
    system,
    ...
  }: let
    version = "1.32352.0";
    # Anthropic's apt repo only publishes amd64/arm64 debs.
    sources = {
      x86_64-linux = {
        arch = "amd64";
        hash = "sha256-JEDQdDdlU9cLIvweUzR9pg5YdXSYll7+uYmYh9ph4Nk=";
      };
      aarch64-linux = {
        arch = "arm64";
        hash = "sha256-sKLeZMXpR/BnkknlRfnHrqip57I6v27YJx+qnl++mkE=";
      };
    };
    plat =
      sources.${system}
      or (throw "claude-desktop overlay: unsupported system ${system}");
  in {
    overlayAttrs = {
      claude-desktop = pkgs.stdenv.mkDerivation {
        pname = "claude-desktop";
        inherit version;

        src = pkgs.fetchurl {
          url = "https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop/claude-desktop_${version}_${plat.arch}.deb";
          inherit (plat) hash;
        };

        nativeBuildInputs = with pkgs; [
          autoPatchelfHook
          dpkg
          makeWrapper
        ];

        buildInputs = with pkgs; [
          alsa-lib
          at-spi2-core
          cairo
          cups
          dbus
          expat
          glib
          gtk3 # also provides GSETTINGS_SCHEMAS_PATH
          libcap_ng # virtiofsd (Cowork's VM file sharing)
          libgbm
          libseccomp # virtiofsd
          libx11
          libxcb
          libxcomposite
          libxdamage
          libxext
          libxfixes
          libxkbcommon
          nspr
          nss
          pango
          systemdLibs # libudev
        ];

        # dlopened, so autoPatchelf can't see them in DT_NEEDED.
        runtimeDependencies = with pkgs; [
          libnotify
          libpulseaudio
          libsecret
        ];

        # Bundled ANGLE dlopens libEGL.so.1; runtimeDependencies only reaches executables.
        appendRunpaths = ["${pkgs.lib.getLib pkgs.libglvnd}/lib"];

        dontUnpack = true;

        installPhase = ''
          runHook preInstall

          # chrome-sandbox is setuid, so `dpkg -x` bails; unpack the payload tarball
          # directly. Non-setuid is fine — Chromium's namespace sandbox works here.
          dpkg --fsys-tarfile $src | tar --extract --no-same-permissions --no-same-owner

          mkdir -p $out/lib $out/share
          mv usr/lib/claude-desktop $out/lib/
          mv usr/share/icons $out/share/

          # Patched rather than regenerated to keep upstream's desktop actions.
          install -Dm444 usr/share/applications/com.anthropic.Claude.desktop \
            $out/share/applications/com.anthropic.Claude.desktop
          substituteInPlace $out/share/applications/com.anthropic.Claude.desktop \
            --replace-fail 'Exec=claude-desktop' "Exec=$out/bin/claude-desktop"

          runHook postInstall
        '';

        # Chromium detects only GNOME/KDE, so niri would get the plaintext store.
        postFixup = ''
          makeWrapper $out/lib/claude-desktop/claude-desktop $out/bin/claude-desktop \
            --prefix XDG_DATA_DIRS : "$GSETTINGS_SCHEMAS_PATH" \
            --suffix PATH : ${pkgs.lib.makeBinPath (with pkgs; [xdg-utils])} \
            --add-flags "--password-store=gnome-libsecret" \
            --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations,WebRTCPipeWireCapturer --enable-wayland-ime=true}}"
        '';

        meta = {
          description = "Claude desktop app (Chat, Cowork and Claude Code)";
          homepage = "https://claude.com/download";
          license = pkgs.lib.licenses.unfree;
          sourceProvenance = [pkgs.lib.sourceTypes.binaryNativeCode];
          platforms = builtins.attrNames sources;
          mainProgram = "claude-desktop";
        };
      };
    };
  };
}
