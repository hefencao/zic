import 'dart:async';
import 'dart:typed_data';

import 'media_load_token.dart';

final class ReaderPageCacheStats {
  const ReaderPageCacheStats({
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

/// Small bounded cache for encoded page bytes around the active Reader page.
///
/// The cache deliberately stores encoded bytes, not decoded frames. Decode and
/// texture ownership remains in sessions/native runtimes. Shared loads use an
/// internal token so one page widget being disposed does not cancel a warmup
/// still useful to the next page.
final class ReaderPageBytesCache {
  ReaderPageBytesCache({
    this.maxBytes = 96 * 1024 * 1024,
    this.maxEntries = 5,
  })  : assert(maxBytes > 0),
        assert(maxEntries > 0);

  final int maxBytes;
  final int maxEntries;

  final Map<String, _ReaderPageCacheEntry> _entries =
      <String, _ReaderPageCacheEntry>{};
  var _clock = 0;
  var _bytes = 0;
  var _hits = 0;
  var _misses = 0;
  var _evictions = 0;
  bool _closed = false;

  ReaderPageCacheStats get stats => ReaderPageCacheStats(
        entries: _entries.values.where((entry) => entry.bytes != null).length,
        inFlight: _entries.values.where((entry) => entry.bytes == null).length,
        bytes: _bytes,
        hits: _hits,
        misses: _misses,
        evictions: _evictions,
      );

  Future<Uint8List> load(
    String key,
    MediaLoadToken callerToken,
    Future<Uint8List> Function(MediaLoadToken token) loader,
  ) async {
    callerToken.throwIfCancelled();
    final entry = _entry(key, loader);
    entry.foregroundWaiters++;
    try {
      return await Future.any<Uint8List>(<Future<Uint8List>>[
        entry.future,
        callerToken.whenCancelled.then<Uint8List>((_) {
          callerToken.throwIfCancelled();
          throw StateError('unreachable cancellation path');
        }),
      ]);
    } finally {
      entry.foregroundWaiters--;
    }
  }

  Future<void> warm(
    String key,
    Future<Uint8List> Function(MediaLoadToken token) loader,
  ) async {
    if (_closed) {
      return;
    }
    try {
      await _entry(key, loader).future;
    } on Object {
      // Warmup failure is surfaced by the foreground page if it is requested.
    }
  }

  /// Cancels obsolete in-flight warmups while preserving active page callers.
  void retainWarmKeys(Set<String> keys) {
    for (final candidate in _entries.entries.toList(growable: false)) {
      final entry = candidate.value;
      if (entry.bytes == null &&
          entry.foregroundWaiters == 0 &&
          !keys.contains(candidate.key)) {
        entry.token.cancel();
      }
    }
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    final pending = <Future<Uint8List>>[];
    for (final entry in _entries.values) {
      if (entry.bytes == null) {
        entry.token.cancel();
        pending.add(entry.future);
      }
    }
    if (pending.isNotEmpty) {
      await Future.wait<void>(
        pending.map((future) async {
          try {
            await future;
          } on Object {
            // Cancellation/failure is expected during Reader shutdown.
          }
        }),
      );
    }
    _entries.clear();
    _bytes = 0;
  }

  _ReaderPageCacheEntry _entry(
    String key,
    Future<Uint8List> Function(MediaLoadToken token) loader,
  ) {
    if (_closed) {
      throw StateError('reader page cache is closed');
    }
    final existing = _entries[key];
    if (existing != null) {
      _hits++;
      existing.touched = ++_clock;
      return existing;
    }

    _misses++;
    final entry = _ReaderPageCacheEntry(
      token: MediaLoadToken(),
      touched: ++_clock,
    );
    _entries[key] = entry;
    entry.future = Future<Uint8List>.sync(() => loader(entry.token)).then(
      (bytes) {
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
      },
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_entries[key], entry)) {
          _entries.remove(key);
        }
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    return entry;
  }

  void _evict({required String protectedKey}) {
    while (_bytes > maxBytes || _completedEntryCount > maxEntries) {
      String? victimKey;
      _ReaderPageCacheEntry? victim;
      for (final candidate in _entries.entries) {
        final entry = candidate.value;
        if (candidate.key == protectedKey ||
            entry.bytes == null ||
            entry.foregroundWaiters > 0) {
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

final class _ReaderPageCacheEntry {
  _ReaderPageCacheEntry({required this.token, required this.touched});

  final MediaLoadToken token;
  late Future<Uint8List> future;
  Uint8List? bytes;
  int touched;
  int foregroundWaiters = 0;
}
