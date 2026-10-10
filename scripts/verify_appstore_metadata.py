#!/usr/bin/env python3
"""Preflight App Store orientation metadata before spending time on archive/upload."""
from __future__ import annotations

import plistlib
import sys
from pathlib import Path

PLIST = Path("ShittyFriends/Info.plist")
IPHONE_KEY = "UISupportedInterfaceOrientations~iphone"
IPAD_KEY = "UISupportedInterfaceOrientations~ipad"
ALL_IPAD = {
    "UIInterfaceOrientationPortrait",
    "UIInterfaceOrientationPortraitUpsideDown",
    "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight",
}


def main() -> int:
    if not PLIST.is_file():
        print(f"ERROR: Missing {PLIST}.", file=sys.stderr)
        return 2
    with PLIST.open("rb") as fh:
        info = plistlib.load(fh)

    # A generic portrait-only declaration is what triggered App Store error 90474.
    generic = info.get("UISupportedInterfaceOrientations")
    if generic:
        print(
            "ERROR: Generic UISupportedInterfaceOrientations is present. Use device-specific "
            "~iphone/~ipad keys so iPhone can remain portrait-only while iPad supports all orientations.",
            file=sys.stderr,
        )
        return 2

    iphone = info.get(IPHONE_KEY)
    if iphone != ["UIInterfaceOrientationPortrait"]:
        print(f"ERROR: {IPHONE_KEY} must be portrait-only; got {iphone!r}.", file=sys.stderr)
        return 2

    ipad = info.get(IPAD_KEY)
    if not isinstance(ipad, list) or set(ipad) != ALL_IPAD or len(ipad) != len(ALL_IPAD):
        print(
            f"ERROR: {IPAD_KEY} must contain all four orientations required by App Store iPad multitasking validation; got {ipad!r}.",
            file=sys.stderr,
        )
        return 2

    print("OK: iPhone is portrait-only and iPad declares all four orientations for App Store validation.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
