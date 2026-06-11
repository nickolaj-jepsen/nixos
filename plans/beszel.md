# Plan: Beszel — local host / container / GPU monitor

## Goal

A fully-local, glanceable monitor for the homelab box (CPU, RAM, disk, network,
docker containers, **and GPU**) that survives a Grafana Cloud outage/quota. Your
only metrics path today is Prometheus agent-mode → hosted Grafana Cloud; Beszel
complements it with an on-box dashboard and **NVIDIA GPU utilisation** — directly
useful since this box does Jellyfin/Immich transcode + ML.

> Beszel **complements** the Prometheus→Grafana Cloud pipeline; it does not ingest
> or replace it (separate SQLite/PocketBase backend).

## Verified facts (pinned nixpkgs, beszel 0.18.7)

Two modules: `services.beszel.hub` + `services.beszel.agent`.

- **hub**: `enable`, `package`, `host` (default `127.0.0.1`), `port` (default
  `8090`), `dataDir` (`/var/lib/beszel-hub`), `environment`, `environmentFile`.
  Hardened DynamicUser. Runs migrations on start.
- **agent**: `enable`, `openFirewall` (port 45876), `smartmon.{enable,package,
deviceAllow}`, `environment` (typed, incl. `SKIP_SYSTEMD`), `environmentFile`,
  `extraPath`.
- **GPU is automatic**: the agent module appends `nvidia-smi` to its PATH when
  `services.xserver.videoDrivers` contains `"nvidia"` — which it does on this
  host. No manual `extraPath` needed.
- Topology here = **one hub + one agent on the same box**; the hub reaches the
  agent over `localhost:45876`, so `openFirewall` stays **false**.

## The pairing problem → two-phase deploy

The agent authorises the hub using the hub's **public key**, which the hub only
generates on first boot and reveals in the web UI when you click _Add System_.
You can't know it in advance, so deploy in two phases.

### Decisions

- Web UI behind **oauth2-proxy** (`allowed_groups = ["default"]`), like Glance —
  defence in depth. You'll still do one Beszel login that the browser remembers
  (or wire Zitadel OIDC later via `environment.DISABLE_PASSWORD_AUTH`).
- `smartmon.enable = true` for disk SMART health (adds the agent to the `disk`
  group + the needed capabilities).
- Hub data dir in the restic set.

## Module: `modules/homelab/beszel.nix`

```nix
{
  config,
  lib,
  fpLib,
  ...
}: let
  cfg = config.fireproof.homelab;
  domain = "beszel.${cfg.domain}";
  port = 8090;
in {
  config = lib.mkIf cfg.enable {
    # Filled in PHASE 2 with the hub's public key (and TOKEN if you use it):
    #   KEY=ssh-ed25519 AAAA...
    age.secrets.beszel-agent-env.rekeyFile =
      ../../secrets/hosts/homelab/beszel-agent-env.age;

    services.restic.backups.homelab.paths = [ "/var/lib/beszel-hub" ];

    services.oauth2-proxy.nginx.virtualHosts."${domain}".allowed_groups = ["default"];

    services.nginx.virtualHosts."${domain}" = fpLib.mkVirtualHost {
      inherit port;
      websockets = true; # PocketBase realtime
    };

    services.beszel = {
      hub = {
        enable = true;
        host = "127.0.0.1";
        inherit port;
      };

      # ── PHASE 2: uncomment once beszel-agent-env.age contains the KEY ──
      # agent = {
      #   enable = true;
      #   environmentFile = config.age.secrets.beszel-agent-env.path;
      #   smartmon.enable = true;          # disk SMART
      #   # nvidia-smi auto-added because videoDrivers = ["nvidia"] → GPU stats
      # };
    };
  };
}
```

## Procedure

**Phase 1 — hub only**

```fish
# (agent block commented out)
just build-system homelab   # then switch
```

Open `https://beszel.nickolaj.com` → create the admin account → **Add System**:

- Name: `homelab`, Host/IP: `localhost`, Port: `45876`
- Copy the **KEY** it shows (`ssh-ed25519 AAAA…`).

**Phase 2 — agent**

```fish
just secret-edit ./secrets/hosts/homelab/beszel-agent-env.age
# paste:  KEY=ssh-ed25519 AAAA...   (the value from the UI)
just secret-rekey
```

Uncomment the `agent` block, then `just build-system homelab` → switch. The system
tile in the UI flips to green and GPU/disk panels populate.

## Dashboard tile (`modules/homelab/glance/_home-page.nix`)

```nix
{ title = "Beszel"; url = "https://beszel.${cfg.domain}"; icon = "sh:beszel"; same-tab = true; }
```

## Verify

```fish
just build-system homelab
systemctl status beszel-hub beszel-agent
journalctl -u beszel-agent -n 50
# In the UI: CPU/mem/disk/net live; GPU panel shows the GTX 970; SMART under disk.
```

## Caveats / notes

- The hub's admin account + paired-system config is imperative state inside
  `/var/lib/beszel-hub` (now backed up).
- This is GPU **monitoring** (nvidia-smi), unrelated to the local-LLM limitation —
  it works fine on the GTX 970.
- If you later add other hosts to the tailnet, install the agent there and add
  them in the same UI (their own KEY each).
