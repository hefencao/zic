import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transport/transport.dart';
import 'package:zic/asset_bundle_transport.dart';

void main() {
  test(
    'asset transport serves full and validator-matched range responses',
    () async {
      final transport = AssetBundleTransport(
        _MemoryBundle(<String, List<int>>{
          'assets/page.webp': <int>[1, 2, 3, 4, 5],
        }),
      );

      final full = await transport.open(Uri.parse('assets/page.webp'));
      final fullBytes = await full.bytes.expand((chunk) => chunk).toList();
      expect(full.statusCode, 200);
      expect(full.rangeStart, 0);
      expect(full.totalLength, 5);
      expect(fullBytes, <int>[1, 2, 3, 4, 5]);

      final partial = await transport.open(
        Uri.parse('asset:///assets/page.webp'),
        range: const ByteRange(start: 2, end: 3),
        validators: full.validators,
      );
      final partialBytes = await partial.bytes.expand((chunk) => chunk).toList();
      expect(partial.statusCode, 206);
      expect(partial.rangeStart, 2);
      expect(partial.totalLength, 5);
      expect(partialBytes, <int>[3, 4]);
    },
  );

  test('asset transport restarts when resume validators do not match', () async {
    final transport = AssetBundleTransport(
      _MemoryBundle(<String, List<int>>{
        'assets/page.webp': <int>[1, 2, 3],
      }),
    );

    final response = await transport.open(
      Uri.parse('assets/page.webp'),
      range: const ByteRange(start: 2),
      validators: const Validators(etag: 'stale'),
    );
    final bytes = await response.bytes.expand((chunk) => chunk).toList();

    expect(response.statusCode, 200);
    expect(response.rangeStart, 0);
    expect(bytes, <int>[1, 2, 3]);
  });
}

final class _MemoryBundle extends CachingAssetBundle {
  _MemoryBundle(this.assets);

  final Map<String, List<int>> assets;

  @override
  Future<ByteData> load(String key) async {
    final bytes = assets[key];
    if (bytes == null) {
      throw StateError('missing test asset: $key');
    }
    return ByteData.sublistView(Uint8List.fromList(bytes));
  }
}
