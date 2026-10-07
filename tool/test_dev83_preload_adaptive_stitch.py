#!/usr/bin/env python3
"""Ownership gate for dev.83 preload, adaptive profile and stitch geometry."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")




def current_dev() -> int:
    for line in read('apps/app/pubspec.yaml').splitlines():
        if line.startswith('version:') and '+' in line:
            return int(line.rsplit('+', 1)[1].strip())
    raise AssertionError('app version code missing')
def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise AssertionError(f"{path} missing dev.83 tokens: {missing}")


def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    if present:
        raise AssertionError(f"{path} restored rejected dev.83 tokens: {present}")


def main() -> None:
    require(
        "packages/sessions/lib/src/live_coordinator.dart",
        "import 'decode_session.dart';",
        "import 'upload_session.dart';",
        "DecodeSnapshot?",
        "DecodeState.failed",
        "UploadState.ready",
    )
    require(
        "packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart",
        "static const stable = ReaderPipelineProfile(",
        "forwardEncodedPages: 7",
        "backwardEncodedPages: 3",
        "forwardDecodePages: 2",
        "backwardDecodePages: 1",
        "nearRadius: 0",
        "PolicyGuard(maxDownloadDemands: 11)",
        "HeuristicPolicy(decodeWarmPages: true)",
        "networkConcurrency: 5",
        "decodeConcurrency: 3",
        "uploadConcurrency: 2",
    )
    if current_dev() >= 293:
        require(
            "packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart",
            "ReaderPipelineProfile readerPipelineProfileFor(",
            "ReaderPipelineProfile.stable;",
        )
    else:
        require(
            "packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart",
            "return ReaderPipelineProfile.stable",
        )
    reject(
        "packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart",
        "uri.scheme",
        "venera-resource",
        "ReaderPipelineProfile.standard",
        "ReaderPipelineProfile.sourceStreaming",
        "maxDownloadDemands: 7",
        "networkConcurrency: 3",
    )
    require(
        "packages/pipeline_runtime/test/reader_pipeline_profile_test.dart",
        "hasLength(11)",
        "hasLength(11)",
        "demand.targetWatermark == 1",
        "hasLength(1)",
        "'mihon-resource'",
        "'venera-resource'",
        "'https'",
        "'file'",
    )

    require(
        "packages/reader_runtime/lib/src/reader_session_settings.dart",
        "final class AdaptiveReaderMetadata",
        "currentModelVersion = 8",
        "applyConfidence = 0.60",
        "stopConfidence = 0.80",
        "metadataFingerprint",
        "classifyMetadata()",
        "_animatedSamples.length < _requiredAnimationSamples",
        "_geometrySampleLimit = 3",
        "_geometryDecisionComplete",
        "_samples.length < target",
        "_classifyAnimated('decoded-animation')",
        "page.index == 0",
        "basis: 'title:$animatedTitle'",
        "final category = _category(value.tags)",
        "final language = _metadataLanguage(value)",
        "final verticalMetadata = _tagWeight(",
        "static const int _requiredAnimationSamples = 2",
        "_ambiguousLandscapeRatio = 0.65",
        "_pagedPortraitRatio = 1.20",
    )
    reject(
        "packages/reader_runtime/lib/src/reader_session_settings.dart",
        "basis: 'source-hint'",
        "runtimeAnimatedReaderProfile",
        "if (page.animatedHint && !_isCover(page))",
    )
    require(
        "packages/reader_runtime/lib/src/reader_runtime_screen.dart",
        "this.adaptiveMetadata",
        "AdaptiveReaderClassifier(",
        "metadata: widget.adaptiveMetadata",
        "stored.metadataFingerprint == _adaptiveClassifier.metadataFingerprint",
        "_adaptiveClassifier.observeAnimated(asset)",
        "_adaptiveClassifier.observeDimensions(asset, width, height)",
        "_settings.copyWith(adaptiveProfile: candidate)",
    )
    require(
        "packages/local_media_ui/lib/src/local_media_screens.dart",
        "this.adaptiveMetadata",
        "adaptiveMetadata: adaptiveMetadata ??",
        "AdaptiveReaderMetadata(",
        "title: record.comicTitle",
        "authors: record.comicAuthors",
    )
    require(
        "packages/local_media_ui/lib/src/catalog_and_codec.dart",
        "animatedHint: image.format == LocalImageFormat.gif",
    )
    require(
        "packages/local_media_ui/lib/src/local_image_player.dart",
        "webpNativeTextureViewportKey",
        "FilterQuality.low",
    )
    reject(
        "packages/local_media_ui/lib/src/local_image_player.dart",
        "image.format == LocalImageFormat.webp ||",
    )
    reject(
        "packages/local_media_ui/lib/src/catalog_and_codec.dart",
        "image.format == LocalImageFormat.webp ||",
    )
    require(
        "apps/app/lib/app_preferences.dart",
        "AdaptiveReaderProfile? adaptiveProfile",
        "'adaptiveProfile': adaptiveProfile!.toJson()",
        "AdaptiveReaderProfile.fromJson",
    )

    require(
        "packages/reader/lib/src/vertical_reader_geometry.dart",
        "devicePixelRatio",
        "(bounded * dpr).round()",
    )
    require(
        "packages/reader/lib/src/reader_view.dart",
        "addRepaintBoundaries: !stitched",
        "(stitched || !_stripZoomed) && _zoomedPage == null",
        "? page",
        ": ClipRect(child: page)",
    )
    reject(
        "packages/reader/lib/src/reader_view.dart",
        "_verticalStitchOverlap",
        "Transform.translate",
        "Positioned(top: -",
    )
    if current_dev() >= 293:
        require(
            "packages/local_media_ui/lib/src/local_image_player.dart",
            "Presentation must never inherit a transient aspect error",
            "fit == BoxFit.fitWidth ? Alignment.topCenter",
            "fit: fit,",
            "builder(BoxFit.fill)",
        )
        reject(
            "packages/local_media_ui/lib/src/local_image_player.dart",
            "ReaderVerticalGeometry already owns the exact",
        )
    else:
        require(
            "packages/local_media_ui/lib/src/local_image_player.dart",
            "ReaderVerticalGeometry already owns the exact",
            "builder(BoxFit.fill)",
        )
    require(
        "packages/texture_bridge/lib/src/native_texture_viewport.dart",
        "if (fit == BoxFit.fill)",
        "Avoid a second FittedBox/layer",
        "return SizedBox.expand(",
    )
    require(
        "packages/reader/test/vertical_reader_geometry_test.dart",
        "stitched boundaries share one physical-pixel grid",
        "geometry.devicePixelRatio",
        "bounds.end, geometry.boundsAt(index + 1).start",
    )
    require(
        "packages/texture_bridge/test/native_texture_viewport_test.dart",
        "authoritative stitched box fills without a second FittedBox",
        "find.byType(FittedBox), findsNothing",
    )

    deterministic_tests = (
        "packages/pipeline_runtime/test/reader_pipeline_profile_test.dart",
        "packages/reader_runtime/test/adaptive_reader_classifier_test.dart",
        "packages/reader/test/vertical_reader_geometry_test.dart",
        "packages/texture_bridge/test/native_texture_viewport_test.dart",
    )
    for path in deterministic_tests:
        reject(
            path,
            "HttpServer",
            "Future.delayed",
            "pumpAndSettle",
            "pump(const Duration",
            ".single",
            "scrollUntilVisible",
            "dragUntilVisible",
        )

    assert (ROOT / "docs/archive/adr/0067-stable-preload-adaptive-profile-and-pixel-stitch.md").exists()
    assert (ROOT / "docs/archive/audits/dev83-preload-adaptive-stitch-audit.md").exists()
    print("dev.83 preload, adaptive and stitch ownership: OK")


if __name__ == "__main__":
    main()
