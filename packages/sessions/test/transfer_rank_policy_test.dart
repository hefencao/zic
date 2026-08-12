import 'package:sessions/sessions.dart';
import 'package:test/test.dart';

void main() {
  test('full-body catchup is one demand-rank versus cost-rank comparison', () {
    const policy = TransferRankPolicy();

    expect(
      policy.allowsFullBodyCatchup(
        priority: 0,
        completionRequired: false,
        preservedLength: 512 * 1024,
      ),
      isTrue,
    );
    expect(
      policy.allowsFullBodyCatchup(
        priority: 819,
        completionRequired: false,
        preservedLength: 2 * 1024 * 1024,
      ),
      isFalse,
    );
    expect(
      policy.allowsFullBodyCatchup(
        priority: 820,
        completionRequired: false,
        preservedLength: 2 * 1024 * 1024,
      ),
      isTrue,
    );
    expect(
      policy.allowsFullBodyCatchup(
        priority: 899,
        completionRequired: false,
        preservedLength: 9 * 1024 * 1024,
      ),
      isFalse,
    );
    expect(
      policy.allowsFullBodyCatchup(
        priority: 900,
        completionRequired: false,
        preservedLength: 9 * 1024 * 1024,
      ),
      isTrue,
    );
    expect(
      policy.allowsFullBodyCatchup(
        priority: 1,
        completionRequired: true,
        preservedLength: 64 * 1024 * 1024,
      ),
      isTrue,
    );
  });
}
