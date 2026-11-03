#!/usr/bin/env python3
"""A virtual pointer that stays connected, so the headless seat has one. Reads commands from a
FIFO: `move x y`, `click`, `wheel n` (n clicks down, negative for up).

Usage: pointer.py <bindings dir> <fifo> <width> <height>
"""
import os
import select
import sys
import time

sys.path.insert(0, sys.argv[1])
from protocols.wayland import WlSeat  # noqa: E402
from protocols.wlr_virtual_pointer_unstable_v1 import ZwlrVirtualPointerManagerV1  # noqa: E402
from pywayland.client import Display  # noqa: E402

WIDTH, HEIGHT = int(sys.argv[3]), int(sys.argv[4])
BUTTON_LEFT = 272

display = Display()
display.connect()
registry = display.get_registry()
found = {}


def on_global(reg, name, interface, version):
    if interface == "zwlr_virtual_pointer_manager_v1":
        found["manager"] = reg.bind(name, ZwlrVirtualPointerManagerV1, min(version, 2))
    elif interface == "wl_seat":
        found["seat"] = reg.bind(name, WlSeat, 1)


registry.dispatcher["global"] = on_global
display.roundtrip()
pointer = found["manager"].create_virtual_pointer(found["seat"])
display.roundtrip()


def stamp():
    return int(time.monotonic() * 1000) & 0xFFFFFFFF


def run(words):
    if words[0] == "move":
        pointer.motion_absolute(stamp(), int(words[1]), int(words[2]), WIDTH, HEIGHT)
        pointer.frame()
    elif words[0] == "click":
        pointer.button(stamp(), BUTTON_LEFT, 1)
        pointer.frame()
        display.flush()
        time.sleep(0.05)
        pointer.button(stamp(), BUTTON_LEFT, 0)
        pointer.frame()
    elif words[0] == "wheel":
        clicks = int(words[1])
        for _ in range(abs(clicks)):
            pointer.axis_source(0)
            pointer.axis_discrete(stamp(), 0, 15.0 if clicks > 0 else -15.0, 1 if clicks > 0 else -1)
            pointer.frame()
            display.flush()
            time.sleep(0.03)
    display.flush()


# Read and write, so the FIFO stays open between writers.
fifo = os.open(sys.argv[2], os.O_RDWR)
buffered = b""
while True:
    ready, _, _ = select.select([fifo], [], [], 0.2)
    display.roundtrip()
    if ready:
        buffered += os.read(fifo, 4096)
        while b"\n" in buffered:
            line, buffered = buffered.split(b"\n", 1)
            run(line.decode().split())
