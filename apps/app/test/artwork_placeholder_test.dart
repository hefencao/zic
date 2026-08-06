import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/artwork_placeholder.dart';

void main() {
  test('artwork fallback colors are soft and vary by seed', () {
    final first = softArtworkColor('comic-a');
    final second = softArtworkColor('comic-b');
    final firstHsl = HSLColor.fromColor(first);

    expect(first, isNot(second));
    expect(firstHsl.saturation, inInclusiveRange(0.18, 0.31));
    expect(firstHsl.lightness, inInclusiveRange(0.76, 0.83));
  });

  testWidgets('artwork fallback does not show a broken-image icon', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 48,
          height: 64,
          child: SoftArtworkPlaceholder(seed: 'comic-a'),
        ),
      ),
    );

    expect(find.byType(Icon), findsNothing);
  });
}
