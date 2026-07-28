import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_media/local_media.dart';

void main() {
  test('image signature detector recognizes supported raster families', () {
    final cases = <LocalImageFormat, List<int>>{
      LocalImageFormat.png: base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
      LocalImageFormat.jpeg: <int>[0xff, 0xd8, 0xff, 0xe0],
      LocalImageFormat.gif: <int>[...'GIF89a'.codeUnits, 1, 0, 1, 0],
      LocalImageFormat.webp: <int>[
        ...'RIFF'.codeUnits,
        22,
        0,
        0,
        0,
        ...'WEBP'.codeUnits,
        ...'VP8X'.codeUnits,
        10,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
      ],
      LocalImageFormat.bmp: <int>[
        ...'BM'.codeUnits,
        26,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        14,
        0,
        0,
        0,
        12,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
      ],
      LocalImageFormat.tiff: <int>[
        0x49,
        0x49,
        0x2a,
        0x00,
        0x08,
        0x00,
        0x00,
        0x00,
      ],
      LocalImageFormat.ico: <int>[
        0x00,
        0x00,
        0x01,
        0x00,
        0x01,
        0x00,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
      ],
      LocalImageFormat.avif: <int>[
        0,
        0,
        0,
        20,
        ...'ftyp'.codeUnits,
        ...'avif'.codeUnits,
        0,
        0,
        0,
        0,
        ...'avif'.codeUnits,
      ],
      LocalImageFormat.heif: <int>[
        0,
        0,
        0,
        20,
        ...'ftyp'.codeUnits,
        ...'heic'.codeUnits,
        0,
        0,
        0,
        0,
        ...'mif1'.codeUnits,
      ],
    };

    for (final entry in cases.entries) {
      expect(
        detectLocalImageFormat(Uint8List.fromList(entry.value)),
        entry.key,
        reason: entry.key.name,
      );
    }
  });

  test('WebP sniffing tolerates metadata or unknown leading chunks', () {
    final bytes = Uint8List.fromList(<int>[
      ...'RIFF'.codeUnits,
      32,
      0,
      0,
      0,
      ...'WEBP'.codeUnits,
      ...'JUNK'.codeUnits,
      4,
      0,
      0,
      0,
      1,
      2,
      3,
      4,
    ]);

    expect(detectLocalImageFormat(bytes), LocalImageFormat.webp);
  });

  test('image signature detector rejects truncated container labels', () {
    expect(
      detectLocalImageFormat(
        Uint8List.fromList(<int>[
          ...'RIFF'.codeUnits,
          0,
          0,
          0,
          0,
          ...'WEB'.codeUnits,
        ]),
      ),
      isNull,
    );
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
        ]),
      ),
      isNull,
    );
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
        ]),
      ),
      isNull,
    );
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
          ...'IHD'.codeUnits,
        ]),
      ),
      isNull,
    );
    expect(
      detectLocalImageFormat(
        Uint8List.fromList(<int>[
          ...'RIFF'.codeUnits,
          0,
          0,
          0,
          0,
          ...'WEBP'.codeUnits,
        ]),
      ),
      isNull,
    );
  });

  test('image signature detector rejects extensions and arbitrary text', () {
    expect(
      detectLocalImageFormat(Uint8List.fromList('page.webp'.codeUnits)),
      isNull,
    );
    expect(detectLocalImageFormat(Uint8List(0)), isNull);
  });
}
