#!/usr/bin/env python3
"""Guard dev.121 static-watermark satisfaction and localized Reader rebuilds."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.121 contract: {token}")


policy = read("packages/sessions/lib/src/decode_refill_policy.dart")
coordinator = read("packages/sessions/lib/src/live_coordinator.dart")
policy_test = read("packages/sessions/test/decode_refill_policy_test.dart")
reader = (
    read("packages/reader/lib/src/reader_view.dart")
    + read("packages/reader/lib/src/reader_page_host.dart")
)
reader_test = read("packages/reader/test/reader_navigation_test.dart")
screen = read("packages/reader_runtime/lib/src/reader_runtime_screen.dart")
check = read("tool/check.sh")

for text, token, owner in (
    (policy, "typedef DecodeSatisfiedLookup = bool Function(DecodeId id);", "refill satisfaction lookup"),
    (policy, "DecodeSatisfiedLookup satisfiedOf = _neverSatisfied", "refill satisfaction API"),
    (policy, "satisfiedOf(entry.key)", "single-frame satisfaction"),
    (policy, "satisfiedOf(id)", "staged satisfaction"),
    (coordinator, "animation.frameCount <= 1", "authoritative static classification"),
    (coordinator, "snapshot.depth + preparedDepth >= 1", "single-frame watermark satisfaction"),
    (policy_test, "authoritative static current is satisfied by one prepared frame", "mixed media owner test"),
    (reader, "final class _ReaderPageShell extends StatefulWidget", "localized page shell"),
    (reader, "widget.controller.addListener(_handleControllerChanged)", "page-local controller listener"),
    (reader, "return LayoutBuilder(", "ReaderView localized root"),
    (reader_test, "vertical current changes rebuild only page shells whose state changed", "localized rebuild owner test"),
    (screen, "child: _topControls(context, reader)", "top controls listener"),
    (screen, "_bottomControls(context, reader)", "bottom controls listener"),
    (screen, "_animationControls(reader)", "playback-only controls remain a sibling of fixed bottom controls"),
    (check, "test_dev121_static_watermark_reader_rebuild.py", "repository check"),
):
    require(text, token, owner)

if "return AnimatedBuilder(\n      animation: widget.controller" in reader:
    raise SystemExit("ReaderView still rebuilds the whole scrollable for every controller notification")

if "return AnimatedBuilder(\n      animation: reader,\n      builder: (context, _) => Scaffold(" in screen:
    raise SystemExit("ReaderRuntimeScreen still wraps the entire Scaffold in reader animation")

print("dev.121 static watermark and localized Reader rebuild contract: OK")
