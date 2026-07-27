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

  test('cursor steps separate frame, incremental wait, and end states', () {
    final frame = _Frame();
    final ready = CursorStep.frame(frame);
    const waiting = CursorStep.needMoreData();
    const ended = CursorStep.end();

    expect(ready.kind, CursorStepKind.frame);
    expect(ready.frame, same(frame));
    expect(waiting.kind, CursorStepKind.needMoreData);
    expect(waiting.frame, isNull);
    expect(ended.kind, CursorStepKind.end);
    expect(ended.frame, isNull);
  });
}

final class _Frame implements FrameRef {
  @override
  int get epoch => 0;
  @override
  int get index => 0;
  @override
  int get width => 1;
  @override
  int get height => 1;
  @override
  int get byteLength => 4;
  @override
  Duration get duration => const Duration(milliseconds: 1);
  @override
  bool get disposed => false;

  @override
  void dispose() {}
}
