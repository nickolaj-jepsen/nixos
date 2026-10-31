"""walldye's glyph-donut as one frame of a spin: same shading and palette, smaller, and drawn
at a fixed spot so consecutive frames line up."""

import math

import numpy as np
from numpy.typing import NDArray
from scipy import ndimage

from walldye import (
    ACCENT,
    ACCENT_1,
    ACCENT_2,
    ACCENT_4,
    UI,
    UI_ALT,
    UI_HI,
    Canvas,
    Color,
    Params,
    by_regime,
    design,
    knob,
    mix,
)
from walldye.pixel import glyphs

type Vec3 = NDArray[np.float64]


class Frame(Params):
    a: float = knob(default=-52, unit="deg", doc="donut.c's A: tilt about the screen's x axis")
    b: float = knob(default=-20, unit="deg", doc="donut.c's B: turn about the view axis")


RAMP = ".`-:;+=*o%#@"  # darkest to brightest
LOW, MID = by_regime(UI, UI_ALT), by_regime(UI_ALT, mix(UI_ALT, UI_HI, 0.5))
WARM = by_regime(ACCENT_4, ACCENT_2)
TONES: tuple[Color, ...] = (LOW,) * 4 + (MID,) * 4 + (UI_HI, WARM, ACCENT_1, ACCENT)
CW, CH = 8, 16
COLS, ROWS = 80, 40  # the whole grid is drawn, untrimmed, so the torus never shifts between frames
R1, R2 = 1, 2
K1, K2 = 360, 7
SAMPLES = (400, 1100)


def unit(v: tuple[float, float, float]) -> Vec3:
    a = np.asarray(v, dtype=float)
    return a / np.linalg.norm(a)


def rotate(v: Vec3, a: float, b: float) -> Vec3:
    ca, sa, cb, sb = math.cos(a), math.sin(a), math.cos(b), math.sin(b)
    rx = np.array([[1, 0, 0], [0, ca, sa], [0, -sa, ca]])
    rz = np.array([[cb, sb, 0], [-sb, cb, 0], [0, 0, 1]])
    return v @ rx @ rz


LIGHT = unit((-0.4, 0.45, -0.8))
GLINT = unit((-0.6, 0.5, -0.62))


@design(aspects="any")
def draw(s: Canvas[Frame]) -> None:
    th, ph = np.meshgrid(
        np.linspace(0, 2 * np.pi, SAMPLES[0], endpoint=False),
        np.linspace(0, 2 * np.pi, SAMPLES[1], endpoint=False),
    )
    ring = R2 + R1 * np.cos(th)
    pts = np.stack([ring * np.cos(ph), R1 * np.sin(th), ring * np.sin(ph)], axis=-1)
    normal = np.stack([np.cos(th) * np.cos(ph), np.sin(th), np.cos(th) * np.sin(ph)], axis=-1)
    a, b = math.radians(s.params.a), math.radians(s.params.b)
    pts, normal = rotate(pts, a, b), rotate(normal, a, b)
    x, y, z = pts[..., 0], pts[..., 1], pts[..., 2]
    ooz = 1 / (z + K2)
    i = ((COLS * CW / 2 + K1 * ooz * x) // CW).astype(int)
    j = ((ROWS * CH / 2 - K1 * ooz * y) // CH).astype(int)
    diffuse = np.clip(normal @ LIGHT, 0, 1)
    spec = np.clip(normal @ GLINT, 0, 1) ** 10 * (np.cos(th) > 0)
    lum = 0.62 * diffuse**1.3 + 0.5 * spec
    lvl = np.where(diffuse < 0.1, -1, np.minimum((lum * len(RAMP)).astype(int), len(RAMP) - 1))

    ok = (i >= 0) & (i < COLS) & (j >= 0) & (j < ROWS)
    i, j, ooz, lvl = i[ok], j[ok], ooz[ok], lvl[ok]
    out = np.full((ROWS, COLS), -1)
    order = np.argsort(ooz)
    out[j[order], i[order]] = lvl[order]
    nb = ndimage.convolve((out >= 0).astype(int), np.ones((3, 3), int), mode="constant")
    out[nb < 3] = -1
    lines = ["".join(RAMP[v] if v >= 0 else " " for v in row) for row in out.tolist()]

    c = s.pick(landscape=(0.5, 0.5), portrait=(0.5, 0.5), snap=1)
    at = (c.x - COLS * CW // 2, c.y - ROWS * CH // 2)
    glyphs(s, lines, lambda col, row, ch: TONES[RAMP.index(ch)], at=at, font="8x16", px=1)
