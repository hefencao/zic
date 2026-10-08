import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:downloads_bridge/downloads_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_media_ui/local_media_ui.dart';
import 'package:pipeline_native/pipeline_native.dart';
import 'package:plugin_host/plugin_host.dart';
import 'package:plugin_host_bridge/plugin_host_bridge.dart';
// Test-only explicit completion demand; the production transfer owner schedules it.
// ignore: depend_on_referenced_packages
import 'package:sessions/sessions.dart';
// Test-only inspection of durable authority; no new application dependency.
// ignore: depend_on_referenced_packages
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';
import 'package:zic/main.dart' as app_entrypoint;
import 'package:zic/startup_platform.dart';

// Test-only loopback HTTP -> production source/Binder/file -> DownloadSession,
// persistent artifact and actual Reader presentation. No user store is opened.
// The server holds its own TCP output; no production read Future is delayed.
const _key = 'source_native_webp_pipeline_fixture';
const _post = 'native-webp-fixture-post';
const _sourceUa = 'SourceNativeWebpFixture/1';
const _transitionOnly = bool.fromEnvironment('ZIC_SOURCE_NATIVE_WEBP_TRANSITION_ONLY');
const _partialOnly = bool.fromEnvironment('ZIC_SOURCE_NATIVE_WEBP_PARTIAL_ONLY');
const _partialFailuresOnly = bool.fromEnvironment('ZIC_SOURCE_NATIVE_WEBP_PARTIAL_FAILURES_ONLY');
const _partialMetadataOnly = bool.fromEnvironment('ZIC_SOURCE_NATIVE_WEBP_PARTIAL_METADATA_ONLY');
final _events = <Map<String, Object?>>[];
final _traces = <Map<String, Object?>>[];
final _clock = Stopwatch()..start();
late String _output;

@pragma('vm:entry-point')
Future<void> zicExternalPluginRuntimeServiceMain() =>
    app_entrypoint.zicExternalPluginRuntimeServiceMain();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _status('正文缓存与呈现验收');
  await waitForFirstFlutterUiDisplayed();
  for (final plugin in <String>['network_bridge', 'plugin_host_bridge',
    'texture_bridge', 'reader_runtime']) {
    await attachAndroidPlugin(plugin);
  }
  final support = await getStartupApplicationSupportPath();
  _require(support != null, 'native support path missing');
  _output = '$support/zic-source-native-webp-pipeline-results.json';
  final root = await Directory.systemTemp.createTemp('zic-source-native-webp-pipeline-');
  final wire = _Wire(ServicesBinding.instance.defaultBinaryMessenger);
  _Origin? origin;
  ExternalPluginRuntimeSession? session;
  ExternalPluginResourceTransportPool? pool;
  _Composition? current;
  try {
    _require(<bool>[_transitionOnly, _partialOnly, _partialFailuresOnly, _partialMetadataOnly]
      .where((enabled) => enabled).length <= 1, 'fixture modes are mutually exclusive');
    origin = await _Origin.start(await _inputs(support!));
    final payload = await File('${root.path}/fixture.js').writeAsString(
      "class SourceNativeWebpPipelineFixture extends ComicSource {name='Fixture';"
      "key='$_key';version='1';url='https://fixture.invalid';"
      "explore=[{title:'Fixture',type:'multiPageComicList',load:async(page)=>[]}];"
      "comic={onThumbnailLoad:(uri)=>({method:uri.includes('/partial-range-')?'GET':'POST',"
      "headers:{Cookie:'acceptance=present','User-Agent':'$_sourceUa'},"
      "data:uri.includes('/partial-range-')?'':'$_post',"
      "...((uri.includes('/transition-')||uri.includes('/partial-'))?{}:"
      "{onResponse:async(input)=>input})})};}",
    );
    final plugin = ExternalComicPluginCatalogEntry(
      format: ExternalComicPluginFormat.veneraJavaScript,
      pluginId: 'venera:source-native-webp-pipeline-fixture', name: 'Fixture', version: '1',
      entrypoint: Uri.parse('https://fixture.invalid/fixture.js'),
      sources: const <ExternalComicPluginSource>[
        ExternalComicPluginSource(sourceId: 'venera:source_native_webp_pipeline_fixture',
          externalId: _key, name: 'Fixture', language: 'en'),
      ],
    );
    final inspection = await VeneraJavaScriptInspector(
      requestedCapabilities: const <ExternalPluginCapability>{},
      payloads: CallbackExternalPluginPayloadLoader((_) async =>
        ExternalPluginPayloadFile(path: payload.path,
          byteLength: await payload.length())),
    ).inspect(plugin);
    const limits = ExternalPluginRuntimeLimits(
      invocationTimeout: Duration(seconds: 60), maxConcurrentInvocations: 1,
      maxResponseBytes: 32 * 1024 * 1024,
    );
    final connection = await AndroidVeneraSandboxRuntimeBackend(channel: MethodChannel(
      'dev.zic/plugin_host_runtime_bridge', const StandardMethodCodec(), wire,
    )).activate(VeneraExecutionRequest(
      plugin: plugin, payloadPath: payload.path,
      payloadByteLength: await payload.length(),
      payloadSha256: inspection.payloadSha256, sourceKey: _key,
      capabilities: const <ExternalPluginCapability>{}, limits: limits,
    ));
    session = ExternalPluginRuntimeSession(
      plugin: plugin, connection: connection, limits: limits,
    );
    final process = await Process.run('/system/bin/pidof',
      <String>['dev.zic.zic:zic_plugin_runtime']);
    final sourcePid = int.parse((process.stdout as String).trim());
    _require(sourcePid != pid, 'source runtime is not a separate actual process');
    final source = session.sources.single;
    pool = ExternalPluginResourceTransportPool(
      directTransport: RhttpSourceResourceDirectTransport(),
      defaultUserAgentProvider: () => 'FallbackPipelineFixture/1',
    );
    if (_transitionOnly || _partialOnly || _partialFailuresOnly || _partialMetadataOnly) {
      if (_transitionOnly) {
        await _transitionCase(root.path, origin, pool, source, wire);
      } else {
        await _partialCase(root.path, origin, pool, source, wire,
          failures: _partialFailuresOnly || _partialMetadataOnly);
      }
      await session.close();
      session = null;
      pool.close();
      pool = null;
      final originRequestsForMode = origin.requests.length;
      await origin.close();
      origin = null;
      await Directory('$support/zic-source-native-webp-inputs').delete(recursive: true);
      await root.delete(recursive: true);
      await _record(<String, Object?>{
        'case': 'complete', 'status': 'passed',
        'cases': _transitionOnly || _partialMetadataOnly ? 1 : _partialFailuresOnly ? 4 : 2,
        'production_modified': false, 'host_pid': pid, 'source_pid': sourcePid,
        'actual_HTTP_requests': originRequestsForMode,
        'test_root_removed': !root.existsSync(),
        'all_test_compositions_and_source_session_closed': true,
        'test_inputs_removed': !Directory('$support/zic-source-native-webp-inputs').existsSync(),
        'real_origin_or_final_display_performance_proven': false,
      });
      _status(_transitionOnly ? '拖动首帧验收通过' : 'partial重入验收通过');
      return;
    }
    for (final plane in <String>['static', 'animated']) {
      final record = _chapter(plane, origin.uri('/$plane/full'));
      final manifest = record.toManifest();
      final id = readerPageDownloadId(manifest, manifest.pages.single);
      final directory = '${root.path}/$plane';
      final loader = _ObservedLoader(pool.controlledLoaderFor(source, id.canonicalUri),
        selfBoundedOpen: pool.selfBoundsOpenFor(source, id.canonicalUri));
      wire.beginCase();
      current = await _Composition.open(directory);
      await _present(record, current, loader);
      final ready = await current.ready(id);
      final proof = await _artifactProof(ready, wire, plane, origin.bytesFor(plane));
      final native = await _nativeProof(plane, current.trace);
      _require(loader.opens == 1 && origin.requests.length ==
        (plane == 'static' ? 1 : 3), 'first download did not use one origin request');
      _require(current.trace.events.any((e) => e.kind == TraceEventKind.bytesCommitted) &&
        current.trace.events.any((e) => e.kind == TraceEventKind.artifactPromoted),
        'production DownloadSession did not commit and promote the source body');
      _require(current.runtime.findSession(id) != null,
        'presentation bypassed the physical DownloadSession');
      wire.requireReleased();
      final beforeClose = _lane(current);
      final trace = _captureTrace('$plane-first-download', current.trace);
      await _record(<String, Object?>{
        'case': '$plane-first-download', 'status': 'passed',
        'reader_mounted': true, 'first_frame_callback': true,
        'origin_requests': loader.opens, 'source_input_bytes': origin.bytesFor(plane).length,
        'claims': wire.claims, 'releases': wire.releases,
        'source_transform_operations': wire.transforms,
        'body_delivery': loader.deliveries.single, 'artifact': proof, 'native': native,
        'lane_after_presentation': beforeClose, 'trace_summary': trace,
      });
      // Hold only the already-presented test route for the runner's screenshot.
      await Future<void>.delayed(const Duration(seconds: 2));
      final warm = current;
      await _unmount();
      await warm.close();
      current = null;
      final warmExit = warm.exitProof;

      wire.beginCase();
      final requestsBeforeCold = origin.requests.length;
      final coldLoader = _ObservedLoader(pool.controlledLoaderFor(source, id.canonicalUri),
        selfBoundedOpen: pool.selfBoundsOpenFor(source, id.canonicalUri));
      current = await _Composition.open(directory);
      _require(!identical(current.cache, warm.cache) &&
        !identical(current.runtime, warm.runtime) &&
        current.runtime.registry.sessions.isEmpty && current.cache.memoryEntryCount == 0,
        'cold entry retained a physical session or memory artifact');
      final indexedBefore = await current.store.index.get(id.key);
      _require(indexedBefore != null && indexedBefore.state == CacheState.ready &&
        _sameArtifact(indexedBefore, ready), 'READY proof did not survive store reopen');
      await _present(record, current, coldLoader);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final coldReady = await current.ready(id);
      _require(_sameArtifact(coldReady, ready) && coldLoader.opens == 0 &&
        origin.requests.length == requestsBeforeCold && wire.claims == 0 && wire.transforms == 0,
        'cold READY presentation reopened source or changed exact identity');
      _require(current.trace.events.every((e) => e.kind != TraceEventKind.downloadStarted &&
        e.kind != TraceEventKind.taskFailed), 'cold cache presentation started network or failed');
      final coldNative = await _nativeProof(plane, current.trace);
      final coldTrace = _captureTrace('$plane-cold-READY', current.trace);
      await _record(<String, Object?>{
        'case': '$plane-cold-READY', 'status': 'passed',
        'reader_mounted': true, 'first_frame_callback': true,
        'origin_requests': coldLoader.opens, 'READY_identity_preserved': true,
        'new_store_cache_transfer_and_raster_owners': true,
        'previous_composition_exit': warmExit, 'trace_summary': coldTrace, 'native': coldNative,
      });
      await Future<void>.delayed(const Duration(seconds: 2));
      await _unmount();
      await current.close();
      current = null;

      wire.beginCase();
      final cancelUri = origin.uri('/$plane/cancel-input');
      final cancelledRecord = _chapter('$plane-cancel', cancelUri);
      final cancelManifest = cancelledRecord.toManifest();
      final cancelId = readerPageDownloadId(cancelManifest, cancelManifest.pages.single);
      final cancelLoader = _ObservedLoader(pool.controlledLoaderFor(source, cancelUri),
        selfBoundedOpen: pool.selfBoundsOpenFor(source, cancelUri));
      final held = origin.hold(cancelUri.path);
      current = await _Composition.open('${root.path}/$plane-cancel');
      var unexpectedFrame = false;
      _mount(cancelledRecord, current, cancelLoader, () => unexpectedFrame = true);
      await held.headers.future.timeout(const Duration(seconds: 20));
      _require(!unexpectedFrame && cancelLoader.opens == 1 && !current.lane.isIdle,
        'held actual HTTP input is not inside a live physical transfer');
      final laneBeforeCancel = _lane(current);
      final cancelAt = _clock.elapsedMicroseconds;
      await _unmount();
      await current.factory.disposeRetainedSessions().timeout(const Duration(seconds: 20));
      _require(!current.runtime.hasConsumers, 'route teardown left a Reader transfer consumer');
      await current.runtime.dispose().timeout(const Duration(seconds: 20));
      await held.peerClosed.future.timeout(const Duration(seconds: 20));
      _require(cancelLoader.cancelled == 1 && wire.claims == 0 && wire.transforms == 0 &&
        current.lane.isIdle && !unexpectedFrame,
        'route cancellation lost typed failure, physical exit or published a body/frame');
      final cancelledIndex = await current.store.index.get(cancelId.key);
      _require(cancelledIndex == null || cancelledIndex.state != CacheState.ready,
        'unfinished source input polluted durable READY');
      final cancelledTrace = _captureTrace('$plane-route-cancellation', current.trace);
      await current.close();
      await Future<void>.delayed(const Duration(seconds: 2));
      _require(cancelLoader.opens == 1 && !unexpectedFrame && origin.requests.where((r) => r['path'] == cancelUri.path).length == 1,
        'cancelled source input reopened or presented late');
      final exit = current.exitProof;
      current = null;
      await _record(<String, Object?>{
        'case': '$plane-route-cancellation', 'status': 'passed',
        'headers_and_partial_input_sent': true, 'actual_TCP_peer_closed': true,
        'typed_cancellation': true, 'no_READY_or_first_frame': true,
        'claims': wire.claims, 'source_transform_operations': wire.transforms,
        'cancel_to_peer_close_micros': held.peerClosedAt! - cancelAt,
        'lane_before_cancel': laneBeforeCancel, 'composition_exit': exit,
        'trace_summary': cancelledTrace,
      });
    }
    _require(origin.requests.length == 4 && origin.requests.every((r) =>
      r['method_POST'] == true && r['nonempty_Cookie_preserved'] == true &&
      r['source_UA_preserved'] == true && r['nonempty_POST_body_preserved'] == true),
      'source HTTP plan method/Cookie/UA/body was changed');
    await session.close();
    session = null;
    pool.close();
    pool = null;
    await origin.close();
    origin = null;
    await Directory('$support/zic-source-native-webp-inputs').delete(recursive: true);
    await root.delete(recursive: true);
    await _record(<String, Object?>{
      'case': 'complete', 'status': 'passed', 'cases': 6,
      'production_modified': false, 'host_pid': pid, 'source_pid': sourcePid,
      'source_process_generation_at_activation': wire.sourceGeneration,
      'actual_HTTP_requests': 4, 'all_test_compositions_and_source_session_closed': true,
      'test_root_removed': !root.existsSync(),
      'selected_static_and_animated_native_WebP_pipeline_proven': true,
      'real_origin_or_final_display_performance_proven': false,
      'test_inputs_removed': !Directory('$support/zic-source-native-webp-inputs').existsSync(),
    });
    _status('缓存与呈现验收通过');
  } on Object catch (error, stack) {
    if (current != null) _captureTrace('failed-case', current.trace);
    await _record(<String, Object?>{
      'case': 'complete', 'status': 'failed',
      'error': error.toString(), 'stack': stack.toString(),
    });
    _status('缓存与呈现验收失败');
  } finally {
    if (current != null) await _unmount();
    await current?.close();
    await session?.close();
    pool?.close();
    await origin?.close();
    if (root.existsSync()) await root.delete(recursive: true);
    final inputs = Directory('$support/zic-source-native-webp-inputs');
    if (inputs.existsSync()) await inputs.delete(recursive: true);
  }
}

ImportedChapterRecord _chapter(String label, Uri uri) => ImportedChapterRecord(
  directoryId: 'fixture:$label', displayName: 'Fixture $label',
  sourceId: 'venera:source_native_webp_pipeline_fixture', comicId: 'fixture-comic',
  chapterId: label, sourceRevision: 'fixture-r1',
  pages: <ImportedPageRecord>[
    ImportedPageRecord(displayName: 'page.webp', sourceId: uri.toString(),
      pageId: 'page-0', mediaFormat: 'webp', contentKindHint: ContentKindHint.webp),
  ],
);

void _mount(ImportedChapterRecord record, _Composition composition,
    _ObservedLoader loader, VoidCallback onFirstFrame) {
  _mountPages(record, composition,
    <String, _ObservedLoader>{record.pages.single.sourceId: loader}, onFirstFrame);
}

void _mountPages(ImportedChapterRecord record, _Composition composition,
    Map<String, _ObservedLoader> loaders, VoidCallback onFirstFrame,
    {bool gestureTarget = false}) {
  final screen = ImportedImageChapterScreen(
    record: record, pipelineFactory: composition.factory,
    staticPresentation: composition.presentation, traceSink: composition.trace,
    responseSources: <String, LocalImageResponseSource>{
      for (final entry in loaders.entries) entry.key: LocalImageResponseSource(
        openControlledResponse: entry.value.open,
        selfBoundedOpen: entry.value.selfBoundedOpen,
      ),
    },
    initialReaderSettings: gestureTarget ? const ReaderSessionSettings(
      comicSpecificEnabled: true, directionOverride: ReadingDirection.ltr,
      verticalStitchOverride: false) : const ReaderSessionSettings(),
    onFirstPresentationFrame: onFirstFrame,
  );
  runApp(MaterialApp(key: UniqueKey(), home: gestureTarget
    ? Semantics(container: true, explicitChildNodes: true,
        label: '正文拖动验收区域', child: screen)
    : screen));
}

Future<void> _until(bool Function() condition, String reason) async {
  final timer = Stopwatch()..start();
  while (!condition()) {
    _require(timer.elapsed < const Duration(seconds: 30), reason);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> _transitionCase(String directory, _Origin origin,
    ExternalPluginResourceTransportPool pool, BrowsableComicSource source,
    _Wire wire) async {
  final currentUri = origin.uri('/animated/transition-current');
  final nextUri = origin.uri('/animated/transition-next');
  final held = origin.hold(currentUri.path)..progressive = true;
  final record = ImportedChapterRecord(
    directoryId: 'fixture:transition', displayName: 'Transition fixture',
    sourceId: 'venera:source_native_webp_pipeline_fixture', comicId: 'fixture-comic',
    chapterId: 'transition', sourceRevision: 'fixture-r1',
    pages: <ImportedPageRecord>[
      for (final uri in <Uri>[currentUri, nextUri]) ImportedPageRecord(
        displayName: 'page.webp', sourceId: uri.toString(), pageId: uri.path,
        mediaFormat: 'webp', contentKindHint: ContentKindHint.webp),
    ],
  );
  final manifest = record.toManifest();
  final ids = manifest.pages.map((page) => readerPageDownloadId(manifest, page)).toList();
  final loaders = <String, _ObservedLoader>{
    for (final uri in <Uri>[currentUri, nextUri]) uri.toString(): _ObservedLoader(
      pool.controlledLoaderFor(source, uri), selfBoundedOpen: pool.selfBoundsOpenFor(source, uri)),
  };
  wire.beginCase();
  final composition = await _Composition.open('$directory/transition');
  final trace = composition.trace;
  try {
    _mountPages(record, composition, loaders, () {}, gestureTarget: true);
    await held.headers.future.timeout(const Duration(seconds: 20));
    await _until(() => composition.runtime.findSession(ids[1])?.snapshot.committedLength != null &&
      composition.runtime.findSession(ids[1])!.snapshot.committedLength > 0 &&
      trace.events.any((e) => e.kind == TraceEventKind.decodeState &&
        e.payload['state'] == 'waitingSource' && e.payload['depth'] == 0),
      'current did not wait at zero frames while neighbor predownload committed');
    _require(trace.events.every((e) => e.kind != TraceEventKind.frameDecoded &&
      e.kind != TraceEventKind.firstFrameReady && e.kind != TraceEventKind.taskFailed),
      'fixture did not establish zero-frame current and unpresented neighbor');
    final currentIdentity = trace.events.firstWhere((e) =>
      e.kind == TraceEventKind.decodeRefill && e.payload['role'] == 'current').identityHash;
    final sessions = ids.map(composition.runtime.findSession).toList();
    final epochs = sessions.map((session) => session!.snapshot.epoch).toList();
    await _record(<String, Object?>{
      'case': 'transition-awaiting-drag', 'status': 'ready',
      'current_depth': 0, 'current_body_unsealed': true,
      'target_predownload_committed_bytes': sessions[1]!.snapshot.committedLength,
      'target_decoded_frames': 0, 'gesture_target': '正文拖动验收区域',
    });
    await _until(() => trace.events.any((e) => e.kind == TraceEventKind.firstFrameReady &&
      e.payload['pageIndex'] == 1), 'real drag target did not present while current was waiting');
    final targetFrame = trace.events.firstWhere((e) =>
      e.kind == TraceEventKind.firstFrameReady && e.payload['pageIndex'] == 1);
    // Coverage diagnostics are sampled, whereas the real transition demand is
    // reconciled every frame. Its threshold need not have an earlier trace row.
    await _until(() => trace.events.any((e) => e.kind == TraceEventKind.pageTransition &&
      (e.payload['targetCoverage'] as num? ?? 0) >= .15 && e.payload['currentIndex'] == 0 &&
      e.payload['interaction'] == 'dragging'), 'real partial drag did not cross transition coverage');
    _require(trace.events.every((e) => e.kind != TraceEventKind.frameDecoded ||
      e.identityHash != currentIdentity), 'current frame arrived before independent target');
    final transitionRefill = trace.events.firstWhere((e) =>
      e.kind == TraceEventKind.decodeRefill && e.payload['role'] == 'transition');
    _require(transitionRefill.monotonicMicros <= targetFrame.monotonicMicros &&
      transitionRefill.payload['depth'] == 0 && transitionRefill.payload['target'] == 1,
      'transition did not bootstrap its own single frame');
    await origin.release(currentUri.path);
    await _until(() => trace.events.any((e) => e.kind == TraceEventKind.decodeState &&
      e.identityHash == currentIdentity && e.payload['state'] == 'ready' &&
      (e.payload['depth'] as num? ?? 0) >= 3), 'current bootstrap did not recover after body release');
    final bootstrap = trace.events.firstWhere((e) =>
      e.kind == TraceEventKind.decodeState && e.identityHash == currentIdentity &&
      e.payload['state'] == 'ready' && (e.payload['depth'] as num? ?? 0) >= 3);
    _require(trace.events.every((e) => e.kind != TraceEventKind.decodeRefill ||
      e.monotonicMicros >= bootstrap.monotonicMicros ||
      !<String>['transition', 'next', 'next2', 'previous'].contains(e.payload['role']) ||
      (e.payload['target'] as num? ?? 0) <= 1),
      'neighbor deep refill preceded current bootstrap');
    await _record(<String, Object?>{
      'case': 'transition-awaiting-reverse', 'status': 'ready',
      'reader_mounted': true, 'target_first_frame_current_depth_zero': true,
      'current_bootstrap_before_neighbor_deep_refill': true,
      'target_mount_to_first_frame_micros': targetFrame.payload['mountToFirstFrameMicros'],
    });
    await _until(() => trace.events.any((e) => e.kind == TraceEventKind.readerObservation &&
      e.payload['currentIndex'] == 1), 'forward gesture did not make target current');
    final forward = trace.events.lastWhere((e) =>
      e.kind == TraceEventKind.readerObservation && e.payload['currentIndex'] == 1);
    await _until(() => trace.events.any((e) => e.kind == TraceEventKind.readerObservation &&
      e.monotonicMicros > forward.monotonicMicros && e.payload['currentIndex'] == 0),
      'reverse gesture did not restore original current');
    for (var i = 0; i < ids.length; i++) {
      _require(identical(sessions[i], composition.runtime.findSession(ids[i])) &&
        sessions[i]!.snapshot.epoch == epochs[i], 'reverse drag replaced media identity or epoch');
    }
    final sourcePlanPreserved = origin.requests.every((r) => r['method_POST'] == true &&
      r['nonempty_Cookie_preserved'] == true && r['source_UA_preserved'] == true &&
      r['nonempty_POST_body_preserved'] == true);
    _require(loaders.values.every((loader) => loader.opens == 1) && origin.requests.length == 2 &&
      sourcePlanPreserved &&
      trace.events.every((e) => e.kind != TraceEventKind.taskFailed) && wire.transforms == 0,
      'gesture reopened source, failed or bypassed progressive delivery');
    _captureTrace('transition-zero-current', trace);
    await _unmount();
    await composition.close();
    await _record(<String, Object?>{
      'case': 'transition-zero-current', 'status': 'passed',
      'target_first_frame_current_depth_zero': true,
      'current_bootstrap_before_neighbor_deep_refill': true,
      'reverse_same_physical_sessions_and_epochs': true,
      'actual_HTTP_requests': origin.requests.length,
      'source_plan_POST_Cookie_UA_body_preserved': sourcePlanPreserved,
      'composition_exit': composition.exitProof,
    });
  } finally {
    if (composition.exitProof == null) {
      _captureTrace('transition-failed-case', trace);
      await _unmount();
      await composition.close();
    }
  }
}

Future<void> _partialCase(String directory, _Origin origin,
    ExternalPluginResourceTransportPool pool, BrowsableComicSource source,
    _Wire wire, {bool failures = false}) async {
  final uri = origin.uri(failures ? '/animated/partial-range-current' : '/animated/partial-current');
  final playableLength = _animatedPrefix(origin.bytesFor('animated'), 2);
  final held = origin.hold(uri.path)..progressive = true
    ..prefixLength = playableLength + 64 * 1024;
  final record = _chapter('partial-current', uri);
  final manifest = record.toManifest();
  final id = readerPageDownloadId(manifest, manifest.pages.single);
  final equivalent = DownloadId(
    content: const ContentId(sourceId: 'venera:source_native_webp_pipeline_fixture',
      comicId: 'fixture-predecessor', chapterId: 'predecessor', pageId: 'page-0'),
    sourceRevision: 'fixture-r0', canonicalUri: uri,
  );
  final path = '$directory/partial';
  _Composition? active;
  try {
    final warm = await _Composition.open(path);
    active = warm;
    var equivalentLookups = 0;
    warm.runtime.versionPageAuthority.replaceScope('fixture-confirmed-page',
      <String, VersionPageReuseResolver>{'page': (candidate) {
        if (candidate != id) return const <DownloadId>[];
        equivalentLookups++;
        return <DownloadId>[equivalent];
      }});
    final loader = _ObservedLoader(pool.controlledLoaderFor(source, uri),
      selfBoundedOpen: pool.selfBoundsOpenFor(source, uri));
    final first = Completer<void>();
    _mount(record, warm, loader, () { if (!first.isCompleted) first.complete(); });
    await held.headers.future.timeout(const Duration(seconds: 20));
    _require(equivalentLookups > 0 && warm.store.findSession(id) == null &&
      warm.store.findSession(equivalent) == null,
      'exact/equivalent cache miss materialized a durable-store DownloadSession');
    await first.future.timeout(const Duration(seconds: 30));
    await _until(() => warm.trace.events.any((e) => e.kind == TraceEventKind.animationLoop &&
      e.payload['partialPrefix'] == true), 'unsealed playable prefix did not loop in DecodeSession');
    final session = warm.runtime.findSession(id)!;
    final committedBeforeCancel = session.snapshot.committedLength;
    final native = warm.trace.events.firstWhere((e) => e.kind == TraceEventKind.frameDecoded);
    _require(native.payload['frame'] == 0 && native.payload['sourceSealed'] == false &&
      committedBeforeCancel >= playableLength && loader.opens == 1 && wire.transforms == 0,
      'first presentation did not consume actual unsealed native WebP');
    _captureTrace('partial-first-presentation', warm.trace);
    await _unmount();
    await warm.close();
    active = null;
    await held.peerClosed.future.timeout(const Duration(seconds: 20));
    if (failures) {
      await _partialFailures(path, record, id, committedBeforeCancel,
        origin, pool, source);
      return;
    }
    await _record(<String, Object?>{
      'case': 'partial-first-presentation', 'status': 'passed',
      'exact_and_verified_equivalent_miss_no_store_session': true,
      'unsealed_native_frame_zero_and_DecodeSession_partial_loop': true,
      'committed_before_physical_cancel': committedBeforeCancel,
      'actual_TCP_peer_closed': true, 'composition_exit': warm.exitProof,
    });

    // The next actual request receives less than a complete frame. Its old
    // playable prefix must come from durable hydration, not origin catch-up.
    final coldHeld = _HeldInput()..progressive = true..prefixLength = 4096;
    origin.held[uri.path] = coldHeld;
    final cold = await _Composition.open(path);
    active = cold;
    _require(!identical(cold.cache, warm.cache) && !identical(cold.runtime, warm.runtime) &&
      !identical(cold.media, warm.media) && cold.runtime.registry.sessions.isEmpty &&
      cold.cache.memoryEntryCount == 0, 'cold entry retained previous media or transfer owners');
    final restored = await cold.store.openPartialDownload(id);
    _require(restored != null && restored.length >= committedBeforeCancel &&
      restored.length < origin.bytesFor('animated').length,
      'physical cancellation lost or sealed the previous playable prefix');
    final prefix = restored!;
    final coldLoader = _ObservedLoader(pool.controlledLoaderFor(source, uri),
      selfBoundedOpen: pool.selfBoundsOpenFor(source, uri));
    await _present(record, cold, coldLoader);
    await coldHeld.headers.future.timeout(const Duration(seconds: 20));
    final coldNative = cold.trace.events.firstWhere((e) => e.kind == TraceEventKind.frameDecoded);
    final hydration = cold.trace.events.firstWhere((e) => e.kind == TraceEventKind.artifactSource &&
      e.payload['stage'] == 'physical-local-prepare' && e.payload['action'] == 'local-hydration-ready');
    final started = cold.trace.events.firstWhere((e) => e.kind == TraceEventKind.downloadStarted);
    _require(coldNative.payload['frame'] == 0 && coldNative.payload['sourceSealed'] == false &&
      (coldNative.payload['sourceLength'] as num) <= prefix.length &&
      hydration.monotonicMicros < started.monotonicMicros &&
      (started.payload['committedLength'] as num) >= prefix.length &&
      coldHeld.sent < prefix.length && coldLoader.opens == 1,
      'cold first frame waited for provider bytes or local prefix followed network admission');
    await _until(() => cold.trace.events.any((e) => e.kind == TraceEventKind.animationLoop &&
      e.payload['partialPrefix'] == true), 'cold native prefix did not resume its own loop');
    _captureTrace('partial-cold-reentry', cold.trace);
    await _unmount();
    await cold.close();
    active = null;
    await coldHeld.peerClosed.future.timeout(const Duration(seconds: 20));
    final stored = await _Composition.open(path);
    active = stored;
    final after = await stored.store.openPartialDownload(id);
    _require(after != null && after.length >= prefix.length,
      'second physical cancellation shrank durable partial');
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in after!.open(start: 0)) { bytes.add(chunk); }
    final actual = bytes.takeBytes();
    final expected = origin.bytesFor('animated');
    _require(actual.length == after.length && actual.asMap().entries.every((e) =>
      e.value == expected[e.key]) && origin.requests.length == 2,
      'cold reentry/cancellation changed playable prefix bytes or duplicated provider requests');
    await stored.close();
    active = null;
    await _record(<String, Object?>{
      'case': 'partial-cold-reentry', 'status': 'passed',
      'new_store_cache_transfer_native_owners': true,
      'durable_prefix_bytes': prefix.length, 'after_cancel_prefix_bytes': after.length,
      'local_hydration_before_provider_started': true,
      'native_frame_zero_from_unsealed_durable_prefix': true,
      'DecodeSession_partial_loop_resumed': true,
      'actual_TCP_peer_closed': true, 'two_cancellations_preserve_exact_origin_prefix': true,
      'actual_HTTP_requests': origin.requests.length, 'composition_exit': cold.exitProof,
    });
  } finally {
    if (active != null) {
      _captureTrace('partial-failed-case', active.trace);
      await _unmount();
      await active.close();
    }
  }
}

Future<void> _partialFailures(String path, ImportedChapterRecord record,
    DownloadId id, int prefixLength, _Origin origin,
    ExternalPluginResourceTransportPool pool, BrowsableComicSource source) async {
  final faults = _partialMetadataOnly ? <String>['network-metadata'] :
    <String>['range-EOF', 'range-mismatch', 'full-body-EOF', 'network-metadata'];
  for (final fault in faults) {
    final uri = id.canonicalUri;
    if (fault == 'network-metadata') {
      final proof = await PersistentDownloadArtifactStore.open(path);
      try {
        // Physical retirement checkpoints into the durable owner's path;
        // the departed warm session's temporary spool no longer exists.
        final stored = await proof.index.get(id.key);
        _require(stored?.id == id && stored?.state == CacheState.partial &&
          stored?.bytes == prefixLength, 'network metadata target has no durable prefix proof');
        final file = File('${stored!.path}.meta');
        final meta = Map<String, Object?>.from(jsonDecode(await file.readAsString()) as Map);
        // Corrupt only network acceleration, keeping body/owner/checkpoint proof.
        meta['validators'] = <String>['invalid-network-type'];
        meta['totalLength'] = 'invalid-network-length';
        await file.writeAsString(jsonEncode(meta), flush: true);
      } finally {
        await proof.close();
      }
    }
    final input = _HeldInput()..progressive = true..prefixLength = 4096
      ..fault = fault == 'network-metadata' ? null : fault;
    origin.held[uri.path] = input;
    final composition = await _Composition.open(path);
    DownloadTransferConsumer? completion;
    try {
      final before = await composition.store.openPartialDownload(id);
      _require(before?.length == prefixLength,
        'previous attempt changed the durable playable prefix');
      if (fault == 'network-metadata') {
        _require(before!.totalLength == null && !before.validators.canResume,
          'malformed network metadata was retained as resume knowledge');
      }
      final loader = _ObservedLoader(pool.controlledLoaderFor(source, uri),
        selfBoundedOpen: pool.selfBoundsOpenFor(source, uri));
      if (fault != 'network-metadata') {
        final transport = LoaderTransport(<Uri, LoaderTransportSource>{
          uri: LoaderTransportSource(openControlledResponse: loader.open,
            selfBoundedOpen: loader.selfBoundedOpen, revision: id.sourceRevision),
        });
        completion = composition.runtime.attachConsumer(
          scopeId: 'fixture-required-$fault', transportFor: (_) => transport,
          consumerTraceSink: composition.trace, retry: const RetryPolicy(maxAttempts: 1));
        completion.replaceDemands('fixture-$fault', 1, <DownloadId, TransferDemand>{
          id: const TransferDemand(priority: 1000, reason: 'explicit-completion',
            completionIntent: TransferCompletionIntent.required),
        });
      }
      await _present(record, composition, loader);
      await input.headers.future.timeout(const Duration(seconds: 20));
      await _until(() => composition.trace.events.any((e) =>
        e.kind == TraceEventKind.animationLoop && e.payload['partialPrefix'] == true),
        'old native prefix did not loop before the fault');
      final physical = composition.runtime.findSession(id)!;
      final epoch = physical.snapshot.epoch;
      final presentedBeforeFault = composition.trace.events.where((e) =>
        e.kind == TraceEventKind.framePresented).length;
      if (fault != 'network-metadata') {
        await origin.finishFault(uri.path);
        await _until(() => physical.snapshot.state == DownloadState.failed &&
          composition.lane.isIdle, 'fault did not retire its actual network attempt');
        _require(physical.snapshot.failure != null &&
          (fault != 'range-mismatch' || physical.snapshot.failure!.code == ErrorCode.resumeRejected),
          'overlap mismatch did not keep its typed rejection');
        await _until(() => composition.trace.events.where((e) =>
          e.kind == TraceEventKind.framePresented).length > presentedBeforeFault,
          'network failure stopped playback of the retained native prefix');
      }
      _require(physical.snapshot.epoch == epoch && physical.committedLength == prefixLength &&
        physical.snapshot.state != DownloadState.sealed &&
        physical.snapshot.state != DownloadState.promoted && loader.opens == 1 &&
        composition.trace.events.every((e) => e.kind != TraceEventKind.sourceDisabled &&
          !(e.kind == TraceEventKind.resumeRestarted &&
            e.payload['strategy'] == 'confirmed-full-body-mismatch-clean-restart')),
        'ordinary fault reset or disabled authoritative partial/Ingress');
      _captureTrace('partial-$fault', composition.trace);
      await _unmount();
      await completion?.dispose();
      completion = null;
      await composition.close();
      await input.peerClosed.future.timeout(const Duration(seconds: 20));
      final proof = await PersistentDownloadArtifactStore.open(path);
      try {
        final after = await proof.openPartialDownload(id);
        _require(after?.length == prefixLength, 'fault shrank the stored prefix');
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in after!.open(start: 0)) { bytes.add(chunk); }
        final actual = bytes.takeBytes();
        final expected = origin.bytesFor('animated');
        _require(actual.length == prefixLength && actual.asMap().entries.every((e) =>
          e.value == expected[e.key]), 'fault corrupted authoritative prefix bytes');
      } finally {
        await proof.close();
      }
      await _record(<String, Object?>{
        'case': 'partial-$fault', 'status': 'passed',
        'actual_HTTP_requests': 1, 'old_native_prefix_played_and_looped': true,
        'physical_epoch_preserved': true, 'prefix_bytes': prefixLength,
        'exact_durable_prefix_preserved': true, 'source_disabled': false,
        'network_failure_only': fault != 'network-metadata',
        'malformed_network_knowledge_discarded': fault == 'network-metadata',
        'actual_TCP_peer_closed': true, 'composition_exit': composition.exitProof,
      });
    } finally {
      if (composition.exitProof == null) {
        _captureTrace('partial-$fault-failed', composition.trace);
        await _unmount();
        await completion?.dispose();
        await composition.close();
      }
    }
  }
}

int _animatedPrefix(Uint8List bytes, int frames, {bool extendDuration = false}) {
  var offset = 12;
  var found = 0;
  var prefix = 0;
  while (offset + 8 <= bytes.length) {
    final size = ByteData.sublistView(bytes, offset + 4, offset + 8).getUint32(0, Endian.little);
    final end = offset + 8 + size + (size & 1);
    _require(end <= bytes.length, 'invalid sealed fixture RIFF chunk');
    if (String.fromCharCodes(bytes.sublist(offset, offset + 4)) == 'ANMF') {
      found++;
      if (extendDuration) {
        // Test-only600ms frames make a two-frame unsealed prefix playable.
        bytes[offset + 20] = 600 & 255;
        bytes[offset + 21] = 600 >> 8;
        bytes[offset + 22] = 0;
      }
      if (found == frames) prefix = end;
    }
    offset = end;
  }
  _require(prefix > 0 && found == 4, 'fixture is not the expected four-frame WebP');
  return prefix;
}

Future<void> _present(ImportedChapterRecord record, _Composition composition,
    _ObservedLoader loader) async {
  final first = Completer<void>();
  _mount(record, composition, loader, () {
    if (!first.isCompleted) first.complete();
  });
  await first.future.timeout(const Duration(seconds: 30));
  await _frames(2);
  _require(composition.trace.events.any((e) => e.kind == TraceEventKind.firstFrameReady) &&
    composition.trace.events.every((e) => e.kind != TraceEventKind.taskFailed),
    'production Reader first-frame trace missing or failed');
}

Future<void> _frames(int count) async {
  for (var i = 0; i < count; i++) {
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
  }
}

void _status(String text) => runApp(MaterialApp(key: UniqueKey(),
  home: Scaffold(body: Center(child: Text(text)))));

Future<void> _unmount() async {
  _status('正文缓存与呈现验收');
  await _frames(2);
}

Map<String, Object?> _lane(_Composition c) => <String, Object?>{
  'running': c.lane.running, 'active': c.lane.active,
  'queued': c.lane.queued, 'transport_leases': c.lane.transportLeases,
  'idle': c.lane.isIdle,
};

Map<String, int> _captureTrace(String label, MemoryTraceSink trace) {
  final counts = <String, int>{};
  for (final event in trace.events) {
    counts.update(event.kind.name, (n) => n + 1, ifAbsent: () => 1);
    _traces.add(<String, Object?>{'case': label, ...event.toJson()});
  }
  return counts;
}

Future<Map<String, Object?>> _artifactProof(CacheRec record, _Wire wire,
    String kind, Uint8List expected) async {
  _require(record.state == CacheState.ready && record.bytes > 512 * 1024 &&
    record.checksumAlgorithm == 'crc32' && !record.pinned,
    'automatic source output did not acquire complete durable proof');
  final file = File(record.path);
  final bytes = await file.readAsBytes();
  final crc = Crc32()..add(bytes);
  final digest = await Process.run('/system/bin/sha256sum', <String>[file.path]);
  _require(digest.exitCode == 0 && bytes.length == record.bytes &&
    crc.hex == record.checksum && wire.reference != null &&
    (digest.stdout as String).split(' ').first == wire.reference!['sha256'],
    'persisted artifact differs from the claimed source output proof');
  _require(bytes.length == expected.length, 'source body changed WebP size');
  for (var i = 0; i < bytes.length; i++) {
    _require(bytes[i] == expected[i], 'source onResponse changed encoded WebP bytes');
  }
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    try {
      _require(frame.image.width == 640 && frame.image.height == 640 &&
        codec.frameCount == (kind == 'static' ? 1 : 4),
        'persistent transformed artifact does not decode');
    } finally { frame.image.dispose(); }
  } finally { codec.dispose(); }
  return <String, Object?>{
    'bytes': record.bytes, 'checksum': crc.hex, 'checksum_algorithm': 'crc32',
    'source_SHA256_matches': true, 'exact_origin_WebP_bytes_match': true,
    'exact_DownloadId_preserved': true,
    'source_body_lease_not_persisted': record.path != wire.lease,
  };
}

bool _sameArtifact(CacheRec a, CacheRec b) => a.id == b.id && a.path == b.path &&
  a.bytes == b.bytes && a.checksum == b.checksum &&
  a.checksumAlgorithm == b.checksumAlgorithm && a.artifactId == b.artifactId &&
  a.storageRootId == b.storageRootId && a.createdUs == b.createdUs && a.pinned == b.pinned;

Future<void> _record(Map<String, Object?> event) async {
  _events.add(<String, Object?>{'micros': _clock.elapsedMicroseconds, ...event});
  debugPrint('ZIC_SOURCE_NATIVE_WEBP_PIPELINE_EVENT ${jsonEncode(_events.last)}');
  await File('$_output.trace.jsonl').writeAsString(
    '${_traces.map(jsonEncode).join('\n')}\n', flush: true);
  await File(_output).writeAsString(jsonEncode(_events), flush: true);
}

void _require(bool condition, String reason) {
  if (!condition) throw StateError(reason);
}

final class _ObservedLoader {
  _ObservedLoader(this.delegate, {required this.selfBoundedOpen});
  final ControlledTransportResponseLoader delegate;
  final bool selfBoundedOpen;
  int opens = 0;
  int cancelled = 0;
  final deliveries = <String>[];

  Future<ByteResponse> open({TaskControl? control, ByteRange? range,
      Validators? validators}) async {
    opens++;
    try {
      final result = await delegate(control: control, range: range, validators: validators);
      deliveries.add(result.diagnostics['sourceRuntimeBodyDelivery'] as String? ??
        result.diagnostics['sourceOpenPath'] as String);
      return result;
    } on Object catch (error) {
      if (error is Failure && error.code == ErrorCode.cancelled) cancelled++;
      rethrow;
    }
  }
}

final class _Composition {
  _Composition(this.store) {
    cache = ArtifactCacheManager(backend: store);
    runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: cache, partialDownloadStore: store,
      net: coordinator.networkLane, localReadScheduler: coordinator.localReadScheduler,
      speculativeEncodedReadBudget: coordinator.speculativeEncodedReadBudget,
    );
    presentation = PipelineStaticPresentation(raster);
    factory = PipelineReaderSessionFactory(
      mediaRuntimeFactory: media, pageDownloadLane: coordinator.networkLane,
      externalPresentationPrewarmer: presentation.prewarm,
      presentationCacheAuthority: presentation.cacheAuthority,
    ).withTransferRuntime(runtime);
  }
  final PersistentDownloadArtifactStore store;
  final coordinator = DownloadResourceCoordinator();
  final media = NativePipelineMediaRuntimeFactory();
  final raster = PipelinePresentationRasterCache();
  final trace = MemoryTraceSink();
  late final ArtifactCacheManager cache;
  late final CompositionDownloadTransferRuntime runtime;
  late final PipelineStaticPresentation presentation;
  late final PipelineReaderSessionFactory factory;
  Map<String, Object?>? exitProof;
  late final lane = coordinator.networkLane;

  static Future<_Composition> open(String directory) async {
    final store = await PersistentDownloadArtifactStore.open(directory);
    return _Composition(store);
  }

  Future<CacheRec> ready(DownloadId id) async {
    final deadline = Stopwatch()..start();
    while (deadline.elapsed < const Duration(seconds: 20)) {
      final record = await store.index.get(id.key);
      if (record?.state == CacheState.ready) return record!;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw StateError('persistent READY promotion did not finish');
  }

  Future<void> close() async {
    if (exitProof != null) return;
    await factory.disposeRetainedSessions().timeout(const Duration(seconds: 20));
    _require(!runtime.hasConsumers, 'Reader consumer remained after retention drain');
    await runtime.dispose().timeout(const Duration(seconds: 20));
    await factory.disposeTransferRuntimes();
    _require(runtime.disposed && runtime.registry.sessions.isEmpty && lane.isIdle,
      'physical transfer teardown left a session or lane task');
    raster.clearPresentationRasters();
    cache.clearMemory();
    await media.shutdownComposition();
    await store.close();
    exitProof = <String, Object?>{
      'transfer_disposed': runtime.disposed, 'consumer_count': 0,
      'physical_sessions': runtime.registry.sessions.length,
      'lane': _lane(this), 'native_composition_shutdown_joined': true,
      'persistent_store_closed': true, 'raster_and_memory_cache_cleared': true,
    };
  }
}

Future<Map<String, Uint8List>> _inputs(String support) async {
  final result = <String, Uint8List>{};
  for (final kind in <String>['static', 'animated']) {
    final bytes = await File('$support/zic-source-native-webp-inputs/$kind.webp').readAsBytes();
    _require(bytes.length > 512 * 1024 && bytes.length < 8 * 1024 * 1024,
      'staged WebP input size violates the fixed test bounds');
    result[kind] = bytes;
    if ((_partialOnly || _partialFailuresOnly || _partialMetadataOnly) && kind == 'animated') {
      _animatedPrefix(bytes, 2, extendDuration: true);
    }
  }
  return result;
}

Future<Map<String, Object?>> _nativeProof(String kind, MemoryTraceSink trace) async {
  // Observe original playback. No forced frames, output/retry/clock changes.
  await Future<void>.delayed(const Duration(seconds: 3));
  final decoded = trace.events.where((e) => e.kind == TraceEventKind.frameDecoded).toList();
  final presented = trace.events.where((e) => e.kind == TraceEventKind.framePresented).toList();
  final timings = trace.events.where((e) => e.kind == TraceEventKind.framePipelineTiming).toList();
  _require(decoded.isNotEmpty && presented.isNotEmpty && timings.isNotEmpty &&
    timings.every((e) => e.payload['renderer'] == 'androidTexture'),
    'WebP bypassed actual native decode/Android texture presentation');
  if (kind == 'animated') {
    _require(presented.length >= 8 && presented.any((e) =>
      e.payload['frame'] is num && (e.payload['frame'] as num) > 0),
      'animated WebP did not advance actual presented frames');
  }
  final prefixWaits = trace.events.where((e) =>
    e.kind == TraceEventKind.retryScheduled).toList();
  _require(trace.events.every((e) => e.kind != TraceEventKind.taskFailed) &&
    prefixWaits.every((e) => e.payload['stage'] == 'decode-prefix' &&
      e.payload['sealed'] == false && e.payload['sourceLength'] is int &&
      e.payload['nextSourceLength'] is int &&
      (e.payload['sourceLength'] as int) > 0 &&
      (e.payload['nextSourceLength'] as int) > (e.payload['sourceLength'] as int)),
    'native WebP failed or retried outside bounded prefix growth');
  return <String, Object?>{
    'native_frame_decoded': decoded.length, 'frame_presented': presented.length,
    'frame_pipeline_timing': timings.length, 'renderer': 'androidTexture',
    'animated_frames_advanced': kind == 'animated', 'observed_playback_seconds': 3,
    'decode_prefix_growth_waits': prefixWaits.length, 'provider_retries': 0,
    'final_physical_display_performance_proven': false,
  };
}

final class _HeldInput {
  final headers = Completer<void>();
  final peerClosed = Completer<void>();
  Socket? socket;
  int? peerClosedAt;
  bool progressive = false;
  int sent = 0;
  Timer? keepAlive;
  int? prefixLength;
  String? fault;
  Uint8List? faultBody;
}

final class _Origin {
  _Origin(this.server, this.bytes);
  final HttpServer server;
  final Map<String, Uint8List> bytes;
  final requests = <Map<String, Object?>>[];
  final held = <String, _HeldInput>{};

  static Future<_Origin> start(Map<String, Uint8List> bytes) async {
    final origin = _Origin(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), bytes);
    origin.server.listen((request) { unawaited(origin.serve(request)); });
    return origin;
  }

  Uri uri(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');
  Uint8List bytesFor(String kind) => bytes[kind]!;
  _HeldInput hold(String path) => held.putIfAbsent(path, _HeldInput.new);

  Future<void> serve(HttpRequest request) async {
    final input = held[request.uri.path];
    final output = bytesFor(request.uri.path.split('/')[1]);
    try {
      final body = await utf8.decoder.bind(request).join();
      requests.add(<String, Object?>{
        'path': request.uri.path,
        'range': request.headers.value('range'),
        'method_POST': request.method == 'POST',
        'nonempty_Cookie_preserved': request.headers.value('cookie') == 'acceptance=present',
        'source_UA_preserved': request.headers.value('user-agent') == _sourceUa,
        'nonempty_POST_body_preserved': body == _post,
      });
      if (input != null) {
        final socket = await request.response.detachSocket(writeHeaders: false);
        input.socket = socket;
        void closed() {
          if (!input.peerClosed.isCompleted) {
            input.peerClosedAt = _clock.elapsedMicroseconds;
            input.peerClosed.complete();
          }
        }
        socket.listen((_) {}, onDone: closed, onError: (Object _) => closed());
        var responseBody = output;
        var status = '200 OK';
        var contentRange = '';
        if (input.fault?.startsWith('range-') == true) {
          final range = request.headers.value('range');
          final match = RegExp(r'^bytes=(\d+)-').firstMatch(range ?? '');
          _require(match != null, 'entityless GET source did not send its overlap Range');
          final start = int.parse(match!.group(1)!);
          _require(start > 0 && start + 64 * 1024 <= output.length,
            'source did not preserve the actual overlap Range');
          responseBody = Uint8List.fromList(output.sublist(start, start + 64 * 1024));
          if (input.fault == 'range-mismatch') responseBody[responseBody.length - 1] ^= 255;
          status = '206 Partial Content';
          contentRange = 'Content-Range: bytes $start-${start + responseBody.length - 1}/${output.length}\r\n';
        }
        input.faultBody = responseBody;
        socket.add(ascii.encode('HTTP/1.1 $status\r\nContent-Type: image/webp\r\n'
          '${contentRange}Content-Length: ${responseBody.length}\r\nConnection: close\r\n\r\n'));
        input.sent = input.prefixLength ?? (input.progressive ? 16 * 1024 : 4096);
        socket.add(responseBody.sublist(0, input.sent));
        await socket.flush();
        input.headers.complete();
        if (input.progressive) {
          final maximum = input.sent + 48 * 1024;
          input.keepAlive = Timer.periodic(const Duration(seconds: 1), (_) {
            // Server output pacing keeps actual TCP alive, below a complete frame.
            if (input.sent >= maximum || input.peerClosed.isCompleted) {
              input.keepAlive?.cancel();
              return;
            }
            socket.add(responseBody.sublist(input.sent, input.sent + 1024));
            input.sent += 1024;
          });
        }
      } else {
        request.response.headers.contentType = ContentType('image', 'webp');
        request.response.contentLength = output.length;
        request.response.add(output);
        await request.response.close();
      }
    } on Object catch (error, stack) {
      if (input != null && !input.headers.isCompleted) input.headers.completeError(error, stack);
      rethrow;
    }
  }

  Future<void> release(String path) async {
    final input = held[path]!;
    input.keepAlive?.cancel();
    final socket = input.socket!;
    socket.add(bytesFor(path.split('/')[1]).sublist(input.sent));
    await socket.flush();
    await socket.close();
  }

  Future<void> finishFault(String path) async {
    final input = held[path]!;
    input.keepAlive?.cancel();
    final socket = input.socket!;
    if (input.fault == 'range-mismatch') {
      socket.add(input.faultBody!.sublist(input.sent));
      await socket.flush();
    }
    // EOF closes the real TCP body early; no production Future is replaced.
    await socket.close();
  }

  Future<void> close() async {
    for (final input in held.values) {
      input.keepAlive?.cancel();
      input.socket?.destroy();
    }
    await server.close(force: true);
  }
}

final class _Wire implements BinaryMessenger {
  _Wire(this.delegate);
  final BinaryMessenger delegate;
  static const codec = StandardMethodCodec();
  int claims = 0;
  int releases = 0;
  int transforms = 0;
  String? lease;
  Map<Object?, Object?>? reference;
  Object? sourceGeneration;

  void beginCase() {
    claims = releases = transforms = 0;
    lease = null;
    reference = null;
  }

  void requireReleased() {
    _require(claims == 1 && releases == 1 && lease != null &&
      !File(lease!).existsSync(), 'source pipeline did not release one claimed body');
  }

  @override
  Future<ByteData?> send(String channel, ByteData? message) async {
    MethodCall? call;
    if (channel == 'dev.zic/plugin_host_runtime_bridge' && message != null) {
      call = codec.decodeMethodCall(message);
      if (call.method == 'invokeExternalRuntime') {
        final args = call.arguments as Map;
        final request = args['request'] as Map;
        if (request['operation'] == 'transformResource') transforms++;
      }
    }
    final reply = await delegate.send(channel, message);
    if (call != null && reply != null) {
      if (call.method == 'claimExternalRuntimeResourceBody') {
        lease = codec.decodeEnvelope(reply) as String;
        reference = Map<Object?, Object?>.from((call.arguments as Map)['reference'] as Map);
        claims++;
      } else if (call.method == 'releaseExternalRuntimeResourceBody') {
        codec.decodeEnvelope(reply);
        releases++;
      } else if (call.method == 'activateVeneraRuntime') {
        sourceGeneration = (codec.decodeEnvelope(reply) as Map)['processId'];
      }
    }
    return reply;
  }

  @override
  Future<void> handlePlatformMessage(String channel, ByteData? data,
    PlatformMessageResponseCallback? callback) =>
      // ignore: deprecated_member_use
      delegate.handlePlatformMessage(channel, data, callback);

  @override
  void setMessageHandler(String channel, MessageHandler? handler) =>
      delegate.setMessageHandler(channel, handler);
}
