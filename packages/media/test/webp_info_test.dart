import 'dart:io';
import 'dart:typed_data';

import 'package:media/media.dart';
import 'package:test/test.dart';

File _fixture(String relativePath) {
  for (final prefix in <String>['', '../../', 'packages/media/../../']) {
    final candidate = File('$prefix$relativePath');
    if (candidate.existsSync()) return candidate;
  }
  return File(relativePath);
}

void main() {
  test('reads VP8X canvas from the partial-blend fixture', () {
    final bytes = _fixture('native/media_core/testdata/partial_blend.webp').readAsBytesSync();

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
    final bytes = _fixture('native/media_core/testdata/partial_blend.webp').readAsBytesSync();
    final prefix = Uint8List.fromList(bytes.sublist(0, 30));

    final info = parseWebpPrefixInfo(prefix);

    expect(info, isNotNull);
    expect(info!.width, 4);
    expect(info.height, 4);
    expect(webpPrefixDeclaresAnimation(prefix), isTrue);
    expect(
      parseWebpPrefixAnimationEvidence(prefix),
      WebpAnimationEvidence.animated,
    );
  });

  test('VP8X prefix proves static without the complete image body', () {
    final prefix = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46,
      0xf4, 0x03, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50,
      0x56, 0x50, 0x38, 0x58,
      0x0a, 0x00, 0x00, 0x00,
      0x00,
      0, 0, 0,
      0x7f, 0x02, 0,
      0xaf, 0x04, 0,
    ]);

    expect(
      parseWebpPrefixAnimationEvidence(prefix),
      WebpAnimationEvidence.staticImage,
    );
    expect(webpPrefixDeclaresAnimation(prefix), isFalse);
  });


  test('reads VP8 canvas before the declared image chunk is complete', () {
    final prefix = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, // RIFF
      0xf4, 0x03, 0x00, 0x00, // declared RIFF payload is much larger
      0x57, 0x45, 0x42, 0x50, // WEBP
      0x56, 0x50, 0x38, 0x20, // VP8
      0xe8, 0x03, 0x00, 0x00, // 1000-byte compressed image chunk
      0x00, 0x00, 0x00,
      0x9d, 0x01, 0x2a,
      0x80, 0x02, // width = 640
      0xb0, 0x04, // height = 1200
    ]);

    final info = parseWebpPrefixInfo(prefix);

    expect(info, isNotNull);
    expect(info!.width, 640);
    expect(info.height, 1200);
  });

  test('incomplete WebP signature waits for more metadata', () {
    final prefix = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46,
      0, 0, 0, 0,
      0x57, 0x45, 0x42, 0x50,
    ]);

    expect(parseWebpPrefixInfo(prefix), isNull);
    expect(parseWebpPrefixAnimationEvidence(prefix), isNull);
    expect(webpPrefixDeclaresAnimation(prefix), isFalse);
    expect(estimateWebpPlayablePrefixBytes(prefix), 256 * 1024);
  });

  test('estimateWebpPlayablePrefixBytes calculates generous threshold for animated webp', () {
    final bytes = _fixture('native/media_core/testdata/partial_blend.webp').readAsBytesSync();
    final estimate = estimateWebpPlayablePrefixBytes(
      bytes,
      totalLength: bytes.length,
    );
    expect(estimate, bytes.length);
  });
}
