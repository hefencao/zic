#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'missing {label}: {token}')

def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'forbidden {label}: {token}')

session = read('packages/sessions/lib/src/download_session.dart')
registry = read('packages/sessions/lib/src/download_registry.dart')
projection = read('packages/sessions/lib/src/download_ingress_projection.dart')
ingress_registry = read('packages/sessions/lib/src/download_ingress_registry.dart')
decode = read('packages/sessions/lib/src/decode_session.dart')
coordinator = read('packages/sessions/lib/src/live_coordinator.dart')
decode_registry = read('packages/sessions/lib/src/decode_registry.dart')
pipe = read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
page_stream = read('packages/pipeline_runtime/lib/src/pipeline_page_stream.dart')
regression = read('packages/sessions/test/download_session_test.dart')

for token in (
    'final Map<String, DownloadIngressProjection> _ingressProjections',
    'void attachIngressProjection(DownloadIngressProjection projection)',
    'Future<void> attachSynchronizedIngressProjection(',
    "message: 'late ingress projection requires synchronized attachment'",
    'final revision = _ingressProjectionRevision;',
    'Future<Stream<List<int>>> openArtifactReplay(',
    'controlledArtifactReplayRangeChunks',
    'artifact.readChunks(',
    'if (_residentBodyBacked) {',
    "message: 'resident-cache projection replay requires durable byte authority'",
    '_ingressProjections[projection.scopeId] = projection;',
):
    require(session, token, 'physical transfer / ingress projection split')
for token in ('final Ingress? ingress', 'this.ingress,', 'ingress: sources?.get(id)'):
    forbid(session + registry, token, 'Reader-native ingress on physical download owner')
for token in ('SourcePool sources', 'this.sources'):
    forbid(registry, token, 'SourcePool ownership in physical DownloadRegistry')

for token in (
    'final class DownloadIngressProjection',
    'final Ingress ingress;',
    'Future<void> rebuild({',
):
    require(projection, token, 'Reader-local native ingress projection')
for token in (
    'final class DownloadIngressProjectionRegistry',
    'final SourcePool sources;',
    'session.attachIngressProjection(projection);',
):
    require(ingress_registry, token, 'Reader-local ingress projection registry')

require(decode, 'required this.ingress,', 'decode gets explicit Reader ingress')
require(decode, 'final DownloadIngressProjection ingress;', 'decode ingress ownership')
forbid(decode, 'download.ingress', 'decode reaching through physical download')

for token in (
    '_ingresses = DownloadIngressProjectionRegistry(',
    'ingresses: _ingresses,',
    '_ingresses.dispose();',
):
    require(pipe, token, 'Reader composition owns ingress projections')
for token in (
    'final projection = ingresses?.get(session);',
    'ingresses?.release(binding.session);',
):
    require(coordinator, token, 'media coordinator drives Reader-local ingress attachment')
require(
    decode_registry,
    'final ingress = ingresses.get(download);',
    'decode consumes the shared Reader-local ingress registry',
)
forbid(
    pipe,
    '_ingresses.attach(session);',
    'Pipeline composition direct ingress attachment',
)
require(page_stream, 'kind: _contentKind(snapshot.contentKind)', 'page kind comes from physical transfer')

for token in (
    'late Reader ingress projections replay and then diverge independently',
    'await session.attachSynchronizedIngressProjection(projectionA);',
    "expect(session.detachIngressProjection('reader-a'), isTrue);",
):
    require(regression, token, 'late projection join/detach regression')

# Later phases may lift the physical registry/retry owner, but Reader-native
# ingress/decode ownership must remain local after that lift.
for token in ('GlobalDownloadRegistry', 'static final DownloadRegistry', 'CompositionDownloadRegistry'):
    forbid(pipe + session + registry, token, 'parallel/second physical transfer owner')
require(pipe, '_ingresses = DownloadIngressProjectionRegistry(', 'Reader-local ingress survives registry lift')

for rel in (
    'docs/adr/0196-reader-local-ingress-projection-before-transfer-registry-lift.md',
    'docs/audits/dev215-download-ingress-projection-root-cause-audit.md',
    'docs/audits/dev215-validation-results.md',
):
    if not (ROOT / rel).exists():
        raise SystemExit(f'dev.215 governance file missing: {rel}')

pubspec = read('apps/app/pubspec.yaml')
version_props = read('apps/app/android/zic-version.properties')
if not any(f'version: 0.31.0+{build}' in pubspec for build in range(215, 1000)):
    raise SystemExit('dev.215 requires app build >= 215')
if not any(f'versionCode={build}' in version_props for build in range(215, 1000)):
    raise SystemExit('dev.215 requires Android versionCode >= 215')
print('dev.215 download ingress projection split: OK')
