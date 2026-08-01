import 'dart:async';

import 'package:domain/domain.dart';

final class MediaLoadToken {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!isCancelled) {
      _cancelled.complete();
    }
  }

  void throwIfCancelled() {
    if (isCancelled) {
      throw const Failure(
        code: ErrorCode.cancelled,
        message: 'media byte load was cancelled',
      );
    }
  }
}
