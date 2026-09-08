#!/usr/bin/env python3
"""Guard dev.117 single-frame bootstrap and early WebP classification."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.117 contract: {token}")

refill = read("packages/sessions/lib/src/decode_refill_policy.dart")
decode = read("packages/sessions/lib/src/decode_session.dart")
local = read("packages/local_media_ui/lib/src/local_image_player.dart")
refill_test = read("packages/sessions/test/decode_refill_policy_test.dart")
decode_test = read("packages/sessions/test/decode_session_test.dart")
local_test = read("packages/local_media_ui/test/image_folder_manifest_test.dart")
check = read("tool/check.sh")

for token in (
    "entry.value.targetWatermark == 1",
    "stage: 'one>0'",
    "b.value.priority.compareTo(a.value.priority)",
    "return oneFramePriority > stagedPriority",
):
    require(refill, token, "single-frame refill policy")
for token in (
    "void _reportAnimationEvidence()",
    "holder.add(frame);\n            _reportAnimationEvidence();",
    "final loop = _cursor!.loop;\n            _reportAnimationEvidence();",
    "ingress.webpAnimationEvidence == WebpAnimationEvidence.staticImage",
):
    require(decode, token, "early authoritative animation reporting")
for token in (
    "image.format == LocalImageFormat.gif ||",
    "image.format == LocalImageFormat.webp",
):
    require(local, token, "local WebP unresolved animation hint")
for text, token, owner in (
    (refill_test, "single-frame demands bootstrap before staged animation waterlines", "refill owner test"),
    (decode_test, "expect(resolvedAnimation?.complete, isTrue);", "decode owner test"),
    (decode_test, "unsealed static VP8X prefix resolves static at a one-frame watermark", "decode static-prefix owner test"),
    (local_test, "local WebP stays an animation candidate until runtime classification", "local-media owner test"),
):
    require(text, token, owner)
require(check, "test_dev117_single_frame_webp_bootstrap.py", "repository check")
print("dev.117 single-frame WebP bootstrap contract: OK")
