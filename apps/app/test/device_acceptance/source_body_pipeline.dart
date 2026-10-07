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

// Test-only loopback HTTP -> production source/Binder/file -> DownloadSession,
// persistent artifact and actual Reader presentation. No user store is opened.
// The server holds its own TCP output; no production read Future is delayed.
const _key = 'source_body_pipeline_fixture';
const _rotate = 'function modifyImage(image){return image.copyAndRotate90()}';
const _post = 'body-pipeline-fixture-post';
const _sourceUa = 'SourcePipelineFixture/1';
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
  _output = '$support/zic-source-body-pipeline-results.json';
  final root = await Directory.systemTemp.createTemp('zic-source-body-pipeline-');
  final wire = _Wire(ServicesBinding.instance.defaultBinaryMessenger);
  _Origin? origin;
  ExternalPluginRuntimeSession? session;
  ExternalPluginResourceTransportPool? pool;
  _Composition? current;
  try {
    origin = await _Origin.start(await _image());
    final payload = await File('${root.path}/fixture.js').writeAsString(
      "class SourceBodyPipelineFixture extends ComicSource {name='Fixture';"
      "key='$_key';version='1';url='https://fixture.invalid';"
      "explore=[{title:'Fixture',type:'multiPageComicList',load:async(page)=>[]}];"
      "comic={onThumbnailLoad:(uri)=>({method:'POST',"
      "headers:{Cookie:'acceptance=present','User-Agent':'$_sourceUa'},"
      "data:'$_post',modifyImage:'$_rotate',"
      "...(uri.indexOf('/canonical/')>=0?{onResponse:async(input)=>input}:{})})};}",
    );
    final plugin = ExternalComicPluginCatalogEntry(
      format: ExternalComicPluginFormat.veneraJavaScript,
      pluginId: 'venera:source-body-pipeline-fixture', name: 'Fixture', version: '1',
      entrypoint: Uri.parse('https://fixture.invalid/fixture.js'),
      sources: const <ExternalComicPluginSource>[
        ExternalComicPluginSource(sourceId: 'venera:source_body_pipeline_fixture',
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
    for (final plane in <String>['canonical', 'isolated']) {
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
      final proof = await _artifactProof(ready, wire);
      _require(loader.opens == 1 && origin.requests.length ==
        (plane == 'canonical' ? 1 : 3), 'first download did not use one origin request');
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
        'origin_requests': loader.opens, 'source_input_bytes': origin.bytes.length,
        'claims': wire.claims, 'releases': wire.releases,
        'source_transform_operations': wire.transforms,
        'body_delivery': loader.deliveries.single, 'artifact': proof,
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
      final coldTrace = _captureTrace('$plane-cold-READY', current.trace);
      await _record(<String, Object?>{
        'case': '$plane-cold-READY', 'status': 'passed',
        'reader_mounted': true, 'first_frame_callback': true,
        'origin_requests': coldLoader.opens, 'READY_identity_preserved': true,
        'new_store_cache_transfer_and_raster_owners': true,
        'previous_composition_exit': warmExit, 'trace_summary': coldTrace,
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
    await root.delete(recursive: true);
    await _record(<String, Object?>{
      'case': 'complete', 'status': 'passed', 'cases': 6,
      'production_modified': false, 'host_pid': pid, 'source_pid': sourcePid,
      'source_process_generation_at_activation': wire.sourceGeneration,
      'actual_HTTP_requests': 4, 'all_test_compositions_and_source_session_closed': true,
      'test_root_removed': !root.existsSync(),
      'actual_PNG_external_static_pipeline_proven': true,
      'native_WebP_or_real_origin_or_final_display_proven': false,
    });
    _status('缓存与呈现验收通过');
  } on Object catch (error, stack) {
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
  }
}

ImportedChapterRecord _chapter(String label, Uri uri) => ImportedChapterRecord(
  directoryId: 'fixture:$label', displayName: 'Fixture $label',
  sourceId: 'venera:source_body_pipeline_fixture', comicId: 'fixture-comic',
  chapterId: label, sourceRevision: 'fixture-r1',
  pages: <ImportedPageRecord>[
    ImportedPageRecord(displayName: 'page.png', sourceId: uri.toString(),
      pageId: 'page-0', mediaFormat: 'png', contentKindHint: ContentKindHint.png),
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

Future<Map<String, Object?>> _artifactProof(CacheRec record, _Wire wire) async {
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
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    try {
      _require(frame.image.width == 1024 && frame.image.height == 1024,
        'persistent transformed artifact does not decode');
    } finally { frame.image.dispose(); }
  } finally { codec.dispose(); }
  return <String, Object?>{
    'bytes': record.bytes, 'checksum': crc.hex, 'checksum_algorithm': 'crc32',
    'source_SHA256_matches': true, 'exact_DownloadId_preserved': true,
    'source_body_lease_not_persisted': record.path != wire.lease,
  };
}

bool _sameArtifact(CacheRec a, CacheRec b) => a.id == b.id && a.path == b.path &&
  a.bytes == b.bytes && a.checksum == b.checksum &&
  a.checksumAlgorithm == b.checksumAlgorithm && a.artifactId == b.artifactId &&
  a.storageRootId == b.storageRootId && a.createdUs == b.createdUs && a.pinned == b.pinned;

Future<void> _record(Map<String, Object?> event) async {
  _events.add(<String, Object?>{'micros': _clock.elapsedMicroseconds, ...event});
  debugPrint('ZIC_SOURCE_BODY_PIPELINE_EVENT ${jsonEncode(_events.last)}');
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

Future<Uint8List> _image() async {
  final rgba = Uint8List(1024 * 1024 * 4);
  var state = 0x12345678;
  for (var i = 0; i < rgba.length; i += 4) {
    state ^= (state << 13) & 0xffffffff;
    state ^= state >> 17;
    state ^= (state << 5) & 0xffffffff;
    rgba[i] = state & 255;
    rgba[i + 1] = 70;
    rgba[i + 2] = 130;
    rgba[i + 3] = 255;
  }
  final ready = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, 1024, 1024, ui.PixelFormat.rgba8888, ready.complete);
  final image = await ready.future;
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    _require(data != null && data.lengthInBytes > 512 * 1024,
      'fixture input did not cross IPC envelope limit');
    return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally { image.dispose(); }
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
  final Uint8List bytes;
  final requests = <Map<String, Object?>>[];
  final held = <String, _HeldInput>{};

  static Future<_Origin> start(Uint8List bytes) async {
    final origin = _Origin(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), bytes);
    origin.server.listen((request) { unawaited(origin.serve(request)); });
    return origin;
  }

  Uri uri(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');
  _HeldInput hold(String path) => held.putIfAbsent(path, _HeldInput.new);

  Future<void> serve(HttpRequest request) async {
    final input = held[request.uri.path];
    try {
      final body = await utf8.decoder.bind(request).join();
      requests.add(<String, Object?>{
        'path': request.uri.path,
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
        socket.add(ascii.encode('HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n'
          'Content-Length: ${bytes.length}\r\nConnection: close\r\n\r\n'));
        socket.add(bytes.sublist(0, 4096));
        await socket.flush();
        input.headers.complete();
      } else {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
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
