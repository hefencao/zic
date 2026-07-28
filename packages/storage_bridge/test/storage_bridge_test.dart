import 'package:flutter_test/flutter_test.dart';
import 'package:storage_bridge/storage_bridge.dart';

void main() {
  test('default imported library factory is exposed', () {
    expect(openDefaultImportedLibraryStore, isA<Function>());
  });
}
