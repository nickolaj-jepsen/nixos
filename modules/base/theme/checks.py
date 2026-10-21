"""Check the palette's contrast and hue spacing and print the specimen's Contrast section.

Usage: checks.py TOKENS_JSON

Exits non-zero when a REQUIRED contrast fails. Hues closer than CLOSE are
listed on the page and warned about on stderr, but don't fail the build.
"""

import json
import math
import re
import sys
from itertools import combinations

# (foreground, background, minimum WCAG ratio), as palette option names.
REQUIRED = [("fg", "bg", 7.0), ("accent", "bg", 4.5)]
# Hand-picked text colors; the semantic colors are added to these.
TEXT = ["fg", "fgAlt", "muted", "accent"]
# OKLab distance below which two colors read as one at a glance.
CLOSE = 0.1
# Touching flame layers, which must stay CLOSE apart for the mark to read.
FLAME = [("outer", "mid"), ("mid", "core")]


def kebab(name: str) -> str:
    return re.sub(r"[A-Z]", lambda m: "-" + m[0].lower(), name)


def linear(hex_: str) -> list[float]:
    channels = [int(hex_.lstrip("#")[i : i + 2], 16) / 255 for i in (0, 2, 4)]
    return [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]


def contrast(a: str, b: str) -> float:
    def luminance(hex_: str) -> float:
        r, g, b = linear(hex_)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b

    lo, hi = sorted([luminance(a), luminance(b)])
    return (hi + 0.05) / (lo + 0.05)


def oklab(hex_: str) -> tuple[float, float, float]:
    r, g, b = linear(hex_)
    l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3)
    m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
    s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
    return (
        0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    )


def distance(a: str, b: str) -> float:
    return sum((x - y) ** 2 for x, y in zip(oklab(a), oklab(b))) ** 0.5


def grade(ratio: float) -> tuple[str, str]:
    if ratio >= 7:
        return "aaa", "AAA"
    if ratio >= 4.5:
        return "aa", "AA"
    if ratio >= 3:
        return "large", "AA large"
    return "fail", "fail"


def main() -> None:
    tokens = json.load(open(sys.argv[1]))
    colors, semantic = tokens["colors"], tokens["semantic"]
    flame = tokens["brand"]["flame"]

    failures = [
        f"{kebab(fg)} on {kebab(bg)} is {contrast(colors[fg], colors[bg]):.2f}:1, needs {need:g}:1"
        for fg, bg, need in REQUIRED
        if contrast(colors[fg], colors[bg]) < need
    ]
    if failures:
        sys.exit("design system contrast check failed:\n  " + "\n  ".join(failures))

    # Each distinct semantic color once, named after its palette entry, with the roles using it.
    found: dict[str, list[str]] = {}
    for role, hex_ in sorted(semantic.items()):
        name = next((n for n, h in colors.items() if h == hex_), None)
        if name is not None:
            found.setdefault(name, []).append(role)
    roles = {name: found.pop(name, []) for name in TEXT}
    for name in sorted(found, key=lambda n: math.atan2(oklab(colors[n])[2], oklab(colors[n])[1]) % math.tau):
        roles[name] = found[name]

    def label(name: str) -> str:
        sub = f"<span>{' &middot; '.join(roles[name])}</span>" if roles[name] else ""
        return f'<i style="background: var(--fp-{kebab(name)})"></i><div><strong>{kebab(name)}</strong>{sub}</div>'

    def ratio(fg: str, bg: str) -> str:
        r = contrast(colors[fg], colors[bg])
        cls, text = grade(r)
        return f'<span class="ratio {cls}">{r:.2f}<em>{text}</em></span>'

    rows = "".join(f'<div class="check">{label(n)}{ratio(n, "bg")}{ratio(n, "bgAlt")}</div>' for n in roles)

    hues = [n for n in roles if n not in TEXT or n == "accent"]
    close = sorted(
        (distance(colors[a], colors[b]), a, b)
        for a, b in combinations(hues, 2)
        if distance(colors[a], colors[b]) < CLOSE
    )
    for d, a, b in close:
        print(f"warning: {kebab(a)} and {kebab(b)} are {d:.3f} apart in OKLab", file=sys.stderr)

    blended = [
        f"flame-{a} and flame-{b} are {distance(flame[a], flame[b]):.3f} apart, need {CLOSE:g}"
        for a, b in FLAME
        if distance(flame[a], flame[b]) < CLOSE
    ]
    if blended:
        sys.exit("design system flame check failed:\n  " + "\n  ".join(blended))
    pairs = "".join(
        f'<div class="check">{label(a)}{label(b)}<span class="ratio fail">{d:.3f}<em>&Delta;E</em></span></div>'
        for d, a, b in close
    ) or f'<p class="lede">No two are closer than {CLOSE:g}.</p>'

    required = " or ".join(f"{kebab(fg)} on {kebab(bg)} drops below {need:g}:1" for fg, bg, need in REQUIRED)
    layers = " and ".join(f"{a}/{b}" for a, b in FLAME)
    print(f"""<p class="lede">WCAG contrast of text colors. The build fails if {required}.</p>
<div class="checks"><div class="check head"><span></span><span></span><span>on bg</span><span>on bg-alt</span></div>{rows}</div>
<h3 class="sub">Hues that read as one</h3>
<p class="lede">OKLab distance between the accent and semantic colors, listed when below {CLOSE:g}. The flame's {layers} layers must stay {CLOSE:g} apart or the build fails.</p>
<div class="checks pairs">{pairs}</div>""")


if __name__ == "__main__":
    main()
