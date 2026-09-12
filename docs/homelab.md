# Homelab services

Read this before adding or reworking a service under `modules/homelab/`.

Services are native NixOS services by default, gated on
`fireproof.homelab.enable` (leaf authoring rules: `docs/modules.md`). Every
new service gets a dashboard link in `modules/homelab/glance/_home-page.nix`,
and its vhost via `fpLib.mkVirtualHost`.

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
needs an API key from its dashboard), profile assignment. qBittorrent is
deliberately not attached to any arr (no torrent indexers).

Naming formats apply to new imports only: Jellyfin keys items by path, so a
mass rename drops watched state. To rename the whole library later, back up
Jellyfin's data dir, run "Rename Files" per series/movie, and accept the lost
watched history (or migrate it first with a plugin keyed on provider ids).

## Shared databases

Two always-on engine leaves mirror each other — `postgres.nix`
(`services.postgresql` + `postgresqlBackup`) and `mariadb.nix`
(`services.mysql` + `mysqlBackup`), both folding dumps into the restic set.
A service declares its own DB against them:

- Postgres: `fpLib.mkPostgresDB` / `services.postgresql.ensure*`.
- MariaDB: append to `services.mysql.ensureDatabases` +
  `services.mysqlBackup.databases`. `ensureUsers` is socket-auth only, so a
  container connecting over TCP needs a
  `systemd.services.mysql.postStart = lib.mkAfter` hook to provision a
  password user. `mariadb.nix` binds `0.0.0.0` and opens 3306 on `docker0`;
  containers reach it via `--add-host=host.docker.internal:host-gateway`.
  Consumer example: `grimmory.nix`.
