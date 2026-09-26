import 'package:domain/domain.dart' show TaskControl;

enum SourceStatus {
  ok,
  nullPointer,
  staleEpoch,
  invalidOffset,
  sealed,
  budget,
  failed,
}

enum SourceKind { unknown, webp, gif, other }

abstract interface class EncodedSource {
  int get epoch;
  int get length;
  bool get sealed;
  SourceKind get kind;

  SourceStatus append({
    required int epoch,
    required int offset,
    required List<int> bytes,
  });

  SourceStatus seal(int epoch);
  SourceStatus reset(int epoch);
  void dispose();
}

abstract interface class ExpectedLengthEncodedSource {
  SourceStatus reserveExpectedLength({
    required int epoch,
    required int length});
}

/// Optional execution capability for encoded sources whose storage mutation
/// can run outside the caller isolate.
///
/// [Ingress] uses this only for asynchronous replay/materialization. Ordinary
/// live append semantics remain synchronous, so transport ownership and source
/// ordering do not move into the worker implementation.
abstract interface class BackgroundWritableEncodedSource {
  Future<SourceStatus> reserveExpectedLengthInBackground({
    required int epoch,
    required int length,
    TaskControl? control,
  });

  Future<SourceStatus> appendInBackground({
    required int epoch,
    required int offset,
    required List<int> bytes,
    TaskControl? control,
  });
}

/// Optional execution capability for immutable direct-file authorities.
///
/// The caller provides only an already-validated generation-scoped locator and
/// range. Concrete native sources may perform both file I/O and native buffer
/// mutation outside the caller isolate, so encoded body bytes never need to be
/// materialized on the Reader/UI isolate.
abstract interface class BackgroundFileRangeWritableEncodedSource {
  Future<SourceStatus> appendFileRangeInBackground({
    required int epoch,
    required int offset,
    required String path,
    required int fileOffset,
    required int length,
    TaskControl? control,
  });
}

abstract interface class SourceFactory {
  EncodedSource create({required int epoch, required int maxBytes});
}
