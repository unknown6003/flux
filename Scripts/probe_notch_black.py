#!/usr/bin/env python3
"""Check empty shell pixels in Flux --snapshot-notch PNGs. Requires Pillow."""

import argparse
from pathlib import Path
import sys

from PIL import Image


def inspect(path, state):
    with Image.open(path) as source:
        image = source.convert("RGBA")
    width, height = image.size
    scale = width / 408
    if scale not in (1, 2, 3, 4) or height != 192 * scale:
        raise ValueError(f"{path}: expected a 408x192-point notch snapshot, got {image.size}")

    # The fixture reserves the top 32 points for the physical notch. Expanded
    # content starts 16 points inside each side of the 360-point shell.
    patches = {"header": (202, 14, 206, 18)}
    if state == "expanded":
        patches.update(left=(30, 78, 34, 82), right=(374, 78, 378, 82))

    passed = True
    for name, rect in patches.items():
        extrema = image.crop(tuple(int(value * scale) for value in rect)).getextrema()
        peak_rgb = max(channel[1] for channel in extrema[:3])
        min_alpha = extrema[3][0]
        good = peak_rgb <= 1 and min_alpha == 255
        print(f"{'PASS' if good else 'FAIL'}: {path.name} {name} "
              f"max RGB={peak_rgb}, min alpha={min_alpha}; expected RGB<=1, alpha=255")
        passed &= good

    return passed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("images", nargs="+", type=Path)
    parser.add_argument("--state", choices=("collapsed", "activity", "expanded"), default="expanded")
    args = parser.parse_args()
    passed = True
    for path in args.images:
        try:
            passed &= inspect(path, args.state)
        except (OSError, ValueError) as error:
            print(f"FAIL: {error}", file=sys.stderr)
            passed = False
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
