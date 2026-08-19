#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.311 missing {label}: {token}')


pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
match = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
if match is None or int(match.group(1)) < 311:
    raise SystemExit('dev.311 app version missing/regressed')
version = int(match.group(1))
if not re.search(rf'^versionCode={version}$', props, re.M):
    raise SystemExit('dev.311 Android version mismatch')

native = read('packages/pipeline_native/lib/src/native_pipeline_media_runtime.dart')
composition = read('apps/app/lib/webp_demo.dart')
standalone = read('packages/local_media_ui/lib/src/native_webp_player.dart')
profile = read('packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart')
view = read('packages/reader/lib/src/reader_view.dart')

# Production Reader composition keeps the no-argument factory. That constructor
# must no longer create a SurfaceProducer presenter/pool; platform texture is an
# explicit opt-in only.
default_start = native.index('NativePipelineMediaRuntimeFactory() {')
default_end = native.index('\n  }', default_start) + 4
default_ctor = native[default_start:default_end]
if 'AndroidTexturePresenter' in default_ctor or '_enablePlatformTexturePresentation' in default_ctor:
    raise SystemExit('dev.311 production Reader constructor still enables platform texture')
require(native, 'NativePipelineMediaRuntimeFactory.platformTexture() {', 'explicit texture opt-in constructor')
require(native, '_enablePlatformTexturePresentation();', 'explicit texture opt-in call')
require(composition, 'final _defaultNativeMediaRuntimeFactory = NativePipelineMediaRuntimeFactory();', 'production Flutter-image composition')

# With no texture pool, the atomic capability must choose the already-existing
# Flutter uploader/projector pair, ending in RawImage while native decode stays.
for token in (
    'renderer: pool == null\n          ? RendererKind.flutterImage',
    'uploader: pool == null\n          ? _FlutterImageUploader()',
    'outputs: pool == null\n          ? const _FlutterOutputProjector()',
    'NativeSourceFactory()',
    'NativeCursorFactory()',
    'ui.decodeImageFromPixels(',
    'RawImage(',
):
    require(native, token, 'native-decode / Flutter-image Reader path')

# Do not delete the platform path: it stays available for targeted diagnostics,
# and the standalone Animated WebP player still owns its existing native texture
# presentation path independently of the Reader Pipeline default.
for token in (
    'AndroidTexturePresenter',
    '_AndroidTextureUploader',
    '_AndroidOutputProjector',
    '_AndroidTextureSurface',
):
    require(native, token, 'retained opt-in platform texture implementation')
for token in (
    'AndroidTexturePresenter.isSupported',
    'RendererKind.androidTexture',
):
    require(standalone, token, 'standalone animated WebP texture path')

# Resource and scroll semantics remain frozen.
for token in (
    'forwardEncodedPages: 7', 'backwardEncodedPages: 3',
    'forwardDecodePages: 2', 'backwardDecodePages: 1',
):
    require(profile, token, 'frozen resource window')
for forbidden in ('GestureBinding', 'resamplingEnabled', 'samplingOffset'):
    if forbidden in ''.join(
        p.read_text(encoding='utf-8')
        for p in (ROOT / 'packages/reader_runtime/lib').rglob('*.dart')
    ):
        raise SystemExit(f'dev.311 restored falsified touch resampling: {forbidden}')
require(view, "'dragDriven': dragDriven,", 'retained ballistic attribution')

for path in (
    'docs/adr/0290-reader-flutter-image-presentation-boundary.md',
    'docs/audits/dev311-reader-flutter-image-presentation-audit.md',
):
    if not (ROOT / path).is_file():
        raise SystemExit(f'dev.311 governance artifact missing: {path}')

docs = ''.join(read(path) for path in (
    'CHANGELOG.md',
    'docs/ARCHITECTURE.md',
    'docs/SPEC.md',
    'docs/IMPLEMENTATION_PLAN.md',
    'docs/IMPLEMENTATION_STATUS.md',
    'docs/NEXT_CHAT_HANDOFF.md',
    'docs/adr/0290-reader-flutter-image-presentation-boundary.md',
    'docs/audits/dev311-reader-flutter-image-presentation-audit.md',
))
for token in (
    '58', '38', 'platformFrameCadenceOutlier', 'VibeVenera',
    'Flutter', 'RawImage', 'SurfaceProducer', 'dev.311',
):
    require(docs, token, 'governed Reader presentation boundary')

print('dev.311 Reader Flutter-image presentation boundary: OK')
