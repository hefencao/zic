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

// Test-only actual source request-plan / NetLane / Android runtime acceptance.
// The original scheduler control, canonical gate and WebView remain authoritative.
const _key = 'zic_priority_runtime_fixture';
const _durations = <String, int>{
  'promote-active': 10000, 'promote-waiter': 50,
  'old-current': 10000, 'new-current': 50,
  'ordinary-active': 700, 'ordinary-waiter': 50,
  'rank-active': 600, 'rank-first': 50, 'rank-second': 50,
  'queue-active': 500, 'queue-cancelled': 50,
  'floor-active': 10000, 'floor-waiter': 50,
};
final _events = <Map<String, Object?>>[];
final _clock = Stopwatch()..start();
late String _output;

@pragma('vm:entry-point')
Future<void> zicExternalPluginRuntimeServiceMain() =>
    app_entrypoint.zicExternalPluginRuntimeServiceMain();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: Scaffold(
    body: Center(child: Text('Venera priority runtime 验收')),
  )));
  await waitForFirstFlutterUiDisplayed();
  await attachAndroidPlugin('network_bridge');
  await attachAndroidPlugin('plugin_host_bridge');
  final support = await getStartupApplicationSupportPath();
  _require(support != null, 'native support path missing');
  _output = '$support/zic-venera-priority-runtime-results.json';
  final root = await Directory.systemTemp.createTemp('zic-priority-runtime-');
  final coordinator = DownloadResourceCoordinator();
  final wire = _Wire(ServicesBinding.instance.defaultBinaryMessenger);
  ExternalPluginRuntimeSession? session;
  HttpServer? marker;
  try {
    final registrations = <String, Completer<Map<String, Object?>>>{};
    marker = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    marker.listen((request) async {
      final state = (jsonDecode(await utf8.decoder.bind(request).join()) as Map)
          .cast<String, Object?>();
      request.response.headers.contentType = ContentType.json;
      request.response.write('{}');
      await request.response.close();
      final signal = registrations.putIfAbsent(state['label'] as String,
        () => Completer<Map<String, Object?>>());
      if (!signal.isCompleted) signal.complete(state);
    });
    final images = _durations.entries.map((e) =>
      'https://fixture.invalid/page?label=${e.key}&duration=${e.value}').toList();
    final payload = await File('${root.path}/fixture.js').writeAsString(
      _script.replaceAll('__MARKER__',
        'http://127.0.0.1:${marker.port}/hook-registered')
        .replaceAll('__PAGES__', jsonEncode(images)), flush: true,
    );
    final plugin = ExternalComicPluginCatalogEntry(
      format: ExternalComicPluginFormat.veneraJavaScript,
      pluginId: 'venera:zic-priority-runtime-fixture', name: 'Priority fixture', version: '1',
      entrypoint: Uri.parse('https://fixture.invalid/priority.js'),
      sources: const <ExternalComicPluginSource>[
        ExternalComicPluginSource(sourceId: 'venera:zic_priority_runtime_fixture',
          externalId: _key, name: 'Priority fixture', language: 'en'),
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
    final comicSource = session.sources.single as ControlledComicSource;
    final comic = await comicSource.loadComicControlled(_comicId('fixture'));
    final chapter = await comicSource.loadChapterControlled(comic.chapters.single.chapterId);
    _require(chapter.pages.length == _durations.length, 'page fixture projection incomplete');
    final pages = <String, Uri>{};
    final entries = _durations.keys.toList();
    for (var i = 0; i < chapter.pages.length; i++) {
      _require(chapter.pages[i].uri.scheme == 'venera-resource',
        'test page did not use a production source locator');
      pages[entries[i]] = chapter.pages[i].uri;
    }
    final h = _Harness(coordinator, session.sources.single as
      ControlledResolvableComicResourceSource, pages, wire, registrations);
    final process = await Process.run('/system/bin/pidof',
      <String>['dev.zic.zic:zic_plugin_runtime']);
    final sourcePid = int.parse((process.stdout as String).trim());
    _require(sourcePid != pid, 'runtime is not a separate Android process');

    var begin = wire.events.length;
    var cancelCount = wire.cancellations;
    var active = h.submit('promote-active', 760);
    final first = await h.registered(active.label);
    var waiting = h.submit('promote-waiter', 780);
    await waiting.started.future;
    final changes = <Map<String, Object?>>[];
    for (final rank in <int>[900, 780, 900]) {
      h.update(waiting, rank);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      _require(wire.cancellations == cancelCount && !waiting.done.isCompleted &&
        !active.done.isCompleted, 'non-current jitter cancelled an active request-plan');
      changes.add(<String, Object?>{'priority': rank, 'cancel_calls': wire.cancellations,
        'micros': _clock.elapsedMicroseconds});
    }
    var changedAt = _clock.elapsedMicroseconds;
    h.update(waiting, 1000);
    final activeResult = await h.join(active);
    final joinedAt = _clock.elapsedMicroseconds;
    final waitingResult = await h.join(waiting);
    _require(activeResult['code'] == 'cancelled' && wire.cancellations == cancelCount + 1 &&
      joinedAt - changedAt < 500000 && active.control?.cancelled == false,
      'current promotion did not cancel and physically join exactly one old invocation');
    h.requirePassed(waitingResult);
    await _record(<String, Object?>{'case': 'waiter-jitter-then-current-promotion',
      'status': 'passed', 'registered': first, 'priority_changes': changes,
      'promotion_to_joined_exit_micros': joinedAt - changedAt,
      'active': activeResult, 'incoming': waitingResult,
      'wire': wire.events.sublist(begin)});

    begin = wire.events.length; cancelCount = wire.cancellations;
    active = h.submit('old-current', 1000);
    await h.registered(active.label);
    waiting = h.submit('new-current', 1000);
    await waiting.started.future;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    _require(wire.cancellations == cancelCount && !waiting.done.isCompleted,
      'equal current pressure cancelled before old current demotion');
    changedAt = _clock.elapsedMicroseconds;
    h.update(active, 900);
    final demoted = await h.join(active);
    final demotionJoined = _clock.elapsedMicroseconds;
    final newCurrent = await h.join(waiting);
    _require(demoted['code'] == 'cancelled' && wire.cancellations == cancelCount + 1 &&
      demotionJoined - changedAt < 500000 && active.control?.cancelled == false,
      'old current demotion did not transfer through one physical cancellation');
    h.requirePassed(newCurrent);
    await _record(<String, Object?>{'case': 'old-current-demotion-with-current-waiter',
      'status': 'passed', 'demotion_to_joined_exit_micros': demotionJoined - changedAt,
      'active': demoted, 'incoming': newCurrent, 'wire': wire.events.sublist(begin)});

    begin = wire.events.length; cancelCount = wire.cancellations;
    active = h.submit('ordinary-active', 820);
    await h.registered(active.label);
    waiting = h.submit('ordinary-waiter', 780);
    await waiting.started.future;
    h.update(active, 600);
    for (final rank in <int>[900, 780, 900]) {
      h.update(waiting, rank);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      _require(wire.cancellations == cancelCount && !active.done.isCompleted,
        'ordinary demotion or viewport jitter caused irreversible cancellation');
    }
    final ordinary = await h.join(active);
    final ordinaryWaiter = await h.join(waiting);
    h.requirePassed(ordinary); h.requirePassed(ordinaryWaiter);
    _require(wire.cancellations == cancelCount, 'ordinary demotion cancelled on transfer');
    await _record(<String, Object?>{'case': 'ordinary-demotion-and-jitter-preserve-active',
      'status': 'passed', 'active': ordinary, 'waiting': ordinaryWaiter,
      'wire': wire.events.sublist(begin)});

    begin = wire.events.length; cancelCount = wire.cancellations;
    active = h.submit('rank-active', 1000);
    await h.registered(active.label);
    final firstRank = h.submit('rank-first', 780);
    final secondRank = h.submit('rank-second', 820);
    await Future.wait(<Future<void>>[firstRank.started.future, secondRank.started.future]);
    h.update(firstRank, 900); h.update(secondRank, 800);
    final blocker = await h.join(active);
    final latestFirst = await h.join(firstRank);
    final latestSecond = await h.join(secondRank);
    h.requirePassed(blocker); h.requirePassed(latestFirst); h.requirePassed(latestSecond);
    final firstStart = (await h.registered('rank-first'))['hook_started_micros'] as num;
    final secondStart = (await h.registered('rank-second'))['hook_started_micros'] as num;
    _require(firstStart < secondStart && wire.cancellations == cancelCount,
      'gate used stale priority or FIFO at physical permit transfer');
    await _record(<String, Object?>{'case': 'permit-transfer-uses-live-priority',
      'status': 'passed', 'active': blocker, 'first': latestFirst, 'second': latestSecond,
      'hook_start_order': <String>['rank-active', 'rank-first', 'rank-second'],
      'first_hook_started_micros': firstStart, 'second_hook_started_micros': secondStart,
      'wire': wire.events.sublist(begin)});

    begin = wire.events.length; cancelCount = wire.cancellations;
    active = h.submit('queue-active', 1000);
    await h.registered(active.label);
    waiting = h.submit('queue-cancelled', 780);
    await waiting.started.future;
    _require(coordinator.networkLane.cancel(waiting.key), 'queued control cancellation lost');
    final queued = await h.join(waiting);
    final unaffected = await h.join(active);
    h.requirePassed(unaffected);
    _require(queued['code'] == 'cancelled' && wire.cancellations == cancelCount &&
      registrations['queue-cancelled']?.isCompleted != true,
      'cancelled gate waiter entered WebView or damaged active source work');
    await _record(<String, Object?>{'case': 'cancelled-gate-waiter-never-enters-WebView',
      'status': 'passed', 'cancelled': queued, 'active': unaffected,
      'wire': wire.events.sublist(begin)});

    begin = wire.events.length; cancelCount = wire.cancellations;
    active = h.submit('floor-active', 700);
    await h.registered(active.label);
    changedAt = _clock.elapsedMicroseconds;
    waiting = h.submit('floor-waiter', 780);
    final previous = await h.join(active);
    final previousJoined = _clock.elapsedMicroseconds;
    final previousPlan = await h.join(waiting);
    h.requirePassed(previousPlan);
    _require(previous['code'] == 'cancelled' && wire.cancellations == cancelCount + 1 &&
      previousJoined - changedAt < 500000,
      'controlled previous pressure stopped observing original forty-point boundary');
    await _record(<String, Object?>{'case': 'previous-floor-original-rank-difference',
      'status': 'passed', 'admission_to_joined_exit_micros': previousJoined - changedAt,
      'active': previous, 'incoming': previousPlan, 'wire': wire.events.sublist(begin)});

    await coordinator.networkLane.idle();
    await session.close(); session = null;
    await marker.close(force: true); marker = null;
    await root.delete(recursive: true);
    _require(wire.maxActive == 1 && wire.active == 0 && wire.cancellations == 3,
      'fixture bypassed canonical invocation ownership');
    _require(registrations.length == 12, 'source hook HTTP count changed');
    final markerStates = await Future.wait(registrations.values.map((c) => c.future));
    _require(markerStates.every((s) => s['sameRequestWaiters'] == 1 &&
      s['requestId'] is String), 'source timer registration proof missing');
    await _record(<String, Object?>{'case': 'complete', 'status': 'passed', 'cases': 6,
      'app_pid': pid, 'source_pid': sourcePid, 'wire': wire.events,
      'max_canonical_invocations': wire.maxActive, 'cancellation_calls': wire.cancellations,
      'actual_hook_markers': registrations.length, 'source_marker_states': markerStates,
      'test_root_removed': !root.existsSync(),
      'test_owners_closed': true, 'user_library_settings_or_sources_opened': false});
  } on Object catch (error, stack) {
    await _record(<String, Object?>{'case': 'complete', 'status': 'failed',
      'error': '$error', 'stack': '$stack'});
  } finally {
    coordinator.networkLane.cancelAll();
    await coordinator.networkLane.idle();
    await session?.close();
    await marker?.close(force: true);
    if (root.existsSync()) await root.delete(recursive: true);
  }
}

final class _Run {
  _Run(this.label);
  final String label;
  String get key => 'priority-fixture:$label';
  final started = Completer<void>();
  final done = Completer<Map<String, Object?>>();
  TaskControl? control;
}

final class _Harness {
  _Harness(this.coordinator, this.source, this.pages, this.wire, this.registrations);
  final DownloadResourceCoordinator coordinator;
  final ControlledResolvableComicResourceSource source;
  final Map<String, Uri> pages;
  final _Wire wire;
  final Map<String, Completer<Map<String, Object?>>> registrations;

  _Run submit(String label, int rank) {
    final run = _Run(label);
    final accepted = coordinator.networkLane.submit(key: run.key, priority: rank,
      task: (control) async {
        run.control = control;
        final begin = _clock.elapsedMicroseconds;
        try {
          final operation = source.resolveResourceControlled(pages[label]!, control: control);
          run.started.complete();
          final request = await operation;
          run.done.complete(<String, Object?>{'label': label, 'status': 'passed',
            'uri': '${request.uri}', 'diagnostics': request.diagnostics,
            'started_micros': begin, 'joined_micros': _clock.elapsedMicroseconds});
        } on Object catch (error) {
          if (!run.started.isCompleted) run.started.complete();
          run.done.complete(<String, Object?>{'label': label, 'status': 'failed',
            'code': error is Failure ? error.code.name : '${error.runtimeType}',
            'error': '$error', 'started_micros': begin,
            'joined_micros': _clock.elapsedMicroseconds});
        }
      });
    _require(accepted, 'scheduler submission lost');
    return run;
  }

  Future<Map<String, Object?>> registered(String label) => registrations
    .putIfAbsent(label, () => Completer<Map<String, Object?>>()).future
    .timeout(const Duration(seconds: 5));

  void update(_Run run, int rank) {
    _require(coordinator.networkLane.updatePriority(run.key, rank) &&
      run.control?.priority == rank, 'live NetLane priority did not reach source control');
  }

  Future<Map<String, Object?>> join(_Run run) async {
    final result = await run.done.future.timeout(const Duration(seconds: 5));
    await coordinator.networkLane.idleKeys(<String>[run.key]);
    return result;
  }

  void requirePassed(Map<String, Object?> result) {
    _require(result['status'] == 'passed' && result['uri'] ==
      'https://fixture.invalid/resolved/${result['label']}', 'request-plan result changed');
    final diagnostics = result['diagnostics'] as Map;
    _require(diagnostics['sourcePlanGateWaitMicros'] is int &&
      diagnostics['sourcePlanRuntimeInvocationMicros'] is int &&
      diagnostics['sourcePlanHookMicros'] is int &&
      diagnostics['sourcePlanBridgeNetworkCalls'] == 1 &&
      diagnostics['sourcePlanBridgeNetworkOriginCalls'] == 1 &&
      diagnostics['sourcePlanBridgeNetworkCacheHits'] == 0,
      'request-plan observations did not include the actual source hook/network call');
  }
}

Future<void> _record(Map<String, Object?> event) async {
  _events.add(<String, Object?>{'micros': _clock.elapsedMicroseconds, ...event});
  debugPrint('ZIC_PRIORITY_RUNTIME_EVENT ${jsonEncode(_events.last)}');
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
class PriorityRuntimeFixture extends ComicSource {
 key="zic_priority_runtime_fixture"; name="Priority fixture"; version="1";
 url="https://fixture.invalid";
 explore=[{title:"Fixture",type:"multiPageComicList",load:async()=>[]}];
 comic={loadInfo:async()=>({title:"Priority fixture",chapters:{fixture:"Fixture"}}),
  loadEp:async()=>__PAGES__,
  onImageLoad:async(original)=>{
   const query=new URL(original).searchParams,label=query.get("label");
   const duration=Number(query.get("duration")),requestId=__zicActiveRequestId;
   const started=performance.now();
   const pending=sendMessage({method:"delay",time:duration})
    .then(()=>({resolved:true}),error=>({error:String(error)}));
   await Network.post("__MARKER__",{"Content-Type":"application/json","cache-time":"no"},
    JSON.stringify({label,requestId,duration,
      sameRequestWaiters:__zicDelayWaiters.get(requestId)?.size||0,
      hook_started_micros:Math.round(started*1000)}));
   const timer=await pending;if(timer.error)throw new Error(timer.error);
   return {url:"https://fixture.invalid/resolved/"+label,headers:{"X-Fixture":label}};
  }};
}
''';
