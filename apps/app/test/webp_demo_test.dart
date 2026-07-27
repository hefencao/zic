import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/webp_demo.dart';

File _nativeFixture(String name) {
  final candidates = <File>[
    File('native/media_core/testdata/$name'),
    File('../../native/media_core/testdata/$name'),
  ];
  return candidates.firstWhere(
    (file) => file.existsSync(),
    orElse: () => throw StateError('Missing native fixture: $name'),
  );
}

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

  test('PickedWebp owns its explicit display-name contract', () {
    final picked = PickedWebp(
      file: XFile('/virtual/source-with-unrelated-name'),
      displayName: ' local.webp ',
    );
    final screen = WebpPlayerScreen.picked(picked);

    expect(picked.displayName, 'local.webp');
    expect(screen.title, 'local.webp');
    expect(screen.sourceUri.path, '/virtual/source-with-unrelated-name');
  });

  test('system picker wraps the selected file', () async {
    final file = XFile('/tmp/imported/selected.webp');

    final picked = await pickLocalWebp(selectFile: () async => file);

    expect(picked, isNotNull);
    expect(picked!.file, same(file));
    expect(picked.displayName, 'selected.webp');
  });

  test('system picker preserves cancellation as null', () async {
    final picked = await pickLocalWebp(selectFile: () async => null);

    expect(picked, isNull);
  });

  test('valid local WebP passes container validation', () {
    final bytes = _nativeFixture('finite_loop.webp').readAsBytesSync();

    final info = parseWebpInfo(bytes);

    expect(info.width, greaterThan(0));
    expect(info.height, greaterThan(0));
  });

  test('malformed local WebP fails container validation', () {
    final bytes = Uint8List.fromList(<int>[
      0x52,
      0x49,
      0x46,
      0x46,
      0,
      0,
      0,
      0,
      0x57,
      0x45,
      0x42,
      0x50,
    ]);

    expect(() => parseWebpInfo(bytes), throwsFormatException);
  });
}
