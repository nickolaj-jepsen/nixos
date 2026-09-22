---
description: Check for updates to manually fetched overlay packages and maintain the update PR
strict: true
on:
  schedule: daily
  workflow_dispatch:
permissions:
  contents: read
  issues: read
  pull-requests: read
  copilot-requests: write
tools:
  github:
    toolsets: [default]
  web-fetch:
network:
  allowed:
    - github
    - downloads.claude.ai
safe-outputs:
  create-pull-request:
    draft: false
    max: 1
    labels: [dependencies, automated]
  update-pull-request:
    target: "*"
  push-to-pull-request-branch:
    max: 1
    target: "*"
    required-title-prefix: "chore(overlays): "
    required-labels: [dependencies, automated]
  noop:
---

# Update Overlay Packages

You are an AI agent that checks for updates to manually fetched packages in a NixOS configuration repository. If updates are found, keep a single pull request with all changes up to date.

## Hash Computation

There is no Nix in this environment and you must not try to install one. Every
hash the overlays need comes from `.github/scripts/nix-hash.py` (plain Python 3,
no dependencies), which prints the SRI string (`sha256-...`) ready to paste:

- **`fetchurl`** (direct file download):
  `python3 .github/scripts/nix-hash.py file <url>`
- **`fetchFromGitHub`** (repo archive, NAR hash of the unpacked tree):
  `python3 .github/scripts/nix-hash.py unpack "https://github.com/<owner>/<repo>/archive/<tag>.tar.gz"`
- **Hex digest from an index** (e.g. an apt `Packages` file):
  `python3 .github/scripts/nix-hash.py sri <hex>`

Never guess or hand-compute a hash. If the script fails, report it with
`missing_tool` instead of working around it.

## Packages to Check

Read each overlay file first to determine the current version/revision, then check upstream.

### 1. Claude Code (`overlays/claude-code.nix`)

The overlay carries no hashes: it feeds upstream's release manifest into the
nixpkgs package, which derives the download URL, version and per-platform
checksum from it. Updating means replacing the vendored manifest.

- **Latest version**: fetch `https://downloads.claude.ai/claude-code-releases/latest` (plain text)
- **Update**: overwrite `overlays/claude-code-manifest.zst.json` with
  `https://downloads.claude.ai/claude-code-releases/<VERSION>/manifest.zst.json`
- **Do not edit** `overlays/claude-code.nix` — no `version` or hash lives there
- Report the old → new version from the manifest's `version` field

### 2. BambuStudio (`overlays/bambu-studio.nix`)

- **Latest version**: Check latest release of `bambulab/BambuStudio` on GitHub
- **New hash**: Find the `BambuStudio_ubuntu-*.AppImage` asset for Ubuntu 24.04 in the release and run `nix-hash.py file <asset-url>`
- **Update fields**: `version`, `ubuntu_version` (extract from asset filename: `BambuStudio_ubuntu<ubuntu_version>.AppImage`), and `sha256`
- **Note**: The URL template in the nix file must match the actual asset filename exactly — upstream has changed naming conventions in the past (e.g. `Bambu_Studio_` → `BambuStudio_`). Always verify the asset name from the release before updating.

### 3. GitHub Agentic Workflows (`overlays/gh-aw.nix`)

- **Latest version**: Check latest release of `github/gh-aw` on GitHub
- **New hashes**: each platform ships a distinct binary, so compute one hash per
  entry in `sha256Map`. For each of `linux-amd64` and `darwin-arm64` (the only
  platforms any host builds), run
  `nix-hash.py file "https://github.com/github/gh-aw/releases/download/v<VERSION>/<platform>"`
- **Update fields**: `version` (in both the attribute and the `url` string) and both
  `sha256Map` entries

### 4. Claude Desktop (`overlays/claude-desktop.nix`)

Upstream publishes no release feed — the apt repository index is the source of truth.

- **Latest version**: fetch
  `https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/main/binary-amd64/Packages`
  and take the highest `Version:` (sort with `sort -V`; entries are not ordered)
- **New hashes**: the index already carries a `SHA256:` per package, so no download is
  needed — read the `SHA256:` of the chosen version from the `binary-amd64` index
  (x86_64-linux is the only platform built) and convert it with `nix-hash.py sri <hex>`
- **Update fields**: `version` and `sources.x86_64-linux.hash`

## Procedure

1. Read all overlay files to get current versions
2. Check each package for updates using the GitHub API and web-fetch
3. For packages with updates available, compute the new hash with `nix-hash.py`
   and edit the file to update version/rev and hash
4. If any files changed, update the existing overlay PR or create it if missing
5. If nothing changed, use `noop`

## Pull Request

The branch name is chosen for you (a `chore/update-overlays-<id>` prefix), so
look for an existing PR by title, not by branch: search open PRs for the exact
title `chore(overlays): update packages` carrying the `automated` label.

If one exists and you have new updates:

- Use `push_to_pull_request_branch` to push the new changes to that PR.
- Use `update_pull_request` to replace the PR body so it lists the full set of
  updated packages.
- Do **not** call `create_pull_request`.

If none exists and updates are needed, call `create_pull_request` with:

- **Title**: `chore(overlays): update packages`
- **Body**: one line per updated package with old → new version, plus any
  package you skipped and why
- **Draft**: `false`
- **Labels**: `dependencies`, `automated`

If the existing PR already contains every update, or nothing changed, use `noop`.
