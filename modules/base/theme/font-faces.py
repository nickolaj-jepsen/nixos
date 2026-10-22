"""Copy the font files of one family into DEST and print @font-face rules for them.

Usage: font-faces.py DEST FAMILY FILE...

Files whose typographic family (name ID 16, else 1) differs from FAMILY are
skipped, so a whole font package can be passed. Exits non-zero when nothing
matches, since a family typo would otherwise ship a page without its font.
"""

import shutil
import sys
from pathlib import Path

from fontTools.ttLib import TTFont

FORMATS = {".ttf": "truetype", ".otf": "opentype", ".woff2": "woff2", ".woff": "woff"}


def main() -> None:
    dest, family, *files = sys.argv[1:]
    matched = 0
    for path in map(Path, files):
        font = TTFont(path, lazy=True)
        name = font["name"]
        if (name.getDebugName(16) or name.getDebugName(1)) != family:
            continue
        if "fvar" in font:
            axis = next((a for a in font["fvar"].axes if a.axisTag == "wght"), None)
            weight = f"{axis.minValue:g} {axis.maxValue:g}" if axis else "normal"
        else:
            weight = str(font["OS/2"].usWeightClass)
        style = "italic" if font["OS/2"].fsSelection & 1 else "normal"
        out = Path(dest) / path.name.replace(" ", "-")
        shutil.copyfile(path, out)
        print(
            f'@font-face {{ font-family: "{family}"; src: url("fonts/{out.name}") '
            f'format("{FORMATS[path.suffix]}"); font-weight: {weight}; font-style: {style}; '
            # The bundle's fonts are large; show fallback text instead of nothing while they load.
            "font-display: swap; }"
        )
        matched += 1
    if not matched:
        sys.exit(f"no font file has family {family!r}")


if __name__ == "__main__":
    main()
