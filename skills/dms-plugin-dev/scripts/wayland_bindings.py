#!/usr/bin/env python3
"""Generate pywayland bindings for `pointer.py`, as nixpkgs ships none for wlr protocols.

Usage: wayland_bindings.py <out dir> <protocol.xml>...
"""
import sys
from pathlib import Path

from pywayland.scanner import Protocol

out = Path(sys.argv[1])
protocols = [Protocol.parse_file(path) for path in sys.argv[2:]]
imports = {interface.name: protocol.name for protocol in protocols for interface in protocol.interface}
for protocol in protocols:
    protocol.output(str(out), imports)
