# Ebook stack: expanding the simple Grimmory setup to the "maxed" version

## Where we are (simple, implemented)

`modules/homelab/grimmory.nix` runs **Grimmory** (the maintained BookLore fork) as a
single OCI container — backed by the shared **native MariaDB** engine
(`modules/homelab/mariadb.nix`, set up like the native postgres pair) — behind nginx
at `grimmory.<domain>`:

- **KOReader file sync** — Grimmory OPDS feed (`/api/v1/opds`).
- **KOReader read sync** — Grimmory's native kosync endpoint (`/api/koreader`),
  configured in KOReader under _Progress sync → Custom sync server_. Two-way,
  device↔device, precise position (XPointer/CFI), no separate sync server.
- **Hardcover** — Grimmory can push reading status/progress to Hardcover per-user
  (one-way scrobble), if a Hardcover token is configured in its UI.
- **Shelfmark** — already feeds the shared `/mnt/data/books` library that Grimmory
  indexes (read-only).
- **Web reader** — built in.

The library is shared read-only (`DISK_TYPE=NETWORK`), so Grimmory never rewrites
files. Books must be **downloaded from Grimmory via OPDS** for progress to link
(KOReader matches by content hash — a sideloaded copy won't match).

What's missing from the wishlist: **Audiobookshelf audiobook progress ↔ KOReader
ebook progress** linkage. That's what the maxed version adds.

## Target (maxed)

Add **`abs-kosync-bridge`** (the `cporcellijr` "ABS-KoSync Enhanced" fork) as the
central sync hub. It ships its own internal kosync server and does multi-way sync
across **Audiobookshelf ↔ KOReader ↔ Grimmory ↔ Hardcover** (and Storyteller, if
ever added). It maps audiobook timecodes to ebook positions via alignment data, so
listening on ABS and reading on KOReader advance the same place in a book.

```
                         ┌─────────────────────┐
   KOReader  ──kosync──▶ │   abs-kosync-bridge │ ──▶ Audiobookshelf (audio position)
  (ebooks)               │  (internal kosync,  │ ──▶ Grimmory       (ebook position)
                         │   :5757 dashboard,  │ ──▶ Hardcover      (scrobble)
   ABS app  ──progress──▶│   :5758 sync API)   │
  (audio)                └─────────────────────┘
   Grimmory OPDS ── files ──▶ KOReader
```

Key change: KOReader's _Progress sync_ server URL moves **from Grimmory to the
bridge**. Grimmory keeps serving files (OPDS) and the web reader; the bridge becomes
the progress authority and fans progress out to Grimmory, ABS, and Hardcover.

## Decisions to make before implementing

1. **Single Hardcover owner.** Both Grimmory and the bridge can scrobble to
   Hardcover; running both = double writes. In the maxed setup let the **bridge own
   Hardcover** (it unifies audio+ebook) and remove the Hardcover token from Grimmory.
2. **Audio↔ebook alignment source.** The bridge maps positions using, in order:
   Storyteller forced-alignment transcripts → embedded SMIL → a `faster-whisper`
   transcription fallback. Whisper is CPU/GPU-heavy. Decide: accept Whisper on the
   homelab (slow, one-time per book), or only expect linkage for books that have
   alignment data. Plain "same title in ABS and Grimmory" without alignment gives
   coarse mapping at best.
3. **Verify upstream specifics — and don't trust the compose's image tag.** Grimmory's
   own `docker-compose.yml` references `grimmory/grimmory:v0.38.2`, a tag that was never
   published (real tags are `v3.x`; we pin `v3.2.2`). Confirm the bridge's image
   name/tag against the registry's actual tag list (Docker Hub / GHCR), plus its env
   vars and ports, rather than trusting the compose or these notes.

## Implementation steps

### 1. Secrets (agenix, nixos side)

Add a bridge env secret holding the credentials the bridge needs:

```
just secret-edit secrets/hosts/homelab/abs-kosync-bridge-env.age   # then `just secret-rekey` (YubiKey)
```

Contents (names per the bridge's compose — verify):

```
ABS_URL=https://audiobookshelf.<domain>
ABS_API_TOKEN=...        # Audiobookshelf → Settings → Users → <user> → API token
GRIMMORY_URL=https://grimmory.<domain>
GRIMMORY_USERNAME=...     # a Grimmory KOReader-sync user
GRIMMORY_PASSWORD=...
HARDCOVER_TOKEN=...       # hardcover.app/account/api (Bearer; expires yearly, rotate)
```

### 2. New module `modules/homelab/abs-kosync-bridge.nix`

Mirror the structure of `grimmory.nix` (it established the homelab's OCI-container
pattern):

- `age.secrets.abs-kosync-bridge-env.rekeyFile = ../../secrets/hosts/homelab/abs-kosync-bridge-env.age;`
- `virtualisation.oci-containers.containers.abs-kosync-bridge`:
  - image/tag/env from the upstream compose (verify);
  - `environmentFiles = [config.age.secrets.abs-kosync-bridge-env.path];`
  - persistent state volume under `/var/lib/abs-kosync-bridge` (tmpfiles-created);
  - `ports = ["127.0.0.1:5757:5757" "127.0.0.1:5758:5758"];` (dashboard + sync API —
    confirm port numbers);
  - reuse the `grimmory` docker network _only_ if the bridge needs to reach MariaDB
    (it shouldn't — it talks HTTP to ABS/Grimmory, so default bridge networking with
    `127.0.0.1` published ports is fine).
- nginx: expose the **sync API** publicly so KOReader can reach it off-LAN:
  `services.nginx.virtualHosts."koreader-sync.<domain>" = fpLib.mkVirtualHost { port = 5758; websockets = true; };`
  Keep the **dashboard** (`:5757`) gated behind oauth2-proxy like Shelfmark:
  `services.oauth2-proxy.nginx.virtualHosts."<dashboard-domain>".allowed_groups = ["arr"];`
  (the sync API must stay un-gated — KOReader can't do the OIDC flow).
- `services.restic.backups.homelab.paths = ["/var/lib/abs-kosync-bridge"];`
- Glance: add a dashboard link in `glance/_home-page.nix`.

### 3. Reconfigure clients (not NixOS — done in the apps)

- **Grimmory:** remove its Hardcover token (bridge owns Hardcover now). Keep OPDS +
  web reader. Keep a KOReader-sync user for the bridge to push into.
- **KOReader:** point _Progress sync → Custom sync server_ at
  `https://koreader-sync.<domain>` (the bridge), instead of Grimmory. Keep the OPDS
  catalog pointed at Grimmory for file downloads. Optionally install the bridge's
  "Bridge Sync" KOReader plugin (auto-uploads reading stats / self-updates).
- **Audiobookshelf:** generate the API token used in the secret. No NixOS change.
- **Bridge dashboard:** link ABS, Grimmory, Hardcover; use per-service _Test
  Connection_; map the books you want audio↔ebook linkage for.

### 4. Cutover & retire Kavita

Once Grimmory + bridge are validated end-to-end (file download, progress round-trip
KOReader↔Grimmory↔ABS, Hardcover scrobble), delete `modules/homelab/kavita.nix` and
its Glance link, and drop the Kavita secrets. (Grimmory and Kavita can run in
parallel during migration — both just index `/mnt/data/books`.)

## Verification checklist

- [ ] KOReader downloads a book from Grimmory OPDS.
- [ ] Read a few pages on KOReader → progress appears in the bridge dashboard and in
      Grimmory's web reader.
- [ ] Listen in ABS → KOReader position for the same book advances (requires
      alignment data for that title).
- [ ] Hardcover shows "Currently reading" / page progress, written **once** (no
      double-scrobble from Grimmory).
- [ ] Reboot the homelab → `mysql`, `docker-grimmory` and `docker-abs-kosync-bridge`
      come back (docker `enableOnBoot`), and `mysqlBackup` still dumps into the restic
      set.

## Gotchas (carried over)

- Progress links only for books **downloaded from Grimmory via OPDS** (content-hash
  matching); sideloaded copies won't sync.
- Hardcover's API is beta ("in flux"), tokens expire after a year and reset Jan 1 —
  rotate the agenix secret annually.
- All Hardcover routes are push-only; nothing pulls Hardcover state back onto the
  device.
