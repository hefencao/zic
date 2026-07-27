import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';
import 'package:test/test.dart';

void main() {
  test('backoff doubles and stops at the cap', () {
    const policy = RetryPolicy(
      maxAttempts: 5,
      baseDelay: Duration(milliseconds: 100),
      maxDelay: Duration(milliseconds: 250),
    );
    expect(policy.delayAfter(1), const Duration(milliseconds: 100));
    expect(policy.delayAfter(2), const Duration(milliseconds: 200));
    expect(policy.delayAfter(3), const Duration(milliseconds: 250));
    expect(
      policy.allows(
        const Failure(code: ErrorCode.network, message: 'network'),
        2,
      ),
      isTrue,
    );
    expect(
      policy.allows(
        const Failure(code: ErrorCode.checksumMismatch, message: 'bad'),
        1,
      ),
      isFalse,
    );
  });

  test('delay configuration is validated outside const evaluation', () {
    const policy = RetryPolicy(
      baseDelay: Duration(seconds: 2),
      maxDelay: Duration(seconds: 1),
    );
    expect(policy.validate, throwsArgumentError);
  });
}
