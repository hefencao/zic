import 'cache_index.dart';

final class CacheLimits {
  const CacheLimits({required this.maxBytes, int? targetBytes})
      : targetBytes = targetBytes ?? maxBytes,
        assert(maxBytes >= 0),
        assert((targetBytes ?? maxBytes) >= 0),
        assert((targetBytes ?? maxBytes) <= maxBytes);

  final int maxBytes;
  final int targetBytes;
}

final class EvictPlan {
  EvictPlan({
    required this.totalBytes,
    required this.targetBytes,
    required this.protectedBytes,
    required List<CacheRec> candidates,
  }) : candidates = List<CacheRec>.unmodifiable(candidates);

  final int totalBytes;
  final int targetBytes;
  final int protectedBytes;
  final List<CacheRec> candidates;

  int get plannedBytes => physicalCacheBytes(candidates);

  int get projectedBytes => totalBytes - plannedBytes;
}

final class CachePolicy {
  const CachePolicy();

  EvictPlan plan({
    required Iterable<CacheRec> records,
    required CacheLimits limits,
    Set<String> protectedKeys = const <String>{},
  }) {
    final groups = _groupPhysicalRecords(records);
    final total = groups.fold<int>(0, (sum, group) => sum + group.bytes);
    final protectedBytes = groups
        .where(
          (group) => group.records.any(
            (record) => protectedKeys.contains(record.key),
          ),
        )
        .fold<int>(0, (sum, group) => sum + group.bytes);
    if (total <= limits.maxBytes) {
      return EvictPlan(
        totalBytes: total,
        targetBytes: limits.targetBytes,
        protectedBytes: protectedBytes,
        candidates: const <CacheRec>[],
      );
    }

    final candidates = groups
        .where(
          (group) => !group.records.any(
            (record) => protectedKeys.contains(record.key),
          ),
        )
        .toList(growable: false)
      ..sort((a, b) {
        final touched = a.touchedUs.compareTo(b.touchedUs);
        if (touched != 0) return touched;
        final state = a.state.index.compareTo(b.state.index);
        if (state != 0) return state;
        return a.key.compareTo(b.key);
      });

    final selected = <CacheRec>[];
    var projected = total;
    for (final group in candidates) {
      if (projected <= limits.targetBytes) break;
      selected.addAll(group.records);
      projected -= group.bytes;
    }
    return EvictPlan(
      totalBytes: total,
      targetBytes: limits.targetBytes,
      protectedBytes: protectedBytes,
      candidates: selected,
    );
  }
}

List<_PhysicalCacheGroup> _groupPhysicalRecords(Iterable<CacheRec> records) {
  final grouped = <String, List<CacheRec>>{};
  for (final record in records) {
    grouped.putIfAbsent(physicalCacheKey(record), () => <CacheRec>[]).add(record);
  }
  return <_PhysicalCacheGroup>[
    for (final entry in grouped.entries) _PhysicalCacheGroup(entry.key, entry.value),
  ];
}

final class _PhysicalCacheGroup {
  _PhysicalCacheGroup(this.key, List<CacheRec> records)
      : records = List<CacheRec>.unmodifiable(records),
        bytes = records.fold<int>(
          0,
          (value, record) => record.bytes > value ? record.bytes : value,
        ),
        touchedUs = records.fold<int>(
          0,
          (value, record) => record.touchedUs > value ? record.touchedUs : value,
        ),
        state = records.any((record) => record.state == CacheState.ready)
            ? CacheState.ready
            : CacheState.partial;

  final String key;
  final List<CacheRec> records;
  final int bytes;
  final int touchedUs;
  final CacheState state;
}
