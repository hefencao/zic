import 'package:media/media.dart';
import 'package:test/test.dart';

void main() {
  test('preparation time is subtracted from encoded frame duration', () {
    expect(
      FramePacing.remaining(
        frameDuration: const Duration(milliseconds: 120),
        preparationElapsed: const Duration(milliseconds: 45),
      ),
      const Duration(milliseconds: 75),
    );
  });

  test('preparation overrun makes the next frame immediately due', () {
    expect(
      FramePacing.remaining(
        frameDuration: const Duration(milliseconds: 80),
        preparationElapsed: const Duration(milliseconds: 100),
      ),
      Duration.zero,
    );
  });

  test('a long animation does not add preparation time twice', () {
    const frames = 145;
    const duration = Duration(milliseconds: 124);
    const preparation = Duration(milliseconds: 55);
    var wall = Duration.zero;

    for (var i = 0; i < frames; i++) {
      wall += preparation;
      wall += FramePacing.remaining(
        frameDuration: duration,
        preparationElapsed: preparation,
      );
    }

    expect(
      wall,
      Duration(milliseconds: duration.inMilliseconds * frames),
    );
  });
}
