import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:domain/domain.dart';

import 'artifact_cache_store.dart';

/// Composition-owned multi-level router for immutable Reader page artifacts.
final class ArtifactCacheManager {
  ArtifactCacheManager({
    required this.backend,
    this.memoryMaxEntries = 10,
    this.memoryMaxBytes = 256 * 1024 * 1024,
    this.equivalenceMaxEntries = 8192,
  })  : assert(memoryMaxEntries > 0),
        assert(memoryMaxBytes > 0),
        assert(equivalenceMaxEntries > 0);

  final ArtifactCacheBackend backend;
  final int memoryMaxEntries;
  final int memoryMaxBytes;
  final int equivalenceMaxEntries;
  final LinkedHashMap<_ArtifactByteKey, Uint8List> _memory =
      LinkedHashMap<_ArtifactByteKey, Uint8List>();
  final Map<_ArtifactByteKey, _InFlightArtifactRead> _inFlight =
      <_ArtifactByteKey, _InFlightArtifactRead>{};
  final Map<DownloadId, int> _mutationGenerations = <DownloadId, int>{};
  final Map<DownloadId, Future<void>> _mutationTails =
      <DownloadId, Future<void>>{};
  final Set<_ArtifactByteKey> _durableMemory = <_ArtifactByteKey>{};
  final LinkedHashMap<DownloadId, LinkedHashSet<DownloadId>> _equivalents =
      LinkedHashMap<DownloadId, LinkedHashSet<DownloadId>>();
  final LinkedHashSet<_ArtifactEquivalencePair> _equivalenceOrder =
      LinkedHashSet<_ArtifactEquivalencePair>();
  int _memoryBytes = 0;

  int get memoryEntryCount => _memory.length;
  int get memoryBytes => _memoryBytes;
  int get equivalenceCount => _equivalenceOrder.length;

  /// Returns the current exact-identity mutation generation. A caller that
  /// starts a source-backed hot-byte retention operation may pass this value
  /// back to [remember] so bytes from an operation that began before an
  /// explicit invalidation cannot repopulate the memory tier afterward.
  int generationFor(DownloadId id) => _mutationGenerations[id] ?? 0;

  Iterable<DownloadId> directEquivalents(DownloadId id) =>
      List<DownloadId>.unmodifiable(
        _equivalents[id] ?? const <DownloadId>{},
      );

  /// Registers a source-verified immutable-artifact equivalence.
  ///
  /// Equivalence is a lookup fallback, never a storage redirect. Both exact
  /// identities remain authoritative for writes. A later
  /// artifact promoted under either version therefore becomes immediately
  /// reusable by the other version without creating a directed alias cycle.
  void linkEquivalent({
    required DownloadId first,
    required DownloadId second,
  }) {
    if (first == second) return;
    final pair = _ArtifactEquivalencePair(first, second);
    _equivalenceOrder.remove(pair);
    _equivalenceOrder.add(pair);
    _equivalents
        .putIfAbsent(first, () => LinkedHashSet<DownloadId>())
        .add(second);
    _equivalents
        .putIfAbsent(second, () => LinkedHashSet<DownloadId>())
        .add(first);
    while (_equivalenceOrder.length > equivalenceMaxEntries) {
      final oldest = _equivalenceOrder.first;
      _equivalenceOrder.remove(oldest);
      _removeEquivalentEdge(oldest.first, oldest.second);
      _removeEquivalentEdge(oldest.second, oldest.first);
    }
  }

  void _removeEquivalentEdge(DownloadId first, DownloadId second) {
    final values = _equivalents[first];
    if (values == null) return;
    values.remove(second);
    if (values.isEmpty) _equivalents.remove(first);
  }

  Iterable<DownloadId> _lookupCandidates(DownloadId id) sync* {
    yield id;
    final equivalents = _equivalents[id];
    if (equivalents == null) return;
    for (final equivalent in equivalents) {
      if (equivalent != id) yield equivalent;
    }
  }

  Uint8List? lookupMemory(DownloadId id, {int? length}) {
    for (final candidate in _lookupCandidates(id)) {
      final bytes = _lookupMemoryExact(candidate, length: length);
      if (bytes != null) return bytes;
    }
    return null;
  }

  Uint8List? _lookupMemoryExact(DownloadId id, {int? length}) {
    _ArtifactByteKey? selected;
    for (final key in _memory.keys.toList(growable: false).reversed) {
      if (key.id == id && (length == null || key.length == length)) {
        selected = key;
        break;
      }
    }
    if (selected == null) return null;
    final bytes = _memory.remove(selected);
    if (bytes == null) return null;
    if (bytes.isEmpty) {
      _durableMemory.remove(selected);
      return null;
    }
    _memory[selected] = bytes;
    // Uint8List is mutable. Return an unmodifiable view so callers
    // cannot mutate the cached memory tier buffer in-place.
    return bytes.asUnmodifiableView();
  }

  Future<ArtifactCacheLookup?> lookup(
    DownloadId id, {
    TaskControl? control,
  }) =>
      _lookupCandidatesInOrder(id, _lookupCandidates(id), control: control);

  /// Looks up only this exact identity's authoritative durable storage.
  ///
  /// Verified equivalence is intentionally excluded. Promotion and other
  /// durable ownership checks must not mistake a related version's artifact
  /// for this exact DownloadId's own persisted artifact.
  Future<ArtifactCacheLookup?> lookupAuthoritative(
    DownloadId id, {
    TaskControl? control,
  }) =>
      _lookupCandidatesInOrder(id, <DownloadId>[id], control: control);

  Future<ArtifactCacheLookup?> _lookupCandidatesInOrder(
    DownloadId id,
    Iterable<DownloadId> candidates, {
    TaskControl? control,
  }) async {
    for (final storageId in candidates) {
      control?.throwIfCancelled();
      await _awaitMutationBarrier(storageId, control);
      final memory = _lookupMemoryExact(storageId);
      if (memory != null) {
        final key = _ArtifactByteKey(storageId, memory.lengthInBytes);
        return ArtifactCacheLookup(
          id: id,
          storageId: storageId,
          entry: _memoryEntry(memory),
          tier: ArtifactCacheTier.memory,
          durable: _durableMemory.contains(key),
          generation: generationFor(storageId),
        );
      }
      var staleLookupAttempts = 0;
      while (true) {
        control?.throwIfCancelled();
        await _awaitMutationBarrier(storageId, control);
        final generation = generationFor(storageId);
        final entry = await _awaitCancellable(
          backend.openArtifactStream(storageId),
          control,
        );
        if (generationFor(storageId) != generation) {
          staleLookupAttempts++;
          if (staleLookupAttempts < 3) continue;
          break;
        }
        if (entry == null) break;
        if (entry.length <= 0) {
          _advanceMutationGeneration(storageId);
          _invalidateMemoryExact(storageId);
          await _awaitCancellable(
            _serializeMutation(storageId, () async {
              await backend.invalidateArtifact(storageId);
            }),
            control,
          );
          break;
        }
        return ArtifactCacheLookup(
          id: id,
          storageId: storageId,
          entry: entry,
          tier: ArtifactCacheTier.persistent,
          durable: true,
          generation: generation,
        );
      }
    }
    return null;
  }

  Future<bool> contains({
    required DownloadId id,
    required int expectedLength,
  }) async {
    final lookup = await this.lookup(id);
    return lookup != null && lookup.entry.length == expectedLength;
  }

  Future<bool> containsBackendExact({
    required DownloadId id,
    required int expectedLength,
  }) async {
    await _awaitMutationBarrier(id, null);
    final generation = generationFor(id);
    final entry = await backend.openArtifactStream(id);
    if (generationFor(id) != generation) return false;
    return entry != null && entry.length == expectedLength;
  }

  Future<ArtifactCacheRead> readForegroundLookup(
    ArtifactCacheLookup lookup, {
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    if (generationFor(lookup.storageId) != lookup.generation) {
      throw const _StaleArtifactCacheLookup();
    }
    if (lookup.tier == ArtifactCacheTier.memory) {
      final bytes = await _awaitCancellable(lookup.entry.readAll!(), control);
      if (generationFor(lookup.storageId) != lookup.generation) {
        throw const _StaleArtifactCacheLookup();
      }
      return ArtifactCacheRead(
        bytes: bytes,
        memoryHit: true,
        joined: false,
        durable: lookup.durable,
      );
    }
    final controlledRead = lookup.entry.readAllControlled;
    final readAll = lookup.entry.readAll;
    return _readJoined(
      id: lookup.storageId,
      length: lookup.entry.length,
      durable: true,
      loader: controlledRead == null
          ? (operationControl) => readAll != null
              ? readAll()
              : _collect(lookup.entry, control: operationControl)
          : (operationControl) => controlledRead(control: operationControl),
      expectedGeneration: lookup.generation,
      control: control,
    );
  }

  Future<ArtifactCacheRead?> readForeground(
    DownloadId id, {
    TaskControl? control,
  }) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final lookup = await this.lookup(id, control: control);
      if (lookup == null) return null;
      try {
        return await readForegroundLookup(lookup, control: control);
      } on _StaleArtifactCacheLookup {
        control?.throwIfCancelled();
      }
    }
    return null;
  }

  Future<ArtifactCacheRead> readSessionArtifact({
    required DownloadId id,
    required int length,
    required Future<Uint8List> Function() loader,
    TaskControl? control,
  }) => _readJoined(
        id: id,
        length: length,
        durable: false,
        loader: (_) => Future<Uint8List>.sync(loader),
        control: control,
      );

  /// Stores bytes only if no exact-identity mutation has started since
  /// [expectedGeneration] was observed. The generation check and the call to
  /// [storePromotedArtifact] are synchronous with respect to other Dart code,
  /// so a mutation that starts afterward is serialized after this write and
  /// remains the authoritative later boundary.
  Future<bool> storePromotedArtifactIfGeneration({
    required DownloadId id,
    required Uint8List bytes,
    required int expectedGeneration,
  }) async {
    if (generationFor(id) != expectedGeneration) return false;
    await storePromotedArtifact(id: id, bytes: bytes);
    return true;
  }

  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {
    if (bytes.isEmpty) {
      throw StateError('cannot store an empty promoted artifact for ${id.key}');
    }
    final ownedBytes = bytes.asUnmodifiableView();
    final generation = _advanceMutationGeneration(id);
    _invalidateMemoryExact(id);
    await _serializeMutation(id, () async {
      await backend.storePromotedArtifact(id: id, bytes: ownedBytes);
    });
    if (generationFor(id) == generation) {
      // Retain durable memory projection: remember(id: id, bytes: bytes, durable: true)
      _rememberExact(id: id, bytes: ownedBytes, durable: true);
    }
  }

  void remember({
    required DownloadId id,
    required Uint8List bytes,
    bool durable = false,
    int? generation,
  }) {
    if (generation != null && generationFor(id) != generation) return;
    if (generation == null) {
      _advanceMutationGeneration(id);
    }
    // A synchronous memory-retention callback cannot wait behind a durable
    // store/invalidation mutation. Do not let it repopulate memory in the
    // interval after the mutation has withdrawn the previous bytes but before
    // its backend operation has committed.
    if (_mutationTails.containsKey(id)) return;
    if (bytes.isEmpty) {
      _invalidateMemoryExact(id);
      return;
    }
    _rememberExact(id: id, bytes: bytes, durable: durable);
  }

  void _rememberExact({
    required DownloadId id,
    required Uint8List bytes,
    bool durable = false,
  }) {
    if (bytes.isEmpty) {
      _invalidateMemoryExact(id);
      return;
    }
    final ownedBytes = bytes.asUnmodifiableView();
    final key = _ArtifactByteKey(id, ownedBytes.lengthInBytes);
    for (final stale in _memory.keys
        .where((candidate) => candidate.id == id && candidate != key)
        .toList(growable: false)) {
      final removed = _memory.remove(stale);
      _durableMemory.remove(stale);
      if (removed != null) _memoryBytes -= removed.lengthInBytes;
    }
    final previous = _memory.remove(key);
    // The byte value may have changed even when the identity and length did
    // not. Durability is provenance of this exact byte value, not a property
    // of the key, so never carry the old flag across a replacement.
    _durableMemory.remove(key);
    if (previous != null) _memoryBytes -= previous.lengthInBytes;
    if (ownedBytes.lengthInBytes > memoryMaxBytes) return;
    _memory[key] = ownedBytes;
    if (durable) _durableMemory.add(key);
    _memoryBytes += ownedBytes.lengthInBytes;
    while (_memory.length > memoryMaxEntries || _memoryBytes > memoryMaxBytes) {
      final oldest = _memory.keys.first;
      _durableMemory.remove(oldest);
      _memoryBytes -= _memory.remove(oldest)!.lengthInBytes;
    }
  }

  void invalidateMemory(DownloadId id) {
    _advanceMutationGeneration(id);
    _invalidateMemoryExact(id);
  }

  void _invalidateMemoryExact(DownloadId id) {
    for (final key in _memory.keys
        .where((candidate) => candidate.id == id)
        .toList(growable: false)) {
      final removed = _memory.remove(key);
      _durableMemory.remove(key);
      if (removed != null) _memoryBytes -= removed.lengthInBytes;
    }
  }

  Future<void> invalidate(DownloadId id, {TaskControl? control}) async {
    control?.throwIfCancelled();
    _advanceMutationGeneration(id);
    _invalidateMemoryExact(id);
    await _awaitCancellable(
      _serializeMutation(id, () async {
        await backend.invalidateArtifact(id);
      }),
      control,
    );
  }

  void clearMemory() {
    final ids = <DownloadId>{
      ..._mutationGenerations.keys,
      ..._memory.keys.map((key) => key.id),
      ..._inFlight.keys.map((key) => key.id),
    };
    // Clearing the memory tier invalidates any generation-scoped retention
    // that is still in flight. Remove those operations from the join table as
    // well; otherwise a read that starts immediately after clearMemory() can
    // join an operation captured under the old generation and receive a
    // cancellation/stale-generation result instead of opening a fresh read.
    for (final id in ids) {
      _advanceMutationGeneration(id);
    }
    _memory.clear();
    _durableMemory.clear();
    _equivalents.clear();
    _equivalenceOrder.clear();
    _memoryBytes = 0;
  }

  Future<ArtifactCacheRead> _readJoined({
    required DownloadId id,
    required int length,
    required bool durable,
    required Future<Uint8List> Function(TaskControl operationControl) loader,
    int? expectedGeneration,
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    await _awaitMutationBarrier(id, control);
    if (expectedGeneration != null &&
        generationFor(id) != expectedGeneration) {
      throw const _StaleArtifactCacheLookup();
    }
    if (length <= 0) {
      if (control == null) {
        await invalidate(id);
      } else {
        await invalidate(id, control: control);
      }
      throw StateError('artifact cache entry is empty for ${id.key}');
    }
    final cached = _lookupMemoryExact(id, length: length);
    if (cached != null) {
      return ArtifactCacheRead(
        bytes: cached,
        memoryHit: true,
        joined: false,
        durable: _durableMemory.contains(_ArtifactByteKey(id, length)),
      );
    }
    final key = _ArtifactByteKey(id, length);
    final running = _inFlight[key];
    if (running != null && !running.control.cancelled) {
      final bytes = await _awaitJoined(running, control);
      // Durability belongs to the shared operation's source, not to the
      // caller that happened to join it. A foreground backend read must never
      // be made to look persisted merely because it joined a non-durable
      // session-artifact read (or vice versa).
      return ArtifactCacheRead(
        bytes: bytes,
        memoryHit: false,
        joined: true,
        durable: running.durable,
      );
    }
    if (running != null && identical(_inFlight[key], running)) {
      _inFlight.remove(key);
    }
    final generation = generationFor(id);
    late final Future<Uint8List> tracked;
    late final _InFlightArtifactRead operation;
    final operationControl = _JoinedArtifactReadControl(
      priority: control?.priority ?? 0,
    );
    tracked = Future<Uint8List>.sync(
      () => loader(operationControl),
    ).then<Uint8List>((bytes) async {
      final ownedBytes = bytes.asUnmodifiableView();
      if (ownedBytes.isEmpty || ownedBytes.lengthInBytes != length) {
        await _invalidateAfterInvalidRead(
          id,
          generation: generation,
          operationControl: operationControl,
        );
        throw StateError(
          ownedBytes.isEmpty
              ? 'artifact cache body is empty for ${id.key}'
              : 'artifact cache length changed while reading: '
                  '${ownedBytes.lengthInBytes}/$length for ${id.key}',
        );
      }
      if (operationControl.cancelled || generationFor(id) != generation) {
        throw const Failure(
          code: ErrorCode.cancelled,
          message: 'artifact cache read was invalidated or withdrawn while reading',
        );
      }
      _rememberExact(id: id, bytes: ownedBytes, durable: durable);
      return ownedBytes;
    }).whenComplete(() {
      operation.futureCompleted = true;
      if (identical(_inFlight[key]?.future, tracked)) _inFlight.remove(key);
    });
    // A final consumer may cancel before an uncontrolled backend future has
    // settled. Keep the shared operation's eventual error observed even when
    // no caller remains to await it; individual callers still receive the
    // original result/error through [operation.future] when they are present.
    unawaited(
      tracked.then<void>(
        (_) {},
        onError: (Object _, StackTrace __) {},
      ),
    );
    operation = _InFlightArtifactRead(
      key: key,
      future: tracked,
      control: operationControl,
      generation: generation,
      durable: durable,
    );
    _inFlight[key] = operation;
    final bytes = await _awaitJoined(operation, control);
    return ArtifactCacheRead(
      bytes: bytes,
      memoryHit: false,
      joined: false,
      durable: operation.durable,
    );
  }

  Future<Uint8List> _awaitJoined(
    _InFlightArtifactRead operation,
    TaskControl? control,
  ) async {
    // Register before the cancellation check. A caller can be cancelled in
    // the small interval between _readJoined's initial check and this join;
    // registering first lets the normal release path cancel/remove an
    // otherwise consumer-less operation instead of orphaning it in _inFlight.
    operation.consumers++;
    var released = false;
    void release() {
      if (released) return;
      released = true;
      operation.consumers--;
      if (operation.consumers == 0 && !operation.futureCompleted) {
        operation.control.cancel();
        if (identical(_inFlight[operation.key], operation)) {
          // An uncontrolled backend future may never observe the operation
          // control. It must no longer be joinable once its final consumer
          // has withdrawn; its eventual completion is still observed by the
          // detached handler installed in [_readJoined].
          _inFlight.remove(operation.key);
        }
      }
    }

    try {
      control?.throwIfCancelled();
      if (control != null && control.priority > operation.control.priority) {
        operation.control.updatePriority(control.priority);
      }
      final waits = <Future<Uint8List>>[
        operation.future,
        operation.control.whenCancelled.then<Uint8List>((_) {
          throw const Failure(
            code: ErrorCode.cancelled,
            message: 'artifact cache read was invalidated or withdrawn',
          );
        }),
      ];
      if (control != null) {
        waits.add(control.whenCancelled.then<Uint8List>((_) {
          throw const Failure(
            code: ErrorCode.cancelled,
            message:
                'artifact cache read was cancelled by its scheduler owner',
          );
        }));
      }
      final result = await Future.any<Uint8List>(waits);
      release();
      return result;
    } catch (error, stackTrace) {
      release();
      if (control?.cancelled == true) {
        control!.throwIfCancelled();
      }
      throw Error.throwWithStackTrace(error, stackTrace);
    }
  }

  static Future<T> _awaitCancellable<T>(
    Future<T> operation,
    TaskControl? control,
  ) async {
    if (control == null) return operation;
    // The cancellation race only withdraws the caller's await. Observe the
    // backend future independently so an uncontrolled late failure cannot
    // become an unhandled asynchronous error after the caller has left.
    unawaited(
      operation.then<void>(
        (_) {},
        onError: (Object _, StackTrace __) {},
      ),
    );
    control.throwIfCancelled();
    try {
      return await Future.any<T>(<Future<T>>[
        operation,
        control.whenCancelled.then<T>((_) {
          throw const Failure(
            code: ErrorCode.cancelled,
            message:
                'artifact cache read was cancelled by its scheduler owner',
          );
        }),
      ]);
    } catch (error, stackTrace) {
      if (control.cancelled) {
        control.throwIfCancelled();
      }
      throw Error.throwWithStackTrace(error, stackTrace);
    }
  }

  static ArtifactCacheStreamEntry _memoryEntry(Uint8List bytes) =>
      ArtifactCacheStreamEntry(
        length: bytes.lengthInBytes,
        open: ({required int start, int? endExclusive}) async* {
          final end = (endExclusive ?? bytes.lengthInBytes)
              .clamp(start, bytes.lengthInBytes)
              .toInt();
          for (var offset = start;
              offset < end;
              offset += promotedArtifactReadChunkBytes) {
            final chunkEnd = (offset + promotedArtifactReadChunkBytes)
                .clamp(offset, end)
                .toInt();
            yield Uint8List.sublistView(bytes, offset, chunkEnd).asUnmodifiableView();
          }
        },
        readAll: () async => bytes.asUnmodifiableView(),
      );

  static Future<Uint8List> _collect(
    ArtifactCacheStreamEntry entry, {
    TaskControl? control,
  }) async {
    final iterator = StreamIterator<List<int>>(entry.open(start: 0));
    final builder = BytesBuilder(copy: false);
    try {
      while (true) {
        if (control == null) {
          if (!await iterator.moveNext()) break;
        } else {
          control.throwIfCancelled();
          try {
            final available = await Future.any<bool>(<Future<bool>>[
              iterator.moveNext(),
              control.whenCancelled.then<bool>((_) {
                throw const Failure(
                  code: ErrorCode.cancelled,
                  message: 'artifact cache read was cancelled',
                );
              }),
            ]);
            if (!available) break;
          } catch (error, stackTrace) {
            if (control.cancelled) control.throwIfCancelled();
            throw Error.throwWithStackTrace(error, stackTrace);
          }
        }
        control?.throwIfCancelled();
        builder.add(iterator.current);
      }
    } finally {
      // StreamIterator.cancel is cleanup, not the operation's result. A
      // backend subscription is allowed to report a late close failure, but
      // that failure must not replace the caller's cancellation or the
      // backend read error that caused this collection to stop.
      try {
        await iterator.cancel();
      } on Object {
        // Preserve the authoritative read/cancellation outcome.
      }
    }
    final bytes = builder.takeBytes();
    if (bytes.lengthInBytes != entry.length) {
      throw StateError(
        'artifact cache entry length changed while reading: '
        '${bytes.lengthInBytes}/${entry.length}',
      );
    }
    return bytes;
  }

  int _advanceMutationGeneration(
    DownloadId id, {
    bool cancelInFlight = true,
  }) {
    final generation = generationFor(id) + 1;
    _mutationGenerations[id] = generation;
    if (!cancelInFlight) return generation;
    for (final entry in _inFlight.entries
        .where((entry) => entry.key.id == id)
        .toList(growable: false)) {
      entry.value.control.cancel();
      if (identical(_inFlight[entry.key], entry.value)) {
        _inFlight.remove(entry.key);
      }
    }
    return generation;
  }

  Future<void> _invalidateAfterInvalidRead(
    DownloadId id, {
    required int generation,
    required TaskControl operationControl,
  }) async {
    // A cancelled/stale backend operation must not invalidate or cancel a
    // newer read that was admitted after the original operation was withdrawn.
    // In particular, an old empty/short body may complete after invalidate()
    // removed its in-flight entry. The generation check below ensures this
    // cleanup applies only to the operation that observed the invalid body.
    if (operationControl.cancelled || generationFor(id) != generation) {
      return;
    }
    // No newer read can start between this synchronous generation check and
    // the mutation advance. Remove every currently joined operation so a
    // fresh reader cannot join this known-invalid body while invalidation is
    // still waiting on the backend. Keep the operation that discovered the
    // invalid body uncancelled so its callers receive the original
    // length/empty-body error rather than a cancellation error.
    _advanceMutationGeneration(id, cancelInFlight: false);
    for (final entry in _inFlight.entries
        .where((entry) => entry.key.id == id)
        .toList(growable: false)) {
      if (!identical(entry.value.control, operationControl)) {
        entry.value.control.cancel();
      }
      if (identical(_inFlight[entry.key], entry.value)) {
        _inFlight.remove(entry.key);
      }
    }
    _invalidateMemoryExact(id);
    await _serializeMutation(id, () => backend.invalidateArtifact(id));
  }

  Future<void> _awaitMutationBarrier(
    DownloadId id,
    TaskControl? control,
  ) {
    final tail = _mutationTails[id];
    if (tail == null) return Future<void>.value();
    return _awaitCancellable(tail, control);
  }

  Future<void> _serializeMutation(
    DownloadId id,
    Future<void> Function() action,
  ) {
    final previous = _mutationTails[id] ?? Future<void>.value();
    final ready = previous.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    final current = ready.then<void>((_) => action());
    _mutationTails[id] = current;
    unawaited(
      current.then<void>(
        (_) {
          if (identical(_mutationTails[id], current)) {
            _mutationTails.remove(id);
          }
        },
        onError: (Object _, StackTrace __) {
          if (identical(_mutationTails[id], current)) {
            _mutationTails.remove(id);
          }
        },
      ),
    );
    return current;
  }
}

enum ArtifactCacheTier { memory, persistent }

final class ArtifactCacheLookup {
  const ArtifactCacheLookup({
    required this.id,
    DownloadId? storageId,
    required this.entry,
    required this.tier,
    this.durable = false,
    this.generation = 0,
  }) : storageId = storageId ?? id;

  /// Identity requested by the caller.
  final DownloadId id;

  /// Exact authoritative artifact used after alias resolution.
  final DownloadId storageId;
  final ArtifactCacheStreamEntry entry;
  final ArtifactCacheTier tier;
  final bool durable;

  /// Exact-identity mutation generation observed when this lookup was made.
  /// A held lookup must not read through a later invalidation/store boundary.
  final int generation;
}

final class _StaleArtifactCacheLookup implements Exception {
  const _StaleArtifactCacheLookup();
}

final class ArtifactCacheRead {
  const ArtifactCacheRead({
    required this.bytes,
    required this.memoryHit,
    required this.joined,
    this.durable = false,
  });

  final Uint8List bytes;
  final bool memoryHit;
  final bool joined;
  final bool durable;
}

final class _ArtifactEquivalencePair {
  const _ArtifactEquivalencePair(this.first, this.second);

  final DownloadId first;
  final DownloadId second;

  @override
  bool operator ==(Object other) =>
      other is _ArtifactEquivalencePair &&
      ((other.first == first && other.second == second) ||
          (other.first == second && other.second == first));

  @override
  int get hashCode => first.hashCode ^ second.hashCode;
}

final class _InFlightArtifactRead {
  _InFlightArtifactRead({
    required this.key,
    required this.future,
    required this.control,
    required this.generation,
    required this.durable,
  });

  final _ArtifactByteKey key;
  final Future<Uint8List> future;
  final _JoinedArtifactReadControl control;
  final int generation;
  final bool durable;
  int consumers = 0;
  bool futureCompleted = false;
}

final class _JoinedArtifactReadControl implements TaskControl {
  _JoinedArtifactReadControl({required this.priority});

  final Completer<void> _cancelled = Completer<void>();

  @override
  int priority;

  @override
  bool get cancelled => _cancelled.isCompleted;

  @override
  Future<void> get whenCancelled => _cancelled.future;

  void updatePriority(int value) {
    if (value > priority) priority = value;
  }

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
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
