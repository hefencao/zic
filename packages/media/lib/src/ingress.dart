import 'package:domain/domain.dart';
import 'package:transport/transport.dart';

import 'source.dart';

final class IngressSnap {
  const IngressSnap({
    required this.epoch,
    required this.length,
    required this.kind,
    required this.sealed,
    required this.sourceReady,
    this.revision = 0,
    this.failure,
  });

  final SourceEpoch epoch;
  final int length;
  final ContentKind kind;
  final bool sealed;
  final bool sourceReady;
  final int revision;
  final Failure? failure;
}

final class Ingress {
  Ingress({
    required SourceFactory factory,
    required this.maxBytes,
  })  : _factory = factory,
        assert(maxBytes >= 0);

  final SourceFactory _factory;
  final int maxBytes;

  SourceEpoch _epoch = const SourceEpoch(0);
  EncodedSource? _source;
  ContentKind _kind = ContentKind.unknown;
  List<int> _pending = <int>[];
  int _length = 0;
  bool _sealed = false;
  int _revision = 0;
  bool _disposed = false;
  Failure? _failure;

  IngressSnap get snapshot => IngressSnap(
        epoch: _epoch,
        length: _length,
        kind: _kind,
        sealed: _sealed,
        sourceReady: _source != null,
        revision: _revision,
        failure: _failure,
      );

  EncodedSource? get source => _source;

  void append({
    required SourceEpoch epoch,
    required int offset,
    required List<int> bytes,
  }) {
    _requireOpen();
    _epoch.requireMatch(epoch);
    if (_sealed) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'cannot append to a sealed ingress',
      );
    }
    if (offset != _length) {
      throw Failure(
        code: ErrorCode.invalidOffset,
        message: 'expected ingress offset $_length, got $offset',
      );
    }
    if (bytes.isEmpty) {
      return;
    }

    final source = _source;
    if (source != null) {
      _invoke(
        () => source.append(
          epoch: epoch.value,
          offset: offset,
          bytes: bytes,
        ),
        operation: 'append',
      );
      _length += bytes.length;
      _revision++;
      return;
    }

    if (_kind != ContentKind.unknown) {
      _length += bytes.length;
      _revision++;
      return;
    }

    final prior = List<int>.of(_pending);
    final remaining = sniffPrefixLength - _pending.length;
    if (remaining > 0) {
      _pending.addAll(bytes.take(remaining));
    }
    final detected = sniffContent(_pending);
    _kind = detected;
    _length += bytes.length;

    if (detected == ContentKind.webp) {
      final EncodedSource created;
      try {
        created = _factory.create(epoch: epoch.value, maxBytes: maxBytes);
      } on Object catch (error) {
        _disable(
          Failure(
            code: ErrorCode.source,
            message: 'encoded source creation failed',
            cause: error,
          ),
        );
        _pending = <int>[];
        return;
      }
      _source = created;
      final replay = <int>[...prior, ...bytes];
      _invoke(
        () => created.append(
          epoch: epoch.value,
          offset: 0,
          bytes: replay,
        ),
        operation: 'initial append',
      );
      _pending = <int>[];
    } else if (detected != ContentKind.unknown) {
      _pending = <int>[];
    }
    _revision++;
  }

  void seal(SourceEpoch epoch) {
    _requireOpen();
    _epoch.requireMatch(epoch);
    if (_sealed) {
      return;
    }
    if (_kind == ContentKind.unknown) {
      _kind = sniffContent(_pending, finalChunk: true);
      _pending = <int>[];
    }
    final source = _source;
    if (source != null) {
      _invoke(() => source.seal(epoch.value), operation: 'seal');
    }
    _sealed = true;
    _revision++;
  }

  Future<void> rebuild({
    required SourceEpoch epoch,
    required Stream<List<int>> chunks,
    required bool sealed,
  }) async {
    reset(epoch);
    var offset = 0;
    await for (final chunk in chunks) {
      append(epoch: epoch, offset: offset, bytes: chunk);
      offset += chunk.length;
    }
    if (sealed) {
      seal(epoch);
    }
  }

  void reset(SourceEpoch epoch) {
    _requireOpen();
    _source?.dispose();
    _source = null;
    _epoch = epoch;
    _kind = ContentKind.unknown;
    _pending = <int>[];
    _length = 0;
    _sealed = false;
    _failure = null;
    _revision++;
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _source?.dispose();
    _source = null;
    _disposed = true;
  }

  void _invoke(
    SourceStatus Function() operationCall, {
    required String operation,
  }) {
    try {
      _apply(operationCall(), operation: operation);
    } on Object catch (error) {
      _disable(
        Failure(
          code: ErrorCode.source,
          message: 'encoded source failed during $operation',
          cause: error,
        ),
      );
    }
  }

  void _apply(SourceStatus status, {required String operation}) {
    switch (status) {
      case SourceStatus.ok:
        return;
      case SourceStatus.budget:
        _disable(
          Failure(
            code: ErrorCode.memoryBudgetExceeded,
            message: 'encoded source exceeded its $maxBytes byte budget',
          ),
        );
        return;
      case SourceStatus.staleEpoch:
        _disable(
          Failure(
            code: ErrorCode.staleEpoch,
            message: 'native source rejected stale epoch during $operation',
          ),
        );
        return;
      case SourceStatus.invalidOffset:
        _disable(
          Failure(
            code: ErrorCode.invalidOffset,
            message: 'native source rejected offset during $operation',
          ),
        );
        return;
      case SourceStatus.sealed:
        _disable(
          Failure(
            code: ErrorCode.invalidState,
            message: 'native source was already sealed during $operation',
          ),
        );
        return;
      case SourceStatus.nullPointer:
        _disable(
          Failure(
            code: ErrorCode.source,
            message: 'native source was unavailable during $operation',
          ),
        );
        return;
      case SourceStatus.failed:
        _disable(
          Failure(
            code: ErrorCode.source,
            message: 'native source failed during $operation',
          ),
        );
        return;
    }
  }

  void _disable(Failure failure) {
    _failure = failure;
    _revision++;
    _source?.dispose();
    _source = null;
  }

  void _requireOpen() {
    if (_disposed) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'ingress is disposed',
      );
    }
  }
}
