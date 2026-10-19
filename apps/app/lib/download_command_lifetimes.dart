import 'dart:async';

import 'package:domain/domain.dart';
import 'package:flutter/foundation.dart';

/// Lifetime of a user command before/around its durable download owner. This
/// lets Android start its service while the initiating Activity is visible,
/// including slow source refresh. It never admits or schedules network work.
final class DownloadCommandLifetimes extends ChangeNotifier {
  static final instance = DownloadCommandLifetimes();
  final Set<DownloadCommandLifetime> _active = {};

  int get activeCount => _active.length;

  Future<T> run<T>(Future<T> Function(DownloadCommandLifetime command) action) async {
    final command = DownloadCommandLifetime._();
    _active.add(command);
    notifyListeners();
    try {
      return await action(command);
    } finally {
      _active.remove(command);
      command._finished.complete();
      notifyListeners();
    }
  }

  Future<void> cancelAll() {
    final commands = _active.toList();
    for (final command in commands) {
      command._cancelled = true;
    }
    return Future.wait([for (final command in commands) command._finished.future]);
  }
}

final class DownloadCommandLifetime {
  DownloadCommandLifetime._();
  final _finished = Completer<void>();
  bool _cancelled = false;

  void check() {
    if (_cancelled) {
      throw const Failure(code: ErrorCode.cancelled, message: '下载任务已停止');
    }
  }
}
