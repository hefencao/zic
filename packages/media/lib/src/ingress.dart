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
    required this.maxBytes})  : _factory = factory,
        assert(maxBytes >= 0);

  final SourceFactory _factory;
  final int maxBytes;

  SourceEpoch _epoch = const SourceEpoch(0);
  EncodedSource? _source;
  ContentKind _kind = ContentKind.unknown;
  List<int> _pending = <int>[];
  int _length = 0;
  bool _sealed = false;
  bool _backgroundSourcePending = false;
  int _revision = 0;
  bool _disposed = false;
  Failure? _failure;
  int? _expectedLength;

  IngressSnap get snapshot => IngressSnap(
        epoch: _epoch,
        length: _length,
        kind: _kind,
        sealed: _sealed,
        sourceReady: _source != null && !_backgroundSourcePending,
        revision: _revision,
        failure: _failure,
      );

  EncodedSource? get source => _backgroundSourcePending ? null : _source;

  void expectLength(int? length) {
    _requireOpen();
    if (length == null) return;
    if (length < 0 || length > maxBytes) {
      throw Failure(
        code: ErrorCode.memoryBudgetExceeded,
        message: 'encoded source expected length $length exceeds $maxBytes',
      );
    }
    // Expected-length reservation is a pre-seal capacity hint. Late Reader
    // projections can learn the authoritative total after their replay has
    // already sealed the native source; repeating the same length must be an
    // idempotent confirmation rather than a native reserve-after-seal call.
    if (_sealed) {
      if (length != _length) {
        throw Failure(
          code: ErrorCode.artifactCorruption,
          message: 'sealed ingress length $_length differs from expected $length',
        );
      }
      _expectedLength = length;
      return;
    }
    _expectedLength = length;
    final source = _source;
    if (source is ExpectedLengthEncodedSource) {
      final reservable = source as ExpectedLengthEncodedSource;
      _invoke(
        () => reservable.reserveExpectedLength(
          epoch: _epoch.value,
          length: length,
        ),
        operation: 'reserve expected length',
      );
    }
  }

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
          bytes: bytes),
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
      final expectedLength = _expectedLength;
      if (expectedLength != null && created is ExpectedLengthEncodedSource) {
        final reservable = created as ExpectedLengthEncodedSource;
        _invoke(
          () => reservable.reserveExpectedLength(
            epoch: epoch.value,
            length: expectedLength,
          ),
          operation: 'reserve expected length',
        );
      }
      // If the very first chunk is already enough to identify WebP, it is
      // already the complete replay prefix. Reuse it synchronously instead of
      // allocating/copying the whole chunk once in Dart before NativeSource
      // copies it into its owned buffer. Split-prefix detection still needs to
      // prepend the bytes retained in [prior].
      final replay = prior.isEmpty ? bytes : <int>[...prior, ...bytes];
      _invoke(
        () => created.append(
          epoch: epoch.value,
          offset: 0,
          bytes: replay),
        operation: 'initial append',
      );
      _pending = <int>[];
    } else if (detected != ContentKind.unknown) {
      _pending = <int>[];
    }
    _revision++;
  }

  /// Appends replay/materialization bytes without requiring native storage
  /// mutation to run on the caller isolate when the source supports it.
  ///
  /// This preserves the same byte ordering and logical ingress state as
  /// [append]. It changes only the execution domain of source reserve/copy
  /// work; transport and page-role policy remain outside [Ingress].
  Future<void> appendInBackground({
    required SourceEpoch epoch,
    required int offset,
    required List<int> bytes,
    TaskControl? control,
  }) async {
    _requireOpen();
    control?.throwIfCancelled();
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
    if (bytes.isEmpty) return;

    final source = _source;
    if (source != null) {
      if (source is BackgroundWritableEncodedSource) {
        final background = source as BackgroundWritableEncodedSource;
        final status = await background.appendInBackground(
          epoch: epoch.value,
          offset: offset,
          bytes: bytes,
          control: control,
        );
        control?.throwIfCancelled();
        if (!_backgroundSourceIsCurrent(source, epoch)) return;
        _apply(status, operation: 'background append');
      } else {
        _invoke(
          () => source.append(epoch: epoch.value, offset: offset, bytes: bytes),
          operation: 'append',
        );
      }
      if (_disposed || _epoch != epoch) return;
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
      _backgroundSourcePending = created is BackgroundWritableEncodedSource;
      final expectedLength = _expectedLength;
      if (expectedLength != null && created is ExpectedLengthEncodedSource) {
        if (created is BackgroundWritableEncodedSource) {
          final background = created as BackgroundWritableEncodedSource;
          final status = await background.reserveExpectedLengthInBackground(
            epoch: epoch.value,
            length: expectedLength,
            control: control,
          );
          control?.throwIfCancelled();
          if (!_backgroundSourceIsCurrent(created, epoch)) return;
          _apply(status, operation: 'background reserve expected length');
          if (!identical(_source, created)) {
            _pending = <int>[];
            _revision++;
            return;
          }
        } else {
          final reservable = created as ExpectedLengthEncodedSource;
          _invoke(
            () => reservable.reserveExpectedLength(
              epoch: epoch.value,
              length: expectedLength,
            ),
            operation: 'reserve expected length',
          );
        }
      }
      final replay = prior.isEmpty ? bytes : <int>[...prior, ...bytes];
      if (created is BackgroundWritableEncodedSource) {
        final background = created as BackgroundWritableEncodedSource;
        final status = await background.appendInBackground(
          epoch: epoch.value,
          offset: 0,
          bytes: replay,
          control: control,
        );
        control?.throwIfCancelled();
        if (!_backgroundSourceIsCurrent(created, epoch)) return;
        _apply(status, operation: 'background initial append');
        if (identical(_source, created)) {
          _backgroundSourcePending = false;
        }
      } else {
        _invoke(
          () => created.append(epoch: epoch.value, offset: 0, bytes: replay),
          operation: 'initial append',
        );
      }
      _pending = <int>[];
    } else if (detected != ContentKind.unknown) {
      _pending = <int>[];
    }
    _revision++;
  }

  Future<bool> appendFileRangeInBackground({
    required SourceEpoch epoch,
    required int offset,
    required String path,
    required int fileOffset,
    required int length,
    TaskControl? control,
  }) async {
    _requireOpen();
    control?.throwIfCancelled();
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
    if (length <= 0) return true;
    final source = _source;
    if (source is! BackgroundFileRangeWritableEncodedSource) return false;
    final encodedSource = source as EncodedSource;
    final background = source as BackgroundFileRangeWritableEncodedSource;
    final status = await background.appendFileRangeInBackground(
      epoch: epoch.value,
      offset: offset,
      path: path,
      fileOffset: fileOffset,
      length: length,
      control: control,
    );
    control?.throwIfCancelled();
    if (!_backgroundSourceIsCurrent(encodedSource, epoch)) return true;
    _apply(status, operation: 'background direct-file append');
    if (_disposed || _epoch != epoch) return true;
    _length += length;
    _revision++;
    return true;
  }

  /// Rebuilds a direct immutable file authority without moving its encoded
  /// body through the caller isolate. Only the small metadata prefix used to
  /// establish content kind/source ABI is supplied as Dart bytes.
  Future<bool> rebuildFromDirectFile({
    required SourceEpoch epoch,
    required List<int> metadataPrefix,
    required String path,
    required int endExclusive,
    required bool sealed,
    TaskControl? control,
  }) async {
    final expectedLength = _expectedLength;
    reset(epoch);
    _expectedLength = expectedLength;
    final prefixLength = metadataPrefix.length < endExclusive
        ? metadataPrefix.length
        : endExclusive;
    if (prefixLength <= 0) return false;
    await appendInBackground(
      epoch: epoch,
      offset: 0,
      bytes: metadataPrefix.take(prefixLength).toList(growable: false),
      control: control,
    );
    if (endExclusive > prefixLength) {
      final supported = await appendFileRangeInBackground(
        epoch: epoch,
        offset: prefixLength,
        path: path,
        fileOffset: prefixLength,
        length: endExclusive - prefixLength,
        control: control,
      );
      if (!supported) {
        reset(epoch);
        _expectedLength = expectedLength;
        return false;
      }
    }
    if (sealed) {
      seal(epoch);
    }
    return true;
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
    TaskControl? control,
  }) async {
    final expectedLength = _expectedLength;
    reset(epoch);
    _expectedLength = expectedLength;
    var offset = 0;
    await for (final chunk in chunks) {
      control?.throwIfCancelled();
      await appendInBackground(epoch: epoch, offset: offset, bytes: chunk,
        control: control,
      );
      offset += chunk.length;
    }
    control?.throwIfCancelled();
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
    _backgroundSourcePending = false;
    _failure = null;
    _expectedLength = null;
    _revision++;
  }

  /// Marks this Reader-local source projection as failed without mutating the
  /// physical download. Used when a late consumer cannot replay the physical
  /// committed prefix into its own native source.
  void fail(Failure failure) {
    _requireOpen();
    _disable(failure);
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _source?.dispose();
    _source = null;
    _backgroundSourcePending = false;
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
    _backgroundSourcePending = false;
  }

  bool _backgroundSourceIsCurrent(EncodedSource source, SourceEpoch epoch) =>
      !_disposed && identical(_source, source) && _epoch == epoch && !_sealed;

  void _requireOpen() {
    if (_disposed) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'ingress is disposed',
      );
    }
  }
}
