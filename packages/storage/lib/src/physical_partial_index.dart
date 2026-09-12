import 'package:domain/domain.dart';

/// Durable metadata for one mutable physical encoded-body prefix.
///
/// Unlike the exact logical cache-binding record, this is not a DownloadId binding. It owns
/// one single-writer partial body keyed only by [PhysicalMediaId]. Provider
/// request identity and validators stay outside this storage contract.
final class PhysicalPartialRecord {
  const PhysicalPartialRecord({
    required this.id,
    required this.path,
    required this.bytes,
    required this.checksum,
    required this.createdUs,
    required this.touchedUs,
    this.checksumAlgorithm = 'crc32',
    this.storageRootId = 'default',
  }) : assert(bytes > 0);

  final PhysicalMediaId id;
  final String path;
  final int bytes;
  final String checksum;
  final int createdUs;
  final int touchedUs;
  final String checksumAlgorithm;
  final String storageRootId;

  String get key => id.key;

  PhysicalPartialRecord copyWith({
    String? path,
    int? bytes,
    String? checksum,
    int? createdUs,
    int? touchedUs,
    String? checksumAlgorithm,
    String? storageRootId,
  }) =>
      PhysicalPartialRecord(
        id: id,
        path: path ?? this.path,
        bytes: bytes ?? this.bytes,
        checksum: checksum ?? this.checksum,
        createdUs: createdUs ?? this.createdUs,
        touchedUs: touchedUs ?? this.touchedUs,
        checksumAlgorithm: checksumAlgorithm ?? this.checksumAlgorithm,
        storageRootId: storageRootId ?? this.storageRootId,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PhysicalPartialRecord &&
          id == other.id &&
          path == other.path &&
          bytes == other.bytes &&
          checksum == other.checksum &&
          createdUs == other.createdUs &&
          touchedUs == other.touchedUs &&
          checksumAlgorithm == other.checksumAlgorithm &&
          storageRootId == other.storageRootId;

  @override
  int get hashCode => Object.hash(
        id,
        path,
        bytes,
        checksum,
        createdUs,
        touchedUs,
        checksumAlgorithm,
        storageRootId,
      );
}

/// Optional durable owner for mutable physical partials.
///
/// This interface is intentionally separate from [CacheIndex]: `cache_entry`
/// remains the exact logical READY/manual binding projection while mutable
/// partials become physical-body state. Implementations may coexist during a
/// lazy migration period where legacy exact partial CacheRec rows are still
/// readable as compatibility fallbacks.
abstract interface class PhysicalPartialIndex {
  Future<PhysicalPartialRecord?> getPhysicalPartial(PhysicalMediaId id);

  Future<List<PhysicalPartialRecord>> listPhysicalPartials();

  Future<void> putPhysicalPartial(PhysicalPartialRecord record);

  Future<void> removePhysicalPartial(PhysicalMediaId id);

  Future<void> touchPhysicalPartial(PhysicalMediaId id, int touchedUs);
}
