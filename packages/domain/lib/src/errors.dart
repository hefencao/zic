enum ErrorCode {
  source,
  network,
  resumeRejected,
  artifactCorruption,
  unsupportedFormat,
  decode,
  texture,
  memoryBudgetExceeded,
  staleEpoch,
  staleWriter,
  staleRun,
  writerBusy,
  sessionBusy,
  invalidOffset,
  invalidState,
  checksumMismatch,
  policy,
  cancelled,
}

final class Failure implements Exception {
  const Failure({
    required this.code,
    required this.message,
    this.cause,
  });

  final ErrorCode code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'Failure(${code.name}): $message';
}

final class SourceEpoch {
  const SourceEpoch(this.value) : assert(value >= 0);

  final int value;

  SourceEpoch next() => SourceEpoch(value + 1);

  void requireMatch(SourceEpoch candidate) {
    if (candidate != this) {
      throw Failure(
        code: ErrorCode.staleEpoch,
        message: 'expected epoch $value, got ${candidate.value}',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is SourceEpoch && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'Epoch($value)';
}
