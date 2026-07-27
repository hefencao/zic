import 'package:media/media.dart';
import 'package:test/test.dart';

void main() {
  test('animation metadata distinguishes infinite and finite play counts', () {
    const unknown = AnimationInfo.unknown();
    expect(unknown.complete, isFalse);
    expect(unknown.infinite, isFalse);
    expect(unknown.allowsCycle(0), isFalse);

    const infinite = AnimationInfo(
      frameCount: 2,
      loopCount: 0,
      complete: true,
    );
    expect(infinite.infinite, isTrue);
    expect(infinite.allowsCycle(1000), isTrue);

    const finite = AnimationInfo(
      frameCount: 2,
      loopCount: 2,
      complete: true,
    );
    expect(finite.allowsCycle(0), isTrue);
    expect(finite.allowsCycle(1), isTrue);
    expect(finite.allowsCycle(2), isFalse);
  });
}
