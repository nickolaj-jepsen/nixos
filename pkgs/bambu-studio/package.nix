{
  appimageTools,
  fetchurl,
  cacert,
  glib-networking,
}: let
  pname = "bambu-studio";
  version = "02.08.02.61";
  ubuntuVersion = "24.04-v02.08.02.61-20260820225108";
  src = fetchurl {
    url = "https://github.com/bambulab/BambuStudio/releases/download/v${version}/BambuStudio_ubuntu${ubuntuVersion}.AppImage";
    hash = "sha256-1QGxA/rFQkUT7A6Na8FF+zBxneLH2U1zINcjdAyBp/0=";
  };
  contents = appimageTools.extractType2 {inherit pname version src;};
in
  appimageTools.wrapType2 {
    inherit pname version src;

    profile = ''
      export SSL_CERT_FILE="${cacert}/etc/ssl/certs/ca-bundle.crt"
      export GIO_MODULE_DIR="${glib-networking}/lib/gio/modules/"
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

    # The entry execs AppRun, which only exists inside the AppImage.
    extraInstallCommands = ''
      install -Dm444 ${contents}/BambuStudio.desktop $out/share/applications/BambuStudio.desktop
      substituteInPlace $out/share/applications/BambuStudio.desktop \
        --replace-fail 'Exec=AppRun' 'Exec=${pname}'
      cp -r ${contents}/usr/share/icons $out/share/
    '';

    meta.platforms = ["x86_64-linux"];
  }
