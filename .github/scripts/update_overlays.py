#!/usr/bin/env python3
"""Bump the manually fetched packages in overlays/ to their latest upstream release.

Each overlay has an updater that finds the latest version, prefetches the new
hash with `nix store prefetch-file` and rewrites the overlay in place. One
overlay failing to update never stops the others.

Usage: update_overlays.py [--only NAME ...] [--json PATH]

--json writes `{name: {"status": "updated"|"unchanged"|"failed", "old", "new",
"error"}}` for every overlay that ran. Exits 0 even when an updater fails; the
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
OVERLAYS = ROOT / "overlays"


def fetch(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "nixos-update-overlays"})
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


def prefetch(url: str) -> str:
    out = subprocess.run(
        ["nix", "store", "prefetch-file", "--json", "--hash-type", "sha256", url],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
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
    path = OVERLAYS / "claude-code-manifest.zst.json"
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
    path = OVERLAYS / "bambu-studio.nix"
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
    # The overlay builds the URL from a template; fail rather than ship a 404.
    expected = (
        f"https://github.com/bambulab/BambuStudio/releases/download/v{new}/"
        f"BambuStudio_ubuntu{ubuntu_version}.AppImage"
    )
    if asset["browser_download_url"] != expected:
        raise RuntimeError(
            f"asset URL {asset['browser_download_url']} no longer matches the overlay's template"
        )
    text = replace_once(text, r'^\s*version = "([^"]+)";', new)
    text = replace_once(text, r'^\s*ubuntu_version = "([^"]+)";', ubuntu_version)
    text = replace_once(text, r'^\s*sha256 = "([^"]+)";', prefetch(expected))
    path.write_text(text)
    return old, new


def update_claude_desktop() -> tuple[str, str]:
    path = OVERLAYS / "claude-desktop.nix"
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
        raise RuntimeError(f"index Filename {latest['Filename']} no longer matches the overlay's URL")
    text = replace_once(text, r'^\s*version = "([^"]+)";', new)
    text = replace_once(text, r'^\s*hash = "([^"]+)";', sri_from_hex(latest["SHA256"]))
    path.write_text(text)
    return old, new


# name -> (updater, files it rewrites); the files are what update_bot.py reverts to hold one back.
UPDATERS = {
    "claude-code": (update_claude_code, ["overlays/claude-code-manifest.zst.json"]),
    "bambu-studio": (update_bambu_studio, ["overlays/bambu-studio.nix"]),
    "claude-desktop": (update_claude_desktop, ["overlays/claude-desktop.nix"]),
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--only", action="append", choices=sorted(UPDATERS))
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()

    results = {}
    for name in args.only or UPDATERS:
        updater, _files = UPDATERS[name]
        try:
            old, new = updater()
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
