import 'package:sessions/sessions.dart';
import 'package:test/test.dart';

void main() {
  test('zero duration never creates an immediately due playback frame', () {
    final timer = PlaybackTimer();

    timer.start(
      frameIndex: 4,
      duration: Duration.zero,
      nowUs: 1000,
    );

    expect(timer.state, PlaybackState.idle);
    expect(timer.active, isFalse);
    expect(timer.takeDue(1000), isNull);
  });

  test('duration begins at actual present time and fires once', () {
    final timer = PlaybackTimer();
    timer.start(
      frameIndex: 4,
      duration: const Duration(milliseconds: 20),
      nowUs: 1000,
    );

    expect(timer.deadlineUs, 21000);
    expect(timer.takeDue(20999), isNull);
    expect(timer.takeDue(21000), 4);
    expect(timer.takeDue(22000), isNull);
    expect(timer.state, PlaybackState.idle);
  });

  test('freeze preserves remaining duration and resume restarts it', () {
    final timer = PlaybackTimer();
    timer.start(
      frameIndex: 2,
      duration: const Duration(milliseconds: 20),
      nowUs: 0,
    );

    expect(timer.freeze(5000), isTrue);
    expect(timer.deadlineUs, isNull);
    expect(timer.remainingUs(100000), 15000);
    expect(timer.takeDue(100000), isNull);
    expect(timer.resume(100000), isTrue);
    expect(timer.deadlineUs, 115000);
    expect(timer.takeDue(114999), isNull);
    expect(timer.takeDue(115000), 2);
  });

  test('starting a new frame replaces the previous deadline', () {
    final timer = PlaybackTimer();
    timer.start(
      frameIndex: 1,
      duration: const Duration(milliseconds: 10),
      nowUs: 0,
    );
    timer.start(
      frameIndex: 2,
      duration: const Duration(milliseconds: 30),
      nowUs: 5000,
    );

    expect(timer.takeDue(10000), isNull);
    expect(timer.takeDue(35000), 2);
  });
  test('reports playback lateness only while a frame is running', () {
    final timer = PlaybackTimer();
    timer.start(
      frameIndex: 7,
      duration: const Duration(milliseconds: 10),
      nowUs: 1000,
    );

    expect(timer.lateByUs(10999), 0);
    expect(timer.lateByUs(12000), 1000);
    expect(timer.freeze(12000), isTrue);
    expect(timer.lateByUs(20000), 0);
    expect(timer.resume(20000), isTrue);
    expect(timer.lateByUs(20000), 0);
  });
}
