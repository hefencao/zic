import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:transport/transport.dart';

/// Read-only transport that lets bundled Reader assets use the same
/// DownloadJob/Artifact lifecycle as file and network media.
final class AssetBundleTransport implements Transport {
  const AssetBundleTransport(this.bundle);

  final AssetBundle bundle;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    range?.validate();
    final asset = uri.scheme == 'asset'
        ? uri.path.replaceFirst(RegExp(r'^/+'), '')
        : uri.toString();
    final data = await bundle.load(asset);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final currentValidators = Validators(etag: '"${bytes.length}:$asset"');
    final canServeRange = range != null &&
        range.start <= bytes.length &&
        (validators == null ||
            validators.isEmpty ||
            validators.matches(currentValidators));
    final start = canServeRange ? range!.start : 0;
    final requestedEnd = canServeRange ? range!.end : null;
    final endExclusive = requestedEnd == null
        ? bytes.length
        : (requestedEnd + 1).clamp(start, bytes.length).toInt();
    final chunk = Uint8List.sublistView(bytes, start, endExclusive);
    return ByteResponse(
      bytes: Stream<List<int>>.value(chunk),
      statusCode: canServeRange ? 206 : 200,
      rangeStart: start,
      totalLength: bytes.length,
      validators: currentValidators,
      rangeSupported: true,
    );
  }
}
