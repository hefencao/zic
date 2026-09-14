import 'clock.dart';
import 'trace.dart';

/// Observational cold-start timeline for the Home surface.
///
/// It records service-open stages, visible-cover source/first-frame events and
/// user interaction arrival at Home controls.
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
    String? presentationStage,
  }) {
    _record(
      TraceEventKind.homeCoverSourceReady,
      identityHash: identity,
      payload: <String, Object?>{
        'source': source,
        if (byteLength != null) 'byteLength': byteLength,
        if (presentationStage != null)
          'presentationStage': presentationStage,
      },
    );
  }

  void coverSourceFailed(
    String identity, {
    required String errorType,
    bool? sourceAvailable,
  }) {
    _record(
      TraceEventKind.homeCoverSourceFailed,
      identityHash: identity,
      payload: <String, Object?>{
        'errorType': errorType,
        if (sourceAvailable != null) 'sourceAvailable': sourceAvailable,
      },
    );
  }

  void coverDecodeFailed(String identity) {
    _record(TraceEventKind.homeCoverDecodeFailed, identityHash: identity);
  }

  void coverFirstFrame(String identity) {
    _record(TraceEventKind.homeCoverFirstFrame, identityHash: identity);
  }

  void interaction(String action, {Map<String, Object?> payload = const {}}) {
    _record(
      TraceEventKind.homeInteraction,
      payload: <String, Object?>{
        'action': action,
        ...payload,
      },
    );
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
