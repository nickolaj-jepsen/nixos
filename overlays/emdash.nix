_: {
  perSystem = {pkgs, ...}: {
    overlayAttrs = {
      emdash = pkgs.appimageTools.wrapType2 rec {
        pname = "emdash";
        version = "0.4.35";

        src = pkgs.fetchurl {
          url = "https://github.com/generalaction/emdash/releases/download/v${version}/emdash-x86_64.AppImage";
          sha256 = "sha256-3WW0wMZ99u6HHJMsfUy30pvNadCbM4wcXILLPsvugPI=";
        };

        extraInstallCommands = let
          contents = pkgs.appimageTools.extractType2 {inherit pname version src;};
        in ''
          install -Dm444 ${contents}/emdash.desktop $out/share/applications/emdash.desktop
          substituteInPlace $out/share/applications/emdash.desktop \
            --replace-warn 'Exec=AppRun' 'Exec=${pname}'
          cp -r ${contents}/usr/share/icons $out/share/
        '';
      };
    };
  };
}
