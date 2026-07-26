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
}
