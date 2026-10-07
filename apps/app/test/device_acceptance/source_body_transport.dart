import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:downloads_bridge/downloads_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:plugin_host/plugin_host.dart';
import 'package:plugin_host_bridge/plugin_host_bridge.dart';
import 'package:zic/main.dart' as app_entrypoint;
import 'package:zic/startup_platform.dart';

// Test-only actual HTTP/source/transform/Binder/file/ByteResponse chain. The
// server controls its own TCP output, not any production Future or file read.
// No user library, artifact index, settings or installed-source roster is opened.
const _key = 'source_body_transport_fixture';
const _rotate = 'function modifyImage(image){return image.copyAndRotate90()}';
const _post = 'body-transport-fixture-post';
const _sourceUa = 'SourceTransportFixture/1';
final _events = <Map<String, Object?>>[];
final _clock = Stopwatch()..start();
late String _output;
final _status = ValueNotifier<String>('正文传输验收');

@pragma('vm:entry-point')
Future<void> zicExternalPluginRuntimeServiceMain() =>
    app_entrypoint.zicExternalPluginRuntimeServiceMain();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MaterialApp(home: Scaffold(
    appBar: AppBar(title: const Text('正文传输验收')),
    body: ValueListenableBuilder<String>(
      valueListenable: _status,
      builder: (_, value, _) => Center(child: Text(value)),
    ),
  )));
  await waitForFirstFlutterUiDisplayed();
  await attachAndroidPlugin('network_bridge');
  await attachAndroidPlugin('plugin_host_bridge');
  final support = await getStartupApplicationSupportPath();
  _require(support != null, 'native support path missing');
  _output = '$support/zic-source-body-transport-results.json';
  final root = await Directory.systemTemp.createTemp('zic-source-body-transport-');
  _Origin? origin;
  ExternalPluginRuntimeSession? session;
  ExternalPluginResourceTransportPool? pool;
  final coordinator = DownloadResourceCoordinator();
  final wire = _Wire(ServicesBinding.instance.defaultBinaryMessenger);
  try {
    origin = await _Origin.start(await _image());
    final payload = await File('${root.path}/fixture.js').writeAsString(
      "class SourceBodyTransportFixture extends ComicSource {name='Fixture';"
      "key='$_key';version='1';url='https://fixture.invalid';"
      "explore=[{title:'Fixture',type:'multiPageComicList',load:async(page)=>[]}];"
      "comic={onThumbnailLoad:(uri)=>({method:'POST',"
      "headers:{Cookie:'acceptance=present','User-Agent':'$_sourceUa'},"
      "data:'$_post',modifyImage:'$_rotate',"
      "...(uri.indexOf('/canonical/')>=0?{onResponse:async(input)=>input}:{})})};}",
    );
    final plugin = ExternalComicPluginCatalogEntry(
      format: ExternalComicPluginFormat.veneraJavaScript,
      pluginId: 'venera:source-body-transport-fixture', name: 'Fixture', version: '1',
      entrypoint: Uri.parse('https://fixture.invalid/fixture.js'),
      sources: const <ExternalComicPluginSource>[
        ExternalComicPluginSource(sourceId: 'venera:source_body_transport_fixture',
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
      defaultUserAgentProvider: () => 'FallbackTransportFixture/1',
    );
    final normal = <String, List<int>>{};
    final validators = <String, Validators>{};
    for (final plane in <String>['canonical', 'isolated']) {
      for (final mode in <String>['full', 'matching-range', 'mismatched-validator',
        'discard-before-listen']) {
        final label = '$mode-$plane';
        wire.beginCase(label);
        final uri = origin.uri('/$plane/$mode');
        final result = await _withLane<Map<String, Object?>>(
          coordinator, label, (control) async {
            ByteResponse? response;
            try {
              response = await pool!.controlledLoaderFor(source, uri)(
                control: control,
                range: mode == 'matching-range' || mode == 'mismatched-validator'
                    ? const ByteRange(start: 17, end: 196624) : null,
                validators: mode == 'matching-range' ? validators[plane]
                    : mode == 'mismatched-validator'
                      ? const Validators(etag: '"unrelated-generation"') : null,
              );
              _require(response.diagnostics['sourceRuntimeBodyDelivery'] ==
                'sealed-file-v1', 'source transport did not select a sealed body');
              _require(response.totalLength != null && response.totalLength! >
                512 * 1024, 'source output did not cross IPC envelope limit');
              _require(wire.claims == 1 && wire.releases == 0 &&
                File(wire.lease!).existsSync(), 'body was not claimed before response');
              final bytes = <int>[];
              var chunks = 0;
              var maxChunk = 0;
              if (mode != 'discard-before-listen') {
                await for (final chunk in response.bytes) {
                  control.throwIfCancelled();
                  chunks++;
                  if (chunk.length > maxChunk) maxChunk = chunk.length;
                  bytes.addAll(chunk);
                }
                _require(chunks > 1 && maxChunk <= 65536,
                  'source ByteResponse lost bounded file streaming');
                if (mode == 'full') {
                  normal[plane] = bytes;
                  validators[plane] = response.validators;
                  _require(response.statusCode == 200 && response.rangeStart == 0,
                    'full response metadata changed');
                  _require(bytes.length == response.totalLength,
                    'full source transport body is truncated');
                  final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
                  try {
                    final frame = await codec.getNextFrame();
                    try {
                      _require(frame.image.width == 1024 && frame.image.height == 1024,
                        'real transformed output did not decode');
                    } finally { frame.image.dispose(); }
                  } finally { codec.dispose(); }
                } else if (mode == 'matching-range') {
                  final expected = normal[plane]!.sublist(17, 196625);
                  _require(response.statusCode == 206 && response.rangeStart == 17 &&
                    _equal(bytes, expected), 'matching source range differs from full body');
                } else {
                  _require(response.statusCode == 200 && response.rangeStart == 0 &&
                    _equal(bytes, normal[plane]!), 'mismatched validator served a stale range');
                }
              }
              await response.discard(control: control);
              wire.requireReleased();
              return <String, Object?>{
                'case': label, 'status': 'passed',
                'source_input_bytes': origin!.bytes.length,
                'body_bytes': response.totalLength, 'consumed_bytes': bytes.length,
                'chunks': chunks, 'max_chunk_bytes': maxChunk,
                'status_code': response.statusCode, 'range_start': response.rangeStart,
                'claims': wire.claims, 'releases': wire.releases,
                'lease_removed': !File(wire.lease!).existsSync(),
                'source_transform_operations': wire.transforms,
                'body_delivery': 'sealed-file-v1', 'wire': List<String>.of(wire.events),
              };
            } finally { await response?.discard(control: control); }
          },
        );
        await _record(result);
      }
    }
    wire.beginCase('real-HTTP-input-cancellation');
    final cancellation = Completer<bool>();
    final key = 'source-body-fixture:cancel';
    coordinator.networkLane.submit(key: key, priority: 1000, task: (control) async {
      ByteResponse? response;
      try {
        response = await pool!.controlledLoaderFor(source,
          origin!.uri('/isolated/cancel-input'))(control: control);
        await for (final _ in response.bytes) { control.throwIfCancelled(); }
        cancellation.complete(false);
      } on Object catch (error) {
        cancellation.complete(error is Failure && error.code == ErrorCode.cancelled);
      } finally { await response?.discard(control: control); }
    });
    await origin.heldHeaders.future.timeout(const Duration(seconds: 20));
    _require(!cancellation.isCompleted, 'held actual HTTP input already exited');
    final cancelAt = _clock.elapsedMicroseconds;
    coordinator.networkLane.cancelAll();
    _require(await cancellation.future.timeout(const Duration(seconds: 20)),
      'actual HTTP cancellation did not preserve typed cancellation');
    await coordinator.networkLane.idleKeys(<String>[key]);
    await origin.peerClosed.future.timeout(const Duration(seconds: 20));
    _require(wire.claims == 0 && wire.transforms == 0,
      'cancelled input published a transform or sealed body');
    await _record(<String, Object?>{
      'case': 'real-HTTP-input-cancellation', 'status': 'passed',
      'headers_and_partial_input_sent': true, 'actual_TCP_peer_closed': true,
      'typed_cancellation': true, 'claims': wire.claims,
      'source_transform_operations': wire.transforms,
      'cancel_to_peer_close_micros': origin.peerClosedAt! - cancelAt,
      'wire': List<String>.of(wire.events),
    });
    _require(origin.requests.length == 9 && origin.requests.every((r) =>
      r['method_POST'] == true && r['nonempty_Cookie_preserved'] == true &&
      r['source_UA_preserved'] == true && r['nonempty_POST_body_preserved'] == true),
      'source HTTP plan method/Cookie/UA/body was changed');
    await session.close();
    session = null;
    await _record(<String, Object?>{
      'case': 'complete', 'status': 'passed', 'cases': 9,
      'production_modified': false, 'actual_HTTP_requests': origin.requests,
      'host_pid': pid, 'source_pid': sourcePid,
      'source_process_generation_at_activation': wire.sourceGeneration,
      'SourceResourceTransport_negotiated_transform_subset_proven': true,
      'full_DownloadSession_Pipeline_or_real_origin_proven': false,
    });
    _status.value = '验收通过';
  } on Object catch (error, stack) {
    await _record(<String, Object?>{
      'case': 'complete', 'status': 'failed',
      'error': error.toString(), 'stack': stack.toString(),
    });
    _status.value = '验收失败';
  } finally {
    coordinator.networkLane.cancelAll();
    await session?.close();
    pool?.close();
    await origin?.close();
    await root.delete(recursive: true);
  }
}

Future<T> _withLane<T>(DownloadResourceCoordinator coordinator, String label,
    Future<T> Function(TaskControl) run) async {
  final result = Completer<T>();
  final key = 'source-body-fixture:$label';
  coordinator.networkLane.submit(key: key, priority: 1000, task: (control) async {
    try { result.complete(await run(control)); }
    on Object catch (error, stack) { result.completeError(error, stack); }
  });
  try { return await result.future; }
  finally { await coordinator.networkLane.idleKeys(<String>[key]); }
}

Future<void> _record(Map<String, Object?> event) async {
  _events.add(<String, Object?>{'micros': _clock.elapsedMicroseconds, ...event});
  debugPrint('ZIC_SOURCE_BODY_TRANSPORT_EVENT ${jsonEncode(_events.last)}');
  await File(_output).writeAsString(jsonEncode(_events), flush: true);
}

void _require(bool condition, String reason) {
  if (!condition) throw StateError(reason);
}

bool _equal(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) { if (left[i] != right[i]) return false; }
  return true;
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
  final heldHeaders = Completer<void>();
  final peerClosed = Completer<void>();
  int? peerClosedAt;
  Socket? heldSocket;

  static Future<_Origin> start(Uint8List bytes) async {
    final origin = _Origin(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), bytes);
    origin.server.listen((request) { unawaited(origin.serve(request)); });
    return origin;
  }

  Uri uri(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  Future<void> serve(HttpRequest request) async {
    try {
      final body = await utf8.decoder.bind(request).join();
      requests.add(<String, Object?>{
        'method_POST': request.method == 'POST',
        'nonempty_Cookie_preserved': request.headers.value('cookie') == 'acceptance=present',
        'source_UA_preserved': request.headers.value('user-agent') == _sourceUa,
        'nonempty_POST_body_preserved': body == _post,
      });
      if (request.uri.path.endsWith('/cancel-input')) {
        final socket = await request.response.detachSocket(writeHeaders: false);
        heldSocket = socket;
        void closed() {
          if (!peerClosed.isCompleted) {
            peerClosedAt = _clock.elapsedMicroseconds;
            peerClosed.complete();
          }
        }
        socket.listen((_) {}, onDone: closed, onError: (Object _) => closed());
        socket.add(ascii.encode('HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n'
          'Content-Length: ${bytes.length}\r\nConnection: close\r\n\r\n'));
        socket.add(bytes.sublist(0, 4096));
        await socket.flush();
        heldHeaders.complete();
      } else {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      }
    } on Object catch (error, stack) {
      if (!heldHeaders.isCompleted) heldHeaders.completeError(error, stack);
    }
  }

  Future<void> close() async {
    heldSocket?.destroy();
    await server.close(force: true);
  }
}

final class _Wire implements BinaryMessenger {
  _Wire(this.delegate);
  final BinaryMessenger delegate;
  static const codec = StandardMethodCodec();
  final events = <String>[];
  int claims = 0;
  int releases = 0;
  int transforms = 0;
  String? lease;
  Object? sourceGeneration;

  void beginCase(String label) {
    events.clear();
    claims = releases = transforms = 0;
    lease = null;
  }

  void requireReleased() {
    _require(claims == 1 && releases == 1 && lease != null &&
      !File(lease!).existsSync(), 'source transport did not release one claimed body');
  }

  @override
  Future<ByteData?> send(String channel, ByteData? message) async {
    MethodCall? call;
    if (channel == 'dev.zic/plugin_host_runtime_bridge' && message != null) {
      call = codec.decodeMethodCall(message);
      events.add('${call.method}:start');
      if (call.method == 'invokeExternalRuntime') {
        final args = call.arguments as Map;
        final request = args['request'] as Map;
        if (request['operation'] == 'transformResource') transforms++;
      }
    }
    final reply = await delegate.send(channel, message);
    if (call != null) {
      events.add('${call.method}:exit');
      if (reply != null) {
        if (call.method == 'claimExternalRuntimeResourceBody') {
          lease = codec.decodeEnvelope(reply) as String;
          claims++;
        } else if (call.method == 'releaseExternalRuntimeResourceBody') {
          codec.decodeEnvelope(reply);
          releases++;
        } else if (call.method == 'activateVeneraRuntime') {
          sourceGeneration = (codec.decodeEnvelope(reply) as Map)['processId'];
        }
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
