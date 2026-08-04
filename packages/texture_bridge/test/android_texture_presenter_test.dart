import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:texture_bridge/texture_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test.zic/texture');
  late List<MethodCall> calls;
  Object? presentFailure;

  setUp(() {
    calls = <MethodCall>[];
    presentFailure = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'create':
          return <String, Object?>{'textureId': 17};
        case 'present':
          final failure = presentFailure;
          if (failure != null) {
            throw failure;
          }
          return <String, Object?>{
            'queueMicros': 11,
            'uploadMicros': 23,
            'retainMicros': 3,
            'blitMicros': 7,
            'surfaceReconfigureCount': 1,
            'scheduleMicros': 13,
            'scheduleQueueMicros': 8,
            'scheduleCallMicros': 5,
            'replaceMicros': 17,
            'resultDispatchMicros': 19,
            'deadlineMissMicros': 5,
            'textureBytes': 64,
            'inFlightBytes': 64,
          };
        case 'resize':
        case 'redraw':
        case 'release':
          return null;
        default:
          throw MissingPluginException(call.method);
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('prewarm creates and releases one minimal Android texture', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final presenter = AndroidTexturePresenter(channel: channel);

    await presenter.prewarm();

    expect(calls.map((call) => call.method), <String>['create', 'release']);
    expect(calls.first.arguments, <String, Object?>{'width': 1, 'height': 1});
  });

  test('serial presenter retains frame until platform upload completes', () async {
    final ownership = _Ownership();
    final events = <TextureTelemetry>[];
    final presenter = AndroidTexturePresenter(
      channel: channel,
      telemetrySink: events.add,
    );
    final lease = await presenter.create(width: 4, height: 4);
    final frame = _FakeFrame(ownership: ownership);
    const context = TextureTelemetryContext(
      sessionId: 'reader-1',
      decodeIdentity: 'decode-7',
      demandRevision: 9,
      epoch: 3,
    );

    final sample = await lease.present(
      frame,
      deadlineAfterMicros: 100,
      context: context,
    );

    expect(ownership.retains, 1);
    expect(ownership.releases, 1);
    expect(sample.textureId, 17);
    expect(sample.frameBytes, 64);
    expect(sample.textureBytes, 64);
    expect(sample.inFlightBytes, 64);
    expect(sample.queueMicros, 11);
    expect(sample.uploadMicros, 23);
    expect(sample.retainMicros, 3);
    expect(sample.blitMicros, 7);
    expect(sample.surfaceReconfigureCount, 1);
    expect(sample.scheduleMicros, 13);
    expect(sample.scheduleQueueMicros, 8);
    expect(sample.scheduleCallMicros, 5);
    expect(sample.replaceMicros, 17);
    expect(sample.resultDispatchMicros, 19);
    expect(sample.deadlineMissMicros, 5);
    expect(sample.context, same(context));
    expect(sample.context.sessionId, 'reader-1');
    expect(sample.context.decodeIdentity, 'decode-7');
    expect(sample.context.demandRevision, 9);
    expect(sample.context.epoch, 3);
    expect(events, <TextureTelemetry>[sample]);
    expect(calls.map((call) => call.method), <String>['create', 'present']);
    expect(calls.last.arguments, containsPair('deadlineAfterMicros', 100));
    expect(calls.last.arguments, containsPair('frameBytes', 64));
  });

  test('platform failure releases retained owner and emits fallback', () async {
    final ownership = _Ownership();
    final events = <TextureTelemetry>[];
    presentFailure = PlatformException(code: 'blit_failed');
    final presenter = AndroidTexturePresenter(
      channel: channel,
      telemetrySink: events.add,
    );
    final lease = await presenter.create(width: 4, height: 4);

    const context = TextureTelemetryContext(
      sessionId: 'reader-fallback',
      decodeIdentity: 'decode-fallback',
      demandRevision: 11,
      epoch: 4,
    );

    await expectLater(
      lease.present(
        _FakeFrame(ownership: ownership),
        context: context,
      ),
      throwsA(isA<PlatformException>()),
    );

    expect(ownership.retains, 1);
    expect(ownership.releases, 1);
    expect(events, hasLength(1));
    expect(events.single, isA<TextureFallbackTelemetry>());
    final fallback = events.single as TextureFallbackTelemetry;
    expect(fallback.context, same(context));
    expect(fallback.context.demandRevision, 11);
  });

  test('telemetry sink failure cannot turn a successful present into fallback',
      () async {
    final ownership = _Ownership();
    final presenter = AndroidTexturePresenter(
      channel: channel,
      telemetrySink: (_) => throw StateError('telemetry unavailable'),
    );
    final lease = await presenter.create(width: 4, height: 4);

    final sample = await lease.present(_FakeFrame(ownership: ownership));

    expect(sample.textureId, 17);
    expect(ownership.retains, 1);
    expect(ownership.releases, 1);
  });

  test('redraw resubmits the retained platform output', () async {
    final presenter = AndroidTexturePresenter(channel: channel);
    final lease = await presenter.create(width: 4, height: 4);

    await lease.redraw();

    expect(calls.map((call) => call.method), <String>['create', 'redraw']);
    expect(calls.last.arguments, <String, Object?>{'textureId': 17});
  });

  test('resize updates identity and release is idempotent', () async {
    final presenter = AndroidTexturePresenter(channel: channel);
    final lease = await presenter.create(width: 4, height: 4);

    await lease.resize(width: 8, height: 16);
    await lease.release();
    await lease.release();

    expect(lease.width, 8);
    expect(lease.height, 16);
    expect(lease.released, isTrue);
    expect(calls.map((call) => call.method), <String>[
      'create',
      'resize',
      'release',
    ]);
  });

  test('invalid frame or deadline never crosses the platform boundary', () async {
    final presenter = AndroidTexturePresenter(channel: channel);
    final lease = await presenter.create(width: 4, height: 4);
    final ownership = _Ownership();

    await expectLater(
      lease.present(
        _FakeFrame(ownership: ownership, width: 8, height: 4),
      ),
      throwsStateError,
    );
    await expectLater(
      lease.present(
        _FakeFrame(ownership: ownership),
        deadlineAfterMicros: -1,
      ),
      throwsArgumentError,
    );

    expect(ownership.retains, 0);
    expect(calls.map((call) => call.method), <String>['create']);
  });
}

final class _Ownership {
  int retains = 0;
  int releases = 0;
}

final class _FakeFrame implements TextureFrameOwner {
  _FakeFrame({
    required this.ownership,
    this.width = 4,
    this.height = 4,
    this.isRetained = false,
  });

  final _Ownership ownership;
  final bool isRetained;

  @override
  final int width;

  @override
  final int height;

  @override
  int get byteLength => width * height * 4;

  @override
  int get handleAddress => 1234;

  @override
  int get index => 7;

  @override
  TextureFrameOwner retain() {
    ownership.retains++;
    return _FakeFrame(
      ownership: ownership,
      width: width,
      height: height,
      isRetained: true,
    );
  }

  @override
  void dispose() {
    if (isRetained) {
      ownership.releases++;
    }
  }
}
