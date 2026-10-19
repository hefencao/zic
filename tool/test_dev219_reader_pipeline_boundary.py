#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.219 missing {label}: {token}')

def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'dev.219 forbidden {label}: {token}')

registry = read('packages/sessions/lib/src/download_ingress_registry.dart')
projection = read('packages/sessions/lib/src/download_ingress_projection.dart')
ingress = read('packages/media/lib/src/ingress.dart')
pipe = read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
runtime = read('packages/reader_runtime/lib/src/reader_runtime_screen.dart')
controller = read('packages/reader/lib/src/reader_controller.dart')
regression = read('packages/sessions/test/download_session_test.dart')
coordinator_test = read('packages/sessions/test/live_coordinator_test.dart')
pipeline_controller = read('packages/pipeline/lib/src/pipeline_controller.dart')
pipeline_test = read('packages/pipeline/test/pipeline_test.dart')
reader_test = read('packages/reader/test/reader_controller_test.dart')
architecture = read('docs/ARCHITECTURE.md')
spec = read('docs/SPEC.md')

for token in (
    'if (session.committedLength == 0)',
    'session.attachSynchronizedIngressProjection(',
    '_entries[session.id] = entry;',
    'Future<void> settled(DownloadId id)',
    'session.detachIngressProjection(projection.scopeId);',
    'void dispose()',
):
    require(registry, token, 'non-blocking late Reader ingress join')
require(projection, 'void fail(Failure failure)', 'projection-local failure')
require(ingress, 'void fail(Failure failure)', 'Reader-local ingress failure state')
forbid(registry, 'void dispose(Iterable<DownloadSession> sessions)', 'projection registry enumerating physical registry')

for token in (
    'void enqueueObservation(ReaderObs observation)',
    "'stage': 'reader-observation-reconcile'",
    '_invalidateObservationQueue();',
):
    require(pipe, token, 'enqueue-only Reader observation seam')
require(runtime, 'onObservation: (observation) {', 'Reader observation fan-out')
observation_start = runtime.index('onObservation: (observation) {')
observation_end = runtime.index('clock: _pipeline.clock,', observation_start)
observation_callback = runtime[observation_start:observation_end]
require(observation_callback, '_pipeline.enqueueObservation(observation);', 'Reader runtime enqueue seam')
require(observation_callback, 'widget.presentationExtension?.observe(observation);', 'read-only presentation observation')
forbid(observation_callback, '_pipeline.accept(', 'synchronous Reader reconcile in fan-out')
forbid(runtime, 'onObservation: _pipeline.accept,', 'synchronous Reader->pipeline reconcile')
for token in (
    'final observation = reader.lastObservation;',
    '_pipeline.updateDecodeTarget(target);',
    '_pipeline.enqueueObservation(observation);',
):
    require(runtime, token, 'DecodeTarget incremental pipeline update')
target_region = runtime[runtime.index('if (reader != null) {'):runtime.index('final initialProgress = _matchingInitialProgress()')]
forbid(target_region, '_pipeline.detach(', 'DecodeTarget change detaching all demand')
forbid(target_region, '_pipeline.attach(', 'DecodeTarget change recreating binding')
forbid(runtime, 'previous.dispose();', 'DecodeTarget change destroying navigation controller')
for token in (
    'void updateDecodeTarget(DecodeTarget target)',
    '_decodeTargetDirty = true;',
    '!_decodeTargetDirty',
):
    require(pipeline_controller, token, 'incremental DecodeTarget ownership')
require(pipeline_test, 'decode target update preserves download demand ownership', 'target diff behavior regression')
require(controller, 'ReaderObs? get lastObservation => _lastObservation;', 'navigation-owned last observation')
require(controller, 'FlutterError.reportError(', 'pipeline callback failure isolation')
require(reader_test, 'pipeline observation failure cannot roll back visible navigation', 'navigation failure-isolation regression')

require(regression, 'Reader-local ingress registry joins an existing physical prefix asynchronously', 'late re-entry registry regression')
require(coordinator_test, 'late Reader joins promoted physical download without blocking decode/upload reconcile', 'late re-entry coordinator regression')
for token in ('observation', 'late', 'projection', 'ReaderController'):
    require(architecture + spec, token, 'governed ownership boundary')

for rel in (
    'docs/archive/adr/0200-reader-navigation-pipeline-observation-and-late-ingress-boundary.md',
    'docs/archive/audits/dev219-reader-pipeline-coupling-root-cause-audit.md',
    'docs/archive/audits/dev219-validation-results.md',
):
    if not (ROOT / rel).exists():
        raise SystemExit(f'dev.219 governance file missing: {rel}')

pubspec = read('apps/app/pubspec.yaml')
version_props = read('apps/app/android/zic-version.properties')
pub_match = re.search(r'^version: \d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)$', pubspec, re.M)
android_match = re.search(r'^versionCode=(\d+)$', version_props, re.M)
if pub_match is None or int(pub_match.group(1)) < 219:
    raise SystemExit('dev.219+ app version mismatch')
if android_match is None or int(android_match.group(1)) < 219:
    raise SystemExit('dev.219+ Android version mismatch')
version_code = int(pub_match.group(1))
if version_code < 317:
    require(pipe, 'scheduleMicrotask(() => _drainObservation(generation));', 'historical microtask Reader observation seam')
else:
    require(pipe, 'Timer.run(() => _drainObservation(generation));', 'dev.317+ ordinary-event-turn Reader observation seam')
    forbid(pipe[pipe.index('void _scheduleObservationDrain()'):pipe.index('void _drainObservation(int generation)')], 'scheduleMicrotask(', 'dev.317+ observation drain microtask priority')
print('dev.219 Reader/pipeline observation-projection boundary: OK')
