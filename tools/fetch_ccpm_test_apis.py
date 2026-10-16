#!/usr/bin/env python3
"""Fetch pinned CraftOS APIs for the optional upstream runtime test pass."""

import sys
import urllib.request
from pathlib import Path


REVISION = "794f78ae437a19984f264bd98f055ed19e40512d"
BASE = f"https://raw.githubusercontent.com/cc-tweaked/CC-Tweaked/{REVISION}/projects/core/src/main/resources/data/computercraft/lua/"
FILES = {
    "require.lua": "rom/modules/main/cc/require.lua",
    "expect.lua": "rom/modules/main/cc/expect.lua",
    "bios.lua": "bios.lua",
    "textutils.lua": "rom/apis/textutils.lua",
}


def main():
    output = Path(sys.argv[1])
    output.mkdir(parents=True, exist_ok=True)
    for name, relative in FILES.items():
        with urllib.request.urlopen(BASE + relative, timeout=30) as response:
            source = response.read().decode("utf-8")
        if name == "require.lua":
            # Cobalt accepts the redundant escape in '%%%.'; PUC Lua 5.2
            # rejects it. '%%.' produces the same literal '%.' search pattern.
            source = source.replace('"%%%."', '"%%."')
        (output / name).write_text(source, encoding="utf-8")
    (output / "revision.txt").write_text(REVISION + "\n", encoding="utf-8")
    print(f"CraftOS test APIs: {REVISION}")


if __name__ == "__main__":
    main()
