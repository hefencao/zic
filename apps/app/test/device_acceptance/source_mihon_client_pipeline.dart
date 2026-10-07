import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
// Test-only inspection of durable authority; no new application dependency.
// ignore: depend_on_referenced_packages
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';
import 'package:zic/main.dart' as app_entrypoint;
import 'package:zic/startup_platform.dart';

// Test-only installed WNACG client -> Service/Binder/file -> original
// DownloadSession and native Reader. Only its APK is copied; no user store opens.
// The server holds its own TCP output; no production read Future is delayed.
const _package = 'eu.kanade.tachiyomi.extension.zh.wnacg';
const _sourceId = 'mihon:6551136894818591762';
const _sourceUa = 'SourceMihonClientFixture/1';
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
  _output = '$support/zic-source-mihon-client-pipeline-results.json';
  final root = await Directory.systemTemp.createTemp('zic-source-mihon-client-pipeline-');
  final wire = _Wire(ServicesBinding.instance.defaultBinaryMessenger);
  _Origin? origin;
  ExternalPluginRuntimeSession? session;
  ExternalPluginResourceTransportPool? pool;
  _Composition? current;
  try {
    origin = await _Origin.start(await _inputs(support!));
    final payload = File('$support/zic-source-mihon-client-inputs/original-wnacg.apk');
    const metadata = AndroidMihonApkMetadataReader();
    await metadata.copyInstalled(packageName: _package, destinationPath: payload.path);
    final plugin = ExternalComicPluginCatalogEntry(
      format: ExternalComicPluginFormat.mihonExtension,
      pluginId: 'mihon:source-client-pipeline-fixture', name: 'Fixture',
      version: 'device-immutable', entrypoint: Uri.parse('https://fixture.invalid/wnacg.apk'),
      sources: const <ExternalComicPluginSource>[
        ExternalComicPluginSource(sourceId: _sourceId, externalId: '6551136894818591762',
          name: 'Fixture', language: 'zh'),
      ],
    );
    final inspection = await MihonApkInspector(
      metadata: metadata, payloads: CallbackExternalPluginPayloadLoader((_) async =>
        ExternalPluginPayloadFile(path: payload.path, byteLength: await payload.length())),
    ).inspect(plugin);
    _require(inspection.packageName == _package && inspection.extensionLib == '1.6',
      'Expected installed immutable WNACG1.6 source payload');
    const limits = ExternalPluginRuntimeLimits(
      invocationTimeout: Duration(seconds: 60), maxConcurrentInvocations: 2,
      maxResponseBytes: 32 * 1024 * 1024,
    );
    final connection = await AndroidMihonIsolatedRuntimeBackend(channel: MethodChannel(
      'dev.zic/plugin_host_runtime_bridge', const StandardMethodCodec(), wire,
    )).activate(MihonExecutionRequest(
      plugin: plugin, payloadPath: payload.path, payloadByteLength: await payload.length(),
      payloadSha256: inspection.payloadSha256, packageName: inspection.packageName!,
      signerSha256: inspection.signerSha256!, versionCode: inspection.versionCode!,
      extensionLib: inspection.extensionLib!, entryClasses: inspection.mihonEntryClasses,
      capabilities: const <ExternalPluginCapability>{
        ExternalPluginCapability.network, ExternalPluginCapability.cookies,
      }, limits: limits,
    ));
    session = ExternalPluginRuntimeSession(plugin: plugin, connection: connection, limits: limits);
    final process = await Process.run('/system/bin/pidof',
      <String>['dev.zic.zic:zic_plugin_runtime']);
    final sourcePid = int.parse((process.stdout as String).trim());
    _require(sourcePid != pid, 'source runtime is not a separate actual process');
    final source = session.sources.singleWhere((s) => s.sourceId == _sourceId);
    pool = ExternalPluginResourceTransportPool(
      directTransport: RhttpSourceResourceDirectTransport(),
      defaultUserAgentProvider: () => 'FallbackPipelineFixture/1',
    );
    for (final plane in <String>['static', 'animated']) {
      final record = _chapter(plane, _request(origin.uri('/$plane/start')));
      final requestsBeforeFirst = origin.requests.length;
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
      _require(loader.opens == 1 && wire.loads == 1 && wire.transforms == 0 &&
        origin.requests.length - requestsBeforeFirst >= 2 &&
        origin.requests.where((r) => r['path'] == '/$plane/full').length == 1,
        'first download did not use the original Mihon client after redirect');
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
        'source_transform_operations': wire.transforms, 'runtime_load_operations': wire.loads,
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
        origin.requests.length == requestsBeforeCold && wire.claims == 0 && wire.transforms == 0 && wire.loads == 0,
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
      final cancelUri = origin.uri('/$plane/cancel-start');
      final cancelledRecord = _chapter('$plane-cancel', _request(cancelUri));
      final cancelManifest = cancelledRecord.toManifest();
      final cancelId = readerPageDownloadId(cancelManifest, cancelManifest.pages.single);
      final cancelLoader = _ObservedLoader(pool.controlledLoaderFor(source, cancelId.canonicalUri),
        selfBoundedOpen: pool.selfBoundsOpenFor(source, cancelId.canonicalUri));
      final held = origin.hold('/$plane/cancel-input');
      current = await _Composition.open('${root.path}/$plane-cancel');
      var unexpectedFrame = false;
      _mount(cancelledRecord, current, cancelLoader, () => unexpectedFrame = true);
      await held.headers.future.timeout(const Duration(seconds: 20));
      _require(!unexpectedFrame && cancelLoader.opens == 1 && wire.loads == 1 && !current.lane.isIdle,
        'held actual HTTP input is not inside a live physical transfer');
      final laneBeforeCancel = _lane(current);
      final cancelAt = _clock.elapsedMicroseconds;
      await _unmount();
      await current.factory.disposeRetainedSessions().timeout(const Duration(seconds: 20));
      _require(!current.runtime.hasConsumers, 'route teardown left a Reader transfer consumer');
      await current.runtime.dispose().timeout(const Duration(seconds: 20));
      await held.peerClosed.future.timeout(const Duration(seconds: 20));
      _require(cancelLoader.cancelled == 1 && wire.claims == 0 && wire.transforms == 0 &&
        current.lane.isIdle && wire.loads == 1 && !unexpectedFrame,
        'route cancellation lost typed failure, physical exit or published a body/frame');
      final cancelledIndex = await current.store.index.get(cancelId.key);
      _require(cancelledIndex == null || cancelledIndex.state != CacheState.ready,
        'unfinished source input polluted durable READY');
      final cancelledTrace = _captureTrace('$plane-route-cancellation', current.trace);
      await current.close();
      await Future<void>.delayed(const Duration(seconds: 2));
      _require(cancelLoader.opens == 1 && !unexpectedFrame && origin.requests.where((r) => r['path'] == '/$plane/cancel-input').length == 1 && wire.loads == 1,
        'cancelled source input reopened or presented late');
      final exit = current.exitProof;
      current = null;
      await _record(<String, Object?>{
        'case': '$plane-route-cancellation', 'status': 'passed',
        'headers_and_partial_input_sent': true, 'actual_TCP_peer_closed': true,
        'typed_cancellation': true, 'no_READY_or_first_frame': true,
        'claims': wire.claims, 'source_transform_operations': wire.transforms, 'runtime_load_operations': wire.loads,
        'cancel_to_peer_close_micros': held.peerClosedAt! - cancelAt,
        'lane_before_cancel': laneBeforeCancel, 'composition_exit': exit,
        'trace_summary': cancelledTrace,
      });
    }
    _require(origin.requests.length >= 8 && origin.requests.every((r) =>
      r['method_GET'] == true && r['nonempty_Cookie_preserved'] == true &&
      r['source_UA_preserved'] == true && r['empty_GET_body_preserved'] == true),
      'source HTTP plan method/Cookie/UA/body was changed');
    final actualHttpRequests = List<Map<String, Object?>>.of(origin.requests);
    await session.close();
    session = null;
    pool.close();
    pool = null;
    await origin.close();
    origin = null;
    await Directory('$support/zic-source-mihon-client-inputs').delete(recursive: true);
    await root.delete(recursive: true);
    await _record(<String, Object?>{
      'case': 'complete', 'status': 'passed', 'cases': 6,
      'production_modified': false, 'host_pid': pid, 'source_pid': sourcePid,
      'source_process_generation_at_activation': wire.sourceGeneration,
      'actual_HTTP_requests': actualHttpRequests.length, 'HTTP_request_proof': actualHttpRequests,
      'source_payload_sha256': inspection.payloadSha256,
      'original_package': inspection.packageName, 'extension_lib': inspection.extensionLib, 'all_test_compositions_and_source_session_closed': true,
      'test_root_removed': !root.existsSync(),
      'selected_static_and_animated_native_WebP_pipeline_proven': true,
      'real_origin_or_final_display_performance_proven': false,
      'test_inputs_removed': !Directory('$support/zic-source-mihon-client-inputs').existsSync(),
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
    final inputs = Directory('$support/zic-source-mihon-client-inputs');
    if (inputs.existsSync()) await inputs.delete(recursive: true);
  }
}

Uri _request(Uri uri) => Uri.parse('mihon:resource:${base64Url.encode(utf8.encode(
  jsonEncode(<String, Object?>{'kind': 'resource', 'url': uri.toString(),
    'method': 'GET', 'headers': <String, String>{
      'Cookie': 'acceptance=present', 'User-Agent': _sourceUa,
    }}),
)).replaceAll('=', '')}');

ImportedChapterRecord _chapter(String label, Uri uri) => ImportedChapterRecord(
  directoryId: 'fixture:$label', displayName: 'Fixture $label',
  sourceId: _sourceId, comicId: 'fixture-comic',
  chapterId: label, sourceRevision: 'fixture-r1',
  pages: <ImportedPageRecord>[
    ImportedPageRecord(displayName: 'page.webp', sourceId: uri.toString(),
      pageId: 'page-0', mediaFormat: 'webp', contentKindHint: ContentKindHint.webp),
  ],
);

void _mount(ImportedChapterRecord record, _Composition composition,
    _ObservedLoader loader, VoidCallback onFirstFrame) {
  runApp(MaterialApp(key: UniqueKey(), home: ImportedImageChapterScreen(
    record: record, pipelineFactory: composition.factory,
    staticPresentation: composition.presentation, traceSink: composition.trace,
    responseSources: <String, LocalImageResponseSource>{
      record.pages.single.sourceId: LocalImageResponseSource(
        openControlledResponse: loader.open,
        selfBoundedOpen: loader.selfBoundedOpen,
      ),
    },
    onFirstPresentationFrame: onFirstFrame,
  )));
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
    _require(bytes[i] == expected[i], 'Mihon source client changed controlled encoded WebP bytes');
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
  debugPrint('ZIC_SOURCE_MIHON_CLIENT_PIPELINE_EVENT ${jsonEncode(_events.last)}');
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
      deliveries.add(result.diagnostics['sourceRuntimeBodyDelivery'] as String);
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
    final bytes = await File('$support/zic-source-mihon-client-inputs/$kind.webp').readAsBytes();
    _require(bytes.length > 512 * 1024 && bytes.length < 8 * 1024 * 1024,
      'staged WebP input size violates the fixed test bounds');
    result[kind] = bytes;
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
        'method_GET': request.method == 'GET',
        'nonempty_Cookie_preserved': request.headers.value('cookie') == 'acceptance=present',
        'source_UA_preserved': request.headers.value('user-agent') == _sourceUa,
        'empty_GET_body_preserved': body.isEmpty,
      });
      if (request.uri.path.endsWith('/start') || request.uri.path.endsWith('/cancel-start')) {
        final kind = request.uri.path.split('/')[1];
        final target = request.uri.path.endsWith('/cancel-start') ? 'cancel-input' : 'full';
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, uri('/$kind/$target').toString());
        await request.response.close();
        return;
      }
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
        socket.add(ascii.encode('HTTP/1.1 200 OK\r\nContent-Type: image/webp\r\n'
          'Content-Length: ${output.length}\r\nConnection: close\r\n\r\n'));
        socket.add(output.sublist(0, 4096));
        await socket.flush();
        input.headers.complete();
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

  Future<void> close() async {
    for (final input in held.values) { input.socket?.destroy(); }
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
  int loads = 0;
  String? lease;
  Map<Object?, Object?>? reference;
  Object? sourceGeneration;

  void beginCase() {
    claims = releases = transforms = loads = 0;
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
        if (request['operation'] == 'loadResource') loads++;
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
      } else if (call.method == 'activateMihonRuntime') {
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
