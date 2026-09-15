#!/usr/bin/env python3
"""Compute Nix SRI hashes without a Nix installation.

Subcommands (all print a single `sha256-...` line):
  file <url>      hash for `fetchurl` — sha256 of the downloaded bytes
  unpack <url>    hash for `fetchFromGitHub` / `fetchzip` — NAR hash of the
                  unpacked tarball with its single top-level directory stripped
  sri <hex>       convert a hex sha256 digest (e.g. from an apt Packages index)

Exits non-zero with a message on stderr if the download fails or the tarball
does not have exactly one top-level directory (fetchzip rejects those too).
"""

import base64
import hashlib
import io
import struct
import sys
import tarfile
import urllib.request


def sri(digest: bytes) -> str:
    return "sha256-" + base64.b64encode(digest).decode()


def download(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "nix-hash.py"})
    with urllib.request.urlopen(req, timeout=600) as resp:
        return resp.read()


# NAR serialisation, see Nix manual "Nix Archive (NAR) format".
def nar_str(h, data: bytes) -> None:
    h.update(struct.pack("<Q", len(data)))
    h.update(data)
    if len(data) % 8:
        h.update(b"\0" * (8 - len(data) % 8))


def nar_node(h, node) -> None:
    nar_str(h, b"(")
    nar_str(h, b"type")
    kind = node["type"]
    if kind == "regular":
        nar_str(h, b"regular")
        if node["executable"]:
            nar_str(h, b"executable")
            nar_str(h, b"")
        nar_str(h, b"contents")
        nar_str(h, node["contents"])
    elif kind == "symlink":
        nar_str(h, b"symlink")
        nar_str(h, b"target")
        nar_str(h, node["target"])
    else:
        nar_str(h, b"directory")
        for name in sorted(node["entries"]):  # Nix sorts entries bytewise
            nar_str(h, b"entry")
            nar_str(h, b"(")
            nar_str(h, b"name")
            nar_str(h, name)
            nar_str(h, b"node")
            nar_node(h, node["entries"][name])
            nar_str(h, b")")
    nar_str(h, b")")


def new_dir():
    return {"type": "directory", "entries": {}}


def tar_tree(data: bytes):
    """Build an in-memory tree from a tarball; never touches the filesystem so
    modes and symlinks survive exactly as archived."""
    root = new_dir()
    files = {}  # path -> node, for resolving hard links

    def ensure_dir(parts):
        node = root
        for p in parts:
            node = node["entries"].setdefault(p.encode(), new_dir())
        return node

    with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as tar:
        for m in tar:
            parts = [p for p in m.name.split("/") if p not in ("", ".")]
            if not parts:
                continue
            if m.isdir():
                ensure_dir(parts)
                continue
            parent = ensure_dir(parts[:-1])
            name = parts[-1].encode()
            if m.issym():
                node = {"type": "symlink", "target": m.linkname.encode()}
            elif m.islnk():
                node = files[m.linkname]
            elif m.isfile():
                node = {
                    "type": "regular",
                    "executable": bool(m.mode & 0o111),
                    "contents": tar.extractfile(m).read(),
                }
            else:
                continue  # devices/fifos never appear in source archives
            parent["entries"][name] = node
            files[m.name] = node
    return root


def strip_root(root):
    entries = root["entries"]
    if len(entries) != 1 or next(iter(entries.values()))["type"] != "directory":
        sys.exit("error: tarball does not have a single top-level directory")
    return next(iter(entries.values()))


def main(argv):
    if len(argv) != 3 or argv[1] not in ("file", "unpack", "sri"):
        sys.exit(__doc__.strip())
    cmd, arg = argv[1], argv[2]
    if cmd == "sri":
        print(sri(bytes.fromhex(arg)))
        return
    data = download(arg)
    if cmd == "file":
        print(sri(hashlib.sha256(data).digest()))
        return
    h = hashlib.sha256()
    nar_str(h, b"nix-archive-1")
    nar_node(h, strip_root(tar_tree(data)))
    print(sri(h.digest()))


if __name__ == "__main__":
    main(sys.argv)
