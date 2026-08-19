#!/usr/bin/env python3
"""Guard dev.116 compile closure and runtime WebP classification."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.116 contract: {token}")

manager = read("packages/downloads/lib/src/artifact_cache_manager.dart")
reader = read("packages/reader/lib/src/reader_view.dart")
policy = read("packages/pipeline/lib/src/heuristic_policy.dart")
controller = read("packages/pipeline/lib/src/pipeline_controller.dart")
binding = read("packages/sessions/lib/src/reader_binding.dart")
decode = read("packages/sessions/lib/src/decode_session.dart")
registry = read("packages/sessions/lib/src/decode_registry.dart")
runtime = read("packages/pipeline_runtime/lib/src/pipeline_reader_session.dart")
telemetry = read("packages/telemetry/lib/src/trace.dart")
analyzer = read("tool/analyze_frame_pipeline_trace.py")
check = read("tool/check.sh")

if manager.count("await backend.invalidateArtifact(id);") != 1 or \
        manager.count("await backend.invalidateArtifact(storageId);") != 1:
    raise SystemExit(
        "cache manager must invalidate both exact writes and alias-resolved storage"
    )
if "ArtifactCacheInvalidationBackend" in manager:
    raise SystemExit("cache manager still contains optional invalidation dispatch")
if runtime.count("final artifactReadMicros =") != 1:
    raise SystemExit("pipeline presentation read timing declaration is duplicated")
for token in (
    "bool _keepAliveFor(ReaderController controller)",
    "ReadingDirection.vertical",
    "keepAlive: _keepAlive",
):
    require(reader, token, "vertical host retention")
version_match = re.search(r"^version: 0\.31\.0\+(\d+)$", read("apps/app/pubspec.yaml"), re.M)
version = int(version_match.group(1)) if version_match else 0
keepalive_token = (
    "(widget.index - widget.keepAliveCenter.value).abs() <= 7"
    if version >= 307
    else "(widget.index - controller.currentIndex).abs() <= 7"
)
require(reader, keepalive_token, "vertical host retention")
keep_alive_start = reader.find("bool _keepAliveFor(ReaderController controller)")
keep_alive_end = reader.find("void _readControllerState()", keep_alive_start)
if "animatedHint" in reader[keep_alive_start:keep_alive_end]:
    raise SystemExit("vertical host keep-alive still depends on unreliable WebP hint")
for token in (
    "runtimeAnimatedPages",
    "assumeUnresolvedStatic",
    "return assumeUnresolvedStatic || !chapter.pages[entry.key].animatedHint;",
):
    require(policy, token, "runtime static warming policy")
for token in (
    "bool classifyPage",
    "_assumeUnresolvedStatic",
    "runtimeStaticPages",
):
    require(controller, token, "pipeline runtime media classification")
require(binding, "pipeline.classifyPage", "reader binding classification projection")
for token in (
    "onAnimationResolved",
    "animation.complete",
    "onAnimationResolved?.call(id, animation)",
):
    require(decode, token, "decode authoritative classification")
require(registry, "onAnimationResolved: onAnimationResolved", "decode registry callback")
for token in (
    "scheduleMicrotask(()",
    "TraceEventKind.mediaClassified",
    "_binding?.classifyPage",
):
    require(runtime, token, "pipeline runtime classification application")
require(telemetry, "mediaClassified", "trace classification event")
for token in (
    "mediaClassificationCount",
    "runtimeStaticClassificationCount",
    "runtimeAnimatedClassificationCount",
):
    require(analyzer, token, "trace analyzer classification diagnostics")
for path, token in (
    (
        "packages/pipeline/test/pipeline_test.dart",
        "runtime static WebP evidence enables one-frame chapter warming",
    ),
    (
        "packages/sessions/test/decode_session_test.dart",
        "resolvedAnimation?.frameCount",
    ),
):
    require(read(path), token, path)
require(check, "test_dev116_runtime_webp_classification_compile.py", "repository check")
print("dev.116 runtime WebP classification/compile contract: OK")
