import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';
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
    this.adoptInto,
  });

  final int length;
  final Validators validators;
  final int? totalLength;
  final Stream<List<int>> Function({required int start}) open;

  /// Optional exclusive mutable-spool adoption. Only a store that can prove a
  /// POSIX session-owned partial and keep its index/cleanup authority alive may
  /// expose this. SAF and generic stream stores leave it null and use [open].
  final Future<bool> Function(
    DownloadSession session, {
    TaskControl? control,
  })? adoptInto;
}

abstract interface class PartialDownloadStore {
  Future<PartialDownloadEntry?> openPartialDownload(DownloadId id);

  Future<void> storePartialDownload({
    required DownloadId id,
    required PartialDownloadEntry entry,
  });

  Future<void> invalidatePartialDownload(DownloadId id);
}
