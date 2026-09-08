import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';
import 'package:transport/transport.dart';

typedef PartialDownloadBoundRangeReader = ({
  String accessMode,
  Future<Uint8List> Function(int start, int endExclusive) readRange,
  Future<void> Function() close,
});

/// Durable owner for an incomplete page download after its hot DownloadSession
/// is truly evicted. Reader route detach/reentry must reuse the hot session
/// instead of checkpointing through this interface.
final class PartialDownloadEntry {
  const PartialDownloadEntry({
    required this.length,
    required this.validators,
    required this.open,
    this.openRange,
    this.openBoundRangeReader,
    this.accessMode = 'unknown',
    this.totalLength,
    this.adoptInto,
    this.exactDurableFinal = false,
  });

  final int length;
  final Validators validators;
  final int? totalLength;
  final Stream<List<int>> Function({required int start}) open;
  final Stream<List<int>> Function({
    required int start,
    required int endExclusive,
  })? openRange;

  /// Optional one-generation random-access reader acquired after the durable
  /// backend has already selected/validated the physical access path.
  final Future<PartialDownloadBoundRangeReader?> Function()? openBoundRangeReader;

  /// Non-sensitive selected access mode for diagnostics.
  final String accessMode;

  /// True only when this exact-id entry is already a complete durable final.
  /// A full restore can pass this operation-scoped proof to the promoted cache
  /// handoff so it need not immediately re-stat the same durable body.
  final bool exactDurableFinal;

  /// Optional exclusive mutable-spool adoption. Only a store that can prove a
  /// POSIX session-owned partial and keep its index/cleanup authority alive may
  /// expose this. SAF and generic stream stores leave it null and use [open].
  final Future<bool> Function(
    DownloadSession session, {
    TaskControl? control,
  })? adoptInto;
}

final class PartialDownloadMetadata {
  const PartialDownloadMetadata({
    required this.length,
    required this.exactDurableFinal,
  });

  final int length;
  final bool exactDurableFinal;
}

/// Optional cheap candidate-ranking capability. This metadata is never a body
/// authority: callers MUST still open the selected candidate through
/// [PartialDownloadStore.openPartialDownload] before restoring or binding it.
abstract interface class PartialDownloadMetadataStore {
  Future<PartialDownloadMetadata?> inspectPartialDownloadMetadata(DownloadId id);
}

abstract interface class PartialDownloadStore {
  Future<PartialDownloadEntry?> openPartialDownload(DownloadId id);

  Future<void> storePartialDownload({
    required DownloadId id,
    required PartialDownloadEntry entry,
  });

  Future<void> invalidatePartialDownload(DownloadId id);
}
