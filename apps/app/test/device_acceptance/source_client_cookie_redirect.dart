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

// Test-only original host/source-client fallback and Android CookieManager.
// Every Reader body keeps the original Pipeline/NetLane/retry owners.
const _key = 'source_client_cookie_redirect_fixture';
const _post = 'source-client-cookie-fixture-post';
const _sourceUa = 'SourceClientCookieFixture/1';
const _cases = <String>['stateless', 'set-cookie', 'cookie-followup',
  'redirect-same-origin', 'redirect-cross-origin', 'post-303', 'post-307',
  'cancel-after-redirect'];
const _capabilities = <ExternalPluginCapability>{
  ExternalPluginCapability.network, ExternalPluginCapability.cookies,
};
// Optional name/path metadata from an interrupted run; no cookie value.
final _previousCookieScopes = (jsonDecode(const String.fromEnvironment(
  'ZIC_SOURCE_CLIENT_FIXTURE_PREVIOUS_COOKIE_SCOPES', defaultValue: '[]',
)) as List).map((scope) => Map<String, String>.from(scope as Map)).toList(growable: false);
final _events = <Map<String, Object?>>[];
final _traces = <Map<String, Object?>>[];
final _clock = Stopwatch()..start();
late String _output;

@pragma('vm:entry-point')
Future<void> zicExternalPluginRuntimeServiceMain() =>
    app_entrypoint.zicExternalPluginRuntimeServiceMain();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _status('来源客户端与 Cookie 验收');
  await waitForFirstFlutterUiDisplayed();
  for (final plugin in <String>['network_bridge', 'plugin_host_bridge',
    'texture_bridge', 'reader_runtime']) {
    await attachAndroidPlugin(plugin);
  }
  final support = await getStartupApplicationSupportPath();
  _require(support != null, 'native support path missing');
  _output = '$support/zic-source-client-cookie-redirect-results.json';
  final root = await Directory.systemTemp.createTemp('zic-source-client-cookie-');
  final wire = _Wire(ServicesBinding.instance.defaultBinaryMessenger);
  _Origin? origin;
  ExternalPluginRuntimeSession? session;
  ExternalPluginResourceTransportPool? pool;
  _Composition? current;
  String? cleanupComicId;
  try {
    origin = await _Origin.start(await _image());
    final payload = await File('${root.path}/fixture.js').writeAsString(
      "class SourceClientCookieFixture extends ComicSource {name='Fixture';"
      "key='$_key';version='1';url='https://fixture.invalid';"
      "explore=[{title:'Fixture',type:'multiPageComicList',"
      "load:async(page)=>[{id:'fixture-comic',title:'Fixture'},"
      "{id:'fixture-cleanup',title:'Cookie cleanup'}]}];"
      "comic={loadInfo:async(id)=>{if(id==='fixture-cleanup'){"
      "await Network.get('${origin.uri('cleanup')}',{'cache-time':'0'});"
      "await Network.get('${origin.uri('cleanup', cross:true)}',{'cache-time':'0'});"
      "await Network.get('${origin.uri('cleanup-audit')}',{'cache-time':'0'});"
      "await Network.get('${origin.uri('cleanup-audit', cross:true)}',{'cache-time':'0'});"
      "${_previousCookieScopes.map((scope) => "await Network.get('${origin!.previousScopeUri(scope)}',{'cache-time':'0'});await Network.get('${origin.previousScopeUri(scope, cross:true)}',{'cache-time':'0'});").join()}"
      "}"
      "return {title:'Fixture',chapters:"
      "${jsonEncode(<String, String>{for (final label in _cases) label: label})}};},"
      "loadEp:async(id,ep)=>['${origin.uri('start/')}'+ep+'.png'],"
      "onImageLoad:async(uri)=>{"
      "if(uri.includes('cookie-followup'))await Network.get('${origin.uri('probe-cookie')}',{'cache-time':'0'});"
      "const post=uri.includes('post-');"
      "return {url:uri,method:post?'POST':'GET',headers:{"
      "Cookie:'${origin.explicitCookie}=present',Authorization:'FixtureCredential',"
      "'User-Agent':'$_sourceUa',"
      "...(post?{'Content-Type':'application/x-fixture'}:{})},"
      "...(post?{data:'$_post'}:{})}}};}",
    );
    final plugin = ExternalComicPluginCatalogEntry(
      format: ExternalComicPluginFormat.veneraJavaScript,
      pluginId: 'venera:source-client-cookie-fixture', name: 'Fixture', version: '1',
      entrypoint: Uri.parse('https://fixture.invalid/fixture.js'),
      sources: const <ExternalComicPluginSource>[
        ExternalComicPluginSource(sourceId: 'venera:source_client_cookie_redirect_fixture',
          externalId: _key, name: 'Fixture', language: 'en'),
      ],
    );
    final inspection = await VeneraJavaScriptInspector(
      requestedCapabilities: _capabilities,
      payloads: CallbackExternalPluginPayloadLoader((_) async =>
        ExternalPluginPayloadFile(path: payload.path, byteLength: await payload.length())),
    ).inspect(plugin);
    const limits = ExternalPluginRuntimeLimits(
      invocationTimeout: Duration(seconds: 60), maxConcurrentInvocations: 1,
      maxResponseBytes: 32 * 1024 * 1024,
    );
    final connection = await AndroidVeneraSandboxRuntimeBackend(channel: MethodChannel(
      'dev.zic/plugin_host_runtime_bridge', const StandardMethodCodec(), wire,
    )).activate(VeneraExecutionRequest(
      plugin: plugin, payloadPath: payload.path, payloadByteLength: await payload.length(),
      payloadSha256: inspection.payloadSha256, sourceKey: _key,
      capabilities: _capabilities, limits: limits,
    ));
    session = ExternalPluginRuntimeSession(plugin: plugin, connection: connection, limits: limits);
    final process = await Process.run('/system/bin/pidof',
      <String>['dev.zic.zic:zic_plugin_runtime']);
    final sourcePid = int.parse((process.stdout as String).trim());
    _require(sourcePid != pid, 'source runtime is not an actual separate process');
    final source = session.sources.single;
    final listing = await source.browse(offset: 0, limit: 2);
    cleanupComicId = listing.items.singleWhere((c) => c.title == 'Cookie cleanup').comicId;
    final comic = await source.loadComic(listing.items.singleWhere((c) => c.title == 'Fixture').comicId);
    _require(comic.chapters.length == _cases.length, 'fixture source chapter count differs');
    final direct = _ObservedDirectTransport(RhttpSourceResourceDirectTransport());
    pool = ExternalPluginResourceTransportPool(directTransport: direct,
      defaultUserAgentProvider: () => 'FallbackCookieFixture/1');
    for (final label in _cases) {
      wire.beginCase();
      direct.beginCase();
      final chapter = comic.chapters.singleWhere((c) => c.title == label);
      final record = _chapter(comic.comic, await source.loadChapter(chapter.chapterId));
      final manifest = record.toManifest();
      final page = manifest.pages.single;
      _require(page.uri.scheme == 'venera-resource', 'deferred page authority was bypassed');
      final id = readerPageDownloadId(manifest, page);
      final loader = _ObservedLoader(pool.controlledLoaderFor(source, page.uri),
        selfBoundedOpen: pool.selfBoundsOpenFor(source, page.uri));
      current = await _Composition.open('${root.path}/$label');
      final composition = current;
      final first = Completer<void>();
      _mount(record, composition, loader, () {
        if (!first.isCompleted) first.complete();
      });
      if (label == 'cancel-after-redirect') {
        await origin.partialBody.future.timeout(const Duration(seconds: 20));
        _require(wire.loads == 1 && direct.stateRequired == 1 &&
          composition.lane.active == 1 && !first.isCompleted &&
          !origin.peerClosed.isCompleted, 'cancellation missed the actual source-client body');
        final cancelAt = _clock.elapsedMicroseconds;
        await _unmount();
        await composition.close();
        final exitAt = _clock.elapsedMicroseconds;
        _require(origin.peerClosed.isCompleted && loader.errors.length == 1 &&
          loader.errors.single is Failure &&
          (loader.errors.single as Failure).code == ErrorCode.cancelled,
          'physical source-client body/delegate had not exited at composition completion');
        await _stabilityWindow();
        final cached = await _Composition.open('${root.path}/$label');
        final ready = await cached.store.index.get(id.key);
        _require(ready == null || ready.state != CacheState.ready,
          'cancelled source-client body acquired READY');
        await cached.close();
        _require(_count(composition.trace, TraceEventKind.firstFrameReady) == 0 &&
          _count(composition.trace, TraceEventKind.retryScheduled) == 0 &&
          _count(composition.trace, TraceEventKind.taskFailed) == 0 &&
          origin.forCase(label).length == 3,
          'cancelled source-client work retried or presented');
        await _record(<String, Object?>{
          'case': label, 'status': 'passed', 'actual_source_client_fallback': true,
          'cancel_to_composition_exit_micros': exitAt - cancelAt,
          'actual_TCP_peer_closed_before_exit': true, 'typed_cancelled_delegate': true,
          'no_READY_or_first_frame': true, 'source_loader_opens': loader.opens,
          'runtime_load_operations': wire.loads, 'host_state_required': direct.stateRequired,
          'actual_HTTP_requests': origin.forCase(label), 'composition_exit': composition.exitProof,
          'trace_summary': _captureTrace(label, composition.trace),
          'post_exit_observed_seconds': 6,
        });
        current = null;
      } else {
        await first.future.timeout(const Duration(seconds: 30));
        final ready = await composition.ready(id);
        final proof = await _artifactProof(ready, origin.bytes);
        final fallback = label != 'stateless' && label != 'cookie-followup';
        _require(loader.opens == 1 && loader.errors.isEmpty && wire.resolves == 1 &&
          wire.loads == (fallback ? 1 : 0) && direct.opens == 1 &&
          direct.stateRequired == (fallback ? 1 : 0) &&
          loader.paths.single == (fallback ? 'client-runtime-fallback' : 'direct'),
          'host/source-client handoff created a second retry/resolve or wrong path');
        _require(wire.claims == 0 && wire.transforms == 0,
          'ordinary Venera full-byte fallback was confused with transform/body delivery');
        _require(_count(composition.trace, TraceEventKind.downloadStarted) == 1 &&
          _count(composition.trace, TraceEventKind.retryScheduled) == 0 &&
          _count(composition.trace, TraceEventKind.taskFailed) == 0 &&
          _terminalFailures(composition.trace) == 0,
          'source-client handoff consumed a provider retry or terminal failure');
        origin.requireCase(label);
        final countBefore = origin.requests.length;
        await _stabilityWindow();
        _require(origin.requests.length == countBefore && composition.lane.isIdle,
          'stable cached source media kept issuing HTTP work');
        await _record(<String, Object?>{
          'case': label, 'status': 'passed', 'reader_mounted': true,
          'first_frame_callback': true, 'artifact': proof,
          'source_open_path': loader.paths.single, 'source_loader_opens': loader.opens,
          'runtime_resolve_operations': wire.resolves, 'runtime_load_operations': wire.loads,
          'host_direct_opens': direct.opens, 'host_state_required': direct.stateRequired,
          'actual_HTTP_requests': origin.forCase(label),
          'trace_summary': _captureTrace(label, composition.trace),
          'stable_current_demand_observed_seconds': 6,
        });
        await Future<void>.delayed(const Duration(seconds: 2));
        await _unmount();
        await composition.close();
        current = null;
      }
    }
    await source.loadComic(cleanupComicId);
    _require(origin.cleanupAudits.length == 2 * (1 + _previousCookieScopes.length) &&
      origin.cleanupAudits.every((r) => r['fixture_cookie_absent'] == true),
      'temporary fixture CookieManager state was not removed from both origins');
    final requests = List<Map<String, Object?>>.of(origin.requests);
    final cleanup = List<Map<String, Object?>>.of(origin.cleanupAudits);
    await session.close();
    session = null;
    pool.close();
    pool = null;
    await origin.close();
    origin = null;
    await root.delete(recursive: true);
    await _record(<String, Object?>{
      'case': 'complete', 'status': 'passed', 'cases': _cases.length,
      'production_modified_by_fixture': false, 'host_pid': pid, 'source_pid': sourcePid,
      'actual_HTTP_requests': requests, 'fixture_cookie_cleanup': cleanup,
      'all_test_owners_closed': true, 'test_root_removed': !root.existsSync(),
      'real_external_origin_or_Mihon_or_original19_20_loading_proven': false,
    });
    _status('来源客户端与 Cookie 验收通过');
  } on Object catch (error, stack) {
    if (current != null) _captureTrace('failed-case', current.trace);
    await _record(<String, Object?>{
      'case': 'complete', 'status': 'failed', 'error': error.toString(),
      'stack': stack.toString(), 'actual_HTTP_requests': origin?.requests,
    });
    _status('来源客户端与 Cookie 验收失败');
  } finally {
    if (current != null) await _unmount();
    await current?.close();
    // Each cookie is restricted to a unique test path and unique name. Cleanup
    // uses source-owned HTTP and expires only these cookies, including failures.
    if (session != null && origin != null && cleanupComicId != null) {
      try { await session.sources.single.loadComic(cleanupComicId); } on Object {
        // Preserve the original failed-case result if its source is unavailable.
      }
    }
    await session?.close();
    pool?.close();
    await origin?.close();
    if (root.existsSync()) await root.delete(recursive: true);
  }
}

int _count(MemoryTraceSink trace, TraceEventKind kind) =>
    trace.events.where((event) => event.kind == kind).length;

int _terminalFailures(MemoryTraceSink trace) => trace.events.where((event) =>
    event.kind == TraceEventKind.downloadState && event.payload['state'] == 'failed').length;

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

Future<Map<String, Object?>> _artifactProof(CacheRec record,
    Uint8List expected) async {
  _require(record.state == CacheState.ready && record.bytes == expected.length &&
    record.checksumAlgorithm == 'crc32' && !record.pinned,
    'source media did not acquire complete durable proof');
  final bytes = await File(record.path).readAsBytes();
  final crc = Crc32()..add(bytes);
  _require(bytes.length == expected.length && crc.hex == record.checksum,
    'persisted media does not match its durable proof');
  for (var i = 0; i < expected.length; i++) {
    _require(bytes[i] == expected[i], 'source-owned media bytes changed');
  }
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    try {
      _require(frame.image.width == 1024 && frame.image.height == 1024,
        'persistent media does not decode');
    } finally { frame.image.dispose(); }
  } finally { codec.dispose(); }
  return <String, Object?>{
    'bytes': record.bytes, 'checksum': crc.hex, 'checksum_algorithm': 'crc32',
    'exact_origin_bytes_match': true, 'exact_DownloadId_preserved': true,
  };
}

Future<void> _record(Map<String, Object?> event) async {
  _events.add(<String, Object?>{'micros': _clock.elapsedMicroseconds, ...event});
  debugPrint('ZIC_SOURCE_CLIENT_COOKIE_REDIRECT_EVENT ${jsonEncode(_events.last)}');
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
  final errors = <Object>[];
  final paths = <String>[];

  Future<ByteResponse> open({TaskControl? control, ByteRange? range,
      Validators? validators}) async {
    opens++;
    try {
      final response = await delegate(control: control, range: range, validators: validators);
      final path = response.diagnostics['sourceOpenPath'];
      if (path is String) paths.add(path);
      return response;
    } on Object catch (error) {
      errors.add(error);
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
  _Origin(this.server, this.crossServer, this.bytes);
  final HttpServer server;
  final HttpServer crossServer;
  final Uint8List bytes;
  final prefix = '/zic-cookie-fixture-$pid-${DateTime.now().microsecondsSinceEpoch}/';
  final jarCookie = 'zic_fixture_jar_$pid';
  final explicitCookie = 'zic_fixture_explicit_$pid';
  final requests = <Map<String, Object?>>[];
  final cleanupAudits = <Map<String, Object?>>[];
  final sockets = <Socket>[];
  final partialBody = Completer<void>();
  final peerClosed = Completer<void>();

  static Future<_Origin> start(Uint8List bytes) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final cross = await HttpServer.bind(InternetAddress('127.0.0.2'), 0);
    final origin = _Origin(server, cross, bytes);
    server.listen((request) { unawaited(origin.serve(request, false).catchError(origin.writeAbort)); });
    cross.listen((request) { unawaited(origin.serve(request, true).catchError(origin.writeAbort)); });
    return origin;
  }

  Uri uri(String path, {bool cross = false}) => Uri.parse(
    'http://${cross ? '127.0.0.2' : '127.0.0.1'}:${cross ? crossServer.port : server.port}$prefix$path');
  Uri previousScopeUri(Map<String, String> scope, {bool cross = false}) => Uri.parse(
    'http://${cross ? '127.0.0.2' : '127.0.0.1'}:${cross ? crossServer.port : server.port}${scope['path']}cleanup-audit');
  List<Map<String, Object?>> forCase(String label) => requests
      .where((r) => r['case'] == label).toList(growable: false);

  Future<void> serve(HttpRequest request, bool cross) async {
    final body = await utf8.decoder.bind(request).join();
    final path = request.uri.path;
    final cookie = request.headers.value('cookie') ?? '';
    for (final scope in _previousCookieScopes) {
      if (path == '${scope['path']}cleanup-audit') {
        cleanupAudits.add(<String, Object?>{'cross_origin': cross,
          'previous_failed_run_scope': true,
          'fixture_cookie_absent': !cookie.contains('${scope['name']}=')});
        request.response.write('ok');
        await request.response.close();
        return;
      }
    }
    _require(path.startsWith(prefix), 'unrelated URL reached temporary fixture server');
    final relative = path.substring(prefix.length);
    if (relative == 'cleanup' || relative == 'cleanup-audit') {
      if (relative == 'cleanup') {
        request.response.headers.add('set-cookie', '$jarCookie=; Path=$prefix; Max-Age=0');
        for (final scope in _previousCookieScopes) {
          request.response.headers.add('set-cookie', '${scope['name']}=; Path=${scope['path']}; Max-Age=0');
        }
      } else {
        cleanupAudits.add(<String, Object?>{'cross_origin': cross,
          'fixture_cookie_absent': !cookie.contains('$jarCookie=')});
      }
      request.response.write('ok');
      await request.response.close();
      return;
    }
    final label = relative == 'probe-cookie' ? 'cookie-followup' :
      relative.split('/').last.replaceFirst('.png', '');
    final target = relative.startsWith('target/');
    final probe = relative == 'probe-cookie';
    final post = label.startsWith('post-');
    final is303Target = target && label == 'post-303';
    final authorization = request.headers.value('authorization');
    final entry = <String, Object?>{
      'case': label, 'phase': probe ? 'runtime-CookieJar-probe' : target ? 'redirect-target' : 'initial-media',
      'cross_origin': cross, 'accepted_at_micros': _clock.elapsedMicroseconds,
      'method': request.method, 'body_bytes': body.length,
      'method_preserved': request.method == (post && !is303Target ? 'POST' : 'GET'),
      'body_preserved': body == (post && !is303Target ? _post : ''),
      'content_header_preserved': !post || is303Target ?
        request.headers.value('content-type') == null :
        request.headers.value('content-type') == 'application/x-fixture',
      'source_UA_preserved': request.headers.value('user-agent') == _sourceUa,
      'control_header_stripped': request.headers.value('cache-time') == null,
      'explicit_Cookie_policy': probe || cross ? !cookie.contains('$explicitCookie=') :
        cookie.contains('$explicitCookie=present'),
      'Authorization_policy': probe || cross ? authorization == null :
        authorization == 'FixtureCredential',
      'jar_cookie_policy': probe ? cookie.contains('$jarCookie=set-cookie') :
        cross ? !cookie.contains('$jarCookie=') :
        target ? cookie.contains('$jarCookie=$label') : true,
    };
    requests.add(entry);
    if (probe) {
      request.response.write('ok');
      await request.response.close();
      return;
    }
    if (!target && !const <String>['stateless', 'cookie-followup'].contains(label)) {
      request.response.headers.add('set-cookie', '$jarCookie=$label; Path=$prefix; HttpOnly');
      if (label != 'set-cookie') {
        request.response.statusCode = label == 'post-303' ? 303 : label == 'post-307' ? 307 : 302;
        request.response.headers.set('location', uri('target/$label.png',
          cross: label == 'redirect-cross-origin').toString());
        request.response.contentLength = 0;
        await request.response.close();
        return;
      }
    }
    if (target && label == 'cancel-after-redirect') {
      final socket = await request.response.detachSocket(writeHeaders: false);
      sockets.add(socket);
      void closed() { if (!peerClosed.isCompleted) peerClosed.complete(); }
      socket.listen((_) {}, onDone: closed, onError: (Object error) { closed(); });
      socket.add(ascii.encode('HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n'
        'Content-Length: ${bytes.length}\r\nConnection: close\r\n\r\n'));
      socket.add(bytes.sublist(0, 32 * 1024));
      await socket.flush();
      if (!partialBody.isCompleted) partialBody.complete();
      return;
    }
    request.response.headers.contentType = ContentType('image', 'png');
    request.response.contentLength = bytes.length;
    request.response.add(bytes);
    await request.response.close();
  }

  void requireCase(String label) {
    final rows = forCase(label);
    final expected = label == 'stateless' ? 1 : label == 'set-cookie' ? 2 :
      label == 'cookie-followup' ? 2 : 3;
    _require(rows.length == expected, 'unexpected host/source-client request count for $label');
    for (final row in rows) {
      _require(<String>['method_preserved', 'body_preserved', 'content_header_preserved',
        'control_header_stripped', 'explicit_Cookie_policy', 'Authorization_policy',
        'jar_cookie_policy'].every((key) => row[key] == true),
        'source client changed request/redirect/Cookie policy: $row');
      if (row['phase'] != 'runtime-CookieJar-probe') {
        _require(row['source_UA_preserved'] == true, 'source UA was overridden');
      }
    }
  }

  void writeAbort(Object error) {
    if (error is! HttpException && error is! SocketException) {
      throw error;
    }
  }

  Future<void> close() async {
    for (final socket in sockets) { socket.destroy(); }
    await server.close(force: true);
    await crossServer.close(force: true);
  }
}

final class _ObservedDirectTransport implements SourceResourceDirectTransport,
    SelfBoundedSourceResourceDirectTransport {
  _ObservedDirectTransport(this.delegate);
  final RhttpSourceResourceDirectTransport delegate;
  int opens = 0;
  int stateRequired = 0;
  void beginCase() { opens = stateRequired = 0; }

  @override
  Future<ByteResponse> open(ComicResourceRequest request, {TaskControl? control}) async {
    opens++;
    try { return await delegate.open(request, control: control); }
    on Failure catch (error) {
      if (error.details['sourceClientStateRequired'] == true &&
          error.details['sourceMediaProtocolMismatch'] == true) {
        stateRequired++;
      }
      rethrow;
    }
  }

  @override
  void close() => delegate.close();
}

final class _Wire implements BinaryMessenger {
  _Wire(this.delegate);
  final BinaryMessenger delegate;
  static const codec = StandardMethodCodec();
  int loads = 0;
  int resolves = 0;
  int claims = 0;
  int transforms = 0;
  void beginCase() { loads = resolves = claims = transforms = 0; }

  @override
  Future<ByteData?> send(String channel, ByteData? message) async {
    if (channel == 'dev.zic/plugin_host_runtime_bridge' && message != null) {
      final call = codec.decodeMethodCall(message);
      if (call.method == 'invokeExternalRuntime') {
        final request = (call.arguments as Map)['request'] as Map;
        if (request['operation'] == 'loadResource') loads++;
        if (request['operation'] == 'resolveResource') resolves++;
        if (request['operation'] == 'transformResource') transforms++;
      } else if (call.method == 'claimExternalRuntimeResourceBody') { claims++; }
    }
    return delegate.send(channel, message);
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
