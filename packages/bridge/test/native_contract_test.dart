import 'package:bridge/bridge.dart';
import 'package:test/test.dart';

void main() {
  test('native enum ordering matches the C ABI', () {
    expect(SourceStatus.ok.index, 0);
    expect(SourceStatus.staleEpoch.index, 2);
    expect(SourceStatus.budget.index, 5);
    expect(SourceStatus.failed.index, 6);
    expect(SourceKind.unknown.index, 0);
    expect(SourceKind.webp.index, 1);
    expect(SourceKind.gif.index, 2);
    expect(SourceKind.other.index, 3);
  });

  test('native cursor factory satisfies the media contract', () {
    expect(const NativeCursorFactory(), isA<CursorFactory>());
  });

  test('native version value object is independent of dynamic loading', () {
    const version = NativeVersion(abiVersion: 4, libVersion: 0x000E0000);
    expect(version.abiVersion, 4);
    expect(version.libVersion, 0x000E0000);
  });
}
