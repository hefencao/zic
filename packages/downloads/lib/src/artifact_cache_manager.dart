import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:domain/domain.dart';

import 'artifact_cache_store.dart';

typedef ArtifactEquivalentResolver = Iterable<DownloadId> Function(DownloadId id);
typedef HistoricalCarrierSignatureConflictTrust = bool Function(String sourceId);

/// User-selected policy for an exact URI miss when a READY carrier exists for
/// the same logical page and source revision under an older provider URI.
///
/// Historical carriers are never promoted to verified equivalence. The policy
/// controls read routing only; exact/current durable authority remains keyed by
/// the current [DownloadId].
enum CachedCarrierMismatchPolicy {
  /// Current exact/verified authority only. A miss reopens the source.
  strictReload,

  /// Serve the most-recent historical READY carrier immediately, then replace
  /// it from the current source after presentation has obtained a first frame.
  reuseThenRefresh,

  /// Serve the most-recent historical READY carrier and do not automatically
  /// reopen the current source. Explicit retry/download may still demand it.
  trustCached,
}

/// Composition-owned multi-level router for immutable Reader page artifacts.
final class ArtifactCacheManager {
  ArtifactCacheManager({
    required this.backend,
    this.memoryMaxEntries = 10,
    this.memoryMaxBytes = 256 * 1024 * 1024,
    this.equivalenceMaxEntries = 8192,
    this.equivalenceResolverMaxEntries = 64,
    CachedCarrierMismatchPolicy carrierMismatchPolicy =
        CachedCarrierMismatchPolicy.strictReload,
  })  : _carrierMismatchPolicy = carrierMismatchPolicy,
        assert(memoryMaxEntries > 0),
        assert(memoryMaxBytes > 0),
        assert(equivalenceMaxEntries > 0),
        assert(equivalenceResolverMaxEntries > 0);

  final ArtifactCacheBackend backend;
  final int memoryMaxEntries;
  final int memoryMaxBytes;
  final int equivalenceMaxEntries;
  final int equivalenceResolverMaxEntries;
  CachedCarrierMismatchPolicy _carrierMismatchPolicy;
  HistoricalCarrierSignatureConflictTrust? _signatureConflictTrust;
  final Set<DownloadId> _pendingHistoricalCarrierRevalidation = <DownloadId>{};
  final Map<DownloadId, ({DownloadId storageId, int generation})>
      _retainedHistoricalPresentationAuthorities =
      <DownloadId, ({DownloadId storageId, int generation})>{};
  final LinkedHashMap<_ArtifactByteKey, Uint8List> _memory =
      LinkedHashMap<_ArtifactByteKey, Uint8List>();
  final LinkedHashMap<Object, Uint8List> _residentReplayPrefixes =
      LinkedHashMap<Object, Uint8List>();
  final Map<_ArtifactByteKey, _InFlightArtifactRead> _inFlight =
      <_ArtifactByteKey, _InFlightArtifactRead>{};
  final Map<DownloadId, int> _mutationGenerations = <DownloadId, int>{};
  final Object _presentationFileCacheEpoch = Object();
  final Map<DownloadId, Future<void>> _mutationTails =
      <DownloadId, Future<void>>{};
  final Set<_ArtifactByteKey> _durableMemory = <_ArtifactByteKey>{};
  final LinkedHashMap<DownloadId, LinkedHashSet<DownloadId>> _equivalents =
      LinkedHashMap<DownloadId, LinkedHashSet<DownloadId>>();
  final LinkedHashSet<_ArtifactEquivalencePair> _equivalenceOrder =
      LinkedHashSet<_ArtifactEquivalencePair>();
  final LinkedHashMap<String, ArtifactEquivalentResolver>
      _equivalenceResolvers =
      LinkedHashMap<String, ArtifactEquivalentResolver>();
  // Presentation may semantically reject bytes that are still structurally
  // valid and shared by version-equivalent bindings. During that recovery the
  // affected logical/physical ids must not source bytes from any cache tier or
  // equivalence fallback; one fresh exact durable write clears the group.
  final Map<DownloadId, int> _freshSourceRecoveryGroups = <DownloadId, int>{};
  final Map<int, Set<DownloadId>> _freshSourceRecoveryMembers =
      <int, Set<DownloadId>>{};
  final Set<int> _armedFreshSourceRecoveryGroups = <int>{};
  int _freshSourceRecoverySequence = 0;
  int _memoryBytes = 0;
  int _residentReplayPrefixBytes = 0;

  int get memoryEntryCount => _memory.length;
  int get memoryBytes => _memoryBytes;
  int get residentReplayPrefixEntryCount => _residentReplayPrefixes.length;
  int get residentReplayPrefixBytes => _residentReplayPrefixBytes;
  int get equivalenceCount => _equivalenceOrder.length;
  int get equivalenceResolverCount => _equivalenceResolvers.length;
  bool hasEquivalentResolver(String key) => _equivalenceResolvers.containsKey(key);
  CachedCarrierMismatchPolicy get carrierMismatchPolicy =>
      _carrierMismatchPolicy;

  void updateCarrierMismatchPolicy(CachedCarrierMismatchPolicy value) {
    if (_carrierMismatchPolicy == value) return;
    _carrierMismatchPolicy = value;
    if (value != CachedCarrierMismatchPolicy.reuseThenRefresh) {
      _pendingHistoricalCarrierRevalidation.clear();
      _retainedHistoricalPresentationAuthorities.clear();
    }
  }

  void updateHistoricalCarrierSignatureConflictTrust(
    HistoricalCarrierSignatureConflictTrust? resolver,
  ) {
    _signatureConflictTrust = resolver;
  }

  bool hasPendingHistoricalCarrierRevalidation(DownloadId id) =>
      _pendingHistoricalCarrierRevalidation.contains(id);

  bool consumeHistoricalCarrierRevalidation(DownloadId id) =>
      _pendingHistoricalCarrierRevalidation.remove(id);

  void restoreHistoricalCarrierRevalidation(DownloadId id) {
    if (_carrierMismatchPolicy == CachedCarrierMismatchPolicy.reuseThenRefresh &&
        !requiresFreshSource(id)) {
      _pendingHistoricalCarrierRevalidation.add(id);
    }
  }

  void noteHistoricalCarrierServed(
    DownloadId id, {
    DownloadId? storageId,
    int? generation,
  }) {
    if (_carrierMismatchPolicy != CachedCarrierMismatchPolicy.reuseThenRefresh ||
        requiresFreshSource(id)) {
      return;
    }
    _pendingHistoricalCarrierRevalidation.add(id);
    if (storageId != null && generation != null) {
      _retainedHistoricalPresentationAuthorities[id] = (
        storageId: storageId,
        generation: generation,
      );
    }
  }

  /// Drops only presentation continuity for an already-admitted historical
  /// carrier. This never changes cache routing, equivalence, durability, or
  /// DownloadSession ownership.
  void clearRetainedHistoricalPresentation(DownloadId id) {
    _retainedHistoricalPresentationAuthorities.remove(id);
  }

  bool requiresFreshSource(DownloadId id) =>
      _freshSourceRecoveryGroups.containsKey(id);

  /// Whether presentation may still redraw the exact historical generation
  /// admitted before this fresh-source quarantine. This is never cache/source
  /// selection authority.
  bool hasRetainedHistoricalPresentation(DownloadId id) {
    if (!requiresFreshSource(id)) return false;
    final authority = _retainedHistoricalPresentationAuthorities[id];
    if (authority == null) return false;
    if (generationFor(authority.storageId) != authority.generation) {
      _retainedHistoricalPresentationAuthorities.remove(id);
      return false;
    }
    return true;
  }

  /// Suppresses all cache-backed source selection for the supplied recovery
  /// identities until one member publishes a fresh exact durable artifact.
  /// This is a transient routing quarantine, not deletion of equivalent
  /// siblings: their own logical lookups remain valid.
  int beginFreshSourceRecovery(Iterable<DownloadId> ids) {
    final members = <DownloadId>{...ids};
    if (members.isEmpty) {
      throw ArgumentError.value(ids, 'ids', 'must contain a recovery identity');
    }
    final existingGroups = members
        .map((id) => _freshSourceRecoveryGroups[id])
        .whereType<int>()
        .toSet();
    for (final group in existingGroups) {
      _armedFreshSourceRecoveryGroups.remove(group);
      members.addAll(
        _freshSourceRecoveryMembers.remove(group) ?? const <DownloadId>{},
      );
    }
    final group = ++_freshSourceRecoverySequence;
    for (final id in members) {
      _freshSourceRecoveryGroups[id] = group;
      _invalidateMemoryExact(id);
    }
    _freshSourceRecoveryMembers[group] = members;
    return group;
  }

  /// Allows a post-reset fresh exact store to complete this recovery group.
  /// Stores that began before this point can never release the quarantine.
  void armFreshSourceRecovery(int group) {
    if (_freshSourceRecoveryMembers.containsKey(group)) {
      _armedFreshSourceRecoveryGroups.add(group);
    }
  }

  void _completeFreshSourceRecovery(DownloadId id) {
    final group = _freshSourceRecoveryGroups[id];
    if (group == null) return;
    _armedFreshSourceRecoveryGroups.remove(group);
    final members =
        _freshSourceRecoveryMembers.remove(group) ?? <DownloadId>{id};
    for (final member in members) {
      if (_freshSourceRecoveryGroups[member] == group) {
        _freshSourceRecoveryGroups.remove(member);
      }
      _retainedHistoricalPresentationAuthorities.remove(member);
    }
  }

  /// Returns the current exact-identity mutation generation. A caller that
  /// starts a source-backed hot-byte retention operation may pass this value
  /// back to [remember] so bytes from an operation that began before an
  /// explicit invalidation cannot repopulate the memory tier afterward.
  int generationFor(DownloadId id) => _mutationGenerations[id] ?? 0;

  Iterable<DownloadId> directEquivalents(DownloadId id) {
    if (requiresFreshSource(id)) return const <DownloadId>[];
    final resolved = <DownloadId>{...directLinkedEquivalents(id)};
    for (final resolver in _equivalenceResolvers.values) {
      for (final candidate in resolver(id)) {
        if (candidate != id) resolved.add(candidate);
      }
    }
    return List<DownloadId>.unmodifiable(resolved);
  }

  /// Returns only source-verified equivalence edges already owned as data by
  /// this cache manager. Dynamic resolvers are intentionally excluded.
  ///
  /// Background version-page preparation uses its own immutable projection;
  /// calling [directEquivalents] again during commit would execute that same
  /// projection a second time on the owner isolate.
  Iterable<DownloadId> directLinkedEquivalents(DownloadId id) {
    if (requiresFreshSource(id)) return const <DownloadId>[];
    final explicit = _equivalents[id];
    if (explicit == null || explicit.isEmpty) return const <DownloadId>[];
    return List<DownloadId>.unmodifiable(
      explicit.where((candidate) => candidate != id),
    );
  }

  /// Registers one bounded lazy direct-equivalence resolver.
  ///
  /// This is for compact verified relations whose candidate can be derived
  /// from the queried exact identity without materializing every page pair up
  /// front. Resolvers only participate in fallback lookup/direct-equivalent
  /// discovery; authoritative exact lookup and exact writes still bypass them.
  void registerEquivalentResolver({
    required String key,
    required ArtifactEquivalentResolver resolver,
  }) {
    if (key.isEmpty) {
      throw ArgumentError.value(key, 'key', 'must not be empty');
    }
    _equivalenceResolvers.remove(key);
    _equivalenceResolvers[key] = resolver;
    while (_equivalenceResolvers.length > equivalenceResolverMaxEntries) {
      _equivalenceResolvers.remove(_equivalenceResolvers.keys.first);
    }
  }

  void removeEquivalentResolver(String key) {
    _equivalenceResolvers.remove(key);
  }

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
    if (requiresFreshSource(id)) return;
    yield id;
    yield* directEquivalents(id);
  }

  Uint8List? lookupMemory(DownloadId id, {int? length}) =>
      lookupMemoryWithAuthority(id, length: length)?.bytes;

  /// Returns a previously observed immutable resident-body bootstrap prefix.
  ///
  /// The opaque token is owned by the concrete physical resident generation,
  /// so these bytes are only an acceleration of an authority the caller
  /// already holds. They never participate in artifact lookup, equivalence,
  /// durability, or mutation decisions.
  Uint8List? lookupResidentReplayPrefix(
    Object generationToken, {
    required int endExclusive,
  }) {
    if (endExclusive <= 0) return null;
    final bytes = _residentReplayPrefixes.remove(generationToken);
    if (bytes == null) return null;
    _residentReplayPrefixes[generationToken] = bytes;
    if (bytes.lengthInBytes < endExclusive) return null;
    return Uint8List.sublistView(bytes, 0, endExclusive).asUnmodifiableView();
  }

  /// Remembers only a generation-scoped replay prefix. This is deliberately
  /// separate from the full immutable-artifact memory tier: a prefix must
  /// never be mistaken for a complete cache hit or storage proof.
  void rememberResidentReplayPrefix({
    required Object generationToken,
    required Uint8List bytes,
  }) {
    if (bytes.isEmpty || bytes.lengthInBytes > memoryMaxBytes) return;
    final owned = bytes.asUnmodifiableView();
    final previous = _residentReplayPrefixes.remove(generationToken);
    if (previous != null) {
      _residentReplayPrefixBytes -= previous.lengthInBytes;
    }
    _residentReplayPrefixes[generationToken] = owned;
    _residentReplayPrefixBytes += owned.lengthInBytes;
    _trimMemoryBudget();
  }

  ArtifactCacheMemoryRead? lookupMemoryWithAuthority(
    DownloadId id, {
    int? length,
  }) {
    for (final candidate in _lookupCandidates(id)) {
      final bytes = _lookupMemoryExact(candidate, length: length);
      if (bytes == null) continue;
      return ArtifactCacheMemoryRead(
        bytes: bytes,
        storageId: candidate,
        generation: generationFor(candidate),
        durable: _durableMemory.contains(
          _ArtifactByteKey(candidate, bytes.lengthInBytes),
        ),
      );
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
    // _rememberExact stores an unmodifiable view. Return that exact object so
    // presentation callers can reuse stable ImageProvider cache identity across
    // speculative prewarm and the later visible mount without exposing mutable
    // cache bytes. Re-wrapping here creates a new Uint8List identity each read
    // and defeats Flutter MemoryImage/ImageCache reuse.
    return bytes;
  }

  Future<ArtifactCacheLookup?> lookup(
    DownloadId id, {
    TaskControl? control,
  }) =>
      _lookupCandidatesInOrder(id, _lookupCandidates(id), control: control);

  /// Looks up an older exact URI carrier for the same logical page/revision.
  ///
  /// This path is intentionally disjoint from verified equivalence: it is
  /// enabled only by the user's carrier-mismatch policy and never registers or
  /// persists an alias from the historical carrier to [id].
  Future<HistoricalArtifactCacheLookup?> lookupHistoricalCarrier(
    DownloadId id, {
    TaskControl? control,
  }) async {
    if (_carrierMismatchPolicy == CachedCarrierMismatchPolicy.strictReload ||
        requiresFreshSource(id)) {
      return null;
    }
    final historicalBackend = backend;
    if (historicalBackend is! HistoricalArtifactCarrierQueryBackend) {
      return null;
    }
    final candidates = await _awaitCancellable(
      (historicalBackend as HistoricalArtifactCarrierQueryBackend)
          .historicalArtifactCarriers(id),
      control,
    );
    control?.throwIfCancelled();
    final signatureConflict = candidates.signatureCount > 1;
    final signatureConflictTrusted = signatureConflict &&
        (_signatureConflictTrust?.call(id.content.sourceId) ?? false);
    if (signatureConflict && !signatureConflictTrusted) return null;
    for (final storageId in candidates.ids) {
      if (storageId == id ||
          storageId.content != id.content ||
          storageId.sourceRevision != id.sourceRevision) {
        continue;
      }
      final lookup = await _lookupCandidatesInOrder(
        id,
        <DownloadId>[storageId],
        control: control,
      );
      if (lookup == null) continue;
      return HistoricalArtifactCacheLookup(
        lookup: lookup,
        candidateCount: candidates.readyRecordCount,
        signatureCount: candidates.signatureCount,
        signatureConflictTrusted: signatureConflictTrusted,
      );
    }
    return null;
  }

  Future<bool> isPinnedBackendExact(DownloadId id) {
    final retention = backend;
    if (retention is! ArtifactCacheRetentionQuery) {
      return Future<bool>.value(false);
    }
    return (retention as ArtifactCacheRetentionQuery).isPinnedExactArtifact(id);
  }

  /// Looks up only this exact identity's authoritative durable storage.
  ///
  /// Verified equivalence is intentionally excluded. Promotion and other
  /// durable ownership checks must not mistake a related version's artifact
  /// for this exact DownloadId's own persisted artifact.
  Future<ArtifactCacheLookup?> lookupAuthoritative(
    DownloadId id, {
    TaskControl? control,
  }) => requiresFreshSource(id)
      ? Future<ArtifactCacheLookup?>.value()
      : _lookupCandidatesInOrder(id, <DownloadId>[id], control: control);

  Future<ArtifactCacheStreamEntry?> openPhysicalArtifact(PhysicalMediaId id) {
    final physicalBackend = backend;
    if (physicalBackend is! PhysicalArtifactCacheBackend) {
      return Future<ArtifactCacheStreamEntry?>.value();
    }
    return (physicalBackend as PhysicalArtifactCacheBackend)
        .openPhysicalArtifact(id);
  }

  Future<ArtifactCacheStreamEntry?> openPhysicalArtifactForBoundReplay(
    PhysicalMediaId id,
  ) {
    final physicalBackend = backend;
    if (physicalBackend is PhysicalArtifactBoundReplayBackend) {
      return (physicalBackend as PhysicalArtifactBoundReplayBackend)
          .openPhysicalArtifactForBoundReplay(id);
    }
    return openPhysicalArtifact(id);
  }

  bool get supportsPhysicalArtifactBoundReplay =>
      backend is PhysicalArtifactBoundReplayBackend;

  Future<bool> bindPhysicalArtifact({
    required PhysicalMediaId physicalId,
    required DownloadId sourceId,
  }) {
    final physicalBackend = backend;
    if (physicalBackend is! PhysicalArtifactCacheBackend) {
      return Future<bool>.value(false);
    }
    return (physicalBackend as PhysicalArtifactCacheBackend)
        .bindPhysicalArtifact(physicalId: physicalId, sourceId: sourceId);
  }

  Future<bool> bindPhysicalArtifactFromCandidates({
    required PhysicalMediaId physicalId,
    required Iterable<DownloadId> candidates,
  }) {
    final physicalBackend = backend;
    if (physicalBackend is! PhysicalArtifactCandidateBindingBackend) {
      return Future<bool>.value(false);
    }
    final allowed = candidates
        .where((candidate) => !requiresFreshSource(candidate))
        .toList(growable: false);
    if (allowed.isEmpty) return Future<bool>.value(false);
    return (physicalBackend as PhysicalArtifactCandidateBindingBackend)
        .bindPhysicalArtifactFromCandidates(
          physicalId: physicalId,
          candidates: allowed,
        );
  }

  Future<bool> materializeExactFromPhysical({
    required PhysicalMediaId physicalId,
    required DownloadId targetId,
  }) async {
    if (physicalId.isExactFallback || requiresFreshSource(targetId)) {
      return false;
    }
    final existing = await lookupAuthoritative(targetId);
    if (existing?.durable == true) return true;
    final physicalBackend = backend;
    if (physicalBackend is! PhysicalArtifactExactBindingBackend) {
      return false;
    }

    _advanceMutationGeneration(targetId);
    _invalidateMemoryExact(targetId);
    var bound = false;
    await _serializeMutation(targetId, () async {
      bound = await (physicalBackend as PhysicalArtifactExactBindingBackend)
          .bindExactArtifactFromPhysical(
        physicalId: physicalId,
        targetId: targetId,
      );
    });
    return bound;
  }

  Future<void> invalidatePhysicalArtifact(PhysicalMediaId id) {
    final physicalBackend = backend;
    if (physicalBackend is! PhysicalArtifactCacheBackend) {
      return Future<void>.value();
    }
    return (physicalBackend as PhysicalArtifactCacheBackend)
        .invalidatePhysicalArtifact(id);
  }

  Future<ArtifactCacheLookup?> _retainedHistoricalPresentationLookup(
    DownloadId id, {
    TaskControl? control,
  }) async {
    if (!requiresFreshSource(id)) return null;
    final authority = _retainedHistoricalPresentationAuthorities[id];
    if (authority == null) return null;
    final storageId = authority.storageId;
    control?.throwIfCancelled();
    await _awaitMutationBarrier(storageId, control);
    if (generationFor(storageId) != authority.generation) {
      if (_retainedHistoricalPresentationAuthorities[id] == authority) {
        _retainedHistoricalPresentationAuthorities.remove(id);
      }
      return null;
    }
    final entry = await _awaitCancellable(
      backend.openArtifactStream(storageId),
      control,
    );
    control?.throwIfCancelled();
    if (generationFor(storageId) != authority.generation ||
        entry == null ||
        entry.length <= 0) {
      if (_retainedHistoricalPresentationAuthorities[id] == authority) {
        _retainedHistoricalPresentationAuthorities.remove(id);
      }
      return null;
    }
    return ArtifactCacheLookup(
      id: id,
      storageId: storageId,
      entry: entry,
      tier: ArtifactCacheTier.persistent,
      durable: true,
      generation: authority.generation,
    );
  }

  /// Reads only the exact historical storage generation that was already
  /// admitted for stale presentation. This deliberately bypasses fresh-source
  /// quarantine for presentation continuity only; it never performs candidate
  /// search, equivalence resolution, or current-exact routing.
  Future<ArtifactCacheRead?> readRetainedHistoricalPresentation(
    DownloadId id, {
    TaskControl? control,
  }) async {
    final lookup =
        await _retainedHistoricalPresentationLookup(id, control: control);
    if (lookup == null) return null;
    try {
      return await readForegroundLookup(lookup, control: control);
    } on _StaleArtifactCacheLookup {
      if (_retainedHistoricalPresentationAuthorities[id]?.storageId ==
          lookup.storageId) {
        _retainedHistoricalPresentationAuthorities.remove(id);
      }
      return null;
    }
  }

  /// Opens a file/descriptor lease for only the retained historical
  /// presentation generation. Source/cache routing remains quarantined.
  Future<ArtifactCachePresentationFileRead?>
      openRetainedHistoricalPresentationFile(
    DownloadId id, {
    TaskControl? control,
  }) async {
    final lookup =
        await _retainedHistoricalPresentationLookup(id, control: control);
    if (lookup == null) return null;
    final opener = lookup.entry.openPresentationFile;
    if (opener == null) return null;
    final lease = await opener();
    if (lease == null) return null;
    var keep = false;
    try {
      control?.throwIfCancelled();
      final authority = _retainedHistoricalPresentationAuthorities[id];
      if (authority == null ||
          authority.storageId != lookup.storageId ||
          authority.generation != lookup.generation ||
          generationFor(lookup.storageId) != lookup.generation ||
          lease.length != lookup.entry.length ||
          lease.path.isEmpty) {
        return null;
      }
      keep = true;
      return ArtifactCachePresentationFileRead(
        path: lease.path,
        length: lease.length,
        width: lease.width,
        height: lease.height,
        cacheIdentity: (
          _presentationFileCacheEpoch,
          lookup.storageId.key,
          lookup.generation,
        ),
        storageId: lookup.storageId,
        generation: lookup.generation,
        release: lease.release,
      );
    } finally {
      if (!keep) await lease.release();
    }
  }

  /// Opens a durable engine-readable file/descriptor lease without
  /// materializing the encoded body in Dart.
  ///
  /// Memory-tier hits are intentionally ignored: a file lease must remain
  /// bound to the persistent physical generation selected by the backend.
  Future<ArtifactCachePresentationFileRead?> openPresentationFile(
    DownloadId id, {
    TaskControl? control,
  }) async {
    if (requiresFreshSource(id)) return null;
    for (final storageId in _lookupCandidates(id)) {
      control?.throwIfCancelled();
      await _awaitMutationBarrier(storageId, control);
      final generation = generationFor(storageId);
      final entry = await backend.openArtifactStream(storageId);
      control?.throwIfCancelled();
      if (requiresFreshSource(id) || generationFor(storageId) != generation) {
        continue;
      }
      final opener = entry?.openPresentationFile;
      if (entry == null || opener == null || entry.length <= 0) continue;
      final lease = await opener();
      if (lease == null) continue;
      var keep = false;
      try {
        control?.throwIfCancelled();
        if (requiresFreshSource(id) ||
            generationFor(storageId) != generation ||
            lease.length != entry.length ||
            lease.path.isEmpty) {
          continue;
        }
        keep = true;
        return ArtifactCachePresentationFileRead(
          path: lease.path,
          length: lease.length,
          width: lease.width,
          height: lease.height,
          cacheIdentity: (
            _presentationFileCacheEpoch,
            storageId.key,
            generation,
          ),
          storageId: storageId,
          generation: generation,
          release: lease.release,
        );
      } finally {
        if (!keep) await lease.release();
      }
    }
    return null;
  }

  Future<ArtifactCacheLookup?> _lookupCandidatesInOrder(
    DownloadId id,
    Iterable<DownloadId> candidates, {
    TaskControl? control,
  }) async {
    if (requiresFreshSource(id)) return null;
    for (final storageId in candidates) {
      control?.throwIfCancelled();
      if (requiresFreshSource(id)) return null;
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
        if (requiresFreshSource(id)) return null;
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
    if (requiresFreshSource(id)) return false;
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
        storageId: lookup.storageId,
        generation: lookup.generation,
        memoryHit: true,
        joined: false,
        durable: lookup.durable,
        integrityBasis: ArtifactReadIntegrityBasis.memoryResident,
      );
    }
    final controlledRead = lookup.entry.readAllControlled;
    final readAll = lookup.entry.readAll;
    final integrityBasis = controlledRead != null || readAll != null
        ? lookup.entry.fullReadIntegrity
        : lookup.entry.streamIntegrity;
    return _readJoined(
      id: lookup.storageId,
      length: lookup.entry.length,
      durable: true,
      integrityBasis: integrityBasis,
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
        final read = await readForegroundLookup(lookup, control: control);
        if (requiresFreshSource(id)) return null;
        return read;
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
  }) async {
    // A promoted-session read can overlap the durable cache handoff for the
    // same exact identity. That handoff advances the cache generation and
    // deliberately cancels old in-flight reads so stale bytes cannot be
    // retained. For an active caller this is an authority switch, not media
    // failure: re-enter the joined read after the mutation barrier so the new
    // durable memory/backend generation can satisfy the same byte request.
    // Caller cancellation remains terminal and is never retried.
    for (var attempt = 0; attempt < 3; attempt++) {
      final generation = generationFor(id);
      // This API is entered only by the active DownloadSession that already
      // owns the exact artifact body. A promotion handoff may have advanced
      // the same exact generation and published those immutable bytes to the
      // memory tier while its durable store is still pending. Consume that
      // current-generation projection directly instead of joining an older
      // session read that will be cancelled by the handoff and then wait
      // behind the persistence mutation barrier.
      final hotBytes = _lookupMemoryExact(id, length: length);
      if (hotBytes != null) {
        final key = _ArtifactByteKey(id, hotBytes.lengthInBytes);
        return ArtifactCacheRead(
          bytes: hotBytes,
          storageId: id,
          generation: generation,
          memoryHit: true,
          joined: false,
          durable: _durableMemory.contains(key),
          integrityBasis: ArtifactReadIntegrityBasis.memoryResident,
        );
      }
      try {
        return await _readJoined(
          id: id,
          length: length,
          durable: false,
          integrityBasis: ArtifactReadIntegrityBasis.sessionArtifact,
          loader: (_) => Future<Uint8List>.sync(loader),
          control: control,
        );
      } on Failure catch (error) {
        if (control?.cancelled == true) {
          control!.throwIfCancelled();
        }
        final authorityChanged = generationFor(id) != generation;
        if (error.code != ErrorCode.cancelled ||
            !authorityChanged ||
            attempt == 2) {
          rethrow;
        }
      }
    }
    throw StateError('unreachable artifact session read retry state');
  }

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

  /// Makes a caller-verified equivalent source artifact durable under the
  /// target exact identity. Persistent backends may add a metadata-only
  /// binding; backends without that capability retain the historical body-copy
  /// fallback. The target never inherits source retention flags.
  Future<bool> materializeVerifiedEquivalentTarget({
    required DownloadId sourceId,
    required DownloadId targetId,
  }) async {
    if (sourceId == targetId ||
        requiresFreshSource(sourceId) ||
        requiresFreshSource(targetId)) {
      return false;
    }
    final target = await lookupAuthoritative(targetId);
    if (target?.durable == true) return false;

    final bindingBackend = backend;
    if (bindingBackend is ArtifactCacheBindingBackend) {
      await _awaitMutationBarrier(sourceId, null);
      _advanceMutationGeneration(targetId);
      _invalidateMemoryExact(targetId);
      var bound = false;
      await _serializeMutation(targetId, () async {
        bound = await (bindingBackend as ArtifactCacheBindingBackend)
            .bindExistingArtifact(
          sourceId: sourceId,
          targetId: targetId,
        );
      });
      if (bound) return true;
    }

    final source = await lookupAuthoritative(sourceId);
    if (source == null || !source.durable) return false;
    final read = await readForegroundLookup(source);
    if (read.bytes.isEmpty) return false;
    await storePromotedArtifact(id: targetId, bytes: read.bytes);
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
    final recoveryGroupAtStart = _freshSourceRecoveryGroups[id];
    final recoveryArmedAtStart = recoveryGroupAtStart != null &&
        _armedFreshSourceRecoveryGroups.contains(recoveryGroupAtStart);
    final generation = _advanceMutationGeneration(id);
    _invalidateMemoryExact(id);
    // The promoted bytes are already the new exact immutable generation.
    // Keep that generation available as a non-durable hot projection while
    // the backend store runs so foreground presentation does not wait behind
    // persistence I/O. Any later mutation advances the generation and
    // withdraws this projection synchronously.
    _rememberExact(id: id, bytes: ownedBytes, durable: false);
    try {
      await _serializeMutation(id, () async {
        await backend.storePromotedArtifact(id: id, bytes: ownedBytes);
      });
    } on Object {
      if (generationFor(id) == generation) {
        _invalidateMemoryExact(id);
      }
      rethrow;
    }
    if (generationFor(id) == generation) {
      if (recoveryArmedAtStart &&
          _freshSourceRecoveryGroups[id] == recoveryGroupAtStart) {
        _completeFreshSourceRecovery(id);
      }
      // The exact byte value did not change; only its durability provenance
      // advances after the persistent store commits.
      _rememberExact(id: id, bytes: ownedBytes, durable: true);
    }
  }

  /// Completes an armed fresh-source quarantine after a promoted physical
  /// generation is intentionally kept hot-only because an explicit pinned
  /// exact artifact must remain untouched.
  void completeFreshSourceRecoveryWithoutReplacement(DownloadId id) {
    _completeFreshSourceRecovery(id);
  }

  /// Cancels a fresh-source quarantine when the physical reset transaction
  /// cannot be completed. This restores the previous durable routing policy;
  /// it never deletes or rewrites artifact bytes.
  void cancelFreshSourceRecovery(int group) {
    _armedFreshSourceRecoveryGroups.remove(group);
    final members = _freshSourceRecoveryMembers.remove(group);
    if (members == null) return;
    for (final member in members) {
      if (_freshSourceRecoveryGroups[member] == group) {
        _freshSourceRecoveryGroups.remove(member);
      }
      _retainedHistoricalPresentationAuthorities.remove(member);
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
    _trimMemoryBudget();
  }

  void _trimMemoryBudget() {
    while (_residentReplayPrefixes.length > memoryMaxEntries) {
      _removeOldestResidentReplayPrefix();
    }
    while (_memory.length > memoryMaxEntries) {
      final oldest = _memory.keys.first;
      _durableMemory.remove(oldest);
      _memoryBytes -= _memory.remove(oldest)!.lengthInBytes;
    }
    while (_memoryBytes + _residentReplayPrefixBytes > memoryMaxBytes) {
      // A small replay prefix is only a latency accelerator; full immutable
      // artifact bytes remain the more valuable central cache entry.
      if (_residentReplayPrefixes.isNotEmpty) {
        _removeOldestResidentReplayPrefix();
        continue;
      }
      if (_memory.isEmpty) break;
      final oldest = _memory.keys.first;
      _durableMemory.remove(oldest);
      _memoryBytes -= _memory.remove(oldest)!.lengthInBytes;
    }
  }

  void _removeOldestResidentReplayPrefix() {
    if (_residentReplayPrefixes.isEmpty) return;
    final oldest = _residentReplayPrefixes.keys.first;
    final removed = _residentReplayPrefixes.remove(oldest);
    if (removed != null) {
      _residentReplayPrefixBytes -= removed.lengthInBytes;
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

  Future<bool> invalidateIfGeneration(
    DownloadId id, {
    required int expectedGeneration,
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    await _awaitMutationBarrier(id, control);
    if (generationFor(id) != expectedGeneration) return false;
    _advanceMutationGeneration(id);
    _invalidateMemoryExact(id);
    await _awaitCancellable(
      _serializeMutation(id, () async {
        await backend.invalidateArtifact(id);
      }),
      control,
    );
    return true;
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
    _residentReplayPrefixes.clear();
    _equivalents.clear();
    _equivalenceOrder.clear();
    _equivalenceResolvers.clear();
    _memoryBytes = 0;
    _residentReplayPrefixBytes = 0;
  }

  Future<ArtifactCacheRead> _readJoined({
    required DownloadId id,
    required int length,
    required bool durable,
    required ArtifactReadIntegrityBasis integrityBasis,
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
        storageId: id,
        generation: generationFor(id),
        memoryHit: true,
        joined: false,
        durable: _durableMemory.contains(_ArtifactByteKey(id, length)),
        integrityBasis: ArtifactReadIntegrityBasis.memoryResident,
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
        storageId: id,
        generation: running.generation,
        memoryHit: false,
        joined: true,
        durable: running.durable,
        integrityBasis: running.integrityBasis,
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
      return _lookupMemoryExact(id, length: length) ?? ownedBytes;
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
      integrityBasis: integrityBasis,
    );
    _inFlight[key] = operation;
    final bytes = await _awaitJoined(operation, control);
    return ArtifactCacheRead(
      bytes: bytes,
      storageId: id,
      generation: operation.generation,
      memoryHit: false,
      joined: false,
      durable: operation.durable,
      integrityBasis: operation.integrityBasis,
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
        streamIntegrity: ArtifactReadIntegrityBasis.memoryResident,
        fullReadIntegrity: ArtifactReadIntegrityBasis.memoryResident,
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

final class HistoricalArtifactCacheLookup {
  const HistoricalArtifactCacheLookup({
    required this.lookup,
    required this.candidateCount,
    required this.signatureCount,
    required this.signatureConflictTrusted,
  });

  final ArtifactCacheLookup lookup;
  final int candidateCount;
  final int signatureCount;
  final bool signatureConflictTrusted;
}

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

final class ArtifactCacheMemoryRead {
  const ArtifactCacheMemoryRead({
    required this.bytes,
    required this.storageId,
    required this.generation,
    required this.durable,
  });

  final Uint8List bytes;
  final DownloadId storageId;
  final int generation;
  final bool durable;
}

final class ArtifactCachePresentationFileRead {
  const ArtifactCachePresentationFileRead({
    required this.path,
    required this.length,
    required this.storageId,
    required this.generation,
    required this.cacheIdentity,
    required this.release,
    this.width,
    this.height,
  });

  final String path;
  final int length;
  final int? width;
  final int? height;
  final DownloadId storageId;
  final int generation;
  final Object cacheIdentity;
  final Future<void> Function() release;
}

final class ArtifactCacheRead {
  const ArtifactCacheRead({
    required this.bytes,
    required this.storageId,
    required this.generation,
    required this.memoryHit,
    required this.joined,
    required this.integrityBasis,
    this.durable = false,
  });

  final Uint8List bytes;
  final DownloadId storageId;
  final int generation;
  final bool memoryHit;
  final bool joined;
  final bool durable;
  final ArtifactReadIntegrityBasis integrityBasis;
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
    required this.integrityBasis,
  });

  final _ArtifactByteKey key;
  final Future<Uint8List> future;
  final _JoinedArtifactReadControl control;
  final int generation;
  final bool durable;
  final ArtifactReadIntegrityBasis integrityBasis;
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
