import 'package:test/test.dart';
import 'package:transport/transport.dart';

void main() {
  test('sniffs WebP and GIF signatures', () {
    expect(
      sniffContent(<int>[
        ...'RIFF'.codeUnits,
        0,
        0,
        0,
        0,
        ...'WEBP'.codeUnits,
      ]),
      ContentKind.webp,
    );
    expect(sniffContent('GIF89a'.codeUnits), ContentKind.gif);
  });

  test('waits for enough bytes before fallback', () {
    expect(sniffContent(<int>[1, 2, 3]), ContentKind.unknown);
    expect(
      sniffContent(List<int>.filled(sniffPrefixLength, 1)),
      ContentKind.fallback,
    );
  });

  test('recognizes the supported encoded image signature families', () {
    expect(
      sniffEncodedImageKind(const <int>[0xff, 0xd8, 0xff]),
      EncodedImageKind.jpeg,
    );
    expect(
      sniffEncodedImageKind(
        const <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
      ),
      EncodedImageKind.png,
    );
    expect(
      sniffEncodedImageKind(<int>[
        ...'RIFF'.codeUnits,
        0,
        0,
        0,
        0,
        ...'WEBP'.codeUnits,
      ]),
      EncodedImageKind.webp,
    );
    expect(sniffEncodedImageKind('GIF89a'.codeUnits), EncodedImageKind.gif);
    expect(
      sniffEncodedImageKind(const <int>[0x42, 0x4d]),
      EncodedImageKind.bmp,
    );
    expect(
      sniffEncodedImageKind(const <int>[0x49, 0x49, 0x2a, 0x00]),
      EncodedImageKind.tiff,
    );
    expect(
      sniffEncodedImageKind(const <int>[0x00, 0x00, 0x01, 0x00]),
      EncodedImageKind.ico,
    );
    expect(
      sniffEncodedImageKind(<int>[
        0,
        0,
        0,
        24,
        ...'ftyp'.codeUnits,
        ...'isom'.codeUnits,
        0,
        0,
        0,
        0,
        ...'avif'.codeUnits,
      ]),
      EncodedImageKind.avif,
    );
    expect(
      sniffEncodedImageKind(<int>[
        0,
        0,
        0,
        24,
        ...'ftyp'.codeUnits,
        ...'mif1'.codeUnits,
      ]),
      EncodedImageKind.heif,
    );
  });

  test('generic fallback classification is not image validity', () {
    final html = '<html>not an image</html>'.codeUnits;
    expect(sniffContent(html), ContentKind.fallback);
    expect(sniffEncodedImageKind(html), isNull);
    expect(hasSupportedEncodedImageSignature(html), isFalse);
  });
}
