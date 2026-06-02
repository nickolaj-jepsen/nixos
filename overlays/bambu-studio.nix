_: {
  perSystem = {pkgs, ...}: {
    overlayAttrs = {
      bambu-studio = pkgs.appimageTools.wrapType2 rec {
        name = "BambuStudio";
        pname = "bambu-studio";
        version = "02.07.01.57";
        ubuntu_version = "24.04-v02.07.01.57-20260601192128";

        src = pkgs.fetchurl {
          url = "https://github.com/bambulab/BambuStudio/releases/download/v${version}/BambuStudio_ubuntu-${ubuntu_version}.AppImage";
          sha256 = "sha256-hbBThT8aI4d1zXri1NGVRONSYFkkKNInbKJ9y9X461M=";
        };

        profile = ''
          export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
          export GIO_MODULE_DIR="${pkgs.glib-networking}/lib/gio/modules/"
        '';

        extraPkgs = pkgs:
          with pkgs; [
            cacert
            glib
            glib-networking
            gst_all_1.gst-plugins-bad
            gst_all_1.gst-plugins-base
            gst_all_1.gst-plugins-good
            webkitgtk_4_1
          ];

        extraInstallCommands = let
          contents = pkgs.appimageTools.extractType2 {inherit pname version src;};
        in ''
          install -Dm444 ${contents}/BambuStudio.desktop $out/share/applications/BambuStudio.desktop
          substituteInPlace $out/share/applications/BambuStudio.desktop \
            --replace-warn 'Exec=BambuStudio' 'Exec=${name}'
          cp -r ${contents}/usr/share/icons $out/share/
        '';
      };
    };
  };
}
