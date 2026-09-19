import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'artifact_cache_manager.dart';
import 'artifact_cache_read_scheduler.dart';
import 'artifact_cache_reuse.dart';
import 'partial_download_handoff.dart';
import 'partial_download_store.dart';
import 'physical_transfer_retention.dart';
import 'promoted_artifact_cache_handoff.dart';
import 'version_page_authority.dart';

/// Composition-level owner for physical image transfer state.
///
/// Reader sessions, prefetch and explicit download commands attach consumers;
/// none of those consumers owns the physical [DownloadRegistry], writer,
/// retry state or hot partial. Durable immutable artifacts remain owned by
/// [ArtifactCacheManager], and cold partials remain owned by
/// [PartialDownloadStore].
final class CompositionDownloadTransferRuntime {
  CompositionDownloadTransferRuntime({
    required this.artifactCacheManager,
    required this.partialDownloadStore,
    required this.net,
    ArtifactCacheReadScheduler? localReadScheduler,
    SpeculativeEncodedReadBudget? speculativeEncodedReadBudget,
    EphemeralCacheWorkspace? transferWorkspace,
    this.readStallTimeout = DownloadJob.defaultReadStallTimeout,
    this.maxIdlePromotedSessions = 8,
    this.maxIdlePartialSessions = 32,
    this.maxIdlePartialBytes = 256 * 1024 * 1024,
    VersionPageAuthority? versionPageAuthority,
  })  : versionPageAuthority = versionPageAuthority ?? VersionPageAuthority(),
        localReadScheduler =
            localReadScheduler ?? ArtifactCacheReadScheduler(),
        speculativeEncodedReadBudget =
            speculativeEncodedReadBudget ?? SpeculativeEncodedReadBudget(),
        clock = const SystemClock(),
        traceHub = _CompositionTransferTraceHub(),
        workspace = transferWorkspace ??
            EphemeralCacheWorkspace.readerSession(
              'composition-transfer-${++_sequence}',
            ) {
    final cache = artifactCacheManager;
    if (cache != null) {
      cache.registerEquivalentResolver(
        key: _versionPageAuthorityResolverKey,
        resolver: this.versionPageAuthority.directCandidates,
      );
    }
    final partialStore = partialDownloadStore;
    if (partialStore != null) {
      partialDownloadHandoff = PartialDownloadHandoff(
        store: partialStore,
        equivalentCandidates: _verifiedEquivalentCandidates,
        onError: (error, stackTrace) => _recordHandoffError(
          'partial-download-handoff',
          error,
          stackTrace,
        ),
        clock: clock,
        readScheduler: localReadScheduler,
        physicalArtifactCache: cache,
        traceSink: traceHub,
        sessionId: 'composition-transfer-owner',
      );
    }
    if (cache != null) {
      artifactCacheHandoff = PromotedArtifactCacheHandoff(
        cache: cache,
        onError: (error, stackTrace) => _recordHandoffError(
          'promoted-artifact-handoff',
          error,
          stackTrace,
        ),
        clock: clock,
        traceSink: traceHub,
        sessionId: 'composition-transfer-owner',
        residentReplaySource: (session, endExclusive) => _openResidentReplay(
          session,
          0,
          endExclusive,
          priority: () => session.effectivePriority,
        ),
        requiredExactTargets: (session) =>
            owner.requiredExactDurableTargets(session.id),
        exactDurableRestoreProof: partialDownloadHandoff?.provesExactDurableBody,
        suppressAutomaticCommit: _consumePreservedPinnedReload,
      );
    }
    registry = DownloadRegistry(
      layout: workspace.layout,
      clock: clock,
      traceSink: traceHub,
      onSessionCreated: (session) {
        artifactCacheHandoff?.observe(session);
        _physicalTransferRetention?.observe(session);
      },
    );
    owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      prepareDownload: partialDownloadHandoff == null
          ? null
          : (session) => _restoreLocalSingleFlight(session),
      prepareDownloadWithControl: partialDownloadHandoff == null
          ? null
          : (session, {required control}) =>
              _restoreLocalSingleFlight(
                session,
                control: control,
              ),
      net: net,
      resolveTransferId: _resolveTransferIdForAcquire,
      speculativeEncodedReadBudget: this.speculativeEncodedReadBudget,
      readStallTimeout: readStallTimeout,
    );
    _physicalTransferRetention = PhysicalTransferRetention(
      registry: registry,
      owner: owner,
      clock: clock,
      traceSink: traceHub,
      artifactHandoff: artifactCacheHandoff,
      partialHandoff: partialDownloadHandoff,
      maxIdlePromotedSessions: maxIdlePromotedSessions,
      maxIdlePartialSessions: maxIdlePartialSessions,
      maxIdlePartialBytes: maxIdlePartialBytes,
    );
  }

  static int _sequence = 0;
  static const _versionPageAuthorityResolverKey =
      'composition-version-page-authority';

  final ArtifactCacheManager? artifactCacheManager;
  final VersionPageAuthority versionPageAuthority;
  final PartialDownloadStore? partialDownloadStore;
  final NetLane net;
  final ArtifactCacheReadScheduler localReadScheduler;
  final SpeculativeEncodedReadBudget speculativeEncodedReadBudget;
  final Duration readStallTimeout;
  final int maxIdlePromotedSessions;
  final int maxIdlePartialSessions;
  final int maxIdlePartialBytes;
  final MonoClock clock;
  final _CompositionTransferTraceHub traceHub;

  void _recordHandoffError(
    String stage,
    Object error,
    StackTrace stackTrace,
  ) {
    traceHub.record(
      traceEvent(
        clock: clock,
        sessionId: 'composition-transfer-owner',
        kind: TraceEventKind.taskFailed,
        payload: <String, Object?>{
          'stage': stage,
          'error': '$error',
          'stackTrace': '$stackTrace',
        },
      ),
    );
  }
  final EphemeralCacheWorkspace workspace;
  PromotedArtifactCacheHandoff? artifactCacheHandoff;
  PartialDownloadHandoff? partialDownloadHandoff;
  PhysicalTransferRetention? _physicalTransferRetention;
  late final DownloadRegistry registry;
  late final DownloadTransferOwner owner;
  final Map<DownloadId, PhysicalMediaId> _lastTracedPhysicalMediaOwner =
      <DownloadId, PhysicalMediaId>{};
  final Map<DownloadId, String> _lastTracedCanonicalMediaConflict =
      <DownloadId, String>{};
  final Map<DownloadSession, ({SourceEpoch epoch, Future<void> future})>
      _localRestoreFlights =
      <DownloadSession, ({SourceEpoch epoch, Future<void> future})>{};
  final Map<DownloadId, SourceEpoch?> _preservedPinnedReloadEpochs =
      <DownloadId, SourceEpoch?>{};
  final Map<
      DownloadId,
      ({DownloadSession session, DownloadSnapshotListener listener})>
      _historicalCarrierRevalidationWaiters = <
          DownloadId,
          ({DownloadSession session, DownloadSnapshotListener listener})>{};
  final Map<DownloadId, Future<void>> _historicalCarrierRevalidations =
      <DownloadId, Future<void>>{};
  final Map<String, Map<String, CanonicalMediaChapterAuthority>>
      _canonicalMediaAuthorityScopes =
      <String, Map<String, CanonicalMediaChapterAuthority>>{};
  bool _disposed = false;

  bool get disposed => _disposed;
  bool get hasConsumers => owner.consumers.isNotEmpty;

  Iterable<DownloadId> versionCandidatesFor(DownloadId id) =>
      versionPageAuthority.directCandidates(id);

  PhysicalMediaId physicalMediaIdFor(DownloadId id) =>
      _resolveCanonicalPhysicalMedia(id) ?? registry.physicalMediaIdFor(id);

  int get canonicalMediaAuthorityCount => _canonicalMediaAuthorityScopes.values
      .fold<int>(0, (total, values) => total + values.length);

  void replaceCanonicalMediaAuthorityScope(
    String scope,
    Iterable<CanonicalMediaChapterAuthority> authorities,
  ) {
    if (_disposed) return;
    if (scope.isEmpty) {
      throw ArgumentError.value(scope, 'scope', 'must not be empty');
    }
    final next = <String, CanonicalMediaChapterAuthority>{};
    for (final authority in authorities) {
      if (next.containsKey(authority.exactKey)) {
        throw StateError(
          'duplicate canonical media authority for ${authority.exactKey}',
        );
      }
      next[authority.exactKey] = authority;
    }
    if (next.isEmpty) {
      _canonicalMediaAuthorityScopes.remove(scope);
    } else {
      _canonicalMediaAuthorityScopes[scope] = next;
    }
  }

  PhysicalMediaId? _resolveCanonicalPhysicalMedia(DownloadId id) {
    final candidates = <PhysicalMediaId>{};
    final exactKey = canonicalMediaExactChapterKeyForDownload(id);
    for (final scope in _canonicalMediaAuthorityScopes.values) {
      final authority = scope[exactKey];
      if (authority == null) continue;
      final candidate = authority.resolve(id);
      if (candidate != null) candidates.add(candidate);
    }
    if (candidates.length <= 1) {
      _lastTracedCanonicalMediaConflict.remove(id);
      return candidates.isEmpty ? null : candidates.single;
    }
    _recordCanonicalMediaAuthorityConflict(id, candidates);
    // Conflicting control-plane scopes are not enough authority to merge two
    // physical bodies. Stay exact until the scopes converge rather than
    // guessing one canonical owner.
    return null;
  }

  bool _applyCanonicalPhysicalMedia(DownloadId id) {
    final physicalId = _resolveCanonicalPhysicalMedia(id);
    if (physicalId == null) return false;
    try {
      registry.bindPhysicalMedia(id: id, physicalId: physicalId);
      return true;
    } on StateError {
      // Existing exact/legacy physical state keeps its current generation.
      // The canonical identity is recomputed from the current authority scope
      // on a later acquire after that state has retired; this is not a rebind.
      return false;
    }
  }

  void _recordCanonicalMediaAuthorityConflict(
    DownloadId exactId,
    Set<PhysicalMediaId> candidates,
  ) {
    final ordered = candidates.toList(growable: false)
      ..sort((left, right) => left.key.compareTo(right.key));
    final signature = ordered.map((value) => value.key).join('\\n');
    if (_lastTracedCanonicalMediaConflict[exactId] == signature) return;
    _lastTracedCanonicalMediaConflict[exactId] = signature;
    try {
      traceHub.record(
        traceEvent(
          clock: clock,
          sessionId: 'composition-transfer-owner',
          kind: TraceEventKind.artifactSource,
          identityHash: exactId.key,
          payload: <String, Object?>{
            'stage': 'canonical-media-authority-conflict',
            'sourceId': exactId.content.sourceId,
            'comicId': exactId.content.comicId,
            'chapterId': exactId.content.chapterId,
            'pageId': exactId.content.pageId,
            if (exactId.pageIndexHint != null)
              'pageIndex': exactId.pageIndexHint,
            'sourceRevision': exactId.sourceRevision,
            'candidateCount': ordered.length,
            'candidatePhysicalKeys': ordered
                .map((value) => value.key)
                .toList(growable: false),
            'fallback': 'exact',
          },
        ),
      );
    } on Object {
      // Control-plane diagnostics must never alter transfer acquisition.
    }
  }

  Iterable<DownloadId> _verifiedEquivalentCandidates(DownloadId id) sync* {
    final cache = artifactCacheManager;
    if (cache != null) {
      yield* cache.directEquivalents(id);
      return;
    }
    yield* versionPageAuthority.directCandidates(id);
  }

  /// Resolves a logical page to an already-existing reusable physical carrier
  /// before materializing a new session. The logical identity itself remains
  /// exact; version relations only supply verified candidates.
  DownloadSession sessionFor(DownloadId logicalId) =>
      registry.get(_resolveTransferIdForAcquire(logicalId));

  Future<void> _restoreLocalSingleFlight(
    DownloadSession session, {
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    final handoff = partialDownloadHandoff;
    if (handoff == null || _disposed) return;
    final epoch = session.epoch;
    final existing = _localRestoreFlights[session];
    if (existing != null && existing.epoch == epoch) {
      await existing.future;
      control?.throwIfCancelled();
      return;
    }

    late final Future<void> tracked;
    tracked = handoff.restoreInto(session, control: control).whenComplete(() {
      final current = _localRestoreFlights[session];
      if (current != null && identical(current.future, tracked)) {
        _localRestoreFlights.remove(session);
      }
    });
    _localRestoreFlights[session] = (epoch: epoch, future: tracked);
    await tracked;
    control?.throwIfCancelled();
  }

  /// Starts only the durable/local authority phase for one exact Reader page.
  ///
  /// This never creates network admission or source demand. If the Reader
  /// attaches while the operation is in flight, the owner's normal local
  /// preparation joins the same session+epoch future. A miss simply leaves the
  /// session empty so authoritative demand can choose the normal provider path.
  Future<bool> prewarmLocalArtifact(DownloadId logicalId) async {
    if (_disposed || partialDownloadHandoff == null) return false;
    final startedAtMicros = clock.nowMicros();
    final session = sessionFor(logicalId);
    if (session.state == DownloadState.disposed) return false;
    try {
      if (session.state != DownloadState.promoted &&
          session.committedLength == 0) {
        await _restoreLocalSingleFlight(session);
      }
      final ready = session.state == DownloadState.promoted ||
          session.committedLength > 0;
      traceHub.record(
        traceEvent(
          clock: clock,
          sessionId: 'composition-transfer-owner',
          kind: TraceEventKind.artifactSource,
          identityHash: logicalId.key,
          payload: <String, Object?>{
            'stage': 'local-authority-prewarm',
            'ready': ready,
            'state': session.state.name,
            'committedLength': session.committedLength,
            'physicalMediaKind': session.physicalId.kind.name,
            'physicalMediaKey': session.physicalId.key,
            'prewarmMicros':
                (clock.nowMicros() - startedAtMicros).clamp(0, 1 << 62).toInt(),
          },
        ),
      );
      return ready;
    } on Object catch (error) {
      traceHub.record(
        traceEvent(
          clock: clock,
          sessionId: 'composition-transfer-owner',
          kind: TraceEventKind.artifactSource,
          identityHash: logicalId.key,
          payload: <String, Object?>{
            'stage': 'local-authority-prewarm',
            'ready': false,
            'error': '$error',
            'prewarmMicros':
                (clock.nowMicros() - startedAtMicros).clamp(0, 1 << 62).toInt(),
          },
        ),
      );
      return false;
    }
  }

  /// Read-only logical-session lookup using the same physical-candidate set as
  /// acquire, without creating a new alias or session.
  DownloadSession? findSession(DownloadId logicalId) {
    _applyCanonicalPhysicalMedia(logicalId);
    final resolvedExact = registry.resolvePhysicalId(logicalId);
    if (registry.hasDirectPhysicalMediaBinding(logicalId) ||
        resolvedExact != logicalId) {
      return registry.find(resolvedExact);
    }
    final exact = registry.findExact(logicalId);
    if (exact?.demanded == true) return exact;
    final candidates = <DownloadId, DownloadSession>{};
    if (exact != null && _canJoinEquivalentSession(exact)) {
      candidates[logicalId] = exact;
    }
    for (final equivalent in _verifiedEquivalentCandidates(logicalId)) {
      final physicalId = registry.resolvePhysicalId(equivalent);
      final session = registry.find(physicalId);
      if (session == null || !_canJoinEquivalentSession(session)) continue;
      candidates[physicalId] = session;
    }
    if (candidates.isEmpty) return exact;
    final ordered = candidates.entries.toList(growable: false)
      ..sort(_compareEquivalentPhysicalCandidates);
    return ordered.first.value;
  }

  /// Signals that presentation has obtained a usable frame for [logicalId].
  ///
  /// The signal is policy-neutral from the caller's perspective. When the
  /// cache router served a historical URI under stale-while-revalidate policy,
  /// this is the safe boundary after which the old resident generation may be
  /// retired and a fresh exact source generation admitted in the background.
  void notifyPresentationSatisfied(DownloadId logicalId) {
    if (_disposed) return;
    final cache = artifactCacheManager;
    if (cache == null ||
        !cache.hasPendingHistoricalCarrierRevalidation(logicalId) ||
        _historicalCarrierRevalidations.containsKey(logicalId) ||
        _historicalCarrierRevalidationWaiters.containsKey(logicalId)) {
      return;
    }
    final session = findSession(logicalId);
    if (session == null) return;
    if (_historicalCarrierSessionReadyForRevalidation(session)) {
      _startHistoricalCarrierRevalidation(logicalId);
      return;
    }

    late final DownloadSnapshotListener listener;
    listener = (_) {
      if (_disposed) {
        _removeHistoricalCarrierRevalidationWaiter(logicalId);
        return;
      }
      if (session.state == DownloadState.disposed ||
          session.state == DownloadState.failed) {
        _removeHistoricalCarrierRevalidationWaiter(logicalId);
        return;
      }
      if (!_historicalCarrierSessionReadyForRevalidation(session)) return;
      _removeHistoricalCarrierRevalidationWaiter(logicalId);
      _startHistoricalCarrierRevalidation(logicalId);
    };
    _historicalCarrierRevalidationWaiters[logicalId] = (
      session: session,
      listener: listener,
    );
    session.addSnapshotListener(listener);
    // Close the listener-install race if the cache-backed local transfer
    // promoted synchronously while the first frame callback was being handled.
    listener(session.snapshot);
  }

  bool _historicalCarrierSessionReadyForRevalidation(
    DownloadSession session,
  ) =>
      session.state == DownloadState.promoted &&
      session.residentBodyBacked &&
      session.residentBodyAuthority == ByteResponseBodyAuthority.artifactCache &&
      !session.activeRun &&
      !session.hasWriter;

  void _removeHistoricalCarrierRevalidationWaiter(DownloadId id) {
    final waiter = _historicalCarrierRevalidationWaiters.remove(id);
    if (waiter != null) {
      waiter.session.removeSnapshotListener(waiter.listener);
    }
  }

  void _startHistoricalCarrierRevalidation(DownloadId id) {
    final cache = artifactCacheManager;
    if (_disposed ||
        cache == null ||
        _historicalCarrierRevalidations.containsKey(id) ||
        !cache.consumeHistoricalCarrierRevalidation(id)) {
      return;
    }
    final exactGeneration = cache.generationFor(id);
    late final Future<void> tracked;
    tracked = recoverPresentationArtifact(
      id,
      reason: 'historical-carrier-stale-while-revalidate',
      rejectedStorageId: id,
      rejectedGeneration: exactGeneration,
    ).then<void>((recovered) {
      if (!recovered && !_disposed) {
        cache.restoreHistoricalCarrierRevalidation(id);
      }
      _recordHistoricalCarrierRevalidation(
        id,
        action: recovered ? 'fresh-source-admitted' : 'deferred',
      );
    }, onError: (Object error, StackTrace stackTrace) {
      if (!_disposed) cache.restoreHistoricalCarrierRevalidation(id);
      _recordHandoffError(
        'historical-carrier-revalidation',
        error,
        stackTrace,
      );
    }).whenComplete(() {
      if (identical(_historicalCarrierRevalidations[id], tracked)) {
        _historicalCarrierRevalidations.remove(id);
      }
    });
    _historicalCarrierRevalidations[id] = tracked;
    unawaited(tracked);
    _recordHistoricalCarrierRevalidation(id, action: 'started');
  }

  void _recordHistoricalCarrierRevalidation(
    DownloadId id, {
    required String action,
  }) {
    try {
      traceHub.record(
        traceEvent(
          clock: clock,
          sessionId: 'composition-transfer-owner',
          kind: TraceEventKind.artifactSource,
          identityHash: id.key,
          payload: <String, Object?>{
            'stage': 'historical-carrier-revalidation',
            'action': action,
          },
        ),
      );
    } on Object {
      // Diagnostics cannot own stale-while-revalidate scheduling.
    }
  }

  DownloadId _resolveTransferIdForAcquire(DownloadId exactId) {
    _applyCanonicalPhysicalMedia(exactId);
    final resolvedExact = registry.resolvePhysicalId(exactId);
    _recordPhysicalMediaOwnerResolution(exactId, resolvedExact);
    if (registry.hasDirectPhysicalMediaBinding(exactId) ||
        resolvedExact != exactId) {
      return resolvedExact;
    }
    final exact = registry.findExact(exactId);
    // Never redirect a logical page while its exact physical session still has
    // consumer demand. A retained/parked exact session with no demand is only
    // one reusable carrier candidate and may yield to a more advanced verified
    // equivalent on the next acquire.
    if (exact?.demanded == true) return exactId;

    final candidates = <DownloadId, DownloadSession>{};
    if (exact != null && _canJoinEquivalentSession(exact)) {
      candidates[exactId] = exact;
    }
    for (final equivalent in _verifiedEquivalentCandidates(exactId)) {
      final physicalId = registry.resolvePhysicalId(equivalent);
      final session = registry.find(physicalId);
      if (session == null || !_canJoinEquivalentSession(session)) continue;
      candidates[physicalId] = session;
    }
    if (candidates.isEmpty) return exactId;
    final ordered = candidates.entries.toList(growable: false)
      ..sort(_compareEquivalentPhysicalCandidates);
    final selected = ordered.first;
    if (selected.key == exactId) return exactId;
    if (exact == null) {
      registry.aliasPhysical(id: exactId, target: selected.key);
    }
    _recordAcquireAlias(
      exactId,
      action: exact == null
          ? 'joined-existing-physical'
          : 'preferred-equivalent-over-idle-exact',
      candidate: selected.key,
      session: selected.value,
      candidateOwners: ordered.length,
    );
    return selected.key;
  }

  void _recordPhysicalMediaOwnerResolution(
    DownloadId exactId,
    DownloadId physicalAnchor,
  ) {
    final physicalId = registry.physicalMediaIdFor(exactId);
    if (_lastTracedPhysicalMediaOwner[exactId] == physicalId) return;
    _lastTracedPhysicalMediaOwner[exactId] = physicalId;
    try {
      final direct = registry.hasDirectPhysicalMediaBinding(exactId);
      final exactToken = workspace.layout.tokenFor(exactId);
      traceHub.record(
        traceEvent(
          clock: clock,
          sessionId: 'composition-transfer-owner',
          kind: TraceEventKind.artifactSource,
          identityHash: exactToken,
          payload: <String, Object?>{
            'stage': 'physical-media-owner-resolved',
            'sourceId': exactId.content.sourceId,
            if (exactId.pageIndexHint != null)
              'pageIndex': exactId.pageIndexHint,
            'sourceRevision': exactId.sourceRevision,
            'exactToken': exactToken,
            'physicalToken': workspace.layout.tokenForPhysical(physicalId),
            'physicalMediaKind': physicalId.kind.name,
            'canonicalDirect': direct && !physicalId.isExactFallback,
            'legacyAlias': physicalAnchor != exactId && !direct,
          },
        ),
      );
    } on Object {
      // Physical-owner diagnostics must never alter transfer acquisition.
    }
  }

  void _recordAcquireAlias(
    DownloadId exactId, {
    required String action,
    required DownloadId candidate,
    DownloadSession? session,
    int candidateOwners = 1,
  }) {
    try {
      traceHub.record(
        traceEvent(
          clock: clock,
          sessionId: 'composition-transfer-owner',
          kind: TraceEventKind.artifactSource,
          identityHash: exactId.key,
          payload: <String, Object?>{
            'stage': 'verified-transfer-acquire-alias',
            'action': action,
            'physicalToken': workspace.layout.tokenFor(candidate),
            if (session != null) 'physicalState': session.state.name,
            if (session != null)
              'physicalCommittedLength': session.committedLength,
            'candidateOwners': candidateOwners,
            'selection': candidateOwners > 1
                ? 'preferred-existing-owner'
                : 'unique-existing-owner',
            'phase': 'acquire-before-physical-session',
          },
        ),
      );
    } on Object {
      // Identity diagnostics must never alter physical acquisition.
    }
  }

  int _compareEquivalentPhysicalCandidates(
    MapEntry<DownloadId, DownloadSession> left,
    MapEntry<DownloadId, DownloadSession> right,
  ) {
    final authority = _physicalReuseAuthority(right.value)
        .compareTo(_physicalReuseAuthority(left.value));
    if (authority != 0) return authority;
    final committed = right.value.committedLength
        .compareTo(left.value.committedLength);
    if (committed != 0) return committed;
    final demand = right.value.demandCount.compareTo(left.value.demandCount);
    if (demand != 0) return demand;
    final priority = right.value.effectivePriority
        .compareTo(left.value.effectivePriority);
    if (priority != 0) return priority;
    return left.key.key.compareTo(right.key.key);
  }

  int _physicalReuseAuthority(DownloadSession session) {
    if (session.state == DownloadState.promoted) return 4;
    if (session.hasWriter ||
        session.activeRun ||
        session.state == DownloadState.receiving) {
      return 3;
    }
    if (session.demanded || session.state == DownloadState.queued) return 2;
    if (session.committedLength > 0) return 1;
    return 0;
  }

  bool _canJoinEquivalentSession(DownloadSession session) {
    if (session.state == DownloadState.disposed) return false;
    if (session.residentBodyBacked &&
        session.residentBodyAuthority !=
            ByteResponseBodyAuthority.artifactCache) {
      // A source-resident body has no physical encoded copy to replay through
      // another version safely. Keep it exact until durable cache authority
      // exists; hot/session artifacts can share immediately.
      return false;
    }
    return session.demanded ||
        session.activeRun ||
        session.hasWriter ||
        session.committedLength > 0 ||
        session.state == DownloadState.promoted;
  }

  /// Whether [id] currently resolves to physical encoded state that a newly
  /// verified equivalent identity may safely join at acquire time.
  ///
  /// Keep this query on the transfer runtime so version-reuse preparation and
  /// `_resolveTransferIdForAcquire` share the same resident-body authority
  /// rules instead of duplicating session-state heuristics in the App layer.
  bool hasReusableEquivalentPhysicalState(DownloadId id) {
    final session = registry.find(id);
    return session != null && _canJoinEquivalentSession(session);
  }

  bool hasReusablePhysicalStateForChapter(ChapterManifest chapter) {
    for (final session in registry.sessions) {
      final id = session.id;
      if (id.content.sourceId != chapter.sourceId ||
          id.content.comicId != chapter.comicId ||
          id.content.chapterId != chapter.chapter.chapterId ||
          id.sourceRevision != chapter.chapter.sourceRevision) {
        continue;
      }
      if (_canJoinEquivalentSession(session)) return true;
    }
    return false;
  }

  DownloadTransferConsumer attachConsumer({
    required String scopeId,
    required TransferTransportPick transportFor,
    TransferRetainedTransportPick? retainedTransportFor,
    required TraceSink consumerTraceSink,
    TraceSink? localPhysicalTraceSink,
    TraceSink? sharedPhysicalTraceSink,
    RetryPolicy retry = const RetryPolicy(),
    String Function(DownloadId id)? downloadBucketFor,
    int Function(DownloadId id)? downloadBucketLimitFor,
  }) {
    if (_disposed) {
      throw StateError('composition transfer runtime is disposed');
    }
    if (localPhysicalTraceSink != null) {
      traceHub.attach(localPhysicalTraceSink);
    }
    if (sharedPhysicalTraceSink != null) {
      traceHub.attach(sharedPhysicalTraceSink);
    }
    return owner.attachConsumer(
      scopeId: scopeId,
      transportFor: transportFor,
      retainedTransportFor: retainedTransportFor,
      traceSink: consumerTraceSink,
      retry: retry,
      downloadBucketFor: downloadBucketFor,
      downloadBucketLimitFor: downloadBucketLimitFor,
    );
  }

  void detachPhysicalTrace({
    TraceSink? localPhysicalTraceSink,
    TraceSink? sharedPhysicalTraceSink,
  }) {
    if (localPhysicalTraceSink != null) {
      traceHub.detach(localPhysicalTraceSink);
    }
    if (sharedPhysicalTraceSink != null) {
      traceHub.detach(sharedPhysicalTraceSink);
    }
  }

  Future<Uint8List> readArtifact(Artifact artifact) =>
      workspace.readArtifact(artifact);

  bool _consumePreservedPinnedReload(DownloadSession session) {
    if (!_preservedPinnedReloadEpochs.containsKey(session.id)) return false;
    final rejectedEpoch = _preservedPinnedReloadEpochs[session.id];
    if (rejectedEpoch != null && session.epoch == rejectedEpoch) return false;
    _preservedPinnedReloadEpochs.remove(session.id);
    return true;
  }

  /// Invalidates the exact byte authority rejected by presentation and
  /// reopens the same demanded physical transfer as a fresh epoch. The
  /// rejected storage identity/generation comes from the actual cache read; a
  /// late failure from an older generation must never delete a newer artifact.
  Future<bool> recoverPresentationArtifact(
    DownloadId id, {
    required String reason,
    bool userInitiated = false,
    DownloadId? rejectedStorageId,
    int? rejectedGeneration,
  }) async {
    if (_disposed) return false;
    final cache = artifactCacheManager;
    final rejectedAuthorityKnown =
        rejectedStorageId != null && rejectedGeneration != null;
    if (cache != null &&
        rejectedAuthorityKnown &&
        cache.generationFor(rejectedStorageId) != rejectedGeneration) {
      _recordPresentationRecoveryTrace(
        id: id,
        storageId: rejectedStorageId,
        reason: reason,
        action: 'stale-generation-reload',
      );
      return true;
    }

    var storageId = rejectedStorageId;
    var generation = rejectedGeneration;
    if (cache != null && storageId == null) {
      final lookup = await cache.lookup(id);
      storageId = lookup?.storageId ?? id;
      generation = lookup?.generation ?? cache.generationFor(storageId);
    }
    storageId ??= id;
    _applyCanonicalPhysicalMedia(id);
    final physicalAnchor = registry.resolvePhysicalId(id);
    final physicalMediaId = physicalMediaIdFor(id);
    final sessionBeforeRecovery = registry.find(physicalAnchor);
    final preservePinnedExact = cache != null &&
        (await cache.isPinnedBackendExact(storageId) ||
            (storageId != id && await cache.isPinnedBackendExact(id)));
    if (preservePinnedExact) {
      _preservedPinnedReloadEpochs[physicalAnchor] =
          sessionBeforeRecovery?.epoch;
    } else {
      _preservedPinnedReloadEpochs.remove(physicalAnchor);
    }
    int? freshSourceRecoveryGroup;

    return owner.recoverPresentationArtifact(
      id,
      invalidateArtifact: () async {
        if (reason != 'historical-carrier-stale-while-revalidate') {
          cache?.clearRetainedHistoricalPresentation(id);
        }
        var invalidated = true;
        if (cache != null && !preservePinnedExact) {
          final expectedGeneration = generation;
          if (expectedGeneration == null) {
            await cache.invalidate(storageId!);
          } else {
            invalidated = await cache.invalidateIfGeneration(
              storageId!,
              expectedGeneration: expectedGeneration,
            );
          }
        }
        if (invalidated && cache != null) {
          freshSourceRecoveryGroup = cache.beginFreshSourceRecovery(<DownloadId>{
            id,
            physicalAnchor,
          });
        }
        _recordPresentationRecoveryTrace(
          id: id,
          storageId: storageId!,
          reason: reason,
          action: invalidated
              ? preservePinnedExact
                  ? userInitiated
                      ? 'preserve-pinned-manual-retry'
                      : 'preserve-pinned-automatic-retry'
                  : (userInitiated ? 'manual-retry' : 'automatic-retry')
              : 'stale-generation-reload',
        );
        return invalidated;
      },
      afterPhysicalReset: () async {
        final group = freshSourceRecoveryGroup;
        if (group == null || cache == null) return;
        try {
          if (!physicalMediaId.isExactFallback) {
            await cache.invalidatePhysicalArtifact(physicalMediaId);
            final partialStore = partialDownloadStore;
            if (partialStore is PhysicalPartialDownloadStore) {
              await (partialStore as PhysicalPartialDownloadStore)
                  .invalidatePhysicalPartialDownload(physicalMediaId);
            }
          }
          cache.armFreshSourceRecovery(group);
        } on Object {
          cache.cancelFreshSourceRecovery(group);
          _preservedPinnedReloadEpochs.remove(physicalAnchor);
          rethrow;
        }
      },
    );
  }

  void _recordPresentationRecoveryTrace({
    required DownloadId id,
    required DownloadId storageId,
    required String reason,
    required String action,
  }) {
    try {
      traceHub.record(
        traceEvent(
          clock: clock,
          sessionId: 'composition-transfer-owner',
          kind: TraceEventKind.artifactSource,
          identityHash: id.key,
          payload: <String, Object?>{
            'stage': 'presentation-artifact-recovery',
            'action': action,
            'reason': reason,
            if (storageId != id) 'storageIdentityHash': storageId.key,
          },
        ),
      );
    } on Object {
      // Recovery diagnostics must never alter cache/session authority.
    }
  }

  /// Replays the mutable encoded body owned by one hot physical session through
  /// the same composition-wide local-read scheduler used by durable READY
  /// bodies. The DownloadSession remains the byte authority; this capability
  /// owns only read bandwidth/admission.
  DownloadArtifactReplayRangeSourceWithControl
      artifactReplayRangeSourceWithControl({
    required int Function(DownloadId id) priorityFor,
  }) =>
          (session, start, endExclusive,
              {required chunkSize, required control}) async {
            control.throwIfCancelled();
            if (_disposed || !identical(registry.find(session.id), session)) {
              throw const Failure(
                code: ErrorCode.invalidState,
                message:
                    'hot artifact replay requires the current physical session',
              );
            }
            if (session.residentBodyBacked ||
                start < 0 ||
                endExclusive <= start ||
                endExclusive > session.artifact.committedLength) {
              throw Failure(
                code: ErrorCode.artifactCorruption,
                message: 'invalid hot artifact replay range '
                    '$start..$endExclusive/${session.artifact.committedLength}',
              );
            }
            int replayPriority() {
              final controlled = control.priority;
              if (controlled > 0) return controlled;
              final physical = session.effectivePriority;
              return physical > 0 ? physical : priorityFor(session.id);
            }

            final initialReplayCreditBytes =
                session.contentKind == ContentKind.webp &&
                        start == 0 &&
                        chunkSize <= webpDecodePrefixQuantumBytesFor(session.id)
                    ? chunkSize
                    : 0;
            return _scheduledResidentReplay(
              session.artifact.readChunks(
                start: start,
                endExclusive: endExclusive,
                chunkSize: chunkSize,
              ),
              priority: replayPriority,
              control: control,
              initialReplayCreditBytes: initialReplayCreditBytes,
              traceId: session.id,
              replaySource: 'hot-artifact',
            );
          };

  /// Returns the composition-owned resident-body replay service for one
  /// consumer. Storage/source backend selection stays here; consumers supply
  /// only a dynamic priority projection for the shared local-read scheduler.
  DownloadResidentReplaySource residentReplaySource({
    required int Function(DownloadId id) priorityFor,
  }) =>
      (session, endExclusive) => _openResidentReplay(
            session,
            0,
            endExclusive,
            priority: () => priorityFor(session.id),
          );

  DownloadResidentReplaySourceWithControl residentReplaySourceWithControl({
    required int Function(DownloadId id) priorityFor,
  }) =>
      (session, endExclusive, {required control}) => _openResidentReplay(
            session,
            0,
            endExclusive,
            priority: () => priorityFor(session.id),
            control: control,
          );

  DownloadResidentReplayRangeSource residentReplayRangeSource({
    required int Function(DownloadId id) priorityFor,
  }) =>
      (session, start, endExclusive) => _openResidentReplay(
            session,
            start,
            endExclusive,
            priority: () => priorityFor(session.id),
          );

  DownloadResidentReplayRangeSourceWithControl
      residentReplayRangeSourceWithControl({
    required int Function(DownloadId id) priorityFor,
  }) =>
          (session, start, endExclusive, {required control}) =>
              _openResidentReplay(
                session,
                start,
                endExclusive,
                priority: () => priorityFor(session.id),
                control: control,
              );

  Future<Stream<List<int>>> _openResidentReplay(
    DownloadSession session,
    int start,
    int endExclusive, {
    required int Function() priority,
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    int replayPriority() {
      final controlled = control?.priority;
      if (controlled != null) return controlled;
      final physical = session.effectivePriority;
      return physical > 0 ? physical : priority();
    }
    if (_disposed) {
      throw StateError('composition transfer runtime is disposed');
    }
    if (!identical(registry.find(session.id), session)) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'resident replay requires the current physical session',
      );
    }
    if (start < 0 ||
        endExclusive <= start ||
        endExclusive > session.committedLength) {
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message: 'invalid resident replay range $start..$endExclusive/'
            '${session.committedLength}',
      );
    }
    final initialReplayCreditBytes =
        session.contentKind == ContentKind.webp &&
                start == 0 &&
                endExclusive <= remoteWebpDecodePrefixQuantumBytes
            ? endExclusive
            : 0;
    final cache = artifactCacheManager;
    final residentReplayGenerationToken = session.residentReplayGenerationToken;
    if (initialReplayCreditBytes > 0 &&
        residentReplayGenerationToken != null &&
        cache != null) {
      final prefix = cache.lookupResidentReplayPrefix(
        residentReplayGenerationToken,
        endExclusive: endExclusive,
      );
      if (prefix != null) {
        return _scheduledResidentReplay(
          Stream<List<int>>.value(prefix),
          priority: replayPriority,
          control: control,
          initialReplayCreditBytes: initialReplayCreditBytes,
          traceId: session.id,
          replaySource: 'resident-bootstrap-memory',
        );
      }
    }

    final boundReplay = session.residentReplayRangeChunks;
    if (boundReplay != null) {
      return _scheduledResidentReplay(
        _boundedResidentReplay(
          boundReplay,
          start,
          endExclusive,
          control: control,
        ),
        priority: replayPriority,
        control: control,
        allowBackgroundDuringForegroundPressure:
            session.residentReplayAccessMode != 'saf',
        initialReplayCreditBytes: initialReplayCreditBytes,
        traceId: session.id,
        replaySource: 'resident-bound',
        rememberResidentReplayPrefixToken: residentReplayGenerationToken,
      );
    }

    if (cache != null) {
      final lookup = await cache.lookup(session.id, control: control);
      control?.throwIfCancelled();
      if (lookup != null) {
        final expectedTotal = session.totalLength;
        if ((expectedTotal == null || lookup.entry.length == expectedTotal) &&
            lookup.entry.length >= endExclusive) {
          return _scheduledResidentReplay(
            lookup.entry.open(
              start: start,
              endExclusive: endExclusive,
            ),
            priority: replayPriority,
            control: control,
            allowBackgroundDuringForegroundPressure:
                lookup.entry.accessMode != 'saf',
            initialReplayCreditBytes: initialReplayCreditBytes,
            traceId: session.id,
            replaySource: 'artifact-cache',
          );
        }
      }
    }

    final scheme = session.id.canonicalUri.scheme.toLowerCase();
    if (scheme != 'file' && scheme != 'content' && scheme != 'asset') {
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message: 'resident encoded-byte replay authority is unavailable for '
            '${session.id.key}',
      );
    }
    final chunks = await owner.openResidentReplay(
      session.id,
      start: start,
      endExclusive: endExclusive,
      control: control,
    );
    return _scheduledResidentReplay(
      chunks,
      priority: replayPriority,
      control: control,
      initialReplayCreditBytes: initialReplayCreditBytes,
      traceId: session.id,
      replaySource: 'local-source',
    );
  }

  Stream<List<int>> _boundedResidentReplay(
    DownloadResidentReplayRangeChunks openRange,
    int start,
    int endExclusive, {
    TaskControl? control,
  }) async* {
    const quantumBytes = 256 * 1024;
    var offset = start;
    while (offset < endExclusive) {
      control?.throwIfCancelled();
      final remaining = endExclusive - offset;
      final end = offset +
          (remaining < quantumBytes ? remaining : quantumBytes);
      final chunks = await openRange(offset, end);
      control?.throwIfCancelled();
      var emitted = 0;
      await for (final chunk in chunks) {
        control?.throwIfCancelled();
        if (chunk.isEmpty) continue;
        emitted += chunk.length;
        yield chunk;
      }
      if (emitted != end - offset) {
        throw Failure(
          code: ErrorCode.artifactCorruption,
          message: 'resident replay quantum was short: $emitted/${end - offset}',
        );
      }
      offset = end;
    }
  }

  Stream<List<int>> _scheduledResidentReplay(
    Stream<List<int>> chunks, {
    required int Function() priority,
    TaskControl? control,
    bool allowBackgroundDuringForegroundPressure = true,
    int initialReplayCreditBytes = 0,
    DownloadId? traceId,
    String? replaySource,
    Object? rememberResidentReplayPrefixToken,
  }) async* {
    final iterator = StreamIterator<List<int>>(chunks);
    var replayCreditRemaining = initialReplayCreditBytes;
    var bootstrapTracePending = initialReplayCreditBytes > 0 && traceId != null;
    BytesBuilder? residentReplayPrefix =
        initialReplayCreditBytes > 0 &&
                rememberResidentReplayPrefixToken != null &&
                artifactCacheManager != null
            ? BytesBuilder(copy: false)
            : null;
    try {
      final budgetAccount = control == null
          ? null
          : speculativeEncodedReadBudget.accountFor(control, control: control);
      while (true) {
        final usesReplayCredit = replayCreditRemaining > 0;
        final budgetWaitStartedAt = clock.nowMicros();
        if (!usesReplayCredit) {
          await budgetAccount?.waitForRead(control: control);
        }
        final budgetWaitMicros = clock.nowMicros() - budgetWaitStartedAt;
        final schedulerActiveAtRequest = localReadScheduler.activeCount;
        final schedulerForegroundAtRequest =
            localReadScheduler.activeForegroundCount;
        final schedulerBackgroundAtRequest =
            localReadScheduler.activeBackgroundCount;
        final schedulerPendingAtRequest = localReadScheduler.pendingCount;
        final schedulerWaitStartedAt = clock.nowMicros();
        final lease = await localReadScheduler.acquire(
          priority: priority,
          control: control,
          allowBackgroundDuringForegroundPressure:
              allowBackgroundDuringForegroundPressure,
        );
        final schedulerWaitMicros = clock.nowMicros() - schedulerWaitStartedAt;
        final bool hasChunk;
        final readStartedAt = clock.nowMicros();
        try {
          hasChunk = await _moveNextResidentReplayChunk(iterator, control);
        } finally {
          lease.release();
        }
        final readMicros = clock.nowMicros() - readStartedAt;
        if (!hasChunk) break;
        control?.throwIfCancelled();
        final chunk = iterator.current;
        if (chunk.isNotEmpty) {
          final prefixBuilder = residentReplayPrefix;
          if (prefixBuilder != null) {
            final remaining = initialReplayCreditBytes - prefixBuilder.length;
            if (remaining > 0) {
              if (chunk.length <= remaining) {
                prefixBuilder.add(chunk);
              } else {
                prefixBuilder.add(Uint8List.sublistView(
                  chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
                  0,
                  remaining,
                ));
              }
            }
            if (prefixBuilder.length >= initialReplayCreditBytes) {
              artifactCacheManager!.rememberResidentReplayPrefix(
                generationToken: rememberResidentReplayPrefixToken!,
                bytes: prefixBuilder.takeBytes(),
              );
              residentReplayPrefix = null;
            }
          }
          if (bootstrapTracePending && usesReplayCredit) {
            bootstrapTracePending = false;
            traceHub.record(
              traceEvent(
                clock: clock,
                sessionId: 'composition-transfer-owner',
                kind: TraceEventKind.artifactSource,
                identityHash: traceId!.key,
                payload: <String, Object?>{
                  'stage': 'reader-local-replay-bootstrap',
                  'action': 'first-quantum',
                  if (replaySource != null) 'source': replaySource,
                  'priority': priority(),
                  'bytes': chunk.length,
                  'budgetWaitMicros': budgetWaitMicros,
                  'schedulerWaitMicros': schedulerWaitMicros,
                  'readMicros': readMicros,
                  'schedulerActiveAtRequest': schedulerActiveAtRequest,
                  'schedulerForegroundAtRequest':
                      schedulerForegroundAtRequest,
                  'schedulerBackgroundAtRequest':
                      schedulerBackgroundAtRequest,
                  'schedulerPendingAtRequest': schedulerPendingAtRequest,
                },
              ),
            );
          }
          if (usesReplayCredit) {
            // A Reader joining an already-owned hot partial needs one bounded
            // local decoder bootstrap quantum even when older speculative
            // physical tasks have saturated the shared read-ahead budget. The
            // bytes already exist in the physical artifact, so this does not
            // admit more network growth; all later local replay returns to the
            // normal speculative budget. The granted quantum is still charged
            // after the read so the cap remains an accounting threshold rather
            // than a hidden unmetered path.
            replayCreditRemaining -= chunk.length;
            if (replayCreditRemaining < 0) {
              replayCreditRemaining = 0;
            }
          }
          budgetAccount?.recordRead(chunk.length);
          yield chunk;
        }
      }
    } finally {
      await iterator.cancel();
    }
  }

  Future<bool> _moveNextResidentReplayChunk(
    StreamIterator<List<int>> iterator,
    TaskControl? control,
  ) async {
    if (control == null) return iterator.moveNext();
    control.throwIfCancelled();
    try {
      return await Future.any<bool>(<Future<bool>>[
        iterator.moveNext(),
        control.whenCancelled.then<bool>((_) {
          throw const Failure(
            code: ErrorCode.cancelled,
            message: 'resident replay was cancelled',
          );
        }),
      ]);
    } catch (error, stackTrace) {
      if (control.cancelled) control.throwIfCancelled();
      throw Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> settlePhysicalRetention() async {
    await _physicalTransferRetention?.settle();
  }

  /// Retires an idle transfer session after a durable owner has applied its
  /// logical delete. This deliberately disposes only the in-memory physical
  /// owner; persistent bytes are deleted (or retained for another binding) by
  /// [ArtifactCacheBackend]. Calling the registry's evict primitive here would
  /// blindly delete a shared staging final after the durable owner had kept it.
  Future<void> retirePhysicalAfterDelete(DownloadId id) async {
    final session = registry.find(id);
    if (session == null || session.demanded || !session.canEvict) return;
    final retired = registry.takeIdlePhysical(id);
    if (retired != null) {
      _physicalTransferRetention?.forget(retired);
      await retired.dispose();
    }
  }

  Future<void> persistPromoted(DownloadId id) async {
    final session = registry.find(id);
    if (session == null || session.state != DownloadState.promoted) return;
    final handoff = artifactCacheHandoff;
    final cache = artifactCacheManager;
    if (handoff == null || cache == null) return;
    if (id != session.id && !registry.sharesPhysicalMedia(id, session.id)) {
      throw StateError(
        'exact durable materialization requires shared physical media authority',
      );
    }
    await handoff.persist(session, exactId: id);
    final expectedLength = session.committedLength;
    if (expectedLength > 0 &&
        !await cache.containsBackendExact(
          id: id,
          expectedLength: expectedLength,
        )) {
      throw StateError(
        'required exact durable artifact was not materialized for ${id.key}',
      );
    }
  }

  Future<void> checkpointPartials({
    String reason = 'runtime-safety-checkpoint',
  }) async {
    final handoff = partialDownloadHandoff;
    if (handoff == null || _disposed) return;
    final candidates = registry.sessions
        .where((session) =>
            session.state != DownloadState.promoted &&
            session.state != DownloadState.disposed &&
            !session.residentBodyBacked &&
            session.artifact.committedLength > 0)
        .toList(growable: false)
      ..sort((left, right) {
        final priority =
            right.effectivePriority.compareTo(left.effectivePriority);
        if (priority != 0) return priority;
        return right.artifact.committedLength
            .compareTo(left.artifact.committedLength);
      });
    for (final session in candidates) {
      await handoff.persist(session, reason: reason);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    if (hasConsumers) {
      throw StateError('cannot dispose composition transfer with active consumers');
    }
    _disposed = true;
    _canonicalMediaAuthorityScopes.clear();
    _lastTracedPhysicalMediaOwner.clear();
    _lastTracedCanonicalMediaConflict.clear();
    _preservedPinnedReloadEpochs.clear();
    for (final waiter in _historicalCarrierRevalidationWaiters.values) {
      waiter.session.removeSnapshotListener(waiter.listener);
    }
    _historicalCarrierRevalidationWaiters.clear();
    final historicalRevalidations =
        _historicalCarrierRevalidations.values.toList(growable: false);
    if (historicalRevalidations.isNotEmpty) {
      await Future.wait<void>(historicalRevalidations);
    }
    _historicalCarrierRevalidations.clear();
    artifactCacheManager?.removeEquivalentResolver(
      _versionPageAuthorityResolverKey,
    );
    await _physicalTransferRetention?.dispose();
    await owner.dispose();
    final standaloneRestores = _localRestoreFlights.values
        .map((entry) => entry.future)
        .toList(growable: false);
    if (standaloneRestores.isNotEmpty) {
      await Future.wait<void>(standaloneRestores);
    }
    _localRestoreFlights.clear();
    await artifactCacheHandoff?.drain(registry.sessions);
    artifactCacheHandoff?.detach();
    await partialDownloadHandoff?.drain(registry.sessions);
    await registry.dispose();
    await partialDownloadHandoff?.close();
    await workspace.dispose();
  }
}

final class CompositionDownloadTransferRuntimePool {
  final Map<_CompositionTransferRuntimeKey, CompositionDownloadTransferRuntime>
      _entries = <_CompositionTransferRuntimeKey, CompositionDownloadTransferRuntime>{};

  CompositionDownloadTransferRuntime get({
    required ArtifactCacheManager? artifactCacheManager,
    required PartialDownloadStore? partialDownloadStore,
    required NetLane net,
    ArtifactCacheReadScheduler? localReadScheduler,
    SpeculativeEncodedReadBudget? speculativeEncodedReadBudget,
  }) {
    final key = _CompositionTransferRuntimeKey(
      artifactCacheManager: artifactCacheManager,
      partialDownloadStore: partialDownloadStore,
      net: net,
      localReadScheduler: localReadScheduler,
      speculativeEncodedReadBudget: speculativeEncodedReadBudget,
    );
    return _entries.putIfAbsent(
      key,
      () => CompositionDownloadTransferRuntime(
        artifactCacheManager: artifactCacheManager,
        partialDownloadStore: partialDownloadStore,
        net: net,
        localReadScheduler: localReadScheduler,
        speculativeEncodedReadBudget: speculativeEncodedReadBudget,
      ),
    );
  }

  bool get hasConsumers => _entries.values.any((runtime) => runtime.hasConsumers);

  Future<void> disposeIdle() async {
    final idleKeys = <_CompositionTransferRuntimeKey>[
      for (final entry in _entries.entries)
        if (!entry.value.hasConsumers) entry.key,
    ];
    for (final key in idleKeys) {
      final runtime = _entries.remove(key);
      if (runtime != null) {
        await runtime.dispose();
      }
    }
  }

  Future<void> disposeAll() async {
    if (hasConsumers) {
      throw StateError('cannot dispose physical transfers with active consumers');
    }
    final runtimes = _entries.values.toList(growable: false);
    _entries.clear();
    for (final runtime in runtimes) {
      await runtime.dispose();
    }
  }
}

final class _CompositionTransferRuntimeKey {
  const _CompositionTransferRuntimeKey({
    required this.artifactCacheManager,
    required this.partialDownloadStore,
    required this.net,
    required this.localReadScheduler,
    required this.speculativeEncodedReadBudget,
  });

  final ArtifactCacheManager? artifactCacheManager;
  final PartialDownloadStore? partialDownloadStore;
  final NetLane net;
  final ArtifactCacheReadScheduler? localReadScheduler;
  final SpeculativeEncodedReadBudget? speculativeEncodedReadBudget;

  @override
  bool operator ==(Object other) =>
      other is _CompositionTransferRuntimeKey &&
      identical(artifactCacheManager, other.artifactCacheManager) &&
      identical(partialDownloadStore, other.partialDownloadStore) &&
      identical(net, other.net) &&
      identical(localReadScheduler, other.localReadScheduler) &&
      identical(speculativeEncodedReadBudget, other.speculativeEncodedReadBudget);

  @override
  int get hashCode => Object.hash(
        identityHashCode(artifactCacheManager),
        identityHashCode(partialDownloadStore),
        identityHashCode(net),
        identityHashCode(localReadScheduler),
        identityHashCode(speculativeEncodedReadBudget),
      );
}

final class _CompositionTransferTraceHub implements TraceSink {
  final Map<TraceSink, int> _sinks = <TraceSink, int>{};

  void attach(TraceSink sink) {
    _sinks.update(sink, (count) => count + 1, ifAbsent: () => 1);
  }

  void detach(TraceSink sink) {
    final count = _sinks[sink];
    if (count == null) return;
    if (count <= 1) {
      _sinks.remove(sink);
      return;
    }
    _sinks[sink] = count - 1;
  }

  @override
  void record(TraceEvent event) {
    for (final sink in _sinks.keys.toList(growable: false)) {
      try {
        sink.record(event);
      } on Object {
        // A consumer diagnostics sink cannot break physical transfer ownership.
      }
    }
  }
}
