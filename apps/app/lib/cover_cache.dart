import 'dart:typed_data';

final class CoverCacheStats {
  const CoverCacheStats({
    required this.entries,
    required this.inFlight,
    required this.bytes,
    required this.hits,
    required this.misses,
    required this.evictions,
  });

  final int entries;
  final int inFlight;
  final int bytes;
  final int hits;
  final int misses;
  final int evictions;
}

/// Bounded in-memory cache for compressed cover bytes.
///
/// It coalesces concurrent reads for the same key and applies LRU eviction after
/// a load completes. Flutter's decoded image cache remains a separate concern;
/// callers should still request an appropriately resized decode.
final class CoverMemoryCache {
  CoverMemoryCache({
    this.maxBytes = 32 * 1024 * 1024,
    this.maxEntries = 96,
  })  : assert(maxBytes > 0),
        assert(maxEntries > 0);

  final int maxBytes;
  final int maxEntries;

  final Map<String, _CoverCacheEntry> _entries = <String, _CoverCacheEntry>{};
  var _clock = 0;
  var _bytes = 0;
  var _hits = 0;
  var _misses = 0;
  var _evictions = 0;

  CoverCacheStats get stats => CoverCacheStats(
        entries: _entries.values.where((entry) => entry.bytes != null).length,
        inFlight: _entries.values.where((entry) => entry.bytes == null).length,
        bytes: _bytes,
        hits: _hits,
        misses: _misses,
        evictions: _evictions,
      );

  Future<Uint8List> load(
    String key,
    Future<Uint8List> Function() loader,
  ) {
    final current = _entries[key];
    if (current != null) {
      _hits++;
      current.touched = ++_clock;
      return current.future;
    }

    _misses++;
    final entry = _CoverCacheEntry(touched: ++_clock);
    _entries[key] = entry;
    entry.future = Future<Uint8List>.sync(loader).then((bytes) {
      if (!identical(_entries[key], entry)) {
        return bytes;
      }
      if (bytes.lengthInBytes > maxBytes) {
        _entries.remove(key);
        return bytes;
      }
      entry.bytes = bytes;
      _bytes += bytes.lengthInBytes;
      _evict(protectedKey: key);
      return bytes;
    }, onError: (Object error, StackTrace stackTrace) {
      if (identical(_entries[key], entry)) {
        _entries.remove(key);
      }
      Error.throwWithStackTrace(error, stackTrace);
    });
    return entry.future;
  }

  void invalidate(String key) {
    final removed = _entries.remove(key);
    final bytes = removed?.bytes;
    if (bytes != null) {
      _bytes -= bytes.lengthInBytes;
    }
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
  }

  void _evict({required String protectedKey}) {
    while (_bytes > maxBytes || _completedEntryCount > maxEntries) {
      String? victimKey;
      _CoverCacheEntry? victim;
      for (final candidate in _entries.entries) {
        final entry = candidate.value;
        if (candidate.key == protectedKey || entry.bytes == null) {
          continue;
        }
        if (victim == null || entry.touched < victim.touched) {
          victimKey = candidate.key;
          victim = entry;
        }
      }
      if (victimKey == null || victim == null) {
        return;
      }
      _entries.remove(victimKey);
      _bytes -= victim.bytes!.lengthInBytes;
      _evictions++;
    }
  }

  int get _completedEntryCount =>
      _entries.values.where((entry) => entry.bytes != null).length;
}

final class _CoverCacheEntry {
  _CoverCacheEntry({required this.touched});

  late Future<Uint8List> future;
  Uint8List? bytes;
  int touched;
}
