import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:plugin_host/plugin_host.dart';
import 'package:plugin_host_bridge/plugin_host_bridge.dart';
import 'package:zic/main.dart' as app_entrypoint;
import 'package:zic/startup_platform.dart';

// Test-only entry. No library, download index, settings or installed-source
// roster is opened. The native bridge, actual Android Service and Dart body
// consumer are unchanged. IOOverrides only observes the real file operations.
const _key = 'dart_body_fixture';
const _rotate = 'function modifyImage(image){return image.copyAndRotate90()}';
late String _output;
final _status = ValueNotifier<String>('正文寿命验收');
final _events = <Map<String, Object?>>[];
final _clock = Stopwatch()..start();

@pragma('vm:entry-point')
Future<void> zicExternalPluginRuntimeServiceMain() =>
    app_entrypoint.zicExternalPluginRuntimeServiceMain();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MaterialApp(home: Scaffold(
    appBar: AppBar(title: const Text('正文寿命验收')),
    body: ValueListenableBuilder<String>(
      valueListenable: _status,
      builder: (_, value, _) => Center(child: Text(value)),
    ),
  )));
  await waitForFirstFlutterUiDisplayed();
  await attachAndroidPlugin('network_bridge');
  await attachAndroidPlugin('plugin_host_bridge');
  final root = await Directory.systemTemp.createTemp('zic-dart-body-');
  final support = await getStartupApplicationSupportPath();
  _require(support != null, 'native application support path missing');
  _output = '$support/zic-dart-body-consumer-results.json';
  try {
    final payload = await File('${root.path}/fixture.js').writeAsString(
      "class DartBodyFixture extends ComicSource {name='Fixture';key='$_key';"
      "version='1';url='https://fixture.invalid';explore=[{title:'Fixture',"
      "type:'multiPageComicList',load:async(page)=>[]}];comic={onThumbnailLoad:"
      "(uri)=>({onResponse:async(input)=>input,modifyImage:'$_rotate'})};}",
    );
    final plugin = ExternalComicPluginCatalogEntry(
      format: ExternalComicPluginFormat.veneraJavaScript,
      pluginId: 'venera:dart-body-fixture', name: 'Fixture', version: '1',
      entrypoint: Uri.parse('https://fixture.invalid/fixture.js'),
      sources: const <ExternalComicPluginSource>[
        ExternalComicPluginSource(sourceId: 'venera:dart_body_fixture',
          externalId: _key, name: 'Fixture', language: 'en'),
      ],
    );
    final inspection = await VeneraJavaScriptInspector(
      requestedCapabilities: const <ExternalPluginCapability>{},
      payloads: CallbackExternalPluginPayloadLoader((_) async =>
        ExternalPluginPayloadFile(path: payload.path,
          byteLength: await payload.length())),
    ).inspect(plugin);
    final activation = VeneraExecutionRequest(
      plugin: plugin, payloadPath: payload.path,
      payloadByteLength: await payload.length(),
      payloadSha256: inspection.payloadSha256, sourceKey: _key,
      capabilities: const <ExternalPluginCapability>{},
      limits: const ExternalPluginRuntimeLimits(
        invocationTimeout: Duration(seconds: 60), maxConcurrentInvocations: 1,
        maxResponseBytes: 32 * 1024 * 1024,
      ),
    );
    final small = await _image(1024);
    final large = await _image(2048);
    await _normal(activation, small, false);
    await _normal(activation, large, true);
    for (final isolated in <bool>[false, true]) {
      for (final mode in <String>['body-dispose', 'stream-cancel', 'session-close']) {
        await _retire(activation, small, isolated, mode);
      }
    }
    await _sourceLoss(activation, small);
    await _record(<String, Object?>{
      'case': 'complete', 'status': 'passed', 'cases': 9,
      'production_modified': false, 'real_File_reads_only': true,
      'forced_future_delays': false,
    });
    _status.value = '验收通过';
  } on Object catch (error, stack) {
    await _record(<String, Object?>{
      'case': 'complete', 'status': 'failed',
      'error': error.toString(), 'stack': stack.toString(),
    });
    _status.value = '验收失败';
  } finally {
    await root.delete(recursive: true);
  }
}

void _require(bool condition, String reason) {
  if (!condition) throw StateError(reason);
}

Future<void> _record(Map<String, Object?> event) async {
  final row = <String, Object?>{'micros': _clock.elapsedMicroseconds, ...event};
  _events.add(row);
  debugPrint('ZIC_DART_BODY_EVENT ${jsonEncode(row)}');
  await File(_output).writeAsString(jsonEncode(_events), flush: true);
}

Future<Uint8List> _image(int width) async {
  final height = width + 1;
  final rgba = Uint8List(width * height * 4);
  var state = 39412;
  for (var i = 0; i < rgba.length; i += 4) {
    state = (state * 1664525 + 1013904223) & 0xffffffff;
    rgba[i] = state >> 16;
    rgba[i + 1] = state >> 8;
    rgba[i + 2] = state;
    rgba[i + 3] = 255;
  }
  final ready = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, width, height, ui.PixelFormat.rgba8888,
    ready.complete);
  final image = await ready.future;
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    _require(data != null, 'fixture PNG encoding failed');
    final bytes = data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    _require(bytes.length > 512 * 1024, 'fixture request did not cross packet limit');
    return bytes;
  } finally {
    image.dispose();
  }
}

class _Run {
  _Run(this.label) : tap = _FileTap();
  final String label;
  final _FileTap tap;
  final List<String> wire = <String>[];
  String? lease;
  int releases = 0;
  String? processId;
  late ExternalPluginRuntimeConnection connection;
  late ExternalPluginRuntimeBodyFile reference;
  late ComicResourceBody body;

  Future<void> open(VeneraExecutionRequest activation, Uint8List input,
      bool isolated) async {
    final messenger = _WireTap(ServicesBinding.instance.defaultBinaryMessenger, this);
    final backend = AndroidVeneraSandboxRuntimeBackend(channel: MethodChannel(
      'dev.zic/plugin_host_runtime_bridge', const StandardMethodCodec(), messenger));
    connection = await backend.activate(activation);
    final response = await connection.invoke(ExternalPluginRuntimeRequest(
      requestId: label, operation: ExternalPluginRuntimeOperation.transformResource,
      externalSourceId: _key, arguments: <String, Object?>{
        'uri': 'https://fixture.invalid/rotate.png', 'bytes': input,
        'bodyDelivery': 'sealed-file-v1',
        if (isolated) '__zicIsolatedModifyImage': _rotate,
      },
    ));
    _require(ExternalPluginRuntimeBodyFile.isBodyFile(response.payload),
      'negotiated output did not return a body: ${response.error?.code}');
    reference = ExternalPluginRuntimeBodyFile.fromMessage(response.payload);
    _require(reference.byteLength > 128 * 1024, 'response did not cross inline limit');
    _require(reference.authorityRevision ==
      'venera-runtime-transform-v1:${activation.payloadSha256}', 'authority changed');
    body = await (connection as BodyExternalPluginRuntimeConnection)
      .takeResourceBody(reference);
    _require(tap.file != null && lease == tap.file!.path,
      'actual claimed File was not observed');
    _require(File(lease!).existsSync(), 'claim disappeared before consumer read');
  }

  void checkReleased() {
    final file = tap.file!;
    _require(file.closed && !file.active && file.closes == 1,
      'read/close did not retire exactly once');
    _require(releases == 1 && !File(lease!).existsSync(),
      'native release did not remove exactly one lease');
    final close = file.timeline.indexOf('close-start');
    final release = file.timeline.indexOf('native-release-start');
    final exit = file.timeline.lastIndexOf('read-exit');
    _require(exit >= 0 && close > exit && release > close,
      'release or close preceded an admitted real read exit');
  }

  Map<String, Object?> proof() => <String, Object?>{
    'case': label, 'status': 'passed', 'body_bytes': reference.byteLength,
    'reads': tap.file!.reads, 'max_read_bytes': tap.file!.maxRead,
    'closes': tap.file!.closes, 'native_releases': releases,
    'lease_removed': !File(lease!).existsSync(),
    'read_close_release_order': tap.file!.timeline,
    'wire': wire,
  };
}

Future<void> _normal(VeneraExecutionRequest activation, Uint8List input,
    bool isolated) async {
  final run = _Run('normal-${isolated ? 'isolated' : 'canonical'}');
  await IOOverrides.runWithIOOverrides(() async {
    await run.open(activation, input, isolated);
    final digest = _Digest();
    await for (final chunk in run.body.open()) { digest.add(chunk); }
    _require(digest.length == run.reference.byteLength &&
      digest.fnv == run.reference.fnv64, 'Dart bounded read differs from sealed body');
    _require(run.tap.file!.maxRead <= 64 * 1024 && run.tap.file!.reads > 1,
      'Dart body was materialized by one whole-file read');
    run.checkReleased();
    await run.body.dispose();
    await run.connection.close();
    run.checkReleased();
    await _record(<String, Object?>{...run.proof(), 'bounded_digest_matches': true});
  }, run.tap);
}

Future<void> _retire(VeneraExecutionRequest activation, Uint8List input,
    bool isolated, String mode) async {
  final run = _Run('$mode-${isolated ? 'isolated' : 'canonical'}');
  await IOOverrides.runWithIOOverrides(() async {
    await run.open(activation, input, isolated);
    final file = run.tap.file!;
    file.armed = true;
    final failure = Completer<Object>();
    var delivered = 0;
    final subscription = run.body.open().listen((chunk) { delivered += chunk.length; },
      onError: (Object value) { if (!failure.isCompleted) failure.complete(value); });
    await file.started.future;
    _require(file.active, 'fixture missed the actual pending OS read; not a product defect');
    file.timeline.add('retirement-requested:$mode');
    Future<void> retirement;
    if (mode == 'body-dispose') {
      retirement = run.body.dispose();
      _require(identical(retirement, run.body.dispose()), 'dispose is not shared');
    } else if (mode == 'stream-cancel') {
      retirement = subscription.cancel();
    } else {
      subscription.pause();
      retirement = run.connection.close();
      _require(identical(retirement, run.connection.close()), 'close is not shared');
    }
    _require(!file.closed && run.releases == 0,
      'retirement acknowledged before pending read exit');
    await retirement.timeout(const Duration(seconds: 30));
    if (mode == 'body-dispose') {
      final error = await failure.future.timeout(const Duration(seconds: 10));
      _require(error is Failure && error.code == ErrorCode.cancelled,
        'dispose did not retire the pending consumer as cancellation');
    }
    await subscription.cancel();
    run.checkReleased();
    _require(delivered == 0, 'retired/paused consumer received late bytes');
    await run.connection.close();
    run.checkReleased();
    await _record(<String, Object?>{...run.proof(),
      'real_read_future_pending_at_retirement': true, 'delivered_bytes': delivered});
  }, run.tap);
}

Future<void> _sourceLoss(VeneraExecutionRequest activation, Uint8List input) async {
  final run = _Run('source-loss-during-Dart-consumption');
  await IOOverrides.runWithIOOverrides(() async {
    await run.open(activation, input, true);
    final process = await Process.run('/system/bin/pidof',
      <String>['dev.zic.zic:zic_plugin_runtime']);
    final sourcePid = int.parse((process.stdout as String).trim());
    final originalProcessId = run.processId;
    _require(sourcePid != pid && sourcePid > 0, 'actual separate Service PID missing');
    final iterator = StreamIterator<List<int>>(run.body.open());
    final digest = _Digest();
    _require(await iterator.moveNext(), 'claimed body had no first chunk');
    digest.add(iterator.current);
    _require(Process.killPid(sourcePid, ProcessSignal.sigkill), 'source kill failed');
    final messenger = _WireTap(ServicesBinding.instance.defaultBinaryMessenger, run);
    final replacement = await AndroidVeneraSandboxRuntimeBackend(channel: MethodChannel(
      'dev.zic/plugin_host_runtime_bridge', const StandardMethodCodec(), messenger))
      .activate(activation);
    final newProcess = await Process.run('/system/bin/pidof',
      <String>['dev.zic.zic:zic_plugin_runtime']);
    final replacementPid = int.parse((newProcess.stdout as String).trim());
    _require(replacementPid != sourcePid && replacementPid != pid &&
      run.processId != null && run.processId != originalProcessId,
      'actual source PID/process generation was not replaced');
    _require(File(run.lease!).existsSync(), 'source restart removed an admitted Dart lease');
    while (await iterator.moveNext()) { digest.add(iterator.current); }
    await iterator.cancel();
    _require(digest.length == run.reference.byteLength && digest.fnv == run.reference.fnv64,
      'source loss/restart changed admitted Dart body');
    run.checkReleased();
    String? staleCloseCode;
    try { await run.connection.close(); }
    on PlatformException catch (error) { staleCloseCode = error.code; }
    await replacement.close();
    run.checkReleased();
    await _record(<String, Object?>{...run.proof(),
      'host_pid': pid, 'old_source_pid': sourcePid,
      'replacement_source_pid': replacementPid,
      'process_generation_changed': run.processId != originalProcessId,
      'actual_source_death_and_reactivation': true,
      'bounded_digest_matches_after_source_loss': true,
      'stale_session_close_code': staleCloseCode});
  }, run.tap);
}

class _Digest {
  int length = 0;
  int _fnv = 0xcbf29ce484222325;
  void add(List<int> bytes) {
    length += bytes.length;
    for (final value in bytes) { _fnv = (_fnv ^ value) * 0x100000001b3; }
  }
  String get fnv => _fnv.toRadixString(16).padLeft(16, '0');
}

final class _FileTap extends IOOverrides {
  _ObservedRandomAccessFile? file;
  @override
  File createFile(String path) {
    final actual = super.createFile(path);
    return path.endsWith('.lease') ? _ObservedFile(actual, this) : actual;
  }
}

class _ObservedFile implements File {
  _ObservedFile(this.actual, this.tap);
  final File actual;
  final _FileTap tap;
  @override
  String get path => actual.path;
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      tap.file = _ObservedRandomAccessFile(await actual.open(mode: mode), path);
  @override
  bool existsSync() => actual.existsSync();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected fixture File method ${invocation.memberName}');
}

class _ObservedRandomAccessFile implements RandomAccessFile {
  _ObservedRandomAccessFile(this.actual, this.path);
  final RandomAccessFile actual;
  @override
  final String path;
  final started = Completer<void>();
  final timeline = <String>[];
  bool armed = false;
  bool active = false;
  bool closed = false;
  int reads = 0;
  int closes = 0;
  int maxRead = 0;
  @override
  Future<int> length() => actual.length();
  @override
  Future<RandomAccessFile> setPosition(int position) => actual.setPosition(position);
  @override
  Future<Uint8List> read(int count) {
    reads++;
    maxRead = count > maxRead ? count : maxRead;
    active = true;
    timeline.add('read-start');
    final pending = actual.read(count).whenComplete(() {
      active = false;
      timeline.add('read-exit');
    });
    if (armed) { armed = false; started.complete(); }
    return pending;
  }
  @override
  Future<void> close() async {
    _require(!active, 'actual RAF closed with physical read still pending');
    closes++;
    timeline.add('close-start');
    await actual.close();
    closed = true;
    timeline.add('close-exit');
  }
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected fixture RAF method ${invocation.memberName}');
}

class _WireTap implements BinaryMessenger {
  _WireTap(this.actual, this.run);
  final BinaryMessenger actual;
  final _Run run;
  static const codec = StandardMethodCodec();
  @override
  Future<ByteData?> send(String channel, ByteData? message) async {
    final method = codec.decodeMethodCall(message!);
    run.wire.add('${method.method}:start');
    if (method.method == 'releaseExternalRuntimeResourceBody') {
      final file = run.tap.file!;
      _require(file.closed && !file.active, 'native release preceded Dart RAF close');
      file.timeline.add('native-release-start');
      run.releases++;
    }
    final reply = await actual.send(channel, message);
    if (method.method == 'activateVeneraRuntime' && reply != null) {
      final activation = codec.decodeEnvelope(reply) as Map;
      run.processId = activation['processId'] as String;
    }
    if (method.method == 'claimExternalRuntimeResourceBody' && reply != null) {
      run.lease = codec.decodeEnvelope(reply) as String;
    }
    run.wire.add('${method.method}:exit');
    return reply;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected fixture messenger ${invocation.memberName}');
}
