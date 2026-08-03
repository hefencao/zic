#!/usr/bin/env python3
"""Reject anonymous test skips and guard the small explicit quarantine set."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MARKER = "ZIC-QUARANTINE(dev.100):"
EXPECTED = {
    "legacy runtime chapter URI refreshes before entering Reader": (
        "whole-App legacy runtime route",
        "source_resource_gateway_test.dart",
    ),
    "persisted legacy Venera chapter refreshes despite local-detail open hint": (
        "persisted legacy route test",
        "runtime_source_adapter_test.dart",
    ),
    "source comic details retries a transient source failure": (
        "whole-App retry test",
        "RemoteComicDetailsScreen",
    ),
}

skip_sites: list[tuple[Path, int, str]] = []
for path in sorted(ROOT.rglob("*_test.dart")):
    text = path.read_text(encoding="utf-8")
    for match in re.finditer(r"\bskip\s*:", text):
        line = text.count("\n", 0, match.start()) + 1
        window = text[match.start() : match.start() + 700]
        skip_sites.append((path, line, window))
        if MARKER not in window:
            raise SystemExit(
                f"FAIL: anonymous or untracked skip at {path.relative_to(ROOT)}:{line}"
            )

if len(skip_sites) != len(EXPECTED):
    raise SystemExit(
        f"FAIL: expected {len(EXPECTED)} quarantined tests, found {len(skip_sites)}"
    )

source_test = (
    ROOT / "apps/app/test/source_browser_test.dart"
).read_text(encoding="utf-8")
policy = (ROOT / "docs/testing/TEST_QUARANTINE.md").read_text(encoding="utf-8")
for name, tokens in EXPECTED.items():
    if name not in source_test:
        raise SystemExit(f"FAIL: quarantined test is missing: {name}")
    if name not in policy:
        raise SystemExit(f"FAIL: quarantine policy omits test: {name}")
    for token in tokens:
        if token not in policy and token not in source_test:
            raise SystemExit(f"FAIL: quarantine evidence missing token: {token}")

app_reader_test = (
    ROOT / "apps/app/test/reader_controls_test.dart"
).read_text(encoding="utf-8")
if "adaptive reader classifier respects animation and page geometry" in app_reader_test:
    raise SystemExit("FAIL: duplicate adaptive classifier test returned to App")
owner_test = (
    ROOT / "packages/reader_runtime/test/adaptive_reader_classifier_test.dart"
).read_text(encoding="utf-8")
for token in (
    "source vertical direction alone is not adaptive evidence",
    "decoded animation requires two non-cover pages",
):
    if token not in owner_test:
        raise SystemExit(f"FAIL: adaptive classifier owner coverage missing: {token}")

print("test quarantine ownership: OK")
