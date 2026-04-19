_: {
  perSystem = {pkgs, ...}: {
    overlayAttrs = {
      bambu-studio = pkgs.appimageTools.wrapType2 rec {
        name = "BambuStudio";
        pname = "bambu-studio";
        version = "02.06.00.51";
        ubuntu_version = "24.04-v02.06.00.51-20260417160415";

        src = pkgs.fetchurl {
          url = "https://github.com/bambulab/BambuStudio/releases/download/v${version}/BambuStudio_ubuntu-${ubuntu_version}.AppImage";
          sha256 = "sha256-CYePefJ7FXcAK+OXsIaNRHkml18BA7um4W2+f6l49zQ=";
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
