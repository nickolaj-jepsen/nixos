#!/usr/bin/env python3
"""Bump the hand-pinned packages in pkgs/ to their latest upstream release.

Each package with an updater gets its latest version looked up, the new hash
prefetched with `nix store prefetch-file`, and pkgs/<name>/ rewritten in place.
One package failing to update never stops the others.

Usage: update_packages.py [--only NAME ...] [--json PATH]

--json writes `{name: {"status": "updated"|"unchanged"|"failed", "old", "new",
"error"}}` for every package that ran. Exits 0 even when an updater fails; the
caller reads the failures from the JSON.
"""

import argparse
import json
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PKGS = ROOT / "pkgs"


def fetch(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "nixos-update-packages"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return resp.read()


def github_latest_release(repo: str) -> dict:
    out = subprocess.run(
        ["gh", "api", f"repos/{repo}/releases/latest"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return json.loads(out)


def prefetch(url: str, unpack: bool = False) -> str:
    """SRI sha256 of `url`; with `unpack`, of the unpacked archive (what fetchzip/fetchFromGitHub pin)."""
    cmd = ["nix", "store", "prefetch-file", "--json", "--hash-type", "sha256", url]
    if unpack:
        cmd.insert(3, "--unpack")
    out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
    return json.loads(out)["hash"]


def sri_from_hex(hex_digest: str) -> str:
    out = subprocess.run(
        ["nix", "hash", "convert", "--hash-algo", "sha256", "--to", "sri", hex_digest],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return out.strip()


def replace_once(text: str, pattern: str, value: str) -> str:
    """Replace group 1 of the single match of `pattern` in `text` with `value`."""
    matches = list(re.finditer(pattern, text, flags=re.MULTILINE))
    if len(matches) != 1:
        raise RuntimeError(f"expected one match for {pattern!r}, found {len(matches)}")
    m = matches[0]
    return text[: m.start(1)] + value + text[m.end(1) :]


def read_field(text: str, pattern: str) -> str:
    m = re.search(pattern, text, flags=re.MULTILINE)
    if not m:
        raise RuntimeError(f"no match for {pattern!r}")
    return m.group(1)


def version_key(v: str) -> list:
    return [int(p) if p.isdigit() else p for p in re.split(r"[.\-+~]", v)]


def update_claude_code() -> tuple[str, str]:
    path = PKGS / "claude-code" / "manifest.zst.json"
    old = json.loads(path.read_text())["version"]
    new = fetch("https://downloads.claude.ai/claude-code-releases/latest").decode().strip()
    if new != old:
        manifest = json.loads(
            fetch(f"https://downloads.claude.ai/claude-code-releases/{new}/manifest.zst.json")
        )
        if manifest.get("version") != new:
            raise RuntimeError(f"manifest for {new} reports version {manifest.get('version')}")
        path.write_text(json.dumps(manifest, indent=2) + "\n")
    return old, new


def update_bambu_studio() -> tuple[str, str]:
    path = PKGS / "bambu-studio" / "package.nix"
    text = path.read_text()
    old = read_field(text, r'^\s*version = "([^"]+)";')
    release = github_latest_release("bambulab/BambuStudio")
    new = release["tag_name"].removeprefix("v")
    if new == old:
        return old, new
    assets = [
        a for a in release["assets"] if re.fullmatch(r"BambuStudio_ubuntu24\.04-.+\.AppImage", a["name"])
    ]
    if len(assets) != 1:
        names = ", ".join(a["name"] for a in release["assets"])
        raise RuntimeError(f"no unique Ubuntu 24.04 AppImage in {new}: {names}")
    asset = assets[0]
    ubuntu_version = asset["name"].removeprefix("BambuStudio_ubuntu").removesuffix(".AppImage")
    # The package builds the URL from a template; fail rather than ship a 404.
    expected = (
        f"https://github.com/bambulab/BambuStudio/releases/download/v{new}/"
        f"BambuStudio_ubuntu{ubuntu_version}.AppImage"
    )
    if asset["browser_download_url"] != expected:
        raise RuntimeError(
            f"asset URL {asset['browser_download_url']} no longer matches the package's template"
        )
    text = replace_once(text, r'^\s*version = "([^"]+)";', new)
    text = replace_once(text, r'^\s*ubuntuVersion = "([^"]+)";', ubuntu_version)
    text = replace_once(text, r'^\s*hash = "([^"]+)";', prefetch(expected))
    path.write_text(text)
    return old, new


def update_claude_desktop() -> tuple[str, str]:
    path = PKGS / "claude-desktop" / "package.nix"
    text = path.read_text()
    old = read_field(text, r'^\s*version = "([^"]+)";')
    index = fetch(
        "https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/main/binary-amd64/Packages"
    ).decode()
    packages = []
    for stanza in index.split("\n\n"):
        fields = dict(line.split(": ", 1) for line in stanza.splitlines() if ": " in line and line[0] != " ")
        if fields.get("Package") == "claude-desktop":
            packages.append(fields)
    if not packages:
        raise RuntimeError("no claude-desktop entries in the apt index")
    latest = max(packages, key=lambda f: version_key(f["Version"]))
    new = latest["Version"]
    if new == old:
        return old, new
    expected_file = f"pool/main/c/claude-desktop/claude-desktop_{new}_amd64.deb"
    if latest["Filename"] != expected_file:
        raise RuntimeError(f"index Filename {latest['Filename']} no longer matches the package's URL")
    text = replace_once(text, r'^\s*version = "([^"]+)";', new)
    text = replace_once(text, r'^\s*hash = "([^"]+)";', sri_from_hex(latest["SHA256"]))
    path.write_text(text)
    return old, new


def update_github_release(name: str, repo: str) -> tuple[str, str]:
    """For a package whose `version` is the release tag and whose src is fetchFromGitHub at it."""
    path = PKGS / name / "package.nix"
    text = path.read_text()
    old = read_field(text, r'^\s*version = "([^"]+)";')
    new = github_latest_release(repo)["tag_name"]
    if new == old:
        return old, new
    text = replace_once(text, r'^\s*version = "([^"]+)";', new)
    text = replace_once(
        text,
        r'^\s*hash = "([^"]+)";',
        prefetch(f"https://github.com/{repo}/archive/{new}.tar.gz", unpack=True),
    )
    path.write_text(text)
    return old, new


# pkgs/<name> -> updater; update_bot.py holds one back by reverting that directory.
UPDATERS = {
    "claude-code": update_claude_code,
    "bambu-studio": update_bambu_studio,
    "claude-desktop": update_claude_desktop,
    "ha-bambulab": lambda: update_github_release("ha-bambulab", "greghesp/ha-bambulab"),
    "zwift-hass": lambda: update_github_release("zwift-hass", "snicker/zwift_hass"),
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--only", action="append", choices=sorted(UPDATERS))
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()

    results = {}
    for name in args.only or UPDATERS:
        try:
            old, new = UPDATERS[name]()
            status = "updated" if old != new else "unchanged"
            results[name] = {"status": status, "old": old, "new": new}
            print(f"{name}: {old} -> {new}" if old != new else f"{name}: {old} (latest)")
        except Exception as e:  # noqa: BLE001 - one broken upstream must not stop the rest
            results[name] = {"status": "failed", "error": f"{type(e).__name__}: {e}"}
            print(f"{name}: FAILED: {e}", file=sys.stderr)

    if args.json:
        args.json.write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
