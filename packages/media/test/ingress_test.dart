import 'package:domain/domain.dart';
import 'package:media/media.dart';
import 'package:test/test.dart';
import 'package:transport/transport.dart';

void main() {
  test('creates a source only after WebP is confirmed and replays prefix', () {
    final factory = _Factory();
    final ingress = Ingress(factory: factory, maxBytes: 1024);
    const epoch = SourceEpoch(0);

    ingress.append(epoch: epoch, offset: 0, bytes: 'RIFF'.codeUnits);
    expect(factory.created, isEmpty);
    expect(ingress.snapshot.kind, ContentKind.unknown);

    ingress.append(
      epoch: epoch,
      offset: 4,
      bytes: '....WEBPpayload'.codeUnits,
    );
    expect(factory.created, hasLength(1));
    expect(factory.created.single.bytes, 'RIFF....WEBPpayload'.codeUnits);
    expect(ingress.snapshot.kind, ContentKind.webp);
    expect(ingress.snapshot.sourceReady, isTrue);

    ingress.seal(epoch);
    expect(factory.created.single.sealed, isTrue);
    expect(ingress.snapshot.sealed, isTrue);
  });

  test('sealed expected length confirmation is idempotent', () {
    final factory = _Factory();
    final ingress = Ingress(factory: factory, maxBytes: 1024);
    const epoch = SourceEpoch(0);
    final bytes = 'RIFF....WEBPpayload'.codeUnits;

    ingress.expectLength(bytes.length);
    ingress.append(epoch: epoch, offset: 0, bytes: bytes);
    ingress.seal(epoch);

    final source = factory.created.single;
    expect(source.reserveExpectedLengthCalls, 1);
    ingress.expectLength(bytes.length);
    expect(source.reserveExpectedLengthCalls, 1);
    expect(ingress.snapshot.sourceReady, isTrue);
    expect(ingress.snapshot.failure, isNull);

    expect(
      () => ingress.expectLength(bytes.length + 1),
      throwsA(
        isA<Failure>().having(
          (error) => error.code,
          'code',
          ErrorCode.artifactCorruption,
        ),
      ),
    );
    expect(ingress.snapshot.sourceReady, isTrue);
  });

  test('source revision advances for every growth and seal event', () {
    final ingress = Ingress(factory: _Factory(), maxBytes: 1024);
    const epoch = SourceEpoch(0);

    final initial = ingress.snapshot.revision;
    ingress.append(epoch: epoch, offset: 0, bytes: 'RIFF'.codeUnits);
    final prefix = ingress.snapshot.revision;
    ingress.append(
      epoch: epoch,
      offset: 4,
      bytes: '....WEBPframe'.codeUnits,
    );
    final ready = ingress.snapshot.revision;
    ingress.append(
      epoch: epoch,
      offset: ingress.snapshot.length,
      bytes: 'more'.codeUnits,
    );
    final grown = ingress.snapshot.revision;
    ingress.seal(epoch);

    expect(prefix, greaterThan(initial));
    expect(ready, greaterThan(prefix));
    expect(grown, greaterThan(ready));
    expect(ingress.snapshot.revision, greaterThan(grown));
  });

  test('does not create native sources for GIF or fallback content', () {
    final factory = _Factory();
    final gif = Ingress(factory: factory, maxBytes: 1024);
    gif.append(
      epoch: const SourceEpoch(0),
      offset: 0,
      bytes: 'GIF89apayload'.codeUnits,
    );
    gif.seal(const SourceEpoch(0));
    expect(gif.snapshot.kind, ContentKind.gif);
    expect(gif.snapshot.sourceReady, isFalse);

    final fallback = Ingress(factory: factory, maxBytes: 1024);
    fallback.append(
      epoch: const SourceEpoch(0),
      offset: 0,
      bytes: List<int>.filled(sniffPrefixLength, 1),
    );
    fallback.seal(const SourceEpoch(0));
    expect(fallback.snapshot.kind, ContentKind.fallback);
    expect(factory.created, isEmpty);
  });

  test('rebuild restores source bytes across arbitrary chunks', () async {
    final factory = _Factory();
    final ingress = Ingress(factory: factory, maxBytes: 1024);
    final bytes = 'RIFF....WEBPabcdef'.codeUnits;

    await ingress.rebuild(
      epoch: const SourceEpoch(4),
      chunks: Stream<List<int>>.fromIterable(<List<int>>[
        bytes.sublist(0, 3),
        bytes.sublist(3, 11),
        bytes.sublist(11),
      ]),
      sealed: true,
    );

    expect(factory.created.single.bytes, bytes);
    expect(factory.created.single.epoch, 4);
    expect(factory.created.single.sealed, isTrue);
    expect(ingress.snapshot.length, bytes.length);
  });

  test('source creation failure degrades without failing download ingress', () {
    final ingress = Ingress(factory: _ThrowingFactory(), maxBytes: 1024);
    final bytes = 'RIFF....WEBPpayload'.codeUnits;

    ingress.append(
      epoch: const SourceEpoch(0),
      offset: 0,
      bytes: bytes,
    );

    expect(ingress.snapshot.length, bytes.length);
    expect(ingress.snapshot.kind, ContentKind.webp);
    expect(ingress.snapshot.sourceReady, isFalse);
    expect(ingress.snapshot.failure?.code, ErrorCode.source);
  });

  test('source budget failure disables decode source without losing length', () {
    final factory = _Factory();
    final ingress = Ingress(factory: factory, maxBytes: 12);
    final bytes = 'RIFF....WEBPpayload'.codeUnits;

    ingress.append(
      epoch: const SourceEpoch(0),
      offset: 0,
      bytes: bytes,
    );

    expect(ingress.snapshot.kind, ContentKind.webp);
    expect(ingress.snapshot.length, bytes.length);
    expect(ingress.snapshot.sourceReady, isFalse);
    expect(ingress.snapshot.failure?.code, ErrorCode.memoryBudgetExceeded);
  });

  test('rejects stale epochs and non-contiguous offsets', () {
    final ingress = Ingress(factory: _Factory(), maxBytes: 1024);
    expect(
      () => ingress.append(
        epoch: const SourceEpoch(1),
        offset: 0,
        bytes: const <int>[1],
      ),
      throwsA(isA<Failure>()),
    );
    expect(
      () => ingress.append(
        epoch: const SourceEpoch(0),
        offset: 2,
        bytes: const <int>[1],
      ),
      throwsA(
        isA<Failure>().having(
          (error) => error.code,
          'code',
          ErrorCode.invalidOffset,
        ),
      ),
    );
  });
}

final class _Factory implements SourceFactory {
  final List<_Source> created = <_Source>[];

  @override
  EncodedSource create({required int epoch, required int maxBytes}) {
    final source = _Source(epoch: epoch, maxBytes: maxBytes);
    created.add(source);
    return source;
  }
}

final class _Source implements EncodedSource, ExpectedLengthEncodedSource {
  _Source({required this.epoch, required this.maxBytes});

  @override
  int epoch;
  final int maxBytes;
  final List<int> bytes = <int>[];
  bool disposed = false;
  int reserveExpectedLengthCalls = 0;

  @override
  int get length => bytes.length;

  @override
  bool sealed = false;

  @override
  SourceKind get kind => bytes.length >= 12 ? SourceKind.webp : SourceKind.unknown;

  @override
  SourceStatus reserveExpectedLength({
    required int epoch,
    required int length,
  }) {
    if (epoch != this.epoch) return SourceStatus.staleEpoch;
    if (sealed) return SourceStatus.sealed;
    if (length > maxBytes) return SourceStatus.budget;
    reserveExpectedLengthCalls++;
    return SourceStatus.ok;
  }

  @override
  SourceStatus append({
    required int epoch,
    required int offset,
    required List<int> bytes,
  }) {
    if (epoch != this.epoch) {
      return SourceStatus.staleEpoch;
    }
    if (sealed) {
      return SourceStatus.sealed;
    }
    if (offset != this.bytes.length) {
      return SourceStatus.invalidOffset;
    }
    if (this.bytes.length + bytes.length > maxBytes) {
      return SourceStatus.budget;
    }
    this.bytes.addAll(bytes);
    return SourceStatus.ok;
  }

  @override
  SourceStatus reset(int epoch) {
    this.epoch = epoch;
    bytes.clear();
    sealed = false;
    return SourceStatus.ok;
  }

  @override
  SourceStatus seal(int epoch) {
    if (epoch != this.epoch) {
      return SourceStatus.staleEpoch;
    }
    sealed = true;
    return SourceStatus.ok;
  }

  @override
  void dispose() {
    disposed = true;
  }
}

final class _ThrowingFactory implements SourceFactory {
  @override
  EncodedSource create({required int epoch, required int maxBytes}) {
    throw StateError('native library unavailable');
  }
}
