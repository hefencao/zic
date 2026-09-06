import 'package:flutter_test/flutter_test.dart';
import 'package:reader_runtime/reader_runtime.dart';

void main() {
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
