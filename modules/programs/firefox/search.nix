{
  config,
  lib,
  pkgs,
  ...
}: let
  nixIcon = "${pkgs.nixos-icons}/share/icons/hicolor/scalable/apps/nix-snowflake.svg";
  superTinyIcon = name: "${pkgs.super-tiny-icons}/share/icons/SuperTinyIcons/svg/${name}.svg";
  githubIcon = superTinyIcon "github";

  mkSearch = {
    template,
    alias,
    icon ? null,
  }:
    {
      metaData.hideOneOffButton = true;
      urls = [{inherit template;}];
      definedAliases = [alias];
    }
    // lib.optionalAttrs (icon != null) {inherit icon;};
in {
  config = lib.mkIf config.fireproof.desktop.enable {
    fireproof.home-manager.programs.firefox.profiles.default.search = {
      default = "Kagi";
      privateDefault = "Kagi";
      force = true;

      engines = {
        "amazondotcom-us".metaData.hidden = true;
        "bing".metaData.hidden = true;
        "google".metaData.hidden = true;
        "ebay".metaData.hidden = true;
        "wikipedia".metaData.hidden = true;
        "ddg".metaData.hidden = true;
        "libredirect".metaData.hidden = true;

        "Kagi" = mkSearch {
          template = "https://kagi.com/search?q={searchTerms}";
          alias = "@k";
        };

        # Nix
        "NixOs Options" = mkSearch {
          template = "https://search.nixos.org/options?channel=unstable&query={searchTerms}";
          alias = "@no";
          icon = nixIcon;
        };

        "Nix Packages" = mkSearch {
          template = "https://search.nixos.org/packages?type=packages&query={searchTerms}";
          alias = "@np";
          icon = nixIcon;
        };

        "NixOS Wiki" = mkSearch {
          template = "https://wiki.nixos.org/w/index.php?search={searchTerms}";
          alias = "@nw";
          icon = nixIcon;
        };

        "Noogle" = mkSearch {
          template = "https://noogle.dev/q?term={searchTerms}";
          alias = "@ng";
          icon = nixIcon;
        };

        "NüschtOS" = mkSearch {
          template = "https://search.xn--nschtos-n2a.de/?query={searchTerms}";
          alias = "@nos";
          icon = nixIcon;
        };

        # GitHub
        "GitHub Code" = mkSearch {
          template = "https://github.com/search?q={searchTerms}&type=code";
          alias = "@gc";
          icon = githubIcon;
        };

        "GitHub Pull Requests" = mkSearch {
          template = "https://github.com/search?q={searchTerms}&type=pullrequests";
          alias = "@gpr";
          icon = githubIcon;
        };

        "GitHub Issues" = mkSearch {
          template = "https://github.com/search?q={searchTerms}&type=issues";
          alias = "@gi";
          icon = githubIcon;
        };

        "GitHub Repositories" = mkSearch {
          template = "https://github.com/search?q={searchTerms}&type=repositories";
          alias = "@gr";
          icon = githubIcon;
        };

        # Dev
        "Can I Use" = mkSearch {
          template = "https://caniuse.com/?search={searchTerms}";
          alias = "@ciu";
          icon = superTinyIcon "html5";
        };

        "npm" = mkSearch {
          template = "https://www.npmjs.com/search?q={searchTerms}";
          alias = "@npm";
          icon = superTinyIcon "npm";
        };

        "PyPI" = mkSearch {
          template = "https://pypi.org/search/?q={searchTerms}";
          alias = "@pip";
          icon = superTinyIcon "python";
        };

        "Docker Hub" = mkSearch {
          template = "https://hub.docker.com/search?q={searchTerms}";
          alias = "@dh";
          icon = superTinyIcon "docker";
        };

        "Crates.io" = mkSearch {
          template = "https://crates.io/search?q={searchTerms}";
          alias = "@cargo";
          icon = superTinyIcon "rust";
        };

        "Home Manager Options" = mkSearch {
          template = "https://home-manager-options.extranix.com/?query={searchTerms}";
          alias = "@hm";
          icon = nixIcon;
        };

        # Tools
        "Outlook" = mkSearch {
          template = "https://outlook.office.com/mail/0/search?query={searchTerms}";
          alias = "@ol";
          icon = superTinyIcon "outlook";
        };
      };
    };
  };
}
