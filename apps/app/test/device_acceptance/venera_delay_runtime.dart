import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:downloads/downloads.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:plugin_host/plugin_host.dart';
import 'package:plugin_host_bridge/plugin_host_bridge.dart';
import 'package:zic/main.dart' as app_entrypoint;
import 'package:zic/startup_platform.dart';

// Test-only actual source/Service/Binder/WebView delay and scheduler cancellation.
// A source-created foreign requestId timer tests the primitive's scope without
// creating a second canonical invocation or replacing production scheduling.
const _key = 'zic_delay_runtime_fixture';
final _events = <Map<String, Object?>>[];
final _clock = Stopwatch()..start();
late String _output;

@pragma('vm:entry-point')
Future<void> zicExternalPluginRuntimeServiceMain() =>
    app_entrypoint.zicExternalPluginRuntimeServiceMain();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: Scaffold(
    body: Center(child: Text('Venera delay runtime 验收')),
  )));
  await waitForFirstFlutterUiDisplayed();
  await attachAndroidPlugin('network_bridge');
  await attachAndroidPlugin('plugin_host_bridge');
  final support = await getStartupApplicationSupportPath();
  _require(support != null, 'native support path missing');
  _output = '$support/zic-venera-delay-runtime-results.json';
  final root = await Directory.systemTemp.createTemp('zic-delay-runtime-');
  final coordinator = DownloadResourceCoordinator();
  final wire = _Wire(ServicesBinding.instance.defaultBinaryMessenger);
  ExternalPluginRuntimeSession? session;
  HttpServer? marker;
  try {
    final registered = Completer<Map<String, Object?>>();
    marker = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    marker.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      final state = (jsonDecode(body) as Map).cast<String, Object?>();
      request.response.headers.contentType = ContentType.json;
      request.response.write('{}');
      await request.response.close();
      if (!registered.isCompleted) registered.complete(state);
    });
    final payload = await File('${root.path}/fixture.js').writeAsString(
      _script.replaceAll('__MARKER__',
        'http://127.0.0.1:${marker.port}/timers-registered'), flush: true,
    );
    final plugin = ExternalComicPluginCatalogEntry(
      format: ExternalComicPluginFormat.veneraJavaScript,
      pluginId: 'venera:zic-delay-runtime-fixture', name: 'Delay fixture', version: '1',
      entrypoint: Uri.parse('https://fixture.invalid/delay.js'),
      sources: const <ExternalComicPluginSource>[
        ExternalComicPluginSource(sourceId: 'venera:zic_delay_runtime_fixture',
          externalId: _key, name: 'Delay fixture', language: 'en'),
      ],
    );
    final inspection = await VeneraJavaScriptInspector(
      payloads: CallbackExternalPluginPayloadLoader((_) async =>
        ExternalPluginPayloadFile(path: payload.path,
          byteLength: await payload.length())),
    ).inspect(plugin);
    const limits = ExternalPluginRuntimeLimits(
      invocationTimeout: Duration(seconds: 30), maxConcurrentInvocations: 1,
      maxResponseBytes: 1024 * 1024,
    );
    final connection = await AndroidVeneraSandboxRuntimeBackend(channel: MethodChannel(
      'dev.zic/plugin_host_runtime_bridge', const StandardMethodCodec(), wire,
    )).activate(VeneraExecutionRequest(
      plugin: plugin, payloadPath: payload.path,
      payloadByteLength: await payload.length(),
      payloadSha256: inspection.payloadSha256, sourceKey: _key,
      capabilities: const <ExternalPluginCapability>{ExternalPluginCapability.network},
      limits: limits,
    ));
    session = ExternalPluginRuntimeSession(
      plugin: plugin, connection: connection, limits: limits,
    );
    final source = session.sources.single as ControlledComicSource;
    final process = await Process.run('/system/bin/pidof',
      <String>['dev.zic.zic:zic_plugin_runtime']);
    final sourcePid = int.parse((process.stdout as String).trim());
    _require(sourcePid != pid, 'runtime is not a separate Android process');
    Future<Map<String, Object?>> load(String mode) => _withLane(
      coordinator, mode, (control) async {
        final manifest = await source.loadComicControlled(_comicId(mode), control: control);
        return (jsonDecode(manifest.comic.description!) as Map)
            .cast<String, Object?>();
      },
    );
    for (final mode in <String>['normal', 'negative', 'same-request-two']) {
      final result = await load(mode);
      final requested = result['requested'] as int;
      final elapsed = (result['elapsedMillis'] as num).toDouble();
      _require(elapsed >= requested && elapsed < requested + 2500,
        'normal WebView delay timing outside observation boundary');
      _require(result['waitersAfter'] == 0 && result['resolved'] ==
        (mode == 'same-request-two' ? 2 : 1), 'normal timer did not retire');
      await _record(<String, Object?>{
        'case': mode, 'status': 'passed', 'proof': result,
      });
    }
    final cancelled = Completer<void>();
    final cancelKey = 'delay-fixture:cancel';
    final errors = <Failure>[];
    coordinator.networkLane.submit(key: cancelKey, priority: 1000,
      task: (control) async {
        try {
          await source.loadComicControlled(_comicId('cancel'), control: control);
          cancelled.completeError(StateError('cancelled delay resolved'));
        } on Failure catch (error) {
          errors.add(error);
          cancelled.complete();
        } on Object catch (error, stack) {
          cancelled.completeError(error, stack);
        }
      },
    );
    final signal = await registered.future.timeout(const Duration(seconds: 10));
    _require(signal['sameRequestWaiters'] == 2 && signal['peerWaiters'] == 1,
      'cancel arrived before actual main/foreign timers were registered');
    final cancelAt = _clock.elapsedMicroseconds;
    coordinator.networkLane.cancel(cancelKey);
    await cancelled.future.timeout(const Duration(seconds: 3));
    await coordinator.networkLane.idleKeys(<String>[cancelKey]);
    final joinedAt = _clock.elapsedMicroseconds;
    _require(errors.length == 1 && errors.single.code == ErrorCode.cancelled,
      'scheduler cancellation was not preserved through the runtime');
    _require(joinedAt - cancelAt < 500000,
      'delay cancellation did not reject and physically join promptly');
    final snapshot = await load('snapshot');
    _require(snapshot['mainRejected'] == 2 && snapshot['mainResolved'] == 0 &&
      snapshot['mainWaiters'] == 0 && snapshot['peerStatus'] == 'waiting' &&
      snapshot['peerWaiters'] == 1, 'cancellation damaged a foreign timer');
    await _record(<String, Object?>{
      'case': 'cancel-two-preserve-peer', 'status': 'passed',
      'registered': signal, 'proof': snapshot,
      'cancel_to_joined_exit_micros': joinedAt - cancelAt,
      'typed_failure': errors.single.code.name,
    });
    final peer = await load('join-peer');
    _require(peer['peerStatus'] == 'resolved' && peer['peerWaiters'] == 0 &&
      (peer['peerElapsedMillis'] as num) >= 1800 && peer['mainRejected'] == 2 &&
      peer['mainResolved'] == 0, 'foreign timer failed or resolved prematurely');
    await _record(<String, Object?>{
      'case': 'peer-normal-completion-after-cancel', 'status': 'passed',
      'proof': peer,
    });
    final next = await load('after-cancel');
    _require(next['resolved'] == 1 && next['waitersAfter'] == 0 &&
      (next['elapsedMillis'] as num) >= 50, 'next invocation lost timer usability');
    await _record(<String, Object?>{
      'case': 'next-canonical-invocation-after-cancel', 'status': 'passed',
      'proof': next,
    });
    await session.close();
    session = null;
    await marker.close(force: true);
    marker = null;
    await root.delete(recursive: true);
    _require(wire.maxActive == 1 && wire.active == 0 && wire.cancellations == 1,
      'test bypassed canonical invocation ownership');
    await _record(<String, Object?>{
      'case': 'complete', 'status': 'passed', 'cases': 6,
      'app_pid': pid, 'source_pid': sourcePid,
      'wire': wire.events, 'max_canonical_invocations': wire.maxActive,
      'cancellation_calls': wire.cancellations,
      'test_root_removed': !root.existsSync(), 'test_owners_closed': true,
      'user_library_settings_or_sources_opened': false,
    });
  } on Object catch (error, stack) {
    await _record(<String, Object?>{
      'case': 'complete', 'status': 'failed', 'error': '$error', 'stack': '$stack',
    });
  } finally {
    await session?.close();
    await marker?.close(force: true);
    if (root.existsSync()) await root.delete(recursive: true);
  }
}

Future<T> _withLane<T>(DownloadResourceCoordinator coordinator, String label,
    Future<T> Function(TaskControl) run) async {
  final result = Completer<T>();
  final key = 'delay-fixture:$label';
  coordinator.networkLane.submit(key: key, priority: 1000, task: (control) async {
    try { result.complete(await run(control)); }
    on Object catch (error, stack) { result.completeError(error, stack); }
  });
  try { return await result.future; }
  finally { await coordinator.networkLane.idleKeys(<String>[key]); }
}

Future<void> _record(Map<String, Object?> event) async {
  _events.add(<String, Object?>{'micros': _clock.elapsedMicroseconds, ...event});
  debugPrint('ZIC_DELAY_RUNTIME_EVENT ${jsonEncode(_events.last)}');
  await File(_output).writeAsString(jsonEncode(_events), flush: true);
}

void _require(bool condition, String reason) {
  if (!condition) throw StateError(reason);
}

String _comicId(String rawId) {
  final bytes = utf8.encode(jsonEncode(<String, Object?>{'v': 2, 'id': rawId}));
  final encoded = base64UrlEncode(bytes).replaceAll('=', '');
  return 'venera:comic:$encoded';
}

final class _Wire implements BinaryMessenger {
  _Wire(this.delegate);
  final BinaryMessenger delegate;
  final codec = const StandardMethodCodec();
  final events = <Map<String, Object?>>[];
  int active = 0;
  int maxActive = 0;
  int cancellations = 0;

  @override
  Future<ByteData?> send(String channel, ByteData? message) async {
    MethodCall? call;
    if (channel == 'dev.zic/plugin_host_runtime_bridge' && message != null) {
      call = codec.decodeMethodCall(message);
      if (call.method == 'invokeExternalRuntime') {
        active++;
        if (active > maxActive) maxActive = active;
      } else if (call.method == 'cancelExternalRuntime') {
        cancellations++;
      }
      events.add(<String, Object?>{
        'method': call.method, 'phase': 'start',
        'micros': _clock.elapsedMicroseconds, 'arguments': call.arguments,
      });
    }
    try { return await delegate.send(channel, message); }
    finally {
      if (call?.method == 'invokeExternalRuntime') active--;
      if (call != null) {
        events.add(<String, Object?>{
          'method': call.method, 'phase': 'exit', 'micros': _clock.elapsedMicroseconds,
        });
      }
    }
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

const _script = r'''
let timerProof={}, peerPromise=null;
const now=()=>performance.now();
function timerState(){return {...timerProof,
 mainWaiters:__zicDelayWaiters.get(timerProof.mainRequestId)?.size||0,
 peerWaiters:__zicDelayWaiters.get(timerProof.peerRequestId)?.size||0};}
class DelayRuntimeFixture extends ComicSource {
 key="zic_delay_runtime_fixture"; name="Delay fixture"; version="1";
 url="https://fixture.invalid";
 explore=[{title:"Fixture",type:"multiPageComicList",load:async()=>[]}];
 comic={loadInfo:async(id)=>{
  let proof;
  if(id==="snapshot")proof=timerState();
  else if(id==="join-peer"){await peerPromise;proof=timerState();}
  else if(id==="cancel"){
   timerProof={mainRequestId:__zicActiveRequestId,peerRequestId:"fixture-foreign-peer",
    mainRejected:0,mainResolved:0,peerStatus:"waiting",peerStarted:now()};
   peerPromise=sendMessage({method:"delay",time:1800,requestId:timerProof.peerRequestId})
    .then(()=>{timerProof.peerStatus="resolved";timerProof.peerElapsedMillis=now()-timerProof.peerStarted;},
      e=>{timerProof.peerStatus="rejected";timerProof.peerError=String(e);});
   const pending=[10000,12000].map(time=>sendMessage({method:"delay",time})
    .then(()=>{timerProof.mainResolved++;return "resolved";},
      e=>{timerProof.mainRejected++;return String(e);}));
   await Network.post("__MARKER__",{"Content-Type":"application/json","cache-time":"no"},
    JSON.stringify({sameRequestWaiters:__zicDelayWaiters.get(timerProof.mainRequestId)?.size||0,
      peerWaiters:__zicDelayWaiters.get(timerProof.peerRequestId)?.size||0}));
   await Promise.all(pending);throw new Error("uncancelled long delay unexpectedly completed");
  }else{
   const requested=id==="negative"?0:id==="same-request-two"?140:id==="after-cancel"?50:180;
   const times=id==="same-request-two"?[40,140]:[id==="negative"?-17:requested];
   const started=now(),requestId=__zicActiveRequestId;
   await Promise.all(times.map(time=>sendMessage({method:"delay",time})));
   proof={requested,elapsedMillis:now()-started,resolved:times.length,
    waitersAfter:__zicDelayWaiters.get(requestId)?.size||0};
  }
  return {title:"Delay proof",chapters:{fixture:"Fixture"},description:JSON.stringify(proof)};
 }};
}
''';
