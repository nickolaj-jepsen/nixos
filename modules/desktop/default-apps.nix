{
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
    ];

    xdg.mime.defaultApplications = {
      # Images
      "image/png" = "org.gnome.Loupe.desktop";
      "image/jpeg" = "org.gnome.Loupe.desktop";
      "image/gif" = "org.gnome.Loupe.desktop";
      "image/webp" = "org.gnome.Loupe.desktop";
      "image/svg+xml" = "org.gnome.Loupe.desktop";
      "image/bmp" = "org.gnome.Loupe.desktop";
      "image/tiff" = "org.gnome.Loupe.desktop";

      # PDF
      "application/pdf" = "org.gnome.Evince.desktop";

      # Video
      "video/mp4" = "io.github.celluloid_player.Celluloid.desktop";
      "video/x-matroska" = "io.github.celluloid_player.Celluloid.desktop";
      "video/webm" = "io.github.celluloid_player.Celluloid.desktop";
      "video/x-msvideo" = "io.github.celluloid_player.Celluloid.desktop";
      "video/quicktime" = "io.github.celluloid_player.Celluloid.desktop";

      # Audio
      "audio/mpeg" = "io.github.celluloid_player.Celluloid.desktop";
      "audio/flac" = "io.github.celluloid_player.Celluloid.desktop";
      "audio/ogg" = "io.github.celluloid_player.Celluloid.desktop";
      "audio/wav" = "io.github.celluloid_player.Celluloid.desktop";
      "audio/x-m4a" = "io.github.celluloid_player.Celluloid.desktop";
      "audio/aac" = "io.github.celluloid_player.Celluloid.desktop";

      # Text
      "text/plain" = "org.gnome.TextEditor.desktop";
      "text/x-log" = "org.gnome.TextEditor.desktop";
      "text/csv" = "org.gnome.TextEditor.desktop";
      "text/xml" = "org.gnome.TextEditor.desktop";
      "application/json" = "org.gnome.TextEditor.desktop";
      "application/x-yaml" = "org.gnome.TextEditor.desktop";

      # Code
      "text/x-python" = "code.desktop";
      "text/x-csrc" = "code.desktop";
      "text/x-java" = "code.desktop";
      "application/javascript" = "code.desktop";

      # File manager
      "inode/directory" = "org.gnome.Nautilus.desktop";

      # Archives
      "application/zip" = "org.gnome.Nautilus.desktop";
      "application/x-tar" = "org.gnome.Nautilus.desktop";
      "application/gzip" = "org.gnome.Nautilus.desktop";
      "application/x-7z-compressed" = "org.gnome.Nautilus.desktop";
      "application/x-rar" = "org.gnome.Nautilus.desktop";
    };
  };
}
