#!/usr/bin/env python3
from __future__ import annotations

import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
read = lambda p: (ROOT / p).read_text(encoding='utf-8')

PUBSPEC = read('apps/app/pubspec.yaml')
ANDROID = read('apps/app/android/zic-version.properties')
build = int(re.search(r'^version:\s*0\.31\.0\+(\d+)$', PUBSPEC, re.M).group(1))
if build < 206:
    raise SystemExit('dev.206 app build missing')
if f'versionCode={build}' not in ANDROID:
    raise SystemExit('dev.206 Android versionCode mismatch')

manager = read('packages/downloads/lib/src/artifact_cache_manager.dart')
store = read('packages/downloads/lib/src/artifact_cache_store.dart')
partial_store = read('packages/downloads/lib/src/partial_download_store.dart')
handoff = read('packages/downloads/lib/src/partial_download_handoff.dart')
chapter = read('packages/downloads/lib/src/chapter_downloads.dart')
persistent_store = read('packages/downloads/lib/src/persistent_download_artifact_store.dart')
pipe = read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
composition_runtime = read('packages/downloads/lib/src/composition_download_transfer_runtime.dart')
decode = read('packages/sessions/lib/src/decode_session.dart')
reader_route = read('apps/app/lib/home_shell_reader_route.dart')
reader_composition = read('apps/app/lib/home_reader_composition.dart')
source_transport = read('packages/downloads/lib/src/source_resource_transport.dart')
rhttp_transport = read('packages/downloads_bridge/lib/src/rhttp_source_resource_transport.dart')
venera_runtime = read('packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraRuntimeDriver.kt')
local_media_ui = read('packages/local_media_ui/lib/src/local_media_screens.dart')

for marker in (
    "'sourceMediaSemanticRejected': true",
    "_isSourceMediaSemanticRejection(error)",
    "_requiresSourceClientState(error)",
    "sourceSemanticRetryExhausted",
):
    if marker not in source_transport:
        raise SystemExit(f'source semantic/client-state recovery split missing: {marker}')
if "'sourceMediaSemanticRejected': true" not in rhttp_transport:
    raise SystemExit('rhttp non-image response is not typed as source semantic rejection')
for marker in (
    'const __zicSemanticRetryLimit=5',
    '__zicSemanticRetryCount:0',
    'retryCount>=__zicSemanticRetryLimit',
    '__zicSemanticRetryCount:retryCount+1',
):
    if marker not in venera_runtime:
        raise SystemExit(f'Venera bounded semantic-recovery chain missing: {marker}')
for forbidden in (
    '__zicSemanticRetryConsumed',
    '__zicResolveFreshResourceConfig(key,source)',
):
    if forbidden in venera_runtime:
        raise SystemExit(f'Venera semantic recovery still resets to the original image config: {forbidden}')

for forbidden in ('PartialDownload', 'openPartial', 'storePartial', 'invalidatePartial'):
    if forbidden in manager or forbidden in store:
        raise SystemExit(f'promoted ArtifactCache owner leaked mutable partial capability: {forbidden}')
for marker in ('abstract interface class PartialDownloadStore', 'final class PartialDownloadEntry'):
    if marker not in partial_store:
        raise SystemExit(f'Download-owned cold partial store missing: {marker}')
for marker in ('final class PartialDownloadHandoff', 'Future<void> restoreInto(', 'DownloadSession session,', 'drain(Iterable<DownloadSession> sessions)'):
    if marker not in handoff:
        raise SystemExit(f'partial handoff contract missing: {marker}')
for marker in ('PersistentDownloadArtifactStore', 'PartialDownloadStore', 'openPartialDownload', 'storePartialDownload'):
    if marker not in persistent_store:
        raise SystemExit(f'download artifact store durable partial owner missing: {marker}')

retain_start = pipe.index('void retainReaderSession()')
retain_end = pipe.index('void resumeRetainedReaderSession', retain_start)
retain = pipe[retain_start:retain_end]
for forbidden in ('PartialDownload', 'partialDownload', 'checkpoint', '.drain('):
    if forbidden in retain:
        raise SystemExit(f'ordinary Reader retain leaked durable partial work: {forbidden}')
if '_readerSessionRetentionDuration = Duration(minutes: 2)' not in pipe:
    raise SystemExit('hot PipelineReaderSession retention owner missing')
for marker in (
    'LocalImageResponseSource(',
    'selfBoundedOpen: _sourceResources.pageOpenSelfBoundedFor(',
):
    if marker not in reader_composition:
        raise SystemExit(f'Reader source-open bound proof lost at App composition: {marker}')
for marker in (
    'final class LocalImageResponseSource',
    'selfBoundedOpen: responseSource?.selfBoundedOpen ?? false',
):
    if marker not in local_media_ui:
        raise SystemExit(f'Reader source-open bound proof lost before LoaderTransport: {marker}')
transfer_owner_path = ROOT / 'packages/sessions/lib/src/download_transfer_owner.dart'
if transfer_owner_path.exists():
    transfer_owner = transfer_owner_path.read_text(encoding='utf-8')
    if build >= 233:
        for marker in (
            'persistUnclaimed',
            'Future<void> _persistUnclaimed(DownloadSession session) async',
            '_unclaimedFlushes',
        ):
            if marker in transfer_owner:
                raise SystemExit(f'sessions owner leaked durable partial policy after dev.233: {marker}')
        for marker in (
            'prepareDownload: partialDownloadHandoff == null',
            '_restoreLocalSingleFlight(',
            'tracked = handoff.restoreInto(session, control: control)',
            'await partialDownloadHandoff?.drain(registry.sessions);',
        ):
            if marker not in composition_runtime:
                raise SystemExit(f'composition physical runtime partial retirement missing: {marker}')
        if 'persistUnclaimed:' in composition_runtime:
            raise SystemExit('composition runtime still injects per-unclaimed durable policy into sessions')
    else:
        for marker in (
            'persistUnclaimed',
            'Future<void> _persistUnclaimed(DownloadSession session) async',
            'final flush = callback(session);',
            'await flush;',
        ):
            if marker not in transfer_owner:
                raise SystemExit(f'composition physical owner lost durable partial final-drain: {marker}')
        for marker in (
            'prepareDownload: partialDownloadHandoff?.restoreInto',
            'persistUnclaimed: partialDownloadHandoff == null',
            "partialDownloadHandoff!.drain(<DownloadSession>[session])",
        ):
            if marker not in composition_runtime:
                raise SystemExit(f'composition physical runtime partial handoff missing: {marker}')
else:
    dispose = pipe[pipe.index('Future<void> dispose() async'):]
    if 'await _partialDownloadHandoff?.drain(_downloads.sessions)' not in dispose:
        raise SystemExit('true session disposal does not cold-drain unfinished partials')
    if 'prepareDownload: _partialDownloadHandoff?.restoreInto' not in pipe:
        raise SystemExit('cold partial is not restored before network prepare')
if '.withPartialDownloadStore(' not in reader_route:
    raise SystemExit('composition does not wire Download-owned partial store')

restart = decode.index('if (_restartCursorWhenHolderEmpty && (_holder?.depth ?? 0) == 0)')
gate = decode.index('if (!source.sealed)', restart)
if restart >= gate:
    raise SystemExit('cursor reentry must clear stale later-frame requirement before prefix gate')
if 'this.partialLoopMinFrames = 30' not in decode:
    raise SystemExit('ZIC partial-loop minimum frame capability was lost')
for root in ('packages/downloads/lib', 'packages/downloads_bridge/lib', 'packages/plugin_host_bridge/lib'):
    for path in (ROOT / root).rglob('*.dart'):
        if 'partialLoopMinFrames' in path.read_text(encoding='utf-8'):
            raise SystemExit(f'30-frame playback threshold leaked outside DecodeSession ownership: {path.relative_to(ROOT)}')

venera = read('packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraRuntimeDriver.kt')
transport = read('packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraResolverHttpTransport.kt')
service = read('packages/plugin_host_bridge/lib/src/venera_resolver_http_service.dart')
handler = read('packages/plugin_host_bridge/lib/src/runtime_service_handler.dart')
host = read('packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/NativeExternalPluginDriverHost.kt')
android_service = read('packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/ExternalPluginRuntimeService.kt')
bridge_pubspec = read('packages/plugin_host_bridge/pubspec.yaml')

# AndroidX Startup runs in the main process, not the isolated runtime service.
# Domain/cookie handling must have the host Context before any driver can run.
bootstrap = android_service[android_service.index('private fun bootstrapEngine()'):]
initialization = bootstrap.find('OkHttp.initialize(applicationContext)')
if initialization < 0 or initialization > bootstrap.index('FlutterEngine(applicationContext'):
    raise SystemExit('isolated runtime must initialize OkHttp with host application Context before engine/driver activation')

for forbidden in ('HttpURLConnection', 'ReflectiveVeneraHttpClient', 'ReflectiveVeneraCall', 'resolveVeneraPublicAddresses', 'openConnection()'):
    if forbidden in venera:
        raise SystemExit(f'old Venera resolver HTTP owner still present: {forbidden}')
for marker in ('resolverHttp.execute(', 'resolverHttp.cancel(requestId)', 'pending.keys.toList().forEach(bridge::cancel)', 'networkCache.lookup(', 'networkCache.store(', 'persistResponseCookies', 'VENERA_HTTP_MAX_REDIRECTS'):
    if marker not in venera:
        raise SystemExit(f'Venera source-runtime semantics missing after rhttp migration: {marker}')
if 'rhttp: 0.18.0' not in bridge_pubspec:
    raise SystemExit('plugin-host bridge does not own explicit rhttp dependency')
for marker in ('rhttp.RhttpClient.create', 'RedirectSettings.none()', 'keepAliveTimeout: Duration(seconds: 60)', 'final cancelToken = rhttp.CancelToken()', 'requestStream(', "_active[callId]?.cancelToken.cancel()", 'active.cancelToken.cancel()', '_active.values.toList(growable: false)'):
    if marker not in service:
        raise SystemExit(f'isolated Dart resolver rhttp owner missing: {marker}')
for marker in ('class DartRhttpVeneraResolverTransport', 'MethodChannel', 'CountDownLatch', 'Looper.myLooper() != Looper.getMainLooper()', 'veneraResolverHttpRequest', 'veneraResolverHttpCancel', 'cancelCall(callId)', 'emptyMap<String, Any?>()'):
    if marker not in transport:
        raise SystemExit(f'Kotlin synchronous resolver facade missing: {marker}')
if 'HttpURLConnection' in transport:
    raise SystemExit('Kotlin rhttp facade regressed to a second HTTP client')
for marker in ('VeneraResolverHttpService()', "call.method == 'veneraResolverHttpRequest'", "call.method == 'veneraResolverHttpCancel'"):
    if marker not in handler:
        raise SystemExit(f'Dart runtime handler does not own resolver HTTP service: {marker}')
for marker in ('veneraResolverHttp = DartRhttpVeneraResolverTransport(channel)', 'NativeExternalPluginDriverHost'):
    if marker not in android_service:
        raise SystemExit(f'Android runtime service resolver composition missing: {marker}')
if 'veneraResolverHttp: VeneraResolverHttpTransport' not in host:
    raise SystemExit('native driver host resolver transport ownership missing')

for rel in (
    'docs/archive/adr/0188-download-owned-partial-and-venera-rhttp-resolver.md',
    'docs/archive/audits/dev206-owner-boundary-root-cause-audit.md',
    'docs/archive/audits/dev206-validation-results.md',
):
    if not (ROOT / rel).exists():
        raise SystemExit(f'dev.206 governance file missing: {rel}')

# Compile the new Kotlin facade independently from Android/Flutter with tiny stubs.
kotlinc = shutil.which('kotlinc')
if kotlinc:
    with tempfile.TemporaryDirectory() as raw:
        work = Path(raw)
        (work / 'AndroidOs.kt').write_text('''package android.os
class Looper { companion object { fun getMainLooper(): Looper = Looper(); fun myLooper(): Looper? = null } }
class Handler(val looper: Looper) { fun post(block: () -> Unit): Boolean { block(); return true } }
object SystemClock { fun elapsedRealtime(): Long = 0L }
''')
        (work / 'AndroidUtil.kt').write_text('''package android.util
object Log {
  const val DEBUG: Int = 3
  fun isLoggable(tag: String, level: Int): Boolean = false
  fun d(tag: String, message: String): Int = 0
}
''')
        (work / 'MethodChannel.kt').write_text('''package io.flutter.plugin.common
class MethodChannel {
  interface Result { fun success(result: Any?); fun error(code: String, message: String?, details: Any?); fun notImplemented() }
  fun invokeMethod(method: String, arguments: Any?, result: Result? = null) {}
}
''')
        jar = work / 'resolver.jar'
        subprocess.run([
            kotlinc,
            str(work / 'AndroidOs.kt'),
            str(work / 'AndroidUtil.kt'),
            str(work / 'MethodChannel.kt'),
            str(ROOT / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraResolverHttpTransport.kt'),
            '-d', str(jar),
        ], check=True)
else:
    print('SKIP: kotlinc unavailable for dev.206 resolver facade compile')

print('dev.206 Download-owned partial + Venera rhttp resolver boundary: OK')
