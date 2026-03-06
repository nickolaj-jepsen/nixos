---
description: Check for updates to manually fetched overlay packages and maintain the update PR
on:
  schedule: daily
  workflow_dispatch:
permissions:
  contents: read
  issues: read
  pull-requests: read
tools:
  github:
    toolsets: [default]
  web-fetch:
network:
  allowed:
    - node
    - github
    - storage.googleapis.com
    - install.determinate.systems
    - cache.nixos.org
    - python
    - go
safe-outputs:
  create-pull-request:
    draft: false
    max: 1
  update-pull-request:
    target: "*"
  push-to-pull-request-branch:
    max: 1
    target: "*"
    title-prefix: "chore(overlays): "
    labels: [dependencies, automated]
  noop:
---

# Update Overlay Packages

You are an AI agent that checks for updates to manually fetched packages in a NixOS configuration repository. If updates are found, keep a single pull request with all changes up to date.

## Setup

Before checking packages, install Nix to compute package hashes:

```bash
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install linux --no-confirm
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
```

Verify with `nix --version`.

## Hash Computation

Two hash formats are used in this repo:

- **Hex format** (no prefix): `"e7e847383c466..."` — used in `claude-code.nix` and `github-copilot-cli.nix`
- **SRI format** (`sha256-` prefix): `"sha256-DfDsU/qY..."` — used everywhere else

To compute hashes:

- **For `fetchurl`** (direct file download): `nix-prefetch-url <url>` returns hex hash
- **For `fetchFromGitHub`** (repo archive): `nix-prefetch-url --unpack "https://github.com/<owner>/<repo>/archive/<rev>.tar.gz"` returns hex hash
- **Convert hex → SRI**: `nix hash to-sri --type sha256 <hex-hash>`

## Packages to Check

Read each overlay file first to determine the current version/revision, then check upstream.

### 1. Claude Code (`overlays/claude-code.nix`)

- **Latest version**: Fetch `https://registry.npmjs.org/@anthropic-ai/claude-code` and read `dist-tags.latest`
- **New hash**: `nix-prefetch-url "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/<VERSION>/linux-x64/claude"`
- **Update fields**: `version` (string) and `sha256` (hex format, no prefix)

### 2. BambuStudio (`overlays/bambu-studio.nix`)

- **Latest version**: Check latest release of `bambulab/BambuStudio` on GitHub
- **New hash**: Find the `Bambu_Studio_ubuntu-*.AppImage` asset in the release. Run `nix-prefetch-url <asset-url>` and convert to SRI
- **Update fields**: `version`, `ubuntu_version` (extract from asset filename: `Bambu_Studio_ubuntu-<ubuntu_version>.AppImage`), and `sha256` (SRI format)

### 3. Fish Plugins (`overlays/fish-plugins.nix`)

For each plugin, check the latest commit on the default branch:

**to-fish** (`joehillen/to-fish`):

- **New hash**: `nix-prefetch-url --unpack "https://github.com/joehillen/to-fish/archive/<REV>.tar.gz"` → SRI
- **Update fields**: `rev` and `sha256` (SRI format)

**theme-bobthefish** (`oh-my-fish/theme-bobthefish`):

- **New hash**: `nix-prefetch-url --unpack "https://github.com/oh-my-fish/theme-bobthefish/archive/<REV>.tar.gz"` → SRI
- **Update fields**: `rev` and `hash` (SRI format)

### 4. Home Assistant Components (`overlays/home-assistant.nix`)

For each component, check the latest GitHub release tag:

**bambu_lab** (`greghesp/ha-bambulab`):

- **Update fields**: `version` and `hash` (SRI format)

**switch_manager** (`Sian-Lee-SA/Home-Assistant-Switch-Manager`):

- **Update fields**: `version` and `hash` (SRI format)

**zwift** (`snicker/zwift_hass`):

- **Update fields**: `version` and `hash` (SRI format)

**zwift-client** (`nickolaj-jepsen/zwift-client`):

- Check latest commit on default branch (not releases)
- **Update fields**: `rev` and `hash` (SRI format)

### 5. GitHub Agentic Workflows (`overlays/gh-aw.nix`)

- **Latest version**: Check latest release of `github/gh-aw` on GitHub
- **New hash**: `nix-prefetch-url "https://github.com/github/gh-aw/releases/download/v<VERSION>/linux-amd64"` → SRI
- **Update fields**: `version` (in both the attribute and the `url` string) and `sha256` (SRI format)

### 6. GitHub Copilot CLI (`overlays/github-copilot-cli.nix`)

- **Latest version**: Fetch `https://registry.npmjs.org/@github/copilot` and read `dist-tags.latest`
- **New hash**: `nix-prefetch-url "https://registry.npmjs.org/@github/copilot/-/copilot-<VERSION>.tgz"`
- **Update fields**: `version` and `sha256` (hex format, no prefix)

### 7. Neovim Plugins (`overlays/neovim-plugins.nix`)

**darcula** (`doums/darcula`):

- Check latest commit on default branch
- **Update fields**: `rev`, `version` (format `YYYY-MM-DD` of commit date), and `sha256` (SRI format)

## Reusing the Existing PR

Always use the branch name `chore/update-overlays`.

Before making any changes, check if there is already an open PR with head branch `chore/update-overlays`. If you cannot find one by branch, fall back to searching for the title `chore(overlays): update packages`.

If an open PR already exists and you have new overlay updates:

- Use `push_to_pull_request_branch` to push the new changes to that PR instead of creating a new PR.
- Use `update_pull_request` to replace the PR body so it matches the latest set of updated packages.
- Keep the PR title as `chore(overlays): update packages`.
- Do **not** call `create_pull_request` for an existing PR.

If no open PR exists and updates are needed, call `create_pull_request` with:

- **Branch**: `chore/update-overlays`
- **Title**: `chore(overlays): update packages`
- **Draft**: `false`
- **Labels**: `dependencies`, `automated`

If the existing PR already contains all the latest updates, or if no files changed, use `noop`.

## Procedure

1. Install Nix (see Setup)
2. Read all overlay files to get current versions
3. Check each package for updates using GitHub API and web-fetch
4. For packages with updates available:
   a. Compute the new hash with `nix-prefetch-url`
   b. Convert to the correct format (hex or SRI as noted above)
   c. Edit the file to update version/rev and hash
5. If any files changed, either update the existing overlay PR or create it if missing
6. If nothing changed, use `noop` output

## Pull Request

- **Title**: `chore(overlays): update packages`
- **Branch**: `chore/update-overlays`
- **Draft**: `false`
- **Body**: List each updated package with old and new version/revision
- **Labels**: `dependencies`, `automated`
