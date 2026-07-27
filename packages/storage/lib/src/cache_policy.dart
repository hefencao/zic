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

  int get plannedBytes =>
      candidates.fold<int>(0, (sum, record) => sum + record.bytes);

  int get projectedBytes => totalBytes - plannedBytes;
}

final class CachePolicy {
  const CachePolicy();

  EvictPlan plan({
    required Iterable<CacheRec> records,
    required CacheLimits limits,
    Set<String> protectedKeys = const <String>{},
  }) {
    final all = records.toList(growable: false);
    final total = all.fold<int>(0, (sum, record) => sum + record.bytes);
    final protectedBytes = all
        .where((record) => protectedKeys.contains(record.key))
        .fold<int>(0, (sum, record) => sum + record.bytes);
    if (total <= limits.maxBytes) {
      return EvictPlan(
        totalBytes: total,
        targetBytes: limits.targetBytes,
        protectedBytes: protectedBytes,
        candidates: const <CacheRec>[],
      );
    }

    final candidates = all
        .where((record) => !protectedKeys.contains(record.key))
        .toList(growable: false)
      ..sort((a, b) {
        final touched = a.touchedUs.compareTo(b.touchedUs);
        if (touched != 0) {
          return touched;
        }
        final state = a.state.index.compareTo(b.state.index);
        if (state != 0) {
          return state;
        }
        return a.key.compareTo(b.key);
      });

    final selected = <CacheRec>[];
    var projected = total;
    for (final record in candidates) {
      if (projected <= limits.targetBytes) {
        break;
      }
      selected.add(record);
      projected -= record.bytes;
    }
    return EvictPlan(
      totalBytes: total,
      targetBytes: limits.targetBytes,
      protectedBytes: protectedBytes,
      candidates: selected,
    );
  }
}
