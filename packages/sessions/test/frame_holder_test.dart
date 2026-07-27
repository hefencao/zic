import 'package:domain/domain.dart';
import 'package:media/media.dart';
import 'package:sessions/sessions.dart';
import 'package:test/test.dart';

void main() {
  test('claims protect frames from trim and consume', () {
    final holder = FrameHolder(epoch: const SourceEpoch(2));
    final first = _Frame(epoch: 2, index: 0, bytes: 10);
    final second = _Frame(epoch: 2, index: 1, bytes: 20);
    holder
      ..add(first)
      ..add(second);

    final claim = holder.claimNext(ClaimKind.present)!;
    expect(claim.frame.index, 0);
    expect(holder.trimTo(0), 1);
    expect(holder.depth, 1);
    expect(first.disposed, isFalse);
    expect(second.disposed, isTrue);
    expect(holder.consume(0), isFalse);

    claim.release();
    expect(holder.consume(0), isTrue);
    expect(first.disposed, isTrue);
    expect(holder.depth, 0);
  });

  test('rejects frames from a stale epoch', () {
    final holder = FrameHolder(epoch: const SourceEpoch(3));
    final stale = _Frame(epoch: 2, index: 0, bytes: 1);

    expect(
      () => holder.add(stale),
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.staleEpoch,
      )),
    );
    expect(stale.disposed, isTrue);
  });
}

final class _Frame implements FrameRef {
  _Frame({required this.epoch, required this.index, required this.bytes});

  @override
  final int epoch;
  @override
  final int index;
  final int bytes;

  @override
  int get byteLength => bytes;
  @override
  Duration get duration => const Duration(milliseconds: 16);
  @override
  int get height => 1;
  @override
  int get width => 1;
  @override
  bool disposed = false;

  @override
  void dispose() => disposed = true;
}
