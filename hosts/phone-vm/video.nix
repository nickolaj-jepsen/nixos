# mpv, to show off pocketnix's frame rate: video is the workload that sends a whole
# buffer every frame. No GPU or EGL, so it draws into wl_shm and decodes in software.
{
  homeManager = {pkgs, ...}: {
    programs.mpv = {
      enable = true;
      # yt-dlp and its deno runtime are 170 MiB of the phone's scarce disk.
      package = pkgs.mpv.override {youtubeSupport = false;};
      config = {
        vo = "wlshm";
        hwdec = "no";
      };
    };

    # Jellyfin's 30 s 1080p60 H.264 test clip, looped; `%%` is a desktop entry's literal %.
    xdg.desktopEntries.video-60fps = {
      name = "60 fps video";
      comment = "Stream a 1080p60 test clip through mpv";
      icon = "mpv";
      exec = "mpv --fs --loop-file=inf https://repo.jellyfin.org/test-videos/SDR/AVC/Test%%20Jellyfin%%201080p%%20AVC%%203M.mp4";
      categories = ["AudioVideo" "Video"];
    };
  };
}
