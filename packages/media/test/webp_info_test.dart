import 'dart:io';
import 'dart:typed_data';

import 'package:media/media.dart';
import 'package:test/test.dart';

void main() {
  test('reads VP8X canvas from the partial-blend fixture', () {
    final bytes = File(
      '../../native/media_core/testdata/partial_blend.webp',
    ).readAsBytesSync();

    final info = parseWebpInfo(bytes);

    expect(info.width, 4);
    expect(info.height, 4);
  });

  test('rejects a signature-only pseudo WebP', () {
    expect(
      () => parseWebpInfo(
        Uint8List.fromList(<int>[
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
        ]),
      ),
      throwsFormatException,
    );
  });

  test('reads animated canvas metadata from an incomplete WebP prefix', () {
    final bytes = File(
      '../../native/media_core/testdata/partial_blend.webp',
    ).readAsBytesSync();
    final prefix = Uint8List.fromList(bytes.sublist(0, 30));

    final info = parseWebpPrefixInfo(prefix);

    expect(info, isNotNull);
    expect(info!.width, 4);
    expect(info.height, 4);
    expect(webpPrefixDeclaresAnimation(prefix), isTrue);
  });

  test('incomplete WebP signature waits for more metadata', () {
    final prefix = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46,
      0, 0, 0, 0,
      0x57, 0x45, 0x42, 0x50,
    ]);

    expect(parseWebpPrefixInfo(prefix), isNull);
    expect(webpPrefixDeclaresAnimation(prefix), isFalse);
  });

}
