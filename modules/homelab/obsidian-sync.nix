# CouchDB backend for Obsidian Self-hosted LiveSync. Public (no SSO: the plugin only
# speaks CouchDB basic auth) so devices off the tailnet, like work PCs, can reach it.
{fpLib, ...}: {
  flake.modules.nixos.obsidian-sync = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.fireproof.homelab;
    couch = config.services.couchdb;
    domain = "obsidian.${cfg.domain}";
    accessLog = "/var/log/nginx/obsidian.access.log";
    # One CouchDB user per device, each a member of every vault database. The Nix
    # hosts decrypt their own password HM-side (modules/programs/obsidian/livesync.nix).
    devices = ["desktop" "laptop" "macbook" "minilab" "work" "phone"];
    vaults = ["legacy" "notes"];
    deviceSecret = device: "obsidian-livesync-${device}";
  in {
    config = lib.mkIf cfg.enable {
      age.secrets =
        {
          couchdb-admin = {
            owner = "couchdb";
            generator.script = {pkgs, ...}: ''printf '[admins]\nadmin = %s\n' "$(${pkgs.pwgen}/bin/pwgen -s 48 1)"'';
          };
        }
        // lib.listToAttrs (map (device:
          lib.nameValuePair (deviceSecret device) {
            rekeyFile = ../../secrets/obsidian + "/${device}.age";
            generator.script = "alnum";
          })
        devices);

      services.couchdb = {
        enable = true;
        extraConfigFiles = [config.age.secrets.couchdb-admin.path];
        # LiveSync's recommended server settings.
        extraConfig = {
          couchdb = {
            single_node = true;
            max_document_size = 50000000;
          };
          # LiveSync's server check wants plain require_valid_user; the _up exception still wins for the Glance probe.
          chttpd = {
            require_valid_user = true;
            require_valid_user_except_for_up = true;
            enable_cors = true;
            max_http_request_size = 4294967296;
          };
          chttpd_auth = {
            require_valid_user = true;
            authentication_redirect = "/_utils/session.html";
          };
          httpd."WWW-Authenticate" = ''Basic realm="couchdb"'';
          cors = {
            origins = "app://obsidian.md,capacitor://localhost,http://localhost";
            credentials = true;
            headers = "accept, authorization, content-type, origin, referer";
            methods = "GET, PUT, POST, HEAD, DELETE";
            max_age = 3600;
          };
        };
      };

      # Idempotent: creates each device user (or resets a changed password) and each
      # vault database with every device as a member. Members can't delete a database,
      # so LiveSync's "rebuild remote" needs the admin login.
      systemd.services.couchdb-obsidian-provision = {
        description = "Provision CouchDB users and databases for Obsidian LiveSync";
        after = ["couchdb.service"];
        requires = ["couchdb.service"];
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = lib.getExe (pkgs.writeShellApplication {
            name = "couchdb-obsidian-provision";
            runtimeInputs = [pkgs.curl pkgs.jq pkgs.gnused pkgs.coreutils];
            text = ''
              base="http://${couch.bindAddress}:${toString couch.port}"
              admin_pass=$(sed -n 's/^admin = //p' ${config.age.secrets.couchdb-admin.path})
              # Credentials go through a curl config fd, not argv (visible in /proc); stdin stays free for bodies.
              as_admin() { curl -sS --max-time 10 -K <(printf 'user = "admin:%s"\n' "$admin_pass") "$@"; }

              for _ in $(seq 1 60); do
                curl -fsS --max-time 2 -o /dev/null "$base/_up" && break
                sleep 1
              done

              ${lib.concatMapStrings (device: ''
                  user=${device}
                  pass=$(tr -d '\n' <${config.age.secrets.${deviceSecret device}.path})
                  if ! curl -fs --max-time 10 -K <(printf 'user = "%s:%s"\n' "$user" "$pass") -o /dev/null "$base/_session"; then
                    rev=$(as_admin "$base/_users/org.couchdb.user:$user" | jq -r '._rev // empty')
                    jq -n --arg n "$user" --arg p "$pass" --arg rev "$rev" \
                      '{name: $n, password: $p, roles: [], type: "user"} + (if $rev == "" then {} else {_rev: $rev} end)' \
                      | as_admin -f -o /dev/null -X PUT -H 'Content-Type: application/json' --data-binary @- \
                        "$base/_users/org.couchdb.user:$user"
                    echo "provisioned user $user"
                  fi
                '')
                devices}

              security=${lib.escapeShellArg (builtins.toJSON {
                admins = {
                  names = [];
                  roles = [];
                };
                members = {
                  names = devices;
                  roles = [];
                };
              })}
              for db in ${lib.escapeShellArgs vaults}; do
                status=$(as_admin -o /dev/null -w '%{http_code}' -X PUT "$base/$db")
                case "$status" in
                  201 | 202) echo "created database $db" ;;
                  412) ;;
                  *) echo "creating $db failed: HTTP $status" >&2; exit 1 ;;
                esac
                printf '%s' "$security" | as_admin -f -o /dev/null -X PUT -H 'Content-Type: application/json' --data-binary @- "$base/$db/_security"
              done
            '';
          });
        };
      };

      services.nginx.virtualHosts.${domain} = fpLib.mkVirtualHost {
        inherit (couch) port;
        host = couch.bindAddress;
        # Own log so the fail2ban jail below only counts this vhost's 401s.
        extraConfig = ''
          access_log ${accessLog};
          client_max_body_size 128M;
        '';
      };

      # CouchDB rejects bad logins itself, which the stock nginx-http-auth jail can't see.
      services.fail2ban.jails.obsidian-couchdb = {
        filter.Definition.failregex = ''^<HOST> \S+ \S+ \[[^]]+\] "[A-Z]+ [^"]*" 401 '';
        settings = {
          enabled = true;
          port = "http,https";
          backend = "auto";
          logpath = accessLog;
        };
      };

      # CouchDB files are append-only, so a live copy restores to the last complete write.
      services.restic.backups.homelab.paths = [couch.databaseDir];
    };
  };
}
