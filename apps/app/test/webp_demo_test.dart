import 'package:flutter_test/flutter_test.dart';
import 'package:zic/webp_demo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled Animated WebP index contains the native fixtures', () async {
    final entries = await loadWebpDemoEntries();

    expect(entries, hasLength(3));
    expect(entries.map((entry) => entry.asset).toList(), <String>[
      'assets/demo/animated/animated.webp',
      'assets/demo/animated/finite_loop.webp',
      'assets/demo/animated/partial_blend.webp',
    ]);
    expect(entries.map((entry) => entry.frameCount).toList(), everyElement(2));
  });
}
