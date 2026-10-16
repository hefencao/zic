import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:sessions/sessions.dart' as scheduling;
import 'package:downloads_bridge/downloads_bridge.dart';

void main() {
  late HttpServer server;
  late scheduling.NetLane lane;
  late Dio client;
  final responses = <HttpResponse>[];

  setUp(() async {
    lane = scheduling.NetLane(maxActive: 1);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      responses.add(request.response);
      request.response.bufferOutput = false;
      request.response.write('first');
      await request.response.flush();
    });
    client = Dio()..httpClientAdapter = ScheduledDioAdapter(lane);
  });

  tearDown(() async {
    client.close(force: true);
    lane.cancelAll();
    await lane.idle().timeout(const Duration(seconds: 3));
    for (final response in responses) {
      unawaited(response.close().catchError((Object _) {}));
    }
    responses.clear();
    await server.close(force: true);
  });

  String endpoint() => 'http://${server.address.address}:${server.port}/';

  test('NetLane holds the response until the consumer exits its body stream', () async {
    final response = await client.httpClientAdapter.fetch(
      RequestOptions(path: endpoint()), null, null);
    expect(lane.active, 1);
    final data = <int>[];
    final first = Completer<void>();
    final subscription = response.stream.listen((bytes) {
      data.addAll(bytes);
      if (!first.isCompleted) first.complete();
    });
    await first.future;
    expect(String.fromCharCodes(data), 'first');
    expect(lane.active, 1);
    await subscription.cancel();
    await lane.idle().timeout(const Duration(seconds: 3));
    expect(lane.active, 0);
  });

  test('queued cancellation and client close complete without opening a socket', () async {
    final hold = Completer<void>();
    lane.submit(key: 'hold', priority: 1000, task: (_) => hold.future);
    final token = CancelToken();
    final cancelled = client.get<dynamic>(endpoint(), cancelToken: token);
    final cancellation = expectLater(cancelled, throwsA(isA<DioException>()));
    await Future<void>.delayed(Duration.zero);
    token.cancel();
    await cancellation;
    final queued = client.get<dynamic>(endpoint());
    final closed = expectLater(queued, throwsA(isA<DioException>()));
    await Future<void>.delayed(Duration.zero);
    client.close(force: true);
    await closed.timeout(const Duration(seconds: 3));
    hold.complete();
    await lane.idle();
    expect(responses, isEmpty);
  });

  test('scheduler cancellation aborts the actual response before capacity is reused', () async {
    final response = await client.get<ResponseBody>(endpoint(),
      options: Options(responseType: ResponseType.stream));
    final body = expectLater(response.data!.stream.drain<void>(), throwsA(isA<DioException>()));
    expect(lane.active, 1);
    lane.cancelAll();
    await body.timeout(const Duration(seconds: 3));
    await lane.idle().timeout(const Duration(seconds: 3));
    expect(lane.active, 0);
  });
}
