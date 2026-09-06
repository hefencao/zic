import 'package:domain/domain.dart';

final class ByteRange {
  const ByteRange({required this.start, this.end});

  final int start;
  final int? end;

  bool get isOpenEnded => end == null;

  void validate() {
    if (start < 0) {
      throw ArgumentError.value(start, 'start', 'must be non-negative');
    }
    if (end != null && end! < start) {
      throw ArgumentError.value(end, 'end', 'must be >= start');
    }
  }

  @override
  String toString() => end == null ? 'bytes=$start-' : 'bytes=$start-$end';
}

final class Validators {
  const Validators({this.etag, this.lastModified});

  final String? etag;
  final DateTime? lastModified;

  bool get isEmpty => etag == null && lastModified == null;
  bool get canResume => !isEmpty;

  bool matches(Validators other) {
    if (etag != null) {
      return other.etag == etag;
    }
    if (lastModified != null) {
      return other.lastModified == lastModified;
    }
    return false;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        if (etag != null) 'etag': etag,
        if (lastModified != null)
          'lastModified': lastModified!.toUtc().toIso8601String(),
      };

  factory Validators.fromJson(Map<String, Object?> json) {
    final etag = json['etag'];
    final modified = json['lastModified'];
    if (etag != null && etag is! String) {
      throw const FormatException('etag must be a string');
    }
    final DateTime? lastModified;
    if (modified == null) {
      lastModified = null;
    } else if (modified is String) {
      lastModified = DateTime.parse(modified);
    } else {
      throw const FormatException('lastModified must be a string');
    }
    return Validators(
      etag: etag as String?,
      lastModified: lastModified,
    );
  }
}

enum ByteResponseDisposition {
  staged,
  durableImmutable,
}

/// Identifies who already owns the immutable response body durably.
///
/// [ByteResponseDisposition.durableImmutable] only states that the body may be
/// consumed as resident immutable ingress without copying it into the
/// transfer's hot artifact. It does not imply that the persistent artifact
/// cache already owns those bytes.
enum ByteResponseBodyAuthority {
  source,
  artifactCache,
}

/// Whether delaying subscription demand on [ByteResponse.bytes] propagates
/// backpressure to an upstream live transport instead of merely delaying a
/// body that has already been materialized in memory/storage.
enum ByteResponseFlowControl {
  none,

  /// Consumer iteration may be paused safely, but the upstream body may have
  /// already been materialized or buffered. This provides scheduler-visible
  /// pseudo-pause semantics without claiming network-byte savings.
  consumerPacing,

  /// Suspending consumer demand propagates to the live upstream transport.
  streamBackpressure,
}

/// Optional live transport-read diagnostics attached to a byte response.
///
/// Implementations may update their counters while [ByteResponse.bytes] is
/// consumed. [snapshot] is observation-only: scheduling, retry and cache
/// policy must never branch on these values.
abstract interface class ByteResponseReadDiagnostics {
  Map<String, Object?> snapshot();
}

final class ByteResponse {
  ByteResponse({
    required this.bytes,
    required this.statusCode,
    required this.rangeStart,
    required this.totalLength,
    this.validators = const Validators(),
    this.rangeSupported = false,
    this.disposition = ByteResponseDisposition.staged,
    this.bodyAuthority = ByteResponseBodyAuthority.source,
    this.flowControl = ByteResponseFlowControl.none,
    Map<String, Object?> diagnostics = const <String, Object?>{},
    this.readDiagnostics,
    Future<void> Function()? onDiscard,
    Future<void> Function({TaskControl? control})? onDiscardControlled,
  })  : diagnostics = Map<String, Object?>.unmodifiable(diagnostics),
        _onDiscard = onDiscard,
        _onDiscardControlled = onDiscardControlled,
        assert(statusCode >= 100),
        assert(rangeStart >= 0),
        assert(totalLength == null || totalLength >= 0);

  final Stream<List<int>> bytes;
  final int statusCode;
  final int rangeStart;
  final int? totalLength;
  final Validators validators;
  final bool rangeSupported;
  final ByteResponseDisposition disposition;
  final ByteResponseBodyAuthority bodyAuthority;

  /// How downstream flow suspension behaves for [bytes]. This is a typed
  /// transport capability, not a scheduling decision. [consumerPacing]
  /// provides a safe pseudo-pause for already-materialized/cooperative bodies;
  /// [streamBackpressure] additionally preserves real upstream network
  /// backpressure.
  final ByteResponseFlowControl flowControl;

  /// Transport-stage timing/route diagnostics for trace consumers.
  ///
  /// This is observational metadata only. Scheduling, retry and cache policy
  /// must never branch on these values.
  final Map<String, Object?> diagnostics;
  final ByteResponseReadDiagnostics? readDiagnostics;
  final Future<void> Function()? _onDiscard;
  final Future<void> Function({TaskControl? control})? _onDiscardControlled;
  Future<void>? _discardFuture;

  bool get isPartial => statusCode == 206;

  Future<void> discard({TaskControl? control}) => _discardFuture ??=
      _discardOnce(control: control);

  Future<void> _discardOnce({required TaskControl? control}) async {
    final controlled = _onDiscardControlled;
    if (controlled != null) {
      await controlled(control: control);
      return;
    }
    final callback = _onDiscard;
    if (callback != null) {
      await callback();
    }
  }
}

const int defaultTransportChunkBytes = 256 * 1024;

abstract interface class Transport {
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  });
}


/// Optional transport capability for scheduler-owned cancellation and priority.
///
/// [control] is observational: transports may abort/sequence their own request
/// work from it, but scheduling policy remains owned by the caller's lane.
abstract interface class ControlledTransport implements Transport {
  Future<ByteResponse> openControlled(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
    TaskControl? control,
  });
}

/// Optional capability for transports whose [open] lifecycle is already
/// bounded by lower-level owners. Download scheduling may omit its generic
/// open watchdog for matching URIs, but cancellation and body-read watchdogs
/// remain owned by the caller.
abstract interface class SelfBoundedOpenTransport implements Transport {
  bool selfBoundsOpen(Uri uri);
}

void requireResumeResponse({
  required int expectedStart,
  required Validators expectedValidators,
  required ByteResponse response,
}) {
  if (!response.isPartial || response.rangeStart != expectedStart) {
    throw const Failure(
      code: ErrorCode.resumeRejected,
      message: 'server did not honor the requested byte range',
    );
  }
  if (!expectedValidators.matches(response.validators)) {
    throw const Failure(
      code: ErrorCode.resumeRejected,
      message: 'response validators do not match the partial artifact',
    );
  }
}
