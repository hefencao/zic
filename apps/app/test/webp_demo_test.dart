import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
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

  test('picked WebP owns an explicit display name', () {
    final picked = PickedWebp(
      file: XFile.fromData(Uint8List(0), mimeType: 'image/webp'),
      displayName: ' local.webp ',
    );
    final screen = WebpPlayerScreen.file(
      picked.file,
      displayName: picked.displayName,
    );

    expect(picked.displayName, 'local.webp');
    expect(screen.title, 'local.webp');
    expect(screen.sourceUri.path, 'local.webp');
  });

  test('system-picked WebP falls back to the path basename', () {
    final picked = PickedWebp.fromFile(XFile('/tmp/imported/broken.webp'));

    expect(picked.displayName, 'broken.webp');
  });
}
