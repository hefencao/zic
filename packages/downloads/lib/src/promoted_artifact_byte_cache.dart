import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:domain/domain.dart';

/// Bounded composition-level L2 cache for immutable promoted page bytes.
///
/// Only current/transition reads populate this cache. Background prefetch keeps
/// using chunked artifact streams so the normal download window does not turn
/// into an unbounded encoded-byte cache. Entries survive individual Reader
/// sessions and therefore avoid reading the same promoted file again on a
/// quick Reader re-entry.
final class PromotedArtifactByteCache {
  PromotedArtifactByteCache({
    this.maxEntries = 4,
    this.maxBytes = 96 * 1024 * 1024,
  })  : assert(maxEntries > 0),
        assert(maxBytes > 0);

  final int maxEntries;
  final int maxBytes;

  final LinkedHashMap<_ArtifactByteKey, Uint8List> _entries =
      LinkedHashMap<_ArtifactByteKey, Uint8List>();
  final Map<_ArtifactByteKey, Future<Uint8List>> _inFlight =
      <_ArtifactByteKey, Future<Uint8List>>{};
  int _retainedBytes = 0;

  int get entryCount => _entries.length;
  int get retainedBytes => _retainedBytes;

  Uint8List? lookup(DownloadId id, {int? length}) {
    _ArtifactByteKey? selected;
    for (final key in _entries.keys.toList(growable: false).reversed) {
      if (key.id == id && (length == null || key.length == length)) {
        selected = key;
        break;
      }
    }
    if (selected == null) return null;
    final bytes = _entries.remove(selected);
    if (bytes == null) return null;
    _entries[selected] = bytes;
    return bytes;
  }

  Future<PromotedArtifactByteRead> read({
    required DownloadId id,
    required int length,
    required Future<Uint8List> Function() loader,
  }) async {
    final key = _ArtifactByteKey(id, length);
    final cached = lookup(id, length: length);
    if (cached != null) {
      return PromotedArtifactByteRead(
        bytes: cached,
        memoryHit: true,
        joined: false,
      );
    }

    final running = _inFlight[key];
    if (running != null) {
      return PromotedArtifactByteRead(
        bytes: await running,
        memoryHit: false,
        joined: true,
      );
    }

    late final Future<Uint8List> tracked;
    tracked = Future<Uint8List>.sync(loader).then<Uint8List>((bytes) {
      if (bytes.lengthInBytes != length) {
        throw StateError(
          'promoted artifact length changed while reading: '
          '${bytes.lengthInBytes}/$length for ${id.key}',
        );
      }
      _remember(key, bytes);
      return bytes;
    }).whenComplete(() {
      if (identical(_inFlight[key], tracked)) {
        _inFlight.remove(key);
      }
    });
    _inFlight[key] = tracked;
    return PromotedArtifactByteRead(
      bytes: await tracked,
      memoryHit: false,
      joined: false,
    );
  }

  void invalidate(DownloadId id) {
    for (final key in _entries.keys
        .where((key) => key.id == id)
        .toList(growable: false)) {
      final removed = _entries.remove(key);
      if (removed != null) {
        _retainedBytes -= removed.lengthInBytes;
      }
    }
  }

  void clear() {
    _entries.clear();
    _retainedBytes = 0;
  }

  void _remember(_ArtifactByteKey key, Uint8List bytes) {
    for (final stale in _entries.keys
        .where((candidate) => candidate.id == key.id && candidate != key)
        .toList(growable: false)) {
      final removed = _entries.remove(stale);
      if (removed != null) {
        _retainedBytes -= removed.lengthInBytes;
      }
    }
    final previous = _entries.remove(key);
    if (previous != null) {
      _retainedBytes -= previous.lengthInBytes;
    }
    if (bytes.lengthInBytes > maxBytes) {
      return;
    }
    _entries[key] = bytes;
    _retainedBytes += bytes.lengthInBytes;
    while (_entries.length > maxEntries || _retainedBytes > maxBytes) {
      final oldest = _entries.keys.first;
      final removed = _entries.remove(oldest)!;
      _retainedBytes -= removed.lengthInBytes;
    }
  }
}

final class PromotedArtifactByteRead {
  const PromotedArtifactByteRead({
    required this.bytes,
    required this.memoryHit,
    required this.joined,
  });

  final Uint8List bytes;
  final bool memoryHit;
  final bool joined;
}

final class _ArtifactByteKey {
  const _ArtifactByteKey(this.id, this.length);

  final DownloadId id;
  final int length;

  @override
  bool operator ==(Object other) =>
      other is _ArtifactByteKey && other.id == id && other.length == length;

  @override
  int get hashCode => Object.hash(id, length);
}
