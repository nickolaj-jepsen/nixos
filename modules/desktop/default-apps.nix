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
    # Sushi's quick preview; Loupe is still under "Open With".
    image = "sushi.desktop";
    media = "io.github.celluloid_player.Celluloid.desktop";
    # Zed only exists with dev; text/plain is the fallback for every unlisted text type.
    text =
      if config.fireproof.dev.enable
      then code
      else "org.gnome.TextEditor.desktop";
    # Both editors stay installed; fireproof.desktop.editor picks the xdg handler.
    editors = {
      zed = "dev.zed.Zed.desktop";
      vscode = "code.desktop";
    };
    code = editors.${config.fireproof.desktop.editor};
    archiver = "org.gnome.FileRoller.desktop";

    # Mounts a zip or tar through gvfs's archive backend and opens it in Nautilus as a folder;
    # gvfs wants the file URI escaped twice. 7z and rar fail its seek, so they stay on File Roller.
    browseArchive = pkgs.writeShellApplication {
      name = "browse-archive";
      runtimeInputs = [pkgs.glib pkgs.jq pkgs.nautilus];
      text = ''
        uri=$(gio info -a standard::name "$1" | sed -n 's/^uri: //p')
        location="archive://$(jq -rn --arg u "$uri" '$u | @uri | @uri')/"
        gio mount "$location" 2>/dev/null || true
        exec nautilus --new-window "$location"
      '';
    };
    browsable = [
      "application/zip"
      "application/x-zip"
      "application/x-zip-compressed"
      "application/x-tar"
      "application/x-gtar"
      "application/x-compressed-tar"
      "application/x-bzip2-compressed-tar"
      "application/x-xz-compressed-tar"
      "application/x-zstd-compressed-tar"
    ];
  in {
    # The same choice for the folder menus in pi, Claude Code and agent-hub, which read it from
    # the session's environment; not gated on Linux, so a Mac's menus follow it too.
    config = lib.mkMerge [
      (lib.mkIf config.fireproof.desktop.enable {
        home.sessionVariables.FIREPROOF_EDITOR = config.fireproof.desktop.editor;
      })
      (lib.mkIf (config.fireproof.desktop.enable && pkgs.stdenv.isLinux) {
        xdg.desktopEntries.sushi = {
          name = "Quick Preview";
          exec = "${lib.getExe' pkgs.sushi "sushi"} %f";
          icon = "org.gnome.NautilusPreviewer";
          noDisplay = true;
        };

        xdg.desktopEntries.browse-archive = {
          name = "Browse Archive";
          exec = "${lib.getExe browseArchive} %u";
          icon = "package-x-generic";
          mimeType = browsable;
          noDisplay = true;
        };

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
              "application/rss+xml"
              "application/rdf+xml"
              "application/xhtml_xml"
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
              "image/apng"
              "image/jp2"
              "image/jxl"
              "image/qoi"
              "image/x-qoi"
              "image/svg+xml-compressed"
              "image/vnd.microsoft.icon"
              "image/x-dds"
              "image/x-exr"
              "image/x-portable-anymap"
              "image/x-portable-bitmap"
              "image/x-portable-graymap"
              "image/x-portable-pixmap"
              "image/x-tga"
              "image/x-win-bitmap"
              "image/x-xbitmap"
              "image/x-xpixmap"
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
              "application/xml"
              "text/x-c"
              "text/x-chdr"
              "text/x-c++src"
              "text/x-c++hdr"
              "text/x-makefile"
              "text/x-tex"
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
            (assoc "browse-archive.desktop" browsable)
            (assoc archiver [
              "application/gzip"
              "application/x-7z-compressed"
              "application/x-rar"
              "application/vnd.rar"
              "application/x-bzip2"
              "application/x-xz"
              "application/zstd"
            ])
          ];
        };

        # Apps rewrite mimeapps.list on "set as default"/first launch; reclaim it on every switch
        # instead of failing activation, so the declared defaults stay authoritative.
        xdg.configFile."mimeapps.list".force = true;
      })
    ];
  };
}
