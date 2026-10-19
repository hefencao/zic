#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'missing {label}: {token}')

def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'superseded {label}: {token}')

cache = read('packages/downloads/lib/src/artifact_cache_transport.dart')
for token in (
    'final class ArtifactCacheTransport implements ControlledTransport',
    'Future<ByteResponse> openControlled(',
    '_throwIfTaskCancelled(control);',
    'fallback is ControlledTransport',
    'fallback.openControlled(',
    'control: control,',
    "'controlledFallback': controlledFallback",
    'priority: control?.priority,',
):
    require(cache, token, 'artifact read-through control propagation')
forbid(
    cache,
    "final response = await fallback.open(\n      uri,",
    'unconditional uncontrolled origin fallback',
)

job = read('packages/sessions/lib/src/download_job.dart')
for token in (
    'transport is ControlledTransport',
    'controlled.openControlled(',
    'control: cancel,',
):
    require(job, token, 'DownloadJob control ingress')

composition = read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
for token in (
    '_artifactCacheTransport = ArtifactCacheTransport(',
    'fallbackFor: _baseTransportFor,',
    '_artifactCacheTransport ?? _baseTransportFor(uri)',
):
    require(composition, token, 'production artifact read-through composition')

loader = read('packages/transport/lib/src/loader_transport.dart')
source_transport = read('packages/downloads/lib/src/source_resource_transport.dart')
runtime = read('packages/plugin_host/lib/src/runtime_source_adapter.dart')
require(loader, 'final class LoaderTransport', 'Loader control capability')
require(
    loader,
    'implements ControlledTransport, SelfBoundedOpenTransport',
    'Loader bounded control capability',
)
require(source_transport, 'resolveResourceControlled(locator, control: control)', 'source plan control')
require(runtime, 'int get priority => control?.priority ?? 0;', 'runtime priority gate')
require(runtime, '_maybePreemptActiveForControlled(control);', 'runtime current pressure preemption')
require(runtime, 'taskControl.priorityChanges.listen', 'runtime dynamic priority observation')

cache_test = read('packages/downloads/test/artifact_cache_transport_test.dart')
for token in (
    'cache miss preserves scheduler control into controlled origin fallback',
    'cancelled controlled cache miss never opens origin fallback',
    'expect(fallback.controlledOpens, 1);',
    'expect(fallback.uncontrolledOpens, 0);',
    'identical(fallback.lastControl, control)',
):
    require(cache_test, token, 'artifact cache controlled fallback regression')

check = read('tool/check.sh')
require(check, 'test_dev181_artifact_cache_controlled_origin_owner.py', 'release gate wiring')

version = re.search(r'^version:\s*\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 181:
    raise SystemExit('App build must be at least 181')
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.181 artifact-cache controlled origin ownership: OK')
