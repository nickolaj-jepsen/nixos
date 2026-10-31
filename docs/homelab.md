# Homelab services

Read this before adding or reworking a service under `modules/homelab/`.

## Every service

- Use a native NixOS service by default, gated on `fireproof.homelab.enable`.
  Leaf authoring rules are in `docs/modules.md`.
- Every new service sets its Glance dashboard link,
  `fireproof.homelab.dashboard.monitors.<name>`, inside its own leaf's gate.
  - Behind SSO it also needs a loopback `checkUrl`, or the monitor only probes
    the Zitadel login.
- Every new service sets its vhost via `fpLib.mkVirtualHost`.
- A service using `/mnt/data` sets
  `systemd.services.<unit>.unitConfig.RequiresMountsFor = ["/mnt/data"];` in
  its own leaf. Without it, the service runs against an empty dir when a data
  disk is missing.
- Ports stay on `127.0.0.1`: an open one bypasses the SSO vhost.

## Containerized services

- For Docker-only upstreams use `virtualisation.oci-containers.containers`.
- The backend is `docker`, set fleet-wide in `modules/programs/docker.nix`.
- `modules/homelab/grimmory.nix` is the reference:
  - container env split into a plain `environment` attr plus an agenix
    `environmentFiles` secret;
  - `virtualisation.docker.enableOnBoot = true` so it survives reboot;
  - port published to `127.0.0.1` behind an nginx vhost.

## Arr stack (Sonarr, Radarr, Prowlarr, SABnzbd)

- The services live in `modules/homelab/arr.nix`.
- recyclarr (`modules/homelab/recyclarr.nix`) owns grab policy: profiles,
  custom formats, quality sizes and naming. It syncs daily from the TRaSH
  guides.
- Never edit profiles or custom formats in the arr UI. recyclarr resets
  unmatched scores and deletes custom formats it does not manage.
- The `{sonarr,radarr}-api-key.age` secrets are copies of each app's API key.
  Update them if a key is regenerated.

### Profiles

Assigned per series or movie in the UI.

- Sonarr:
  - `WEB-1080p`: the default.
  - `WEB-1080p (Keep)`: the same with upgrades off, for legacy shows whose
    sub-1080p files must not be re-downloaded.
  - `WEB-2160p`: 4K HDR opt-in.
  - `[Anime] Remux-1080p`: the series type must be `anime`.
- Radarr:
  - `HD Bluray + WEB`: the default.
  - `UHD Bluray + WEB`: 4K opt-in.
  - `HD Remux (Keep)` and `UHD Remux (Keep)`: upgrades off, for existing
    remuxes the main profiles would replace with encodes.
  - All use language `Original`, set via the API (not a recyclarr field).

### Set once via the API

Not declarative:

- recycle bins at `/mnt/data/.recycle/<app>`;
- SAB remove-completed;
- notifications (Jellyfin needs an API key from its dashboard);
- profile assignment.

### Renaming

- Naming formats apply to new imports only. Jellyfin keys items by path, so a
  mass rename drops watched state.
- To rename the whole library later:
  1. Back up Jellyfin's data dir.
  2. Accept losing the watched history, or migrate it with a plugin keyed on
     provider ids.
  3. Run "Rename Files" per series or movie.

## Subtitles (Bazarr)

- Bazarr (`modules/homelab/arr.nix`) fetches external SRTs for everything
  Sonarr and Radarr import.
- The NixOS module has no settings option. The config below lives in
  `/var/lib/bazarr/config/config.yaml` (restic-backed); re-apply it by hand if
  the data dir is rebuilt.
- A pre-resync archive of every SRT is in `/mnt/data/.subtitle-backup/`.

### Config

- Profile `Default`: Danish + English, no cutoff, HI as fallback, applied to
  everything.
  - Danish rarely exists for older content, so a large wanted list is normal.
- Providers: OpenSubtitles.com (free tier, 20/day), subf2m (self-throttles
  without a browser user-agent string), gestdown, supersubtitles, yify,
  animetosho, embedded.
  - Podnapisi is gone in 1.6; SubDL and Subsource need accounts.
- Embedded PGS/VobSub don't count as present: image subs force a Jellyfin
  transcode.
- Deep audio-track analysis is on.
- Auto-sync thresholds are 96 (series) and 86 (movies).
- "Use original language audio track" is on. Otherwise ffsubsync syncs against
  the first audio stream, and dubbed releases get a bogus offset at the 60 s
  cap.
- For manual syncs, an embedded text track (`reference=s:N`) beats audio.
- Upgrades are on, with a 7-day window.
- Jellyfin refresh is on: API key from the Jellyfin dashboard, immediate,
  Shows + Movies.
- Sonarr and Radarr import extra files (`srt`).

## Home Assistant + Zigbee (`modules/homelab/home-assistant/`)

### Where config lives

- All logic is YAML rendered from Nix.
- `_devices.nix` is the Zigbee inventory and the entity-id contract. Every
  other file derives ids from it, including the config-flow integrations'
  provisional ids.
- The UI owns only:
  - config-flow integrations (the ids automations rely on are pinned in
    `_devices.nix`);
  - the registries: areas, the person's trackers, the enabled link-quality
    sensors, the Adaptive Lighting switch ids;
  - Assist exposure.
- Persistent state used by automations lives in the `input_boolean`s under
  `dev.helpers`.
- `_z2m-mqtt.nix` is the root-only `z2m-mqtt sub|pub` broker client, used by
  the units and for ops.

### Traps

- After adding an Adaptive Lighting room (`dev.alRooms`), check its sleep-mode
  switch id on the device page (see `dev.alLegacySleepIds`).
- Phone pushes use the legacy `notify.mobile_app_<device>` action, because
  channels, tags and actions need `data` and the notify entity service takes
  none.
- The stairs motion sensor's `illuminance_below_threshold_check: false` is a
  Z2M device option set over MQTT. It lives in `devices.yaml`, not in Nix.
  Without it the ungated stairs automation never fires in daylight.

### HTTP settings

- HA migrates the rendered `http:` block into `.storage/http` exactly once and
  ignores YAML afterwards. Manage the live settings under Settings, System,
  Network.
- The login-attempt ban is set to 50 because the Claude MCP connector's
  expired-token 401s count as strikes, and the counter only resets on restart.
- `use_x_forwarded_for` and `trusted_proxies` stay declared in `hass.nix`
  anyway, because that one-shot migration is what seeds a rebuilt data dir.
  Without them every request is attributed to nginx on 127.0.0.1, and failed
  logins ban the proxy, locking everyone out.
- The module always renders an `http:` block, so ignore the "YAML still
  present" repair.

### Zigbee2MQTT

- Friendly names are load-bearing: HA entity ids, the Nix group definitions
  and the switch automations (`zigbee2mqtt/<name>/action`) all derive from
  them. Rename a device only together with every reference.
- Groups:
  - ids and names are settings in `mqtt.nix`;
  - membership lives in Z2M's `database.db` and is reconciled by
    `zigbee2mqtt-groups-sync` after each Z2M start and daily;
  - a member that is powered off at the wall joins on the next run after it is
    back;
  - target group entities, never HA areas, for multi-bulb actions (one
    multicast; no per-bulb timeout).
- Availability is on: a device that stops answering goes `unavailable` in HA.
- `advanced.last_seen` exposes per-device last-seen sensors (disabled by
  default).
- `version` in the Z2M settings must track upstream `CURRENT_VERSION`; Z2M
  refuses to start on an unsupported value.
- `log_level` must be one of `error|warning|info|debug`.
- Secrets live in `zigbee2mqtt-secret.yaml.age`:
  - `password` (MQTT);
  - `network_key`, a list of 16 ints. Rotating it means re-pairing every
    device;
  - `frontend_token`.
- The broker listens on loopback only; both users have `readwrite #`.
- Network identity (`pan_id`, `ext_pan_id`, `channel`, `network_key`) is
  pinned.
- `coordinator_backup.json`, `database.db` and `devices.yaml` are what avoid
  re-pairing. Copy them off-box before touching the dongle or the data dir.
- Coordinator hangs show as `SRSP - ... after 6000ms` in the journal with the
  process still up. `zigbee2mqtt-watchdog` restarts the unit on a burst of
  them.
- `zigbee2mqtt-error-report` (`health.nix`) posts the day's failed-command
  count to #sys-info only when it misses its target.

## Shared databases

- Two always-on engine leaves mirror each other: `postgres.nix`
  (`services.postgresql` + `postgresqlBackup`) and `mariadb.nix`
  (`services.mysql` + `mysqlBackup`).
- Neither dump has its own timer. restic pulls both in right before each
  snapshot, so files and dumps are from the same moment.
- A service declares its own DB against them.
- Postgres: `fpLib.mkPostgresDB` / `services.postgresql.ensure*`.
- MariaDB (consumer example: `grimmory.nix`):
  - append to `services.mysql.ensureDatabases` +
    `services.mysqlBackup.databases`;
  - `ensureUsers` is socket-auth only, so a container connecting over TCP needs
    a `systemd.services.mysql.postStart = lib.mkAfter` hook to provision a
    password user;
  - `mariadb.nix` binds `0.0.0.0` and opens 3306 on `docker0`. Containers reach
    it via `--add-host=host.docker.internal:host-gateway`, and native socket
    consumers ignore both;
  - the firewall's default deny still blocks 3306 on the LAN/WAN NICs.

## Obsidian sync (`obsidian-sync.nix` + `modules/programs/obsidian/`)

- Self-hosted LiveSync against CouchDB at `obsidian.<domain>`.
- It is public and outside SSO (the plugin only speaks CouchDB basic auth), so
  work PCs off the tailnet can sync.
- The `obsidian-couchdb` fail2ban jail bans on that vhost's 401s (own access
  log).
- `/_up` is the only anonymous endpoint.

### Vaults and devices

- Vaults are `~/obsidian/<name>` on every desktop host, one CouchDB database
  each. The name lists live in both files; add a vault to both.
- Each `secrets/obsidian/<device>.age` is one CouchDB user. That is every file
  but `passphrase.age`; `devices` in `obsidian-sync.nix` reads the directory.
  - The homelab and that host's HM half both declare the user, through a
    shared generator.
  - A new Nix host's HM half creates its file via `just secret-generate`.
  - The phone has no Nix: `just secret-edit secrets/obsidian/phone.age` shows
    its password.
  - Revoke a device by deleting its `.age` file, then its `_users` doc.
- `secrets/obsidian/passphrase.age` is the vault E2EE passphrase every device
  shares; the server never sees it. Changing it means a remote rebuild.
- `couchdb-obsidian-provision` creates the users and databases.
- Device users are database members only and can't delete a database, so
  LiveSync's "rebuild remote" (first upload, or after changing E2EE or chunk
  settings) is done with the admin login (`/run/agenix/couchdb-admin` on the
  homelab). Device users then fetch.
- Backup: restic copies the CouchDB data dir as is. Its contents are E2EE, so a
  restore needs `secrets/obsidian/passphrase.age` too.

### Client side

The client files are `default.nix` (app settings), `plugins.nix` (per-vault
plugins) and `livesync.nix`.

- App settings and plugin code (`pkgs.obsidianPlugins`, from the
  `obsidian-extensions` input) are read-only Nix links.
- Plugin settings are deep-merged into each mutable `data.json` on activation;
  Nix keys win.
- Keep LiveSync's hidden-file sync off.
- Customization sync is on so the phone can apply the Nix hosts'
  plugins/settings. Never apply it on a Nix host.
- Templater's "trigger on file creation" is per-device localStorage, so the
  package is patched to default it on.
- `plugin.js` is our own plugin: code-block formatting with Nix-pinned
  formatters, and a Claude terminal toggle.
- Hotkeys are `settings.hotkeys` in `default.nix`.
- LiveSync's own `data.json` stays mutable.
  - `obsidian-livesync-seed` (run on activation) writes the connection, E2EE
    and path-obfuscation settings only when the file is missing.
  - Delete the file to re-seed after a password change.
- `obsidian-livesync-creds` prints the device's login and the passphrase.
- The phone must match the seeded E2EE + path obfuscation settings.

### Agents (`agents.nix`)

- The notes vault's conventions are its own synced `AGENTS.md`.
- Nix adds:
  - the CLI (`obsidian-cli`);
  - a global `/notes` skill (explicit invocation only);
  - in the vault's `.claude/`, vault-scoped skills plus hooks.
- The hooks git-snapshot the vault on session start/end, in a local,
  never-pushed repo. Review agent edits with `git log -p`.
- The hooks also lint changed notes through the running app.
- Claude opens below the note via the Terminal plugin (`plugins.nix`).
- Hidden-file sync being off keeps `.git` and `.claude` local.

## Notifications and health

- Discord is for things that need doing. Routine results go to the journal.
- Status lives where it is looked at:
  - the Glance **Storage** widget: `modules/homelab/storage-status.nix` writes
    `/var/lib/homelab-status/storage.json`, served on the loopback
    `status.localhost` vhost;
  - the HA dashboard's Zigbee Health section.
- A new sender should post on failure only; a "nothing happened" report belongs
  in the journal.

### Channels

- **#sys-urgent**: Grafana Cloud `severity=urgent` alerts (also emailed). The
  only channel worth push notifications.
- **#sys-info**: Grafana `severity=info` alerts and every in-repo sender (grep
  for its webhook secret, `discord-webhook-sys-info`).
- **arr channel**: health issues from Sonarr/Radarr/Lidarr/Prowlarr, configured
  in each app (Settings, Connect), errors only (`includeHealthWarnings` off).

### Grafana Cloud

- Grafana alert rules, contact points and the notification policy live in
  Grafana Cloud, not in this repo.
- Urgent alerts repeat every 24 h and info alerts every 7 days while firing.
- SMART rules must group by `serial_number` (joined from `smartctl_device`).
  `sdX` letters move between boots, so a `delta` keyed on `device` reports a
  rename as sector growth.
