import 'package:domain/domain.dart';
import 'package:transport/transport.dart';

final class OpenReq {
  const OpenReq({required this.uri, this.range, this.validators});

  final Uri uri;
  final ByteRange? range;
  final Validators? validators;
}

final class FakeTransport implements Transport {
  FakeTransport({
    required List<int> bytes,
    this.chunkSize = 4,
    this.rangeSupported = true,
    this.validators = const Validators(etag: 'fixture-v1'),
    this.failAfterBytes,
  }) : bytes = List<int>.unmodifiable(bytes);

  final List<int> bytes;
  final int chunkSize;
  final bool rangeSupported;
  final Validators validators;
  final int? failAfterBytes;
  final List<OpenReq> requests = <OpenReq>[];
  int discardCount = 0;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    range?.validate();
    requests.add(OpenReq(uri: uri, range: range, validators: validators));

    final canServeRange = range != null &&
        rangeSupported &&
        range.start <= bytes.length &&
        (validators == null || validators.isEmpty || validators.matches(this.validators));
    final start = canServeRange ? range!.start : 0;

    return ByteResponse(
      bytes: _chunks(start),
      statusCode: canServeRange ? 206 : 200,
      rangeStart: start,
      totalLength: bytes.length,
      validators: this.validators,
      rangeSupported: rangeSupported,
      onDiscard: () async {
        discardCount++;
      },
    );
  }

  Stream<List<int>> _chunks(int start) async* {
    var emitted = 0;
    var offset = start;
    while (offset < bytes.length) {
      if (failAfterBytes != null && emitted >= failAfterBytes!) {
        throw const Failure(
          code: ErrorCode.network,
          message: 'injected transport failure',
        );
      }
      final remainingBeforeFailure = failAfterBytes == null
          ? bytes.length - offset
          : failAfterBytes! - emitted;
      if (remainingBeforeFailure <= 0) {
        throw const Failure(
          code: ErrorCode.network,
          message: 'injected transport failure',
        );
      }
      var end = offset + chunkSize;
      if (end > bytes.length) {
        end = bytes.length;
      }
      final failureEnd = offset + remainingBeforeFailure;
      if (end > failureEnd) {
        end = failureEnd;
      }
      final chunk = bytes.sublist(offset, end);
      yield chunk;
      emitted += chunk.length;
      offset = end;
    }
  }
}
