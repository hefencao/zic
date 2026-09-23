import 'package:flutter_test/flutter_test.dart';
import 'package:reader_runtime/reader_runtime.dart';

void main() {
  test('source webtoon weight participates in settings identity and copy', () {
    const baseline = ReaderSessionSettings(sourceWebtoonWeight: 0.25);
    final changed = baseline.copyWith(sourceWebtoonWeight: 0.75);

    expect(baseline.sourceWebtoonWeight, 0.25);
    expect(changed.sourceWebtoonWeight, 0.75);
    expect(changed, isNot(baseline));
  });

  test('page inversion is only effective for enabled per-comic settings', () {
    const disabled = ReaderSessionSettings(
      invertPageOrderOverride: true,
    );
    expect(disabled.effectiveInvertPageOrder, isFalse);

    const enabled = ReaderSessionSettings(
      comicSpecificEnabled: true,
      invertPageOrderOverride: true,
    );
    expect(enabled.effectiveInvertPageOrder, isTrue);

    expect(
      enabled.copyWith(comicSpecificEnabled: false).effectiveInvertPageOrder,
      isFalse,
    );
  });
}
