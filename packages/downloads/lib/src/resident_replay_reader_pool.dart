import 'dart:async';

import 'partial_download_store.dart';

/// Stable acceleration identity for one immutable resident artifact generation.
///
/// This key never creates byte authority. Callers may only construct it after
/// the persistent owner has already supplied a complete sealed generation.
final class ResidentReplayGenerationKey {
  const ResidentReplayGenerationKey({
    required this.physicalMediaKey,
    required this.length,
    required this.checksumAlgorithm,
    required this.checksum,
  });

  final String physicalMediaKey;
  final int length;
  final String checksumAlgorithm;
  final String checksum;

  @override
  bool operator ==(Object other) =>
      other is ResidentReplayGenerationKey &&
      other.physicalMediaKey == physicalMediaKey &&
      other.length == length &&
      other.checksumAlgorithm == checksumAlgorithm &&
      other.checksum == checksum;

  @override
  int get hashCode => Object.hash(
        physicalMediaKey,
        length,
        checksumAlgorithm,
        checksum,
      );
}

final class _ResidentReplayReaderPoolEntry {
  _ResidentReplayReaderPoolEntry({
    required this.reader,
    required this.lastUsed,
  });

  final PartialDownloadBoundRangeReader reader;
  int leases = 0;
  int lastUsed;
  bool retired = false;
  bool closed = false;
}

/// Retains a small number of already-preflighted immutable range readers.
///
/// DownloadSession owns only a lease. Releasing a session returns the reader to
/// this pool so a later session for the exact same sealed generation does not
/// have to reopen a slow SAF/provider descriptor. Reader failure retires the
/// pooled descriptor; persistent artifact authority remains elsewhere.
final class ResidentReplayReaderPool {
  // Keep one bounded second-chance window beyond the composition runtime's
  // default eight hot promoted sessions. If both caps were eight, the same
  // pressure that evicts a DownloadSession would normally evict its descriptor
  // too, defeating cross-session reuse.
  static const int maxIdleEntries = 16;

  final Map<ResidentReplayGenerationKey, _ResidentReplayReaderPoolEntry>
      _entries =
      <ResidentReplayGenerationKey, _ResidentReplayReaderPoolEntry>{};
  final Map<ResidentReplayGenerationKey,
          Future<_ResidentReplayReaderPoolEntry?>> _opening =
      <ResidentReplayGenerationKey, Future<_ResidentReplayReaderPoolEntry?>>{};
  int _sequence = 0;
  bool _closing = false;

  int get idleEntryCount =>
      _entries.values.where((entry) => entry.leases == 0).length;

  Future<({PartialDownloadBoundRangeReader reader, bool reused})?> acquire(
    ResidentReplayGenerationKey key,
    Future<PartialDownloadBoundRangeReader?> Function() open,
  ) async {
    if (_closing) return null;
    var entry = _entries[key];
    var reused = entry != null && !entry.retired;
    if (entry == null || entry.retired) {
      if (entry?.retired == true) _entries.remove(key);
      final joined = _opening[key];
      if (joined != null) {
        reused = true;
        entry = await joined;
      } else {
        late final Future<_ResidentReplayReaderPoolEntry?> opening;
        opening = (() async {
          final reader = await open();
          if (reader == null) return null;
          if (_closing) {
            await reader.close();
            return null;
          }
          final created = _ResidentReplayReaderPoolEntry(
            reader: reader,
            lastUsed: ++_sequence,
          );
          _entries[key] = created;
          return created;
        })();
        _opening[key] = opening;
        try {
          entry = await opening;
        } finally {
          if (identical(_opening[key], opening)) _opening.remove(key);
        }
      }
    }
    if (entry == null || entry.retired || _closing) return null;
    entry.leases++;
    entry.lastUsed = ++_sequence;
    _trimIdle();
    var released = false;
    final leasedEntry = entry;
    return (
      reused: reused,
      reader: (
        accessMode: leasedEntry.reader.accessMode,
        readRange: (int start, int endExclusive) async {
          try {
            return await leasedEntry.reader.readRange(start, endExclusive);
          } on Object {
            await _retire(key, leasedEntry);
            rethrow;
          }
        },
        close: () async {
          if (released) return;
          released = true;
          _release(key, leasedEntry);
        },
      ),
    );
  }

  void _release(
    ResidentReplayGenerationKey key,
    _ResidentReplayReaderPoolEntry entry,
  ) {
    if (entry.leases > 0) entry.leases--;
    entry.lastUsed = ++_sequence;
    if (entry.retired && entry.leases == 0) {
      unawaited(_closeEntry(entry));
      return;
    }
    _trimIdle();
  }

  Future<void> _retire(
    ResidentReplayGenerationKey key,
    _ResidentReplayReaderPoolEntry entry,
  ) async {
    entry.retired = true;
    if (identical(_entries[key], entry)) _entries.remove(key);
    if (entry.leases == 0) await _closeEntry(entry);
  }

  void _trimIdle() {
    final idle = _entries.entries
        .where((item) => item.value.leases == 0)
        .toList(growable: false)
      ..sort((left, right) =>
          left.value.lastUsed.compareTo(right.value.lastUsed));
    final excess = idle.length - maxIdleEntries;
    if (excess <= 0) return;
    for (var index = 0; index < excess; index++) {
      final item = idle[index];
      if (identical(_entries[item.key], item.value)) {
        _entries.remove(item.key);
      }
      item.value.retired = true;
      unawaited(_closeEntry(item.value));
    }
  }

  Future<void> _closeEntry(_ResidentReplayReaderPoolEntry entry) async {
    if (entry.closed) return;
    entry.closed = true;
    try {
      await entry.reader.close();
    } on Object {
      // Descriptor pooling is acceleration-only. Cleanup failure cannot change
      // the persistent artifact's authority or surface as Reader failure.
    }
  }

  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    final opening = _opening.values.toList(growable: false);
    if (opening.isNotEmpty) {
      await Future.wait<_ResidentReplayReaderPoolEntry?>(opening);
    }
    _opening.clear();
    final entries = _entries.values.toSet().toList(growable: false);
    _entries.clear();
    await Future.wait<void>(entries.map(_closeEntry));
  }
}
