{
  flake.modules.nixos.default-apps = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      environment.systemPackages = [
        pkgs.celluloid
        pkgs.loupe
        pkgs.gnome-text-editor
        pkgs.file-roller
      ];

      xdg.terminal-exec = {
        enable = true;
        settings.default = ["com.mitchellh.ghostty.desktop"];
      };
    };
  };

  flake.modules.homeManager.default-apps = {
    config,
    lib,
    pkgs,
    ...
  }: let
    assoc = app: types: lib.genAttrs types (_: app);

    browser = "firefox.desktop";
    image = "org.gnome.Loupe.desktop";
    media = "io.github.celluloid_player.Celluloid.desktop";
    text = "org.gnome.TextEditor.desktop";
    code = "code.desktop";
    archive = "org.gnome.FileRoller.desktop";
  in {
    config = lib.mkIf (config.fireproof.desktop.enable && pkgs.stdenv.isLinux) {
      xdg.mimeApps = {
        enable = true;
        defaultApplications = lib.mkMerge [
          (assoc browser [
            "text/html"
            "application/xhtml+xml"
            "x-scheme-handler/http"
            "x-scheme-handler/https"
            "x-scheme-handler/about"
            "x-scheme-handler/unknown"
            "x-scheme-handler/mailto"
          ])
          (assoc image [
            "image/png"
            "image/jpeg"
            "image/gif"
            "image/webp"
            "image/svg+xml"
            "image/bmp"
            "image/tiff"
            "image/avif"
            "image/heif"
          ])
          {"application/pdf" = "org.gnome.Evince.desktop";}
          (assoc media [
            "video/mp4"
            "video/x-matroska"
            "video/webm"
            "video/x-msvideo"
            "video/quicktime"
            "audio/mpeg"
            "audio/flac"
            "audio/ogg"
            "audio/wav"
            "audio/x-m4a"
            "audio/aac"
          ])
          (assoc text [
            "text/plain"
            "text/x-log"
            "text/csv"
            "text/xml"
            "text/markdown"
            "application/json"
            "application/x-yaml"
          ])
          (lib.mkIf config.fireproof.dev.enable (assoc code [
            "text/x-python"
            "text/x-csrc"
            "text/x-java"
            "text/x-shellscript"
            "application/x-shellscript"
            "application/javascript"
          ]))
          {"inode/directory" = "org.gnome.Nautilus.desktop";}
          (assoc archive [
            "application/zip"
            "application/x-tar"
            "application/gzip"
            "application/x-7z-compressed"
            "application/x-rar"
            "application/x-bzip2"
            "application/x-xz"
            "application/zstd"
          ])
        ];
      };

      # Apps rewrite mimeapps.list on "set as default"/first launch; reclaim it on every switch
      # instead of failing activation, so the declared defaults stay authoritative.
      xdg.configFile."mimeapps.list".force = true;
    };
  };
}
