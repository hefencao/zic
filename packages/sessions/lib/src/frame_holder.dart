import 'package:domain/domain.dart';
import 'package:media/media.dart';

enum ClaimKind { upload, present }

final class FrameClaim {
  FrameClaim._({
    required this.frame,
    required this.kind,
    required void Function() release,
  }) : _release = release;

  final FrameRef frame;
  final ClaimKind kind;
  final void Function() _release;
  bool _released = false;

  bool get released => _released;

  void release() {
    if (_released) {
      return;
    }
    _released = true;
    _release();
  }
}

final class FrameHolder {
  FrameHolder({required this.epoch});

  final SourceEpoch epoch;
  final List<_Slot> _frames = <_Slot>[];
  bool _disposed = false;

  int get depth => _frames.length;
  int get bytes => _frames.fold<int>(0, (sum, slot) => sum + slot.frame.byteLength);
  bool get isEmpty => _frames.isEmpty;
  Iterable<FrameRef> get frames => _frames.map((slot) => slot.frame);

  void add(FrameRef frame) {
    _requireOpen();
    if (frame.epoch != epoch.value) {
      frame.dispose();
      throw Failure(
        code: ErrorCode.staleEpoch,
        message: 'expected frame epoch ${epoch.value}, got ${frame.epoch}',
      );
    }
    if (_frames.any((slot) => slot.frame.index == frame.index)) {
      frame.dispose();
      throw Failure(
        code: ErrorCode.invalidState,
        message: 'frame ${frame.index} is already held',
      );
    }
    _frames.add(_Slot(frame));
  }

  FrameClaim? claimNext(ClaimKind kind) {
    _requireOpen();
    for (final slot in _frames) {
      if (slot.claims[kind] == 0) {
        slot.claims[kind] = 1;
        return FrameClaim._(
          frame: slot.frame,
          kind: kind,
          release: () => slot.claims[kind] = 0,
        );
      }
    }
    return null;
  }

  bool consume(int frameIndex) {
    _requireOpen();
    final position = _frames.indexWhere((slot) => slot.frame.index == frameIndex);
    if (position < 0) {
      return false;
    }
    final slot = _frames[position];
    if (slot.claims.values.any((count) => count > 0)) {
      return false;
    }
    _frames.removeAt(position);
    slot.frame.dispose();
    return true;
  }

  int trimTo(int targetDepth) {
    _requireOpen();
    if (targetDepth < 0) {
      throw ArgumentError.value(targetDepth, 'targetDepth', 'must not be negative');
    }
    var removed = 0;
    for (var index = _frames.length - 1;
        index >= 0 && _frames.length > targetDepth;
        index--) {
      final slot = _frames[index];
      if (slot.claims.values.any((count) => count > 0)) {
        continue;
      }
      _frames.removeAt(index);
      slot.frame.dispose();
      removed++;
    }
    return removed;
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    for (final slot in _frames) {
      slot.frame.dispose();
    }
    _frames.clear();
    _disposed = true;
  }

  void _requireOpen() {
    if (_disposed) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'frame holder is disposed',
      );
    }
  }
}

final class _Slot {
  _Slot(this.frame);

  final FrameRef frame;
  final Map<ClaimKind, int> claims = <ClaimKind, int>{
    ClaimKind.upload: 0,
    ClaimKind.present: 0,
  };
}
