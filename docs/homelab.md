# Homelab services

Read this before adding or reworking a service under `modules/homelab/`.

Services are native NixOS services by default, gated on
`fireproof.homelab.enable` (leaf authoring rules: `docs/modules.md`). Every
new service gets a dashboard link in `modules/homelab/glance/_home-page.nix`
(behind SSO it also needs a loopback `check-url`, or the monitor only probes
the Zitadel login), and its vhost via `fpLib.mkVirtualHost`. A service using
`/mnt/data` also sets
`systemd.services.<unit>.unitConfig.RequiresMountsFor = ["/mnt/data"];` in its
own leaf, or it runs against an empty dir when a data disk is missing. Ports stay on `127.0.0.1`: an open one
bypasses the SSO vhost.

## Containerized services

For Docker-only upstreams use `virtualisation.oci-containers.containers`
(backend is `docker`, set fleet-wide in `modules/programs/docker.nix`).
`modules/homelab/grimmory.nix` is the reference:

- container env split into a plain `environment` attr plus an agenix
  `environmentFiles` secret;
- `virtualisation.docker.enableOnBoot = true` so it survives reboot;
- port published to `127.0.0.1` behind an nginx vhost.

## Arr stack (Sonarr, Radarr, Prowlarr, SABnzbd)

Services live in `modules/homelab/arr.nix`; grab policy (profiles, custom
formats, quality sizes, naming) is owned by recyclarr in
`modules/homelab/recyclarr.nix`, synced daily from the TRaSH guides. Never
edit profiles or custom formats in the arr UI — recyclarr resets unmatched
scores and deletes custom formats it does not manage. The
`{sonarr,radarr}-api-key.age` secrets are copies of each app's API key;
update them if a key is regenerated.

Profiles (assigned per series/movie in the UI):

- Sonarr `WEB-1080p` — default. `WEB-1080p (Keep)` — same with upgrades
  off, for legacy shows whose sub-1080p files must not be re-downloaded.
- Sonarr `WEB-2160p` — 4K HDR opt-in. `[Anime] Remux-1080p` — series type
  must be `anime`.
- Radarr `HD Bluray + WEB` — default; `UHD Bluray + WEB` — 4K opt-in.
  `HD Remux (Keep)` / `UHD Remux (Keep)` — upgrades off, for existing remuxes
  the main profiles would replace with encodes. All use language `Original`,
  set via the API (not a recyclarr field).

Not declarative, set once via the API: recycle bins at
`/mnt/data/.recycle/<app>`, SAB remove-completed, notifications (Jellyfin
needs an API key from its dashboard), profile assignment.

Naming formats apply to new imports only: Jellyfin keys items by path, so a
mass rename drops watched state. To rename the whole library later, back up
Jellyfin's data dir, run "Rename Files" per series/movie, and accept the lost
watched history (or migrate it first with a plugin keyed on provider ids).

## Subtitles (Bazarr)

Bazarr (`modules/homelab/arr.nix`) fetches external SRTs for everything Sonarr
and Radarr import. The NixOS module has no settings option: the config below
lives in `/var/lib/bazarr/config/config.yaml` (restic-backed) and must be
re-applied by hand if the data dir is rebuilt.

- Profile `Default`: Danish + English, no cutoff, HI as fallback, applied to
  everything. Danish rarely exists for older content, so a large wanted list
  is normal.
- Providers: OpenSubtitles.com (free tier, 20/day), subf2m (self-throttles
  without a browser user-agent string), gestdown, supersubtitles, yify,
  animetosho, embedded. Podnapisi is gone in 1.6; SubDL/Subsource need
  accounts.
- Embedded PGS/VobSub don't count as present (image subs force a Jellyfin
  transcode). Deep audio-track analysis on.
- Auto-sync thresholds 96 (series) / 86 (movies), "use original language
  audio track" on: otherwise ffsubsync syncs against the first audio stream
  and dubbed releases get a bogus offset at the 60 s cap. For manual syncs,
  an embedded text track (`reference=s:N`) beats audio.
- Upgrades on, 7-day window. Jellyfin refresh on (API key from the Jellyfin
  dashboard, immediate, Shows + Movies).
- Sonarr/Radarr import extra files (`srt`).

Pre-resync archive of every SRT: `/mnt/data/.subtitle-backup/`.

## Home Assistant + Zigbee (`modules/homelab/home-assistant/`)

Files: `hass.nix` (HA package, components, config, Adaptive Lighting profiles,
health template sensors), `_automations.nix` (every automation and script),
`_dashboard.nix` (YAML dashboard), `_devices.nix` (Zigbee inventory and the
entity-id contract every other file derives ids from, including the config-flow
integrations' provisional ids), `_zwift.nix` and `_bambu.nix` (custom
components), `mqtt.nix`
(Mosquitto and Zigbee2MQTT settings, Zigbee groups, group sync), `health.nix`
(readiness check and coordinator watchdog, both posting to #sys-info),
`_z2m-mqtt.nix` (root-only `z2m-mqtt sub|pub` broker client used by the units
and for ops).

All logic is YAML rendered from Nix: automations, scripts, Adaptive Lighting,
template sensors, the `rest_command.discord` notifier (secret `discord_webhook`
in `hass.yaml.age`), the MeteoAlarm binary sensor (YAML platform; `province`
is a regex on the alert's area name) and the dashboard. The UI owns only
config-flow integrations (MQTT, mobile app, UniFi, Google, Spotify, Sleep as
Android, MCP server, Zwift, Jellyfin, Bambu Lab), the registries (areas, the person's trackers, the enabled
link-quality sensors, the Adaptive Lighting switch ids) and Assist exposure.
Adaptive Lighting covers every room (`dev.alRooms`); the office runs AL's
default floors and the other rooms sit slightly above them (`alExtra` in
`hass.nix`). Automations that turn a room on pass `alLevel <room>`, the
`brightness_pct` attribute of that room's AL switch, so a bulb comes up at the
level AL is about to set instead of flashing its last level first; with the
switch off it falls back to a fixed night/day level. AL composes fresh
sleep-mode switch ids as `switch.adaptive_lighting_<room>_sleep_mode`; the
four original rooms keep the hand-set `..._sleep_mode_<room>` ids
(`dev.alLegacySleepIds`). After adding a room, check both ids on its device page.
`zigbee2mqtt-error-report` posts the day's failed-command count to #sys-info
at 18:15; the target is under 50. Persistent state used by automations lives
in the `input_boolean`s listed under `dev.helpers` (sleep and guest mode, the
motion latches, the Zwift ride and watching latches, the MQTT-recovery latch,
the away-simulation flag). Phone pushes use the legacy
`notify.mobile_app_<device>` action: the notify entity service takes no `data`,
so channels, tags and actions need it. The stairs motion sensor's
`illuminance_below_threshold_check: false` is a Z2M device option set over MQTT
(it lives in `devices.yaml`, not in Nix); without it the ungated stairs
automation never fires in daylight.
HA migrates the rendered `http:` block into `.storage/http` exactly once and
ignores YAML afterwards, so the live settings are managed under Settings,
System, Network. The login-attempt ban is set to 50 because the Claude MCP
connector's expired-token 401s count as strikes and the counter only resets on
restart. `use_x_forwarded_for` and `trusted_proxies` stay declared in
`hass.nix` anyway, because that one-shot migration is what seeds a rebuilt data
dir: without them every request is attributed to nginx on 127.0.0.1 and failed
logins ban the proxy, locking everyone out. The module always renders an
`http:` block, so ignore the "YAML still present" repair.

- Zigbee2MQTT friendly names are load-bearing: HA entity ids, the Nix group
  definitions and the switch automations (`zigbee2mqtt/<name>/action`) all
  derive from them. Rename a device only together with every reference.
- Groups: ids/names are settings in `mqtt.nix`; membership lives in Z2M's
  `database.db` and is reconciled by `zigbee2mqtt-groups-sync` after each Z2M
  start and daily. A member that is powered off at the wall joins on the next
  run after it is back. Target group entities, never HA areas, for multi-bulb
  actions (one multicast; no per-bulb timeout).
- Availability is on: a device that stops answering goes `unavailable` in HA.
  `advanced.last_seen` exposes per-device last-seen sensors (disabled by default).
- `version` in the Z2M settings must track upstream `CURRENT_VERSION`; Z2M
  refuses to start on an unsupported value. `log_level` must be one of
  `error|warning|info|debug`.
- Secrets in `zigbee2mqtt-secret.yaml.age`: `password` (MQTT), `network_key`
  (list of 16 ints; rotating it means re-pairing every device), `frontend_token`.
  The broker listens on loopback only; both users have `readwrite #`.
- Network identity (`pan_id`, `ext_pan_id`, `channel`, `network_key`) is pinned;
  `coordinator_backup.json` + `database.db` + `devices.yaml` are what avoid
  re-pairing. Copy them off-box before touching the dongle or the data dir.
- Coordinator hangs show as `SRSP - ... after 6000ms` in the journal with the
  process still up; `zigbee2mqtt-watchdog` restarts the unit on a burst of them.

## Shared databases

Two always-on engine leaves mirror each other — `postgres.nix`
(`services.postgresql` + `postgresqlBackup`) and `mariadb.nix`
(`services.mysql` + `mysqlBackup`). Neither dump has its own timer: restic pulls
both in right before each snapshot, so files and dumps are from the same moment.
A service declares its own DB against them:

- Postgres: `fpLib.mkPostgresDB` / `services.postgresql.ensure*`.
- MariaDB: append to `services.mysql.ensureDatabases` +
  `services.mysqlBackup.databases`. `ensureUsers` is socket-auth only, so a
  container connecting over TCP needs a
  `systemd.services.mysql.postStart = lib.mkAfter` hook to provision a
  password user. `mariadb.nix` binds `0.0.0.0` and opens 3306 on `docker0`;
  containers reach it via `--add-host=host.docker.internal:host-gateway`.
  Consumer example: `grimmory.nix`.

## Obsidian sync (`obsidian-sync.nix` + `modules/programs/obsidian/`)

Self-hosted LiveSync against CouchDB at `obsidian.<domain>`. It is public and
outside SSO (the plugin only speaks CouchDB basic auth) so work PCs off the
tailnet can sync. The `obsidian-couchdb` fail2ban jail bans on that vhost's
401s (own access log); `/_up` is the only anonymous endpoint.

- Vaults: `~/obsidian/<name>` on every desktop host, one CouchDB database
  each. The name lists live in both files; add a vault to both.
- Devices: one CouchDB user per device (`devices` in `obsidian-sync.nix`),
  password in `secrets/obsidian/<device>.age`, declared by the homelab and by
  that host's HM half (a shared generator). The phone has no Nix:
  `just secret-edit secrets/obsidian/phone.age` shows its password. Revoke a
  device by dropping it from `devices` (then delete its `_users` doc).
- `secrets/obsidian/passphrase.age` is the vault E2EE passphrase every device
  shares; the server never sees it. Changing it means a remote rebuild.
- `couchdb-obsidian-provision` creates the users and databases. Device users
  are database members only: they can't delete a database, so LiveSync's
  "rebuild remote" (first upload, or after changing E2EE/chunk settings) is
  done with the admin login (`/run/agenix/couchdb-admin` on the homelab).
  Device users then fetch.
- Backup: restic copies the CouchDB data dir as is. Its contents are E2EE,
  so a restore needs `secrets/obsidian/passphrase.age` too.
- Client side (`default.nix` app settings, `plugins.nix` per-vault plugins,
  `livesync.nix`): app settings and plugin code (`pkgs.obsidianPlugins`, from
  the `obsidian-extensions` input) are read-only Nix links. Plugin settings
  are deep-merged into each mutable `data.json` on activation (Nix keys win).
  Keep LiveSync's hidden-file sync off. Customization sync is on so the phone
  can apply the Nix hosts' plugins/settings; never apply it on a Nix host.
  Templater's "trigger on file creation" is per-device localStorage, so the
  package is patched to default it on. `format-plugin.js` is our own
  plugin (Ctrl+Shift+P): it pipes each fenced code block through a
  Nix-pinned formatter picked by the fence language, then runs the Linter. LiveSync's own `data.json` stays
  mutable: `obsidian-livesync-seed` (run on activation) writes the
  connection, E2EE and path-obfuscation settings only when the file is
  missing, so delete it to re-seed after a password change.
  `obsidian-livesync-creds` prints the device's login and the passphrase; the
  phone must match the seeded E2EE + path obfuscation settings.
