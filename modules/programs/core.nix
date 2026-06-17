{
  flake.aspectTags.core = ["base"];
  flake.modules.nixos.core = {pkgs, ...}: {
    config = {
      environment.enableAllTerminfo = true;

      # Fundamental system utilities that should stay system-level
      environment.systemPackages = with pkgs; [
        file
        findutils
        which
        gnugrep
        gawk
        gnused
        lshw
      ];
    };
  };
  flake.modules.homeManager.core = {pkgs, ...}: {
    config = {
      programs = {
        fzf.enable = true;
        tmux.enable = true;
        ripgrep.enable = true;
        jq.enable = true;
        htop.enable = true;
        man.enable = true;
        # Interactive process monitor with a GPU panel (htop has none). On
        # NVIDIA hosts nvidia.nix swaps in the NVML-linked build.
        btop.enable = true;
        # Example-first `tldr` pages; keep the cache fresh automatically.
        tealdeer = {
          enable = true;
          settings.updates.auto_update = true;
        };
      };

      home.packages = with pkgs; [
        man-pages
        man-pages-posix
        curl
        wget
        whois
        rsync
        tree
        zip
        unzip
        gzip
        xz
      ];
    };
  };
}
