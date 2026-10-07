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
import 'package:pipeline_runtime/pipeline_runtime.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';
import 'package:zic/main.dart' as app_entrypoint;
import 'package:zic/startup_platform.dart';

// Test-only actual source errors and TCP failures through the original Reader
// physical download/retry owner. No fake transport or injected retry timer.
const _key = 'source_runtime_network_pipeline_fixture';
const _rotate = 'function modifyImage(image){return image.copyAndRotate90()}';
const _post = 'source-runtime-network-fixture-post';
const _sourceUa = 'SourceRuntimeNetworkFixture/1';
const _cases = <String>['resolver-transient', 'resolver-exhausted',
  'cancel-resolver-active', 'cancel-resolver-backoff'];
final _events = <Map<String, Object?>>[];
final _traces = <Map<String, Object?>>[];
final _clock = Stopwatch()..start();
late String _output;

@pragma('vm:entry-point')
Future<void> zicExternalPluginRuntimeServiceMain() =>
    app_entrypoint.zicExternalPluginRuntimeServiceMain();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _status('来源运行时网络验收');
  await waitForFirstFlutterUiDisplayed();
  for (final plugin in <String>['network_bridge', 'plugin_host_bridge',
    'texture_bridge', 'reader_runtime']) {
    await attachAndroidPlugin(plugin);
  }
  final support = await getStartupApplicationSupportPath();
  _require(support != null, 'native support path missing');
  _output = '$support/zic-source-runtime-network-pipeline-results.json';
  final root = await Directory.systemTemp.createTemp('zic-source-runtime-network-pipeline-');
  final wire = _Wire(ServicesBinding.instance.defaultBinaryMessenger);
  _Origin? origin;
  ExternalPluginRuntimeSession? session;
  ExternalPluginResourceTransportPool? pool;
  _Composition? current;
  try {
    origin = await _Origin.start(await _image());
    final payload = await File('${root.path}/fixture.js').writeAsString(
      "class SourceRuntimeNetworkPipelineFixture extends ComicSource {name='Fixture';"
      "key='$_key';version='1';url='https://fixture.invalid';"
      "explore=[{title:'Fixture',type:'multiPageComicList',"
      "load:async(page)=>[{id:'fixture-comic',title:'Fixture'}]}];"
      "comic={loadInfo:async(id)=>({title:'Fixture',"
      "chapters:${jsonEncode(<String, String>{for (final label in _cases) label: label})}}),"
      "loadEp:async(id,ep)=>['${origin.uri('/media/')}'+ep+'.png'],"
      "onImageLoad:async(uri)=>{"
      "const locator=uri.replace('/media/','/resolver/').replace('.png','.json');"
      "const response=await Network.post(locator,"
      "{Cookie:'acceptance=present','User-Agent':'$_sourceUa','cache-time':'0'},'$_post');"
      "return {url:JSON.parse(response.body).url,method:'POST',"
      "headers:{Cookie:'acceptance=present','User-Agent':'$_sourceUa'},"
      "data:'$_post',modifyImage:'$_rotate'}}};}",
    );
    final plugin = ExternalComicPluginCatalogEntry(
      format: ExternalComicPluginFormat.veneraJavaScript,
      pluginId: 'venera:source-runtime-network-pipeline-fixture', name: 'Fixture', version: '1',
      entrypoint: Uri.parse('https://fixture.invalid/fixture.js'),
      sources: const <ExternalComicPluginSource>[
        ExternalComicPluginSource(sourceId: 'venera:source_runtime_network_pipeline_fixture',
          externalId: _key, name: 'Fixture', language: 'en'),
      ],
    );
    final inspection = await VeneraJavaScriptInspector(
      requestedCapabilities: const <ExternalPluginCapability>{ExternalPluginCapability.network},
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
      capabilities: const <ExternalPluginCapability>{ExternalPluginCapability.network}, limits: limits,
    ));
    session = ExternalPluginRuntimeSession(
      plugin: plugin, connection: connection, limits: limits,
    );
    final process = await Process.run('/system/bin/pidof',
      <String>['dev.zic.zic:zic_plugin_runtime']);
    final sourcePid = int.parse((process.stdout as String).trim());
    _require(sourcePid != pid, 'source runtime is not a separate actual process');
    final source = session.sources.single;
    final listing = await source.browse(offset: 0, limit: 1);
    final comic = await source.loadComic(listing.items.single.comicId);
    _require(comic.chapters.length == _cases.length,
      'production source catalog did not expose all fixture chapters');
    pool = ExternalPluginResourceTransportPool(
      directTransport: RhttpSourceResourceDirectTransport(),
      defaultUserAgentProvider: () => 'FallbackFailureFixture/1',
    );
    for (final label in _cases) {
      wire.beginCase();
      final resolverUri = origin.uri('/resolver/$label.json');
      final mediaUri = origin.uri('/media/$label.png');
      final chapter = comic.chapters.singleWhere((chapter) => chapter.title == label);
      final record = _chapter(comic.comic, await source.loadChapter(chapter.chapterId));
      final manifest = record.toManifest();
      final pageUri = manifest.pages.single.uri;
      _require(pageUri.scheme == 'venera-resource',
        'test page bypassed the production deferred Reader page locator');
      final id = readerPageDownloadId(manifest, manifest.pages.single);
      final loader = _ObservedLoader(pool.controlledLoaderFor(source, pageUri),
        selfBoundedOpen: pool.selfBoundsOpenFor(source, pageUri));
      current = await _Composition.open('${root.path}/$label');
      final composition = current;
      final first = Completer<void>();
      _mount(record, composition, loader, () {
        if (!first.isCompleted) first.complete();
      });
      if (label == 'resolver-transient') {
        await first.future.timeout(const Duration(seconds: 30));
        final ready = await composition.ready(id);
        final proof = await _artifactProof(ready, wire);
        wire.requireReleased();
        _require(loader.opens == 2 && loader.failures.length == 1 &&
          loader.errors.length == 1, 'runtime resolver success used another retry budget');
        _requireTypedResolverFailures(loader);
        _require(_count(composition.trace, TraceEventKind.retryScheduled) == 1 &&
          _count(composition.trace, TraceEventKind.taskFailed) == 0,
          'runtime failure did not reach the original physical retry owner');
        await _stabilityWindow();
        _require(loader.opens == 2 && composition.lane.isIdle &&
          origin.forPath(resolverUri.path).length == 2 &&
          origin.forPath(mediaUri.path).length == 1 && wire.resolves == 2,
          'successful runtime retry reopened stable demand or bypassed the resolver');
        await _record(<String, Object?>{
          'case': label, 'status': 'passed', 'reader_mounted': true,
          'first_frame_callback': true, 'artifact': proof,
          'source_loader_opens': loader.opens, 'delegate_errors': loader.failureMessages,
          'typed_runtime_network_failures': loader.failures.length,
          'runtime_resolve_operations': wire.resolves,
          'actual_resolver_HTTP_requests': origin.forPath(resolverUri.path),
          'actual_media_HTTP_requests': origin.forPath(mediaUri.path),
          'trace_summary': _captureTrace(label, composition.trace),
          'claims': wire.claims, 'releases': wire.releases,
          'stable_current_demand_observed_seconds': 6,
        });
        await Future<void>.delayed(const Duration(seconds: 2));
      } else if (label.startsWith('cancel-')) {
        final active = label == 'cancel-resolver-active';
        if (active) {
          await origin.partialResolver.future.timeout(const Duration(seconds: 20));
          _require(!origin.resolverPeerClosed.isCompleted &&
            _count(composition.trace, TraceEventKind.retryScheduled) == 0,
            'cancel fixture missed the actual active resolver body');
        } else {
          await _until(() => _count(composition.trace, TraceEventKind.retryScheduled) == 1,
            'runtime resolver never reached the original retry backoff');
          _requireTypedResolverFailures(loader);
        }
        _require(loader.opens == 1 && !first.isCompleted,
          'cancel fixture missed the first actual resolver invocation');
        final cancelAt = _clock.elapsedMicroseconds;
        await _unmount();
        await composition.close();
        final exitAt = _clock.elapsedMicroseconds;
        if (active) {
          await origin.resolverPeerClosed.future.timeout(const Duration(seconds: 10));
          _require(loader.failures.length == 1 &&
            loader.failures.single.code == ErrorCode.cancelled,
            'scheduler cancellation observer: ${jsonEncode(loader.failureMessages)}');
        }
        await _stabilityWindow();
        _require(loader.opens == 1 && !first.isCompleted && wire.resolves == 1 &&
          origin.forPath(resolverUri.path).length == 1 &&
          origin.forPath(mediaUri.path).isEmpty && wire.claims == 0 &&
          _count(composition.trace, TraceEventKind.artifactPromoted) == 0 &&
          _count(composition.trace, TraceEventKind.taskFailed) == 0,
          'retired resolver created late HTTP, READY, failure or a frame');
        await _record(<String, Object?>{
          'case': label, 'status': 'passed', 'source_loader_opens': loader.opens,
          'delegate_errors': loader.failureMessages,
          'runtime_resolve_operations': wire.resolves,
          'actual_resolver_HTTP_requests': origin.forPath(resolverUri.path),
          'actual_media_HTTP_requests': origin.forPath(mediaUri.path),
          'actual_active_TCP_peer_closed': active && origin.resolverPeerClosed.isCompleted,
          'trace_summary': _captureTrace(label, composition.trace),
          'no_late_retry_or_READY_or_frame': true,
          'cancel_to_joined_exit_micros': exitAt - cancelAt,
          'composition_exit': composition.exitProof,
          'post_exit_observed_seconds': 6,
        });
        current = null;
        continue;
      } else {
        await _until(() => composition.runtime.findSession(id)?.snapshot.failure != null &&
          composition.lane.isIdle, 'runtime network attempts never reached terminal failure');
        final failure = composition.runtime.findSession(id)!.snapshot.failure!;
        final attempts = ReaderPipelineProfile.stable.retry.maxAttempts;
        _requireTypedResolverFailures(loader);
        _require(failure.code == ErrorCode.network &&
          failure.details['runtimeRetryable'] == true &&
          loader.opens == attempts && loader.failures.length == attempts &&
          wire.resolves == attempts && origin.forPath(resolverUri.path).length == attempts &&
          _count(composition.trace, TraceEventKind.retryScheduled) == attempts - 1,
          'runtime resolver exhausted with wrong type or multiplied attempt budget');
        await _stabilityWindow();
        final row = await composition.store.index.get(id.key);
        _require(loader.opens == attempts && composition.lane.isIdle &&
          _terminalFailures(composition.trace) == 1 &&
          _count(composition.trace, TraceEventKind.taskFailed) == 1 &&
          !first.isCompleted && wire.claims == 0 &&
          origin.forPath(mediaUri.path).isEmpty &&
          (row == null || row.state != CacheState.ready),
          'terminal runtime failure restarted or published a false READY/frame');
        await _record(<String, Object?>{
          'case': label, 'status': 'passed', 'reader_mounted': true,
          'terminal_failure_code': failure.code.name,
          'terminal_download_state_count': _terminalFailures(composition.trace),
          'source_loader_opens': loader.opens, 'delegate_errors': loader.failureMessages,
          'typed_runtime_network_failures': loader.failures.length,
          'runtime_resolve_operations': wire.resolves,
          'actual_resolver_HTTP_requests': origin.forPath(resolverUri.path),
          'actual_media_HTTP_requests': origin.forPath(mediaUri.path),
          'trace_summary': _captureTrace(label, composition.trace),
          'no_READY_or_first_frame': true, 'claims': wire.claims,
          'stable_current_demand_observed_seconds': 6,
        });
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      await _unmount();
      await composition.close();
      current = null;
    }
    _require(origin.requests.every((r) =>
      r['method_POST'] == true && r['nonempty_Cookie_preserved'] == true &&
      r['source_UA_preserved'] == true && r['nonempty_POST_body_preserved'] == true),
      'source HTTP plan method/Cookie/UA/body was changed');
    final requests = List<Map<String, Object?>>.of(origin.requests);
    await session.close();
    session = null;
    pool.close();
    pool = null;
    await origin.close();
    origin = null;
    await root.delete(recursive: true);
    await _record(<String, Object?>{
      'case': 'complete', 'status': 'passed', 'cases': 4,
      'production_modified_by_fixture': false, 'host_pid': pid, 'source_pid': sourcePid,
      'source_process_generation_at_activation': wire.sourceGeneration,
      'actual_HTTP_requests': requests, 'all_test_owners_closed': true,
      'test_root_removed': !root.existsSync(),
      'ordinary_real_source_or_original_19_20_loading_proven': false,
    });
    _status('来源运行时网络验收通过');
  } on Object catch (error, stack) {
    if (current != null) _captureTrace('failed-case', current.trace);
    await _record(<String, Object?>{
      'case': 'complete', 'status': 'failed',
      'error': error.toString(), 'stack': stack.toString(),
      'actual_HTTP_requests': origin?.requests,
    });
    _status('来源运行时网络验收失败');
  } finally {
    if (current != null) await _unmount();
    await current?.close();
    await session?.close();
    pool?.close();
    await origin?.close();
    if (root.existsSync()) await root.delete(recursive: true);
  }
}

void _requireTypedResolverFailures(_ObservedLoader loader) {
  _require(loader.failures.isNotEmpty && loader.failures.every((failure) =>
    failure.code == ErrorCode.network &&
    failure.details['runtimeRetryable'] == true &&
    failure.details['runtimeErrorCode'] == 'venera-operation-failed' &&
    !RegExp(r'timeout|timed out|connect|network|dns|temporar|HTTP 5\d\d',
      caseSensitive: false).hasMatch(failure.message)),
    'typed resolver retryability was lost or obscured by keyword classification');
}

int _count(MemoryTraceSink trace, TraceEventKind kind) =>
    trace.events.where((event) => event.kind == kind).length;

int _terminalFailures(MemoryTraceSink trace) => trace.events.where((event) =>
    event.kind == TraceEventKind.downloadState && event.payload['state'] == 'failed').length;

Future<void> _until(bool Function() predicate, String reason) async {
  final elapsed = Stopwatch()..start();
  while (!predicate()) {
    if (elapsed.elapsed > const Duration(seconds: 25)) throw StateError(reason);
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _stabilityWindow() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(const Duration(seconds: 1));
    await _frames(2);
  }
}

ImportedChapterRecord _chapter(Comic comic, ChapterManifest manifest) =>
    ImportedChapterRecord.remote(comic: comic, manifest: manifest);

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

Future<void> _record(Map<String, Object?> event) async {
  _events.add(<String, Object?>{'micros': _clock.elapsedMicroseconds, ...event});
  debugPrint('ZIC_SOURCE_RUNTIME_NETWORK_PIPELINE_EVENT ${jsonEncode(_events.last)}');
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
  final errors = <Object>[];
  final failures = <Failure>[];
  List<Map<String, Object?>> get failureMessages => errors.map((error) =>
    <String, Object?>{'runtime_type': error.runtimeType.toString(),
      'domain_failure_at_delegate': error is Failure,
      if (error is Failure) 'code': error.code.name,
      'message': error.toString(),
      if (error is Failure) 'details': error.details}).toList(growable: false);
  final deliveries = <String>[];

  Future<ByteResponse> open({TaskControl? control, ByteRange? range,
      Validators? validators}) async {
    opens++;
    try {
      final result = await delegate(control: control, range: range, validators: validators);
      final delivery = result.diagnostics['sourceRuntimeBodyDelivery'];
      if (delivery is String) deliveries.add(delivery);
      return result;
    } on Object catch (error) {
      errors.add(error);
      if (error is Failure) {
        failures.add(error);
        if (error.code == ErrorCode.cancelled) cancelled++;
      }
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

final class _Origin {
  _Origin(this.server, this.bytes);
  final HttpServer server;
  final Uint8List bytes;
  final requests = <Map<String, Object?>>[];
  final sockets = <Socket>[];
  final partialResolver = Completer<void>();
  final resolverPeerClosed = Completer<void>();

  static Future<_Origin> start(Uint8List bytes) async {
    final origin = _Origin(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), bytes);
    origin.server.listen((request) { unawaited(origin.serve(request)); });
    return origin;
  }

  Uri uri(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');
  List<Map<String, Object?>> forPath(String path) => requests
      .where((request) => request['path'] == path).toList(growable: false);

  Future<void> serve(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final path = request.uri.path;
    final resolver = path.startsWith('/resolver/');
    final label = path.split('/').last.replaceFirst(RegExp(r'\.(json|png)$'), '');
    requests.add(<String, Object?>{
      'path': path, 'phase': resolver ? 'source-runtime-resolver' : 'host-media',
      'accepted_at_micros': _clock.elapsedMicroseconds,
      'method_POST': request.method == 'POST',
      'nonempty_Cookie_preserved': request.headers.value('cookie') == 'acceptance=present',
      'source_UA_preserved': request.headers.value('user-agent') == _sourceUa,
      'nonempty_POST_body_preserved': body == _post,
      'source_control_headers_stripped': request.headers.value('cache-time') == null,
    });
    final broken = resolver && (label == 'resolver-exhausted' ||
      label == 'cancel-resolver-backoff' ||
      (label == 'resolver-transient' && forPath(path).length == 1));
    final active = resolver && label == 'cancel-resolver-active';
    if (broken || active) {
      final socket = await request.response.detachSocket(writeHeaders: false);
      sockets.add(socket);
      socket.listen((_) {}, onDone: () {
        if (active && !resolverPeerClosed.isCompleted) resolverPeerClosed.complete();
      }, onError: (Object error) {
        if (active && !resolverPeerClosed.isCompleted) resolverPeerClosed.complete();
      });
      socket.add(ascii.encode('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n'
        'Content-Length: 4096\r\nConnection: close\r\n\r\n'));
      socket.add(ascii.encode('{"url":'));
      await socket.flush();
      if (active) {
        if (!partialResolver.isCompleted) partialResolver.complete();
      } else {
        await socket.close();
      }
    } else if (resolver) {
      final result = utf8.encode(jsonEncode(<String, String>{
        'url': uri('/media/$label.png').toString(),
      }));
      request.response.headers.contentType = ContentType.json;
      request.response.contentLength = result.length;
      request.response.add(result);
      await request.response.close();
    } else {
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    }
  }

  Future<void> close() async {
    for (final socket in sockets) { socket.destroy(); }
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
  int resolves = 0;
  String? lease;
  Map<Object?, Object?>? reference;
  Object? sourceGeneration;

  void beginCase() {
    claims = releases = transforms = resolves = 0;
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
        if (request['operation'] == 'resolveResource') resolves++;
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
