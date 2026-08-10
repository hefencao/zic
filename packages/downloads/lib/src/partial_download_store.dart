import 'package:domain/domain.dart';
import 'package:transport/transport.dart';

/// Durable owner for an incomplete page download after its hot DownloadSession
/// is truly evicted. Reader route detach/reentry must reuse the hot session
/// instead of checkpointing through this interface.
final class PartialDownloadEntry {
  const PartialDownloadEntry({
    required this.length,
    required this.validators,
    required this.open,
    this.totalLength,
  });

  final int length;
  final Validators validators;
  final int? totalLength;
  final Stream<List<int>> Function({required int start}) open;
}

abstract interface class PartialDownloadStore {
  Future<PartialDownloadEntry?> openPartialDownload(DownloadId id);

  Future<void> storePartialDownload({
    required DownloadId id,
    required PartialDownloadEntry entry,
  });

  Future<void> invalidatePartialDownload(DownloadId id);
}
