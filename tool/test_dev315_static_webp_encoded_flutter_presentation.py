#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.315 missing {label}: {token}')


stream = read('packages/pipeline_runtime/lib/src/pipeline_page_stream.dart')
session = read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
controller = read('packages/pipeline/lib/src/pipeline_controller.dart')
policy = read('packages/pipeline/lib/src/heuristic_policy.dart')
player = read('packages/local_media_ui/lib/src/local_image_player.dart')
trace = read('packages/telemetry/lib/src/trace.dart')
analyzer = read('tool/analyze_static_encoded_presentation.py')
runtime = read('packages/pipeline_native/lib/src/native_pipeline_media_runtime.dart')
test = read('packages/pipeline/test/pipeline_test.dart')

for token in (
    'final bool? animated;',
    'bool get authoritativeStatic => animated == false;',
    'required bool? Function() resolveAnimated',
    'void refreshClassification()',
):
    require(stream, token, 'page-stream animation projection')

for token in (
    'final Map<String, bool> _pageAnimatedByDownload',
    'resolveAnimated: () => _pageAnimatedByDownload[id.key]',
    '_pageAnimatedByDownload[id.download.key] = animated;',
    '_pageStreams[id.download.key]?.refreshClassification();',
):
    require(session, token, 'decoder classification projection')

for token in (
    'runtimeWebpPages: _runtimeWebpCostPages',
    'Set<int> runtimeWebpPages = const <int>{}',
    'final encodedFlutterPresentation =',
    'runtimeWebpPages.contains(entry.key)',
    'runtimeAnimatedPages[entry.key] != true',
    '!encodedFlutterPresentation',
):
    require(controller + policy, token, 'pre-classification texture suppression')

for token in (
    'snapshot.authoritativeStatic',
    'kind == PipelinePageContentKind.webp',
    '_pipelineAuthoritativeStatic',
    'MemoryImage(bytes)',
    'TraceEventKind.staticEncodedPresentation',
    "'pipeline-compressed-bytes-flutter-codec'",
):
    require(player, token, 'encoded static Flutter presentation')

if player.index('} else if (_pipelineAuthoritativeStatic) {') > player.index('} else if (_detectedFormat.isWebp) {'):
    raise SystemExit('dev.315 static encoded build route must precede generic WebP texture branch')

require(trace, 'staticEncodedPresentation,', 'trace kind')
for token in ('static_encoded_presentations=', 'platform_blit_micros_max=', 'verdict='):
    require(analyzer, token, 'static encoded trace analyzer')

# Animated WebP still owns the existing native SurfaceProducer route.
for token in (
    'NativePipelineMediaRuntimeFactory()',
    'AndroidTexturePresenter.isSupported',
    'RendererKind.androidTexture',
    '_AndroidTextureUploader(',
):
    require(runtime, token, 'animated native texture path')

for token in (
    'android texture waits for WebP animation truth and never uploads authoritative static',
    'unresolved WebP must wait for decoder animation truth before SurfaceProducer',
    'authoritative static WebP uses encoded Flutter presentation',
    'authoritative animated WebP keeps native texture presentation',
):
    require(test, token, 'policy regression')

for rel in (
    'docs/adr/0294-static-webp-encoded-flutter-presentation-boundary.md',
    'docs/audits/dev315-static-webp-encoded-presentation-audit.md',
):
    if not (ROOT / rel).is_file():
        raise SystemExit(f'dev.315 missing governance artifact: {rel}')

docs = ''.join(read(path) for path in (
    'CHANGELOG.md',
    'docs/ARCHITECTURE.md',
    'docs/SPEC.md',
    'docs/IMPLEMENTATION_PLAN.md',
    'docs/IMPLEMENTATION_STATUS.md',
    'docs/NEXT_CHAT_HANDOFF.md',
    'docs/adr/0294-static-webp-encoded-flutter-presentation-boundary.md',
    'docs/audits/dev315-static-webp-encoded-presentation-audit.md',
))
for token in (
    '173', '14/14', '16.588ms', 'surfaceReconfigureCount=1',
    'vibevenera-master.zip', 'MemoryImage', 'compressed',
    'dev.311', 'dev.314', 'FALSIFIED',
):
    require(docs, token, 'governed dev.315 evidence')

pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
match = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
if match is None or int(match.group(1)) < 315:
    raise SystemExit('dev.315 app version missing/regressed')
version = int(match.group(1))
if not re.search(rf'^versionCode={version}$', props, re.M):
    raise SystemExit('dev.315 Android version mismatch')

product = policy + player + read('packages/reader_runtime/lib/src/reader_runtime_screen.dart')
for forbidden in (
    'GestureBinding.resamplingEnabled',
    'setRequestedFrameRate(',
    'preferredRefreshRate =',
):
    if forbidden in product:
        raise SystemExit(f'dev.315 leaked unrelated behavior: {forbidden}')

print('dev.315 static WebP encoded Flutter presentation boundary: OK')
