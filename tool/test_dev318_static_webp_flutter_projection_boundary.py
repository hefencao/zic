#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.318 missing {label}: {token}')

def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'dev.318 forbidden {label}: {token}')

pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
if 'version: 0.31.0+318' not in pubspec or 'versionCode=318' not in props:
    raise SystemExit('dev.318 version mismatch')

player = read('packages/local_media_ui/lib/src/local_image_player.dart')
trace = read('packages/telemetry/lib/src/trace.dart')
reader = read('packages/reader/lib/src/reader_view.dart')
session = read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
policy = read('packages/pipeline/lib/src/heuristic_policy.dart')
native = read('packages/pipeline_native/lib/src/native_pipeline_media_runtime.dart')

# dev.317 observation event-turn boundary stays in production.
require(session, 'Timer.run(() => _drainObservation(generation));', 'dev.317 ordinary event turn')

# Unlike dev.315, Pipeline demand and the native texture owner stay intact.
require(policy, 'runtimeLocalStaticPages.contains(entry.key)', 'dev.313 local-static pre-presentation')
for token in ('AndroidTexturePresenter.isSupported', 'RendererKind.androidTexture', '_AndroidTextureUploader('):
    require(native, token, 'native texture Pipeline retention')
for token in ('encodedFlutterPresentation', '_pipelineAuthoritativeStatic', 'staticEncodedPresentation'):
    forbid(policy + session + player, token, 'dev.315 demand-removal experiment')

# Only authoritative one-frame WebP output may prepare the compressed Flutter projection.
for token in (
    '_isAuthoritativeStaticWebpOutput',
    'snapshot.animation.complete',
    'snapshot.animation.frameCount <= 1',
    '_staticWebpProjectionLoadStarted',
    'await tokenLoader(widget.image, token)',
    'MemoryImage(bytes)',
    '_buildStaticWebpProjection(surface, staticProvider)',
    "'textureRetained': true",
    "'pipeline-texture-fallback-to-compressed-flutter-image'",
):
    require(player, token, 'gapless static Flutter projection')

# Texture must remain the fallback until the Flutter compressed-image frame exists.
projection = player[player.index('Widget _buildStaticWebpProjection('):player.index('void _attachPageOutput(')]
for token in ('if (frame != null || wasSynchronouslyLoaded)', 'return child;', 'return surface.build(', 'fit: BoxFit.fill'):
    require(projection, token, 'gapless texture-to-image visual swap')

# Animation must not be routed by a pre-classification guess.
forbid(player, 'snapshot.animation.frameCount > 1', 'animated projection switch')

# New diagnostics distinguish frame cadence from motion cadence without driving policy.
for token in ('scrollCadenceSummary,', 'staticFlutterPresentation,'):
    require(trace, token, 'trace kind')
for token in (
    '_recordVerticalScrollCadenceSummary',
    "'gapLt10msCount'",
    "'gap14To18msCount'",
    "'gapGe35msCount'",
):
    require(reader, token, 'scroll-update cadence summary')
for rel in ('tool/analyze_composition_motion_jank.py',):
    if not (ROOT / rel).is_file():
        raise SystemExit(f'dev.318 missing analyzer: {rel}')

# No 180ms debounce, resampling, frame-rate request or ScrollPhysics experiment.
product = player + reader + session + policy
for token in (
    'Duration(milliseconds: 180)',
    'GestureBinding.resamplingEnabled',
    'setRequestedFrameRate(',
    'preferredRefreshRate =',
):
    forbid(product, token, 'unrelated experiment')

for rel in (
    'docs/adr/0297-static-webp-flutter-projection-composition-boundary.md',
    'docs/audits/dev318-static-webp-composition-audit.md',
):
    if not (ROOT / rel).is_file():
        raise SystemExit(f'dev.318 missing governance artifact: {rel}')

docs = ''.join(read(path) for path in (
    'CHANGELOG.md',
    'docs/IMPLEMENTATION_PLAN.md',
    'docs/IMPLEMENTATION_STATUS.md',
    'docs/NEXT_CHAT_HANDOFF.md',
    'docs/adr/0297-static-webp-flutter-projection-composition-boundary.md',
    'docs/audits/dev318-static-webp-composition-audit.md',
))
for token in ('4772', '4761', '8.319ms', 'VibeVenera', 'ReaderImageProvider', 'dev.315', 'textureRetained'):
    require(docs, token, 'device/source evidence')

print('dev.318 static WebP Flutter projection composition boundary: OK')
