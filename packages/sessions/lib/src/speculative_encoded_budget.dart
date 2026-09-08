import 'dart:async';

import 'package:domain/domain.dart';

const int defaultSpeculativeEncodedReadBudgetBytes = 50 * 1024 * 1024;
const int speculativeEncodedForegroundPriority = 900;

/// Composition-owned cap for encoded bytes read speculatively by active work.
///
/// This is deliberately not a page/window/admission scheduler. Pipeline keeps
/// its stable demand window and NetLane keeps network task admission. Callers
/// enter this gate immediately before requesting the next encoded-byte quantum
/// and report the bytes that were actually delivered afterwards.
///
/// Bytes read while an account is foreground are not charged. Bytes that were
/// read speculatively remain charged for that account while it remains alive;
/// a later foreground promotion temporarily removes the account from the active
/// total, and a later background demotion makes its speculative bytes count
/// again. Closing the account releases them permanently.
///
/// The gate can overshoot the limit by at most one underlying provider chunk
/// per reader already admitted below the limit. Local resident replay therefore
/// keeps its physical provider quantum independently bounded.
final class SpeculativeEncodedReadBudget {
  SpeculativeEncodedReadBudget({
    int limitBytes = defaultSpeculativeEncodedReadBudgetBytes,
    this.foregroundPriority = speculativeEncodedForegroundPriority,
  })  : assert(limitBytes > 0),
        _limitBytes = limitBytes;

  int _limitBytes;
  final int foregroundPriority;
  final Map<Object, SpeculativeEncodedReadAccount> _accounts =
      <Object, SpeculativeEncodedReadAccount>{};
  Completer<void> _changed = Completer<void>();

  int get limitBytes => _limitBytes;
  int get accountCount => _accounts.length;

  int get activeSpeculativeBytes {
    var total = 0;
    for (final account in _accounts.values) {
      if (!account.closed &&
          !account.bypassed &&
          account.priority < foregroundPriority) {
        total += account.speculativeBytes;
      }
    }
    return total;
  }

  void updateLimitBytes(int bytes) {
    if (bytes <= 0) {
      throw ArgumentError.value(bytes, 'bytes', 'must be positive');
    }
    if (_limitBytes == bytes) return;
    _limitBytes = bytes;
    _wake();
  }

  SpeculativeEncodedReadAccount accountFor(
    Object key, {
    required TaskControl control,
    bool bypassed = false,
  }) {
    final existing = _accounts[key];
    if (existing != null && !existing.closed) {
      existing.setBypassed(bypassed);
      return existing;
    }
    final account = SpeculativeEncodedReadAccount._(
      budget: this,
      key: key,
      control: control,
      bypassed: bypassed,
    );
    _accounts[key] = account;
    return account;
  }

  void releaseAccount(Object key) {
    final account = _accounts.remove(key);
    account?._closeFromBudget();
  }

  bool _canRead(SpeculativeEncodedReadAccount account) =>
      account.closed ||
      account.bypassed ||
      account.priority >= foregroundPriority ||
      activeSpeculativeBytes < _limitBytes;

  Future<void> _waitForCapacity(
    SpeculativeEncodedReadAccount account, {
    TaskControl? control,
  }) async {
    while (true) {
      control?.throwIfCancelled();
      if (_canRead(account)) {
        return;
      }
      final wake = _changed.future;
      if (control == null) {
        await wake;
      } else {
        await Future.any<void>(<Future<void>>[
          wake,
          control.whenCancelled,
        ]);
      }
    }
  }

  void _recordRead(SpeculativeEncodedReadAccount account, int bytes) {
    if (bytes <= 0 || account.closed || account.bypassed) return;
    if (account.priority < foregroundPriority) {
      account._speculativeBytes += bytes;
      _wake();
    }
  }

  void _accountClosed(SpeculativeEncodedReadAccount account) {
    if (identical(_accounts[account.key], account)) {
      _accounts.remove(account.key);
    }
    _wake();
  }

  void _wake() {
    final changed = _changed;
    _changed = Completer<void>();
    if (!changed.isCompleted) changed.complete();
  }
}

final class SpeculativeEncodedReadAccount {
  SpeculativeEncodedReadAccount._({
    required SpeculativeEncodedReadBudget budget,
    required this.key,
    required TaskControl control,
    required bool bypassed,
  })  : _budget = budget,
        _control = control,
        _bypassed = bypassed {
    if (control is PriorityObservableTaskControl) {
      _prioritySubscription = control.priorityChanges.listen((_) {
        if (!_closed) _budget._wake();
      });
    }
    unawaited(control.whenCancelled.then<void>((_) => close()));
  }

  final SpeculativeEncodedReadBudget _budget;
  final Object key;
  final TaskControl _control;
  StreamSubscription<int>? _prioritySubscription;
  int _speculativeBytes = 0;
  bool _bypassed;
  bool _closed = false;

  int get priority => _control.priority;
  int get speculativeBytes => _speculativeBytes;
  bool get bypassed => _bypassed;
  bool get closed => _closed;
  bool get readBlocked => !_budget._canRead(this);

  void setBypassed(bool value) {
    if (_closed || _bypassed == value) return;
    _bypassed = value;
    _budget._wake();
  }

  Future<void> waitForRead({TaskControl? control}) =>
      _budget._waitForCapacity(this, control: control ?? _control);

  void recordRead(int bytes) => _budget._recordRead(this, bytes);

  void close() {
    if (_closed) return;
    _closed = true;
    final subscription = _prioritySubscription;
    _prioritySubscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    _budget._accountClosed(this);
  }

  void _closeFromBudget() {
    if (_closed) return;
    _closed = true;
    final subscription = _prioritySubscription;
    _prioritySubscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    _budget._wake();
  }
}
