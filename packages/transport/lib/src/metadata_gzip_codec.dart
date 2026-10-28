import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

final class MetadataGzipLimitException implements Exception {
  const MetadataGzipLimitException();
}

/// File-content compression, independent of HTTP Content-Encoding or storage.
final class MetadataGzipCodec {
  const MetadataGzipCodec();

  List<int> encode(List<int> bytes) => gzip.encode(bytes);

  Uint8List decode(List<int> bytes, {required int maxBytes}) {
    final output = _BoundedGzipOutput(maxBytes);
    final input = gzip.decoder.startChunkedConversion(output);
    for (var offset = 0; offset < bytes.length; offset += 16384) {
      input.add(bytes.sublist(offset, min(offset + 16384, bytes.length)));
    }
    input.close();
    return output.bytes.takeBytes();
  }
}

final class _BoundedGzipOutput extends ByteConversionSinkBase {
  _BoundedGzipOutput(this.maxBytes);
  final int maxBytes;
  final bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> chunk) {
    if (bytes.length + chunk.length > maxBytes) {
      throw const MetadataGzipLimitException();
    }
    bytes.add(chunk);
  }
  @override
  void close() {}
}
