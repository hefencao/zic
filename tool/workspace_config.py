#!/usr/bin/env python3
"""Read stable repository-local workspace delivery settings."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / ".zic-workspace.json"


def load() -> dict[str, object]:
    payload = json.loads(CONFIG.read_text(encoding="utf-8"))
    if payload.get("schema") != "zic-workspace-v1":
        raise SystemExit("unsupported .zic-workspace.json schema")
    patch_dir = payload.get("patch_dir")
    if not isinstance(patch_dir, str) or not patch_dir.strip():
        raise SystemExit("workspace patch_dir must be a non-empty string")
    return payload


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("field", choices=("patch_dir",))
    parser.add_argument("--absolute", action="store_true")
    args = parser.parse_args()
    value = str(load()[args.field])
    if args.absolute:
        value = str((ROOT / value).resolve())
    print(value)


if __name__ == "__main__":
    main()
