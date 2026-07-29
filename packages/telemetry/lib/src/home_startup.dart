import 'clock.dart';
import 'trace.dart';

/// Observational cold-start timeline for the Home surface.
///
/// It records service-open stages and visible-cover source/first-frame events.
/// It never selects covers, owns cache entries, or changes image policy.
final class HomeStartupTelemetry {
  const HomeStartupTelemetry({
    required this.clock,
    required this.sink,
    this.sessionId = 'home-startup',
  });

  final MonoClock clock;
  final TraceSink sink;
  final String sessionId;

  int nowMicros() => clock.nowMicros();

  void bootstrapPresented() => _record(TraceEventKind.homeBootstrapPresented);

  void servicesOpenStarted() =>
      _record(TraceEventKind.homeServicesOpenStarted);

  void serviceReady(String stage, {required int startedAtMicros}) {
    _record(
      TraceEventKind.homeServiceReady,
      payload: <String, Object?>{
        'stage': stage,
        'durationMicros': clock.nowMicros() - startedAtMicros,
      },
    );
  }

  void servicesReady({required int startedAtMicros}) {
    _record(
      TraceEventKind.homeServicesReady,
      payload: <String, Object?>{
        'durationMicros': clock.nowMicros() - startedAtMicros,
      },
    );
  }

  void coverRequested(String identity) {
    _record(TraceEventKind.homeCoverRequested, identityHash: identity);
  }

  void coverSourceReady(
    String identity, {
    required String source,
    int? byteLength,
  }) {
    _record(
      TraceEventKind.homeCoverSourceReady,
      identityHash: identity,
      payload: <String, Object?>{
        'source': source,
        if (byteLength != null) 'byteLength': byteLength,
      },
    );
  }

  void coverFirstFrame(String identity) {
    _record(TraceEventKind.homeCoverFirstFrame, identityHash: identity);
  }

  void _record(
    TraceEventKind kind, {
    String? identityHash,
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    sink.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: kind,
        identityHash: identityHash,
        payload: payload,
      ),
    );
  }
}
