#!/usr/bin/env python3
"""Guard dev.116 compile closure and runtime WebP classification."""
from pathlib import Path

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

if manager.count("await backend.invalidateArtifact(id);") != 2:
    raise SystemExit("cache manager must call the required backend invalidation primitive")
if "ArtifactCacheInvalidationBackend" in manager:
    raise SystemExit("cache manager still contains optional invalidation dispatch")
if runtime.count("final artifactReadMicros =") != 1:
    raise SystemExit("pipeline presentation read timing declaration is duplicated")
for token in (
    "final keepVerticalHost =",
    "ReadingDirection.vertical",
    "(index - widget.controller.currentIndex).abs() <= 4",
    "keepAlive: keepVerticalHost",
):
    require(reader, token, "vertical host retention")
if "!asset.animatedHint" in reader[reader.find("final keepVerticalHost ="):reader.find("return RotatedBox")]:
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
