import 'package:bridge/bridge.dart';
import 'package:test/test.dart';

void main() {
  test('native enum ordering matches the C ABI', () {
    expect(SourceStatus.ok.index, 0);
    expect(SourceStatus.staleEpoch.index, 2);
    expect(SourceStatus.budget.index, 5);
    expect(SourceKind.unknown.index, 0);
    expect(SourceKind.webp.index, 1);
    expect(SourceKind.gif.index, 2);
    expect(SourceKind.other.index, 3);
  });

  test('native version value object is independent of dynamic loading', () {
    const version = NativeVersion(abiVersion: 2, libVersion: 0x00070000);
    expect(version.abiVersion, 2);
    expect(version.libVersion, 0x00070000);
  });
}
