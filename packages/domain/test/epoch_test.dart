import 'package:domain/domain.dart';
import 'package:test/test.dart';

void main() {
  test('stale epoch is rejected with a structured error', () {
    const current = SourceEpoch(2);

    expect(
      () => current.requireMatch(const SourceEpoch(1)),
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.staleEpoch,
        ),
      ),
    );
    expect(current.next(), const SourceEpoch(3));
  });
}
