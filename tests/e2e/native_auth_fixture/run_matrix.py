#!/usr/bin/env python3
"""List or execute the complete native-auth fixture matrix."""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys

from server import build_manifest

HERE = pathlib.Path(__file__).resolve().parent


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="print exact scenario IDs as JSON")
    arguments = parser.parse_args()
    if arguments.list:
        manifest = build_manifest()
        scenarios = [case["id"] for case in manifest["scenarios"]]
        print(json.dumps({"count": len(scenarios), "scenarios": scenarios}, separators=(",", ":")))
        return 0
    return subprocess.call([sys.executable, str(HERE / "test_server.py"), "-v"], cwd=str(HERE))


if __name__ == "__main__":
    raise SystemExit(main())

