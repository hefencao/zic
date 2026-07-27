import 'package:domain/domain.dart';

final class RetryPolicy {
  const RetryPolicy({
    this.maxAttempts = 3,
    this.baseDelay = const Duration(milliseconds: 250),
    this.maxDelay = const Duration(seconds: 4),
  }) : assert(maxAttempts >= 1);

  final int maxAttempts;
  final Duration baseDelay;
  final Duration maxDelay;

  bool allows(Object error, int attempt) {
    if (attempt >= maxAttempts) {
      return false;
    }
    if (error is! Failure) {
      return false;
    }
    return switch (error.code) {
      ErrorCode.network || ErrorCode.sessionBusy => true,
      _ => false,
    };
  }

  void validate() {
    if (baseDelay.isNegative) {
      throw ArgumentError.value(baseDelay, 'baseDelay', 'must not be negative');
    }
    if (maxDelay.isNegative) {
      throw ArgumentError.value(maxDelay, 'maxDelay', 'must not be negative');
    }
    if (maxDelay.inMicroseconds < baseDelay.inMicroseconds) {
      throw ArgumentError.value(
        maxDelay,
        'maxDelay',
        'must be greater than or equal to baseDelay',
      );
    }
  }

  Duration delayAfter(int attempt) {
    validate();
    if (attempt <= 0 || baseDelay == Duration.zero) {
      return Duration.zero;
    }
    var micros = baseDelay.inMicroseconds;
    for (var i = 1; i < attempt; i++) {
      if (micros >= maxDelay.inMicroseconds ~/ 2) {
        micros = maxDelay.inMicroseconds;
        break;
      }
      micros *= 2;
    }
    if (micros > maxDelay.inMicroseconds) {
      micros = maxDelay.inMicroseconds;
    }
    return Duration(microseconds: micros);
  }
}
