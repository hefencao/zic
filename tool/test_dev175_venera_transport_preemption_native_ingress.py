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


control = read('packages/domain/lib/src/task_control.dart')
for token in (
    'abstract interface class TaskControl',
    'bool get cancelled;',
    'Future<void> get whenCancelled;',
    'int get priority;',
):
    require(control, token, 'scheduler control contract')

lane = read('packages/sessions/lib/src/net_lane.dart')
for token in (
    'final class CancelToken',
    'implements PriorityObservableTaskControl, OpenPhaseReportingTaskControl',
    'int priority = 0,',
    'void updatePriority(int priority)',
    'bool _updateActivePriority(_ActiveTask task, int priority)',
    'task.token.updatePriority(priority);',
    'late CancelToken token;',
    'token = CancelToken(',
    'priority: next.priority',
):
    require(lane, token, 'lane-owned mutable task priority')
if not re.search(
    r'CancelToken\(\{?\s*\n?\s*int priority = 0,?',
    lane,
):
    raise SystemExit('CancelToken must retain default mutable priority=0')

transport = read('packages/transport/lib/src/transport.dart')
loader_transport = read('packages/transport/lib/src/loader_transport.dart')
download_job = read('packages/sessions/lib/src/download_job.dart')
for token in (
    'abstract interface class ControlledTransport implements Transport',
    'TaskControl? control,',
):
    require(transport, token, 'controlled transport capability')
for token in (
    'typedef ControlledTransportResponseLoader',
    'this.openControlledResponse,',
    'final class LoaderTransport',
    'implements ControlledTransport, SelfBoundedOpenTransport',
    'openControlledResponse(',
    'control: control,',
):
    require(loader_transport, token, 'Reader loader control propagation')
for token in (
    'transport is ControlledTransport',
    'controlled.openControlled(',
    'control: cancel,',
):
    require(download_job, token, 'DownloadJob scheduler control propagation')

catalog = read('packages/catalog/lib/src/source_catalog.dart')
cached = read('packages/catalog/lib/src/cached_comic_source.dart')
for token in (
    'ControlledResolvableComicResourceSource',
    'ControlledRetryableComicResourceSource',
    'ControlledComicResourceSource',
):
    require(catalog, token, 'controlled source capabilities')
    require(cached, token, 'cached source control forwarding')

source_transport = read('packages/downloads/lib/src/source_resource_transport.dart')
for token in (
    'ExternalPluginControlledResourceResponseLoader',
    'controlledLoaderFor(',
    'final class _SourceResourceTransport',
    'implements ControlledTransport, SelfBoundedOpenTransport',
    'Future<ByteResponse> openControlled(',
    '_resolve(uri, control: control)',
    'resolveResourceControlled(locator, control: control)',
    'retryResourceControlled(locator, control: control)',
    '.loadResourceControlled(uri, control: control)',
    'request.abort(_taskCancelledFailure());',
    'control: control,',
):
    require(source_transport, token, 'source transport cancellation/priority propagation')
require(
    source_transport,
    'if (control == null) {\n      final active = _requestLoads[locator];',
    'controlled request-plan Future isolation',
)

runtime = read('packages/plugin_host/lib/src/runtime_source_adapter.dart')
for token in (
    'TaskControl? control,',
    'final invocationGate = isolatedTransform ? _transformGate : _gate;',
    'invocationGate.run(',
    'control: control,',
    'await _cancelInvocation(request.requestId);',
    'final class _RuntimeInvocationWaiter',
    'int get priority => control?.priority ?? 0;',
    '_RuntimeInvocationWaiter? _takeHighestPriorityWaiter()',
    'waiter.priority > best.priority',
    'ControlledResolvableComicResourceSource',
    'resolveResourceControlled(',
    'loadResourceControlled(',
):
    require(runtime, token, 'priority-aware cancellable runtime gate')
# Venera remains single-context. Current wins by scheduling/cancellation, never
# by opening a second JavaScript/WebView invocation context.
require(
    runtime,
    'plugin.format == ExternalComicPluginFormat.veneraJavaScript\n                  ? 1',
    'Venera single invocation context',
)
forbid(runtime, 'Queue<Completer<void>> _waiters', 'FIFO-only Venera waiter queue')

app_gateway = read('apps/app/lib/source_resource_gateway.dart')
app_home = read('apps/app/lib/demo_home.dart') + read('apps/app/lib/demo_home_reader_route.dart')
local_ui = read('packages/local_media_ui/lib/src/local_media_screens.dart')
for token in (
    'pageControlledResponseLoaderFor(',
    '_transports.controlledLoaderFor(',
):
    require(app_gateway, token, 'App Reader controlled source loader')
require(
    app_home,
    'observedPageControlledResponseLoaderFor(',
    'Reader route controlled loader composition',
)

runtime_test = read('packages/plugin_host/test/runtime_source_adapter_test.dart')
for token in (
    'controlled Venera resource work cancels active prefetch and admits current before queued prefetch',
    "'venera-resource:prefetch-a'",
    "'venera-resource:current'",
    'connection.cancelledRequestIds',
    'expect(connection.maxActive, 1);',
):
    require(runtime_test, token, 'Venera controlled-priority behavior regression')

transport_test = read('packages/downloads/test/source_resource_transport_test.dart')
for token in (
    'controlled Reader loader preserves scheduler control through source resolution',
    '.controlledLoaderFor(source',
    'identical(source.lastResolveControl, control)',
):
    require(transport_test, token, 'source transport control propagation regression')
for token in (
    'final class LocalImageResponseSource',
    'final ControlledTransportResponseLoader openControlledResponse;',
    'final bool selfBoundedOpen;',
    'final Map<String, LocalImageResponseSource> responseSources;',
    'openControlledResponse: responseSource?.openControlledResponse',
    'selfBoundedOpen: responseSource?.selfBoundedOpen ?? false',
):
    require(local_ui, token, 'local media Reader controlled loader boundary')

native_lib = read('native/media_core/src/lib.rs')
webp = read('native/media_core/src/webp.rs')
for token in (
    '.prepare_next(source.committed_bytes(), source.sealed)',
    'match prepared.and_then(|frame| cursor.decoder.decode_prepared(frame))',
    'after the lock is released',
):
    require(native_lib, token, 'short source-lock decode preparation')
forbid(
    native_lib,
    '.decode_next(source.committed_bytes(), source.sealed)',
    'whole-frame decode while source read lock is held',
)

profile = read('packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart')
for token in (
    'forwardEncodedPages: 7',
    'backwardEncodedPages: 3',
    'forwardDecodePages: 2',
    'backwardDecodePages: 1',
    'networkConcurrency: 5',
    'decodeConcurrency: 3',
    'uploadConcurrency: 2',
):
    require(profile, token, 'unchanged Vibe-derived Reader resource policy')
composition = read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
for token in (
    'reservedHighPrioritySlots: 1',
    'highPriorityThreshold: 1000',
    'preemptionThreshold: 40',
):
    require(composition, token, 'unchanged current handoff policy')
for token in (
    'pub(crate) struct PreparedFrame',
    'pub(crate) fn prepare_next(',
    'fragment: bytes[fragment_offset..fragment_end].to_vec()',
    'pub(crate) fn decode_prepared(',
    'decode_rgba_scaled_single_threaded(',
):
    require(webp, token, 'prepared compressed-fragment decode')

check = read('tool/check.sh')
require(
    check,
    'test_dev175_venera_transport_preemption_native_ingress.py',
    'release gate wiring',
)

version = re.search(
    r'^version:\s*0\.31\.0\+(\d+)\s*$',
    read('apps/app/pubspec.yaml'),
    re.M,
)
if version is None or int(version.group(1)) < 175:
    raise SystemExit('App build must be at least 175')
android = re.search(
    r'^versionCode=(\d+)\s*$',
    read('apps/app/android/zic-version.properties'),
    re.M,
)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.175 Venera transport preemption / native ingress contract: OK')
