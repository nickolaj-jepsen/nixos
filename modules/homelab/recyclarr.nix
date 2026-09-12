# Manual steps before `just switch`: pipe each app's API key (Settings → General)
# into `just secret-write secrets/hosts/homelab/{sonarr,radarr}-api-key.age`, then
# `just secret-rekey`.
#
# Deliberately explicit (no TRaSH template includes) so the grab policy is
# reviewable here; CF definitions and default scores still come from the guides.
{
  flake.modules.nixos.recyclarr = {
    config,
    lib,
    ...
  }: let
    sonarrKey = {_secret = config.age.secrets.sonarr-api-key.path;};
    radarrKey = {_secret = config.age.secrets.radarr-api-key.path;};

    assignTo = names: map (name: {inherit name;}) names;

    # ---- Sonarr -----------------------------------------------------------
    sonarrWeb = ["WEB-1080p" "WEB-1080p (Keep)"];
    sonarrWebAll = sonarrWeb ++ ["WEB-2160p"];
    sonarrAnime = "[Anime] Remux-1080p";

    # HDTV/720p allowed below the cutoff (guide has WEB only) so broadcast-only UK shows still land.
    sonarrWebQualities = [
      {
        name = "WEB 1080p";
        qualities = ["WEBDL-1080p" "WEBRip-1080p"];
      }
      {name = "HDTV-1080p";}
      {
        name = "WEB 720p";
        qualities = ["WEBDL-720p" "WEBRip-720p"];
      }
      {name = "HDTV-720p";}
    ];

    # "(Keep)" = upgrades off, for legacy series whose sub-1080p files must not be re-downloaded.
    mkSonarrWebProfile = name: upgrades: {
      inherit name;
      reset_unmatched_scores.enabled = true;
      min_format_score = 0;
      # until_quality is the cutoff; Sonarr requires one even with upgrades off (else HTTP 400).
      upgrade = {
        allowed = upgrades;
        until_quality = "WEB 1080p";
        until_score = 10000;
      };
      qualities = sonarrWebQualities;
    };

    sonarrCustomFormats = [
      {
        # Repack/Proper (why propers_and_repacks is do_not_prefer below)
        trash_ids = [
          "ec8fa7296b64e8cd390a1600981f3923"
          "eb3d5cc0a2be0db205fb823640db6a3c"
          "44e7c4de10ae50265753082e5dc76047"
        ];
        assign_scores_to = assignTo (sonarrWebAll ++ [sonarrAnime]);
      }
      {
        # WEB release-group tiers 01-03 + WEB Scene
        trash_ids = [
          "e6258996055b9fbab7e9cb2f75819294"
          "58790d4e2fdcd9733aa7ae68ba2bb503"
          "d84935abd3f8556dcd51d4f27e22d0a6"
          "d0c516558625b04b363fa6c5c2c7cfd4"
        ];
        assign_scores_to = assignTo sonarrWebAll;
      }
      {
        # Streaming services (general) + HD/UHD streaming boost
        trash_ids = [
          "d660701077794679fd59e8bdf4ce3a29" # AMZN
          "d9e511921c8cedc7282e291b0209cdc5" # ATV
          "f67c9ca88f463a48346062e8ad07713f" # ATVP
          "77a7b25585c18af08f60b1547bb9b4fb" # CC
          "36b72f59f4ea20aad9316f475f2d9fbb" # DCU
          "89358767a60cc28783cdc3d0be9388a4" # DSNP
          "7a235133c87f7da4c8cccceca7e3c7a6" # HBO
          "a880d6abc21e7c16884f3ae393f84179" # HMAX
          "f6cce30f1733d5c8194222a7507909bb" # HULU
          "0ac24a2a68a9700bcb7eeca8e5cd644c" # iT
          "81d1fbf600e2540cee87f3a23f9d3c1c" # MAX
          "d34870697c9db575f17700212167be23" # NF
          "1656adc6d7bb2c8cca6acfb6592db421" # PCOK
          "c67a75ae4a1715f2bb4d492755ba4195" # PMTP
          "6eb71887a8db6e783dd398446eb0e65d" # PLAY
          "da393fd4e2c0cce7c9dc2669c43e0593" # ROKU
          "ae58039e1319178e6be73caab5c42166" # SHO
          "1efe8da11bfd74fbbcd4d8117ddb9213" # STAN
          "9623c5c9cac8e939c1b9aedd32f640bf" # SYFY
          "218e93e5702f44a68ad9e3c6ba87d2f0" # HD Streaming Boost
          "43b3cf48cb385cd3eac608ee6bca7f09" # UHD Streaming Boost
        ];
        assign_scores_to = assignTo sonarrWebAll;
      }
      {
        # Unwanted (hard blocks). x265 (HD) left out on purpose: HEVC plays fine, LQ already catches bad encoders.
        trash_ids = [
          "15a05bc7c1a36e2b57fd628f8977e2fc" # AV1
          "32b367365729d530ca1c124a0b180c64" # Bad Dual Groups
          "85c61753df5da1fb2aab6f2a47426b09" # BR-DISK
          "fbcb31d8dabd2a319072b84fc0b7249c" # Extras
          "9c11cd3f07101cdba90a2d81cf0e56b4" # LQ
          "e2315f990da2e2cbfc9fa5b7a6fcfe48" # LQ (Release Title)
          "23297a736ca77c0fc8e70f8edd7ee56c" # Upscaled
          "ae575f95ab639ba5d15f663bf019e3e8" # Language: Not Original
        ];
        assign_scores_to = assignTo sonarrWebAll;
      }
      {
        # 4K HDR policy: DV without HDR10 fallback and SDR are blocked
        trash_ids = [
          "505d871304820ba7106b693be6fe4a9e" # HDR
          "9b27ab6498ec0f31a3353992e19434ca" # DV (w/o HDR fallback)
          "2016d1676f5ee13a5b7257ff86ac9a93" # SDR
        ];
        assign_scores_to = assignTo ["WEB-2160p"];
      }
      {
        # Anime: full guide set (tiers, versions, unwanted, anime streaming)
        trash_ids = [
          "949c16fe0a8147f50ba82cc2df9411c9" # Anime BD Tier 01
          "ed7f1e315e000aef424a58517fa48727" # Anime BD Tier 02
          "096e406c92baa713da4a72d88030b815" # Anime BD Tier 03
          "30feba9da3030c5ed1e0f7d610bcadc4" # Anime BD Tier 04
          "545a76b14ddc349b8b185a6344e28b04" # Anime BD Tier 05
          "25d2afecab632b1582eaf03b63055f72" # Anime BD Tier 06
          "0329044e3d9137b08502a9f84a7e58db" # Anime BD Tier 07
          "c81bbfb47fed3d5a3ad027d077f889de" # Anime BD Tier 08
          "e0014372773c8f0e1bef8824f00c7dc4" # Anime Web Tier 01
          "19180499de5ef2b84b6ec59aae444696" # Anime Web Tier 02
          "c27f2ae6a4e82373b0f1da094e2489ad" # Anime Web Tier 03
          "4fd5528a3a8024e6b49f9c67053ea5f3" # Anime Web Tier 04
          "29c2a13d091144f63307e4a8ce963a39" # Anime Web Tier 05
          "dc262f88d74c651b12e9d90b39f6c753" # Anime Web Tier 06
          "9965a052eb87b0d10313b1cea89eb451" # Remux Tier 01
          "8a1d0c3d7497e741736761a1da866a2e" # Remux Tier 02
          "b4a1b3d705159cdca36d71e57ca86871" # Anime Raws
          "e3515e519f3b1360cbfc17651944354c" # Anime LQ Groups
          "15a05bc7c1a36e2b57fd628f8977e2fc" # AV1
          "026d5aadd1a6b4e550b134cb6c72b3ca" # Uncensored
          "d2d7b8a9d39413da5f44054080e028a3" # v0
          "273bd326df95955e1b6c26527d1df89b" # v1
          "228b8ee9aa0a609463efca874524a6b8" # v2
          "0e5833d3af2cc5fa96a0c29cd4477feb" # v3
          "4fc15eeb8f2f9a749f918217d4234ad8" # v4
          "b2550eb333d27b75833e25b8c2557b38" # 10bit
          "9c14d194486c4014d422adc64092d794" # Dubs Only
          "07a32f77690263bb9fda1842db7e273f" # VOSTFR
          "3e0b26604165f463f3e8e192261e7284" # CR
          "89358767a60cc28783cdc3d0be9388a4" # DSNP
          "d34870697c9db575f17700212167be23" # NF
          "d660701077794679fd59e8bdf4ce3a29" # AMZN
          "44a8ee6403071dd7b8a3a8dd3fe8cb20" # VRV
          "1284d18e693de8efe0fe7d6b3e0b9170" # FUNi
          "a370d974bc7b80374de1d9ba7519760b" # ABEMA
          "d54cd2bf1326287275b56bccedb72ee2" # ADN
          "7dd31f3dee6d2ef8eeaa156e23c3857e" # B-Global
          "4c67ff059210182b59cdd41697b8cb08" # Bilibili
          "570b03b3145a25011bf073274a407259" # HIDIVE
          "e5e6405d439dcd1af90962538acd4fe0" # WKN
        ];
        assign_scores_to = assignTo [sonarrAnime];
      }
      {
        # Anime Dual Audio: 10 = same tier, 101 = one tier up, 2000 = over any tier
        trash_ids = ["418f50b10f1907201b6cfdf881f467b7"];
        assign_scores_to = [
          {
            name = sonarrAnime;
            score = 101;
          }
        ];
      }
    ];

    # ---- Radarr -----------------------------------------------------------
    radarrHd = "HD Bluray + WEB";
    radarrUhd = "UHD Bluray + WEB";
    radarrBoth = [radarrHd radarrUhd];

    # Profile language (Original) is not a recyclarr field: set via the API, recyclarr leaves it alone.
    mkRadarrProfile = name: cutoff: qualities: {
      inherit name qualities;
      reset_unmatched_scores.enabled = true;
      min_format_score = 0;
      upgrade = {
        allowed = true;
        until_quality = cutoff;
        until_score = 10000;
      };
    };

    radarrCustomFormats = [
      {
        # Repack/Proper
        trash_ids = [
          "e7718d7a3ce595f289bfee26adc178f5"
          "ae43b294509409a6a13919dedd4764c4"
          "5caaaa1c08c1742aa4342d8c4cc463f2"
        ];
        assign_scores_to = assignTo radarrBoth;
      }
      {
        # WEB release-group tiers 01-03
        trash_ids = [
          "c20f169ef63c5f40c2def54abaf4438e"
          "403816d65392c79236dcb6dd591aeda4"
          "af94e0fe497124d1f9ce732069ec8c3b"
        ];
        assign_scores_to = assignTo radarrBoth;
      }
      {
        # HD Bluray release-group tiers 01-03
        trash_ids = [
          "ed27ebfef2f323e964fb1f61391bcb35"
          "c20c8647f2746a1f4c4262b0fbbeeeae"
          "5608c71bcebba0a5e666223bae8c9227"
        ];
        assign_scores_to = assignTo [radarrHd];
      }
      {
        # UHD Bluray release-group tiers 01-03
        trash_ids = [
          "4d74ac4c4db0b64bff6ce0cffef99bf0"
          "a58f517a70193f8e578056642178419d"
          "e71939fae578037e7aed3ee219bbe7c1"
        ];
        assign_scores_to = assignTo [radarrUhd];
      }
      {
        # Streaming services (general)
        trash_ids = [
          "b3b3a6ac74ecbd56bcdbefa4799fb9df" # AMZN
          "df13ed57843877b21ad969184ab6888f" # ATV
          "40e9380490e748672c2522eaaeb692f7" # ATVP
          "cc5e51a9e85a6296ceefe097a77f12f4" # BCORE
          "16622a6911d1ab5d5b8b713d5b0036d4" # CRiT
          "84272245b2988854bfb76a16e60baea5" # DSNP
          "509e5f41146e278f9eab1ddaceb34515" # HBO
          "5763d1b0ce84aff3b21038eea8e9b8ad" # HMAX
          "526d445d4c16214309f0fd2b3be18a89" # Hulu
          "e0ec9672be6cac914ffad34a6b077209" # iT
          "2a6039655313bf5dab1e43523b62c374" # MA
          "6a061313d22e51e0f25b7cd4dc065233" # MAX
          "170b1d363bd8516fbf3a3eb05d4faff6" # NF
          "c9fd353f8f5f1baf56dc601c4cb29920" # PCOK
          "e36a0ba1bc902b26ee40818a1d59b8bd" # PMTP
          "350e9170619683a55cb9191d0b1ababa" # PLAY
          "44c2b54d7c81c1a442a8b2cabeaef54f" # ROKU
          "c2863d2a50c9acad1fb50e53ece60817" # STAN
        ];
        assign_scores_to = assignTo radarrBoth;
      }
      {
        # Unwanted (hard blocks); x265 (HD) left out as for Sonarr
        trash_ids = [
          "b8cd450cbfa689c0259a01d9e29ba3d6" # 3D
          "cae4ca30163749b891686f95532519bd" # AV1
          "b6832f586342ef70d9c128d40c07b872" # Bad Dual Groups
          "cc444569854e9de0b084ab2b8b1532b2" # Black and White Editions
          "ed38b889b31be83fda192888e2286d83" # BR-DISK
          "0a3f082873eb454bde444150b70253cc" # Extras
          "e6886871085226c3da1830830146846c" # Generated Dynamic HDR
          "c465ccc73923871b3eb1802042331306" # Line/Mic Dubbed
          "90a6f9a284dff5103f6346090e6280c8" # LQ
          "e204b80c87be9497a8a6eaff48f72905" # LQ (Release Title)
          "712d74cd88bceb883ee32f773656b1f5" # Sing-Along Versions
          "bfd8eb01832d646a0a89c4deb46f8564" # Upscaled
          "d6e9318c875905d6cfb5bee961afcea9" # Language: Not Original
        ];
        assign_scores_to = assignTo radarrBoth;
      }
      {
        # Movie versions
        trash_ids = [
          "eca37840c13c6ef2dd0262b141a5482f" # 4K Remaster
          "e0c07d59beb37348e975a930d5e50319" # Criterion Collection
          "0f12c086e289cf966fa5948eac571f44" # Hybrid
          "eecf3a857724171f968a66cb5719e152" # IMAX
          "9f6cbff8cfe4ebbc1bde14c7b7bec0de" # IMAX Enhanced
          "9d27d9d2181838f76dee150882bdc58c" # Masters of Cinema
          "09d9dd29a0fc958f9796e65c2a8864b4" # Open Matte
          "570bc9ebecd92723d2d21500f4be314c" # Remaster
          "957d0f44b592285f26449575e8b1167e" # Special Edition
          "e9001909a4c88013a359d0b9920d7bea" # Theatrical Cut
          "db9b4c4b53d312a3ca5f1378f6440fc9" # Vinegar Syndrome
        ];
        assign_scores_to = assignTo radarrBoth;
      }
      {
        # 4K HDR policy, as Sonarr
        trash_ids = [
          "493b6d1dbec3c3364c59d7607f7e3405" # HDR
          "923b6abef9b17f937fab56cfcf89e1f1" # DV (w/o HDR fallback)
          "9c38ebb7384dada637be8899efa68e6f" # SDR
        ];
        assign_scores_to = assignTo [radarrUhd];
      }
      {
        # Audio formats (guide scores these for UHD only)
        trash_ids = [
          "496f355514737f7d83bf7aa4d24f8169" # TrueHD ATMOS
          "2f22d89048b01681dde8afe203bf2e95" # DTS X
          "417804f7f2c4308c1f4c5d380d4c4475" # ATMOS (undefined)
          "1af239278386be2919e1bcee0bde047e" # DD+ ATMOS
          "3cafb66171b47f226146a0770576870f" # TrueHD
          "dcf3ec6938fa32445f590a4da84256cd" # DTS-HD MA
          "a570d4a0e56a2874b64e5bfa55202a1b" # FLAC
          "e7c2fcae07cbada050a0af3357491d7b" # PCM
          "8e109e50e0a0b83a5098b056e13bf6db" # DTS-HD HRA
          "185f1dd7264c4562b9022d963ac37424" # DD+
          "f9f847ac70a0af62ea4a08280b859636" # DTS-ES
          "1c1a4c5e823891c75bc50380a6866f73" # DTS
          "240770601cc226190c367ef59aba7463" # AAC
          "c2998bd0d90ed5621d8df281e839436e" # DD
        ];
        assign_scores_to = assignTo [radarrUhd];
      }
    ];
  in {
    config = lib.mkIf config.fireproof.homelab.enable {
      age.secrets.sonarr-api-key.rekeyFile = ../../secrets/hosts/homelab/sonarr-api-key.age;
      age.secrets.radarr-api-key.rekeyFile = ../../secrets/hosts/homelab/radarr-api-key.age;

      services.recyclarr = {
        enable = true;
        schedule = "daily";
        configuration = {
          # Instance names must be unique across services; duplicates are dropped silently.
          sonarr.sonarr = {
            base_url = "http://127.0.0.1:8989";
            api_key = sonarrKey;
            delete_old_custom_formats = true;
            quality_definition.type = "series";
            media_management.propers_and_repacks = "do_not_prefer";
            # New imports only: Jellyfin keys items by path, a mass rename drops watched state.
            media_naming = {
              series = "jellyfin-tvdb";
              season = "default";
              episodes = {
                rename = true;
                standard = "default";
                daily = "default";
                anime = "default";
              };
            };
            quality_profiles = [
              (mkSonarrWebProfile "WEB-1080p" true)
              (mkSonarrWebProfile "WEB-1080p (Keep)" false)
              {
                name = "WEB-2160p";
                reset_unmatched_scores.enabled = true;
                min_format_score = 0;
                upgrade = {
                  allowed = true;
                  until_quality = "WEB 2160p";
                  until_score = 10000;
                };
                qualities = [
                  {
                    name = "WEB 2160p";
                    qualities = ["WEBDL-2160p" "WEBRip-2160p"];
                  }
                ];
              }
              {
                name = sonarrAnime;
                score_set = "anime-sonarr";
                reset_unmatched_scores.enabled = true;
                min_format_score = 100;
                upgrade = {
                  allowed = true;
                  until_quality = "Bluray 1080p";
                  until_score = 10000;
                };
                qualities = [
                  {
                    name = "Bluray 1080p";
                    qualities = ["Bluray-1080p Remux" "Bluray-1080p"];
                  }
                  {
                    name = "WEB 1080p";
                    qualities = ["HDTV-1080p" "WEBRip-1080p" "WEBDL-1080p"];
                  }
                  {name = "Bluray-720p";}
                  {
                    name = "WEB 720p";
                    qualities = ["HDTV-720p" "WEBRip-720p" "WEBDL-720p"];
                  }
                  {name = "Bluray-480p";}
                  {
                    name = "WEB 480p";
                    qualities = ["WEBRip-480p" "WEBDL-480p"];
                  }
                  {name = "DVD";}
                  {name = "SDTV";}
                ];
              }
            ];
            custom_formats = sonarrCustomFormats;
          };

          radarr.radarr = {
            base_url = "http://127.0.0.1:7878";
            api_key = radarrKey;
            delete_old_custom_formats = true;
            quality_definition.type = "movie";
            media_management.propers_and_repacks = "do_not_prefer";
            media_naming = {
              folder = "jellyfin-imdb";
              movie = {
                rename = true;
                standard = "jellyfin-imdb";
              };
            };
            quality_profiles = [
              (mkRadarrProfile radarrHd "Bluray-1080p" [
                {name = "Bluray-1080p";}
                {
                  name = "WEB 1080p";
                  qualities = ["WEBDL-1080p" "WEBRip-1080p"];
                }
                {name = "Bluray-720p";}
              ])
              (mkRadarrProfile radarrUhd "Bluray-2160p" [
                {name = "Bluray-2160p";}
                {
                  name = "WEB 2160p";
                  qualities = ["WEBDL-2160p" "WEBRip-2160p"];
                }
              ])
            ];
            custom_formats = radarrCustomFormats;
          };
        };
      };
    };
  };
}
