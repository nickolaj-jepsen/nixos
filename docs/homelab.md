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
