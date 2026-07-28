import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_media/local_media.dart';

void main() {
  test('image signature detector recognizes supported raster families', () {
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
      'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    expect(detectLocalImageFormat(png), LocalImageFormat.png);
    expect(
      detectLocalImageFormat(
        Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0xe0]),
      ),
      LocalImageFormat.jpeg,
    );
    expect(
      detectLocalImageFormat(
        Uint8List.fromList(<int>[
          ...'RIFF'.codeUnits,
          22,
          0,
          0,
          0,
          ...'WEBP'.codeUnits,
          ...'VP8X'.codeUnits,
        ]),
      ),
      LocalImageFormat.webp,
    );
  });

  test('image signature detector rejects truncated container labels', () {
    expect(
      detectLocalImageFormat(
        Uint8List.fromList(<int>[
          0x89,
          0x50,
          0x4e,
          0x47,
          0x0d,
          0x0a,
          0x1a,
          0x0a,
          0,
          0,
          0,
          13,
          ...'IHDR'.codeUnits,
          0,
          0,
          0,
          1,
          0,
          0,
          0,
          1,
        ]),
      ),
      isNull,
    );
  });
}
