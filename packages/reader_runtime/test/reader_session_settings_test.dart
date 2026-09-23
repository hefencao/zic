import 'package:flutter_test/flutter_test.dart';
import 'package:reader_runtime/reader_runtime.dart';

void main() {
  test('source webtoon confidence participates in settings identity and copy',
      () {
    const baseline = ReaderSessionSettings(sourceWebtoonConfidence: 0.25);
    final changed = baseline.copyWith(sourceWebtoonConfidence: 0.75);

    expect(baseline.sourceWebtoonConfidence, 0.25);
    expect(changed.sourceWebtoonConfidence, 0.75);
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

  test('per-comic master gates adaptive override', () {
    const inherited = ReaderSessionSettings(
      globalAdaptiveEnabled: true,
      comicAdaptiveEnabled: false,
    );
    expect(inherited.effectiveAdaptiveEnabled, isTrue);

    const follow = ReaderSessionSettings(
      comicSpecificEnabled: true,
      globalAdaptiveEnabled: true,
      comicAdaptiveEnabled: false,
    );
    expect(follow.effectiveAdaptiveEnabled, isFalse);

    const adaptive = ReaderSessionSettings(
      comicSpecificEnabled: true,
      globalAdaptiveEnabled: true,
      comicAdaptiveEnabled: true,
    );
    expect(adaptive.effectiveAdaptiveEnabled, isTrue);
  });
}
