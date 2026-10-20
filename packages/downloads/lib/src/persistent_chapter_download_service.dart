part of 'chapter_downloads.dart';

String? _sourceCrc32Constraint(PageAsset page) {
  final checksum = page.sourceChecksumForAlgorithm('crc32');
  if (checksum == null) return null;
  try {
    Crc32.fromHex(checksum);
    return checksum;
  } on FormatException {
    return null;
  }
}

final class PersistentChapterDownloadService
    implements
        ManagedChapterDownloadService,
        ChapterDownloadExecutionSource,
        ChapterDownloadLocalImportSink,
        ChapterDownloadManagementProjectionReader,
        ChapterCacheManagementProjectionReader,
        ChapterDeleteImpactProjectionReader,
        ChapterDownloadManagementChangeSource,
        ArtifactCacheMaintenance,
        ArtifactCacheBackend,
        ArtifactCacheBindingBackend,
        PhysicalPartialDownloadStore,
        PartialDownloadStore,
        PartialDownloadMetadataStore,
        ConfigurableChapterResourceAccess,
        ChapterDownloadTransferRuntimeProvider {
  /// Stall window for one page's promotion. Re-armed by every non-terminal
  /// progress snapshot, so only a fully silent transfer trips it; total
  /// give-up budget = window × (1 + [_maxPromotionStallReclaims]).
  static const Duration defaultPageStallTimeout = Duration(seconds: 6);

  /// Bounded number of session resets used to reclaim a stalled physical run
  /// before the stall failure fails the chapter command.
  static const int _maxPromotionStallReclaims = 2;

  /// Number of page transfers a chapter command may have admitted at once.
  /// This is deliberately no larger than the per-bucket NetLane limit and
  /// keeps decoded/encoded ingress bounded while still avoiding page-wide
  /// serialization.
  static const int _chapterNetworkWindow = 2;

  static const String _promotionStallMessage =
      'physical transfer promotion stalled: no progress within the stall window';

  PersistentChapterDownloadService._({
    required this.artifactStore,
    required this.artifactCacheManager,
    required this.transferRuntime,
    required IoTransport transport,
    required bool ownsTransferComposition,
    Duration pageStallTimeout = defaultPageStallTimeout,
    TraceSink? traceSink,
  })  : _transport = transport,
        _ownsTransferComposition = ownsTransferComposition,
        _pageStallTimeout = pageStallTimeout,
        _traceSink = traceSink ?? const NoopTraceSink() {
    _artifactManagementProjectionSubscription =
        artifactStore.managementProjectionChanges.listen(
      (_) => _handleArtifactManagementProjectionChanged(),
    );
  }

  static Future<PersistentChapterDownloadService> open(
    String root, {
    String? directory,
    CacheLayout? Function(DownloadId id)? layoutResolver,
    String Function()? userAgentProvider,
    NetLane? transferNet,
    ArtifactCacheReadScheduler? localReadScheduler,
    StorageWriteScheduler? storageWriteScheduler,
    SpeculativeEncodedReadBudget? speculativeEncodedReadBudget,
    SafTreeIo? safTreeIo,
    String? safTreeUri,
    ArtifactPresentationFileLeaseFactory? presentationFileLeaseFactory,
    Duration pageStallTimeout = defaultPageStallTimeout,
    TraceSink? traceSink,
  }) async {
    final authorities = await _openPersistentDownloadAuthorities(
      root,
      directory: directory,
      layoutResolver: layoutResolver,
      transferNet: transferNet,
      localReadScheduler: localReadScheduler,
      storageWriteScheduler: storageWriteScheduler,
      safTreeIo: safTreeIo,
      safTreeUri: safTreeUri,
      presentationFileLeaseFactory: presentationFileLeaseFactory,
      stallTimeout: pageStallTimeout,
      traceSink: traceSink,
    );
    return PersistentChapterDownloadService._(
      artifactStore: authorities.artifactStore,
      artifactCacheManager: authorities.artifactCacheManager,
      transferRuntime: authorities.transferRuntime,
      transport: IoTransport(
        http: HttpTransport(userAgentProvider: userAgentProvider),
      ),
      ownsTransferComposition: true,
      pageStallTimeout: pageStallTimeout,
      traceSink: traceSink,
    );
  }

  @override
  final PersistentDownloadArtifactStore artifactStore;
  @override
  final ArtifactCacheManager artifactCacheManager;
  @override
  final CompositionDownloadTransferRuntime transferRuntime;

  @override
  Future<bool> prewarmLocalReadBackend() =>
      artifactStore.prewarmLocalReadBackend();

  final IoTransport _transport;
  final bool _ownsTransferComposition;
  final Duration _pageStallTimeout;
  final TraceSink _traceSink;
  final MonoClock _traceClock = const SystemClock();
  bool _ownedTransferCompositionDisposed = false;
  ChapterResourceAccess? _resourceAccess;
  List<ComicVersionRelation> _cacheVersionRelations =
      const <ComicVersionRelation>[];
  final StreamController<void> _managementProjectionChanges =
      StreamController<void>.broadcast(sync: true);
  StreamSubscription<void>? _artifactManagementProjectionSubscription;

  @override
  Stream<void> get managementProjectionChanges =>
      _managementProjectionChanges.stream;

  void _handleArtifactManagementProjectionChanged() {
    if (_closed) return;
    // Invalidation is cheap; projection consumers coalesce their reads. A
    // long-running manual task must not hide independent Reader/cache writes.
    if (!_managementProjectionChanges.isClosed) {
      _managementProjectionChanges.add(null);
    }
  }

  Future<_DownloadManagementPhysicalState> _loadManagementPhysicalState() async {
    final index = artifactStore.index;
    final artifacts =
        await (index as PhysicalMediaArtifactIndex).listPhysicalMediaArtifacts();
    final partials =
        await (index as PhysicalPartialIndex).listPhysicalPartials();
    final projections = await artifactStore.loadCanonicalMediaProjections();
    return _DownloadManagementPhysicalState(
      artifacts: artifacts,
      partials: partials,
      projections: projections,
      activeProjectionRanges:
          canonicalMediaActiveRangesFromRelations(_cacheVersionRelations),
    );
  }

  final StreamController<ChapterDownloadSnapshot> _changes =
      StreamController<ChapterDownloadSnapshot>.broadcast(sync: true);
  final Map<String, CancelToken> _tokens = <String, CancelToken>{};
  final Map<String, Future<void>> _runs = <String, Future<void>>{};
  final Map<String, ImportedLibraryEntry> _activeDownloadEntries = {};
  final StreamController<void> _downloadExecutionChanges =
      StreamController<void>.broadcast(sync: true);

  @override
  List<ImportedLibraryEntry> get activeDownloadEntries =>
      List.unmodifiable(_activeDownloadEntries.values);

  @override
  Stream<void> get downloadExecutionChanges => _downloadExecutionChanges.stream;
  final Map<String, CancelToken> _auditTokens = <String, CancelToken>{};
  final Map<String, Future<ChapterFileAuditReport>> _auditRuns =
      <String, Future<ChapterFileAuditReport>>{};
  final Map<String, DownloadTransferConsumer> _commandConsumers =
      <String, DownloadTransferConsumer>{};
  final Set<String> _cancelled = <String>{};
  final Set<String> _deletedIdentities = <String>{};
  final Map<String, ChapterDownloadPhase> _terminalPhases =
      <String, ChapterDownloadPhase>{};
  final Map<String, Set<Uri>> _failedSourceResourceLocators =
      <String, Set<Uri>>{};

  /// Identities whose run has admitted at least one page task to the
  /// transfer layer — the snapshot `started` flag the UI's starting/started
  /// control split is built on.
  final Set<String> _startedRuns = <String>{};

  bool _closed = false;

  /// Sessions are materialized only for exact pages touched after startup.
  /// This metric is intentionally read-only so diagnostics can verify that
  /// opening a large offline library does not eagerly restore every artifact.
  int get materializedSessionCount => artifactStore.materializedSessionCount;

  @override
  Stream<ChapterDownloadSnapshot> get changes => _changes.stream;

  @override
  void setChapterResourceAccess(ChapterResourceAccess? access) {
    _requireOpen();
    _resourceAccess = access;
  }

  @override
  void updateVersionBaselines(List<ComicVersionRelation> relations) {
    artifactStore.updateVersionBaselines(relations);
  }

  @override
  void updateCacheVersionRelations(List<ComicVersionRelation> relations) {
    _cacheVersionRelations = List<ComicVersionRelation>.unmodifiable(relations);
    artifactStore.updateCacheVersionRelations(relations);
  }

  @override
  Future<void> claimComicDirectory({
    required String sourceId,
    required String comicId,
    required String directoryName,
    String? comicTitle,
    DownloadPlacementMode mode = DownloadPlacementMode.createNew,
    String? observedOwnerKey,
    ComicPageOrder pageOrder = ComicPageOrder.auto,
  }) async {
    _requireOpen();
    final owner = '$sourceId\u0000$comicId';
    _recordCommandTrace(owner, 'claim-comic-directory', <String, Object?>{
        'sourceId': sourceId,
        'comicId': comicId,
        'comicTitle': comicTitle,
        'directoryName': directoryName,
        'mode': mode.name,
        'observedOwnerKey': observedOwnerKey,
    });
    if (mode == DownloadPlacementMode.overwrite &&
        observedOwnerKey != null &&
        observedOwnerKey.contains('\u0000')) {
      final parts = observedOwnerKey.split('\u0000');
      if (parts.length == 2) {
        final displacedComicPrefix = '${parts[0]}\u0000${parts[1]}\u0000';
        for (final identity in List.of(_tokens.keys)) {
          if (identity.startsWith(displacedComicPrefix)) {
            _cancelled.add(identity);
            _tokens[identity]?.cancel();
          }
        }
      }
    }
    return artifactStore.claimStructuredComicDirectory(
      sourceId: sourceId,
      comicId: comicId,
      comicTitle: comicTitle,
      directoryName: directoryName,
      mode: mode,
      observedOwnerKey: observedOwnerKey,
      pageOrder: pageOrder,
    );
  }

  @override
  Future<DownloadPlacement?> getDownloadPlacement({
    required String sourceId,
    required String comicId,
  }) async {
    _requireOpen();
    final placement = await artifactStore.getDownloadPlacement(
      sourceId: sourceId,
      comicId: comicId,
    );
    final owner = '$sourceId\u0000$comicId';
    _recordCommandTrace(owner, 'get-download-placement', <String, Object?>{
        'sourceId': sourceId,
        'comicId': comicId,
        'directoryName': placement?.relativeDirectory,
        'mode': placement?.mode.name,
    });
    return placement;
  }

  @override
  Future<void> retry(ImportedLibraryEntry entry) async {
    _requireOpen();
    await cancel(entry);
    final identity = _identity(entry);
    final refresh = _resourceAccess?.refreshResourceGeneration;
    final refreshedThisRetry = <Uri>{};

    Future<void> refreshFailedLocators(String reason) async {
      if (refresh == null) return;
      final failedLocators = _failedSourceResourceLocators[identity];
      if (failedLocators == null || failedLocators.isEmpty) return;
      final pending = failedLocators
          .where((locator) => !refreshedThisRetry.contains(locator))
          .toList(growable: false);
      if (pending.isEmpty) return;
      _recordCommandTrace(identity, 'chapter-retry-source-refresh', <String, Object?>{
        'reason': reason,
        'locators': pending.length,
      });
      for (final locator in pending) {
        await refresh(entry.chapter.sourceId, locator);
        refreshedThisRetry.add(locator);
        failedLocators.remove(locator);
      }
      if (failedLocators.isEmpty) {
        _failedSourceResourceLocators.remove(identity);
      }
    }

    await refreshFailedLocators('known-terminal-source');
    try {
      await download(entry);
    } on Failure catch (error, stackTrace) {
      // Pre-v327 / previous-process failed chapter state can survive after the
      // in-memory locator set that identified its source-terminal page has
      // disappeared. The explicit user Retry still authorizes one fresh
      // download generation. If that first retry run rediscovers an exact
      // source-terminal locator, refresh only that locator and continue the
      // same user command once. Never refresh unreached pages, and never
      // freshen the same locator twice for one Retry press.
      if (error.code != ErrorCode.source || refresh == null) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      final discovered = _failedSourceResourceLocators[identity];
      final hasNewLocator = discovered != null &&
          discovered.any((locator) => !refreshedThisRetry.contains(locator));
      if (!hasNewLocator) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      await refreshFailedLocators('rediscovered-historical-terminal-source');
      await download(entry);
    }
  }

  @override
  Future<void> download(ImportedLibraryEntry entry) => _startDownload(entry);

  @override
  Future<void> importLocalChapter(
    ImportedLibraryEntry entry,
    Map<Uri, File> preparedFiles,
  ) {
    _requireOpen();
    if (entry.chapter.sourceId != externalDownloadsSourceId ||
        preparedFiles.length != entry.chapter.pages.length ||
        entry.chapter.pages.any((page) =>
            page.uri.scheme != 'zic-import' || !preparedFiles.containsKey(page.uri))) {
      throw ArgumentError('local import requires an exact prepared page mapping');
    }
    if (_runs.containsKey(_identity(entry))) {
      throw StateError('this chapter already has an active download command');
    }
    final transport = LoaderTransport({
      for (final page in entry.chapter.pages)
        page.uri: LoaderTransportSource(
          revision: entry.chapter.sourceRevision,
          openControlledResponse: ({range, validators, control}) async {
            final response = await const FileTransport().openControlled(
              preparedFiles[page.uri]!.uri,
              range: range, validators: validators, control: control,
            );
            // Import staging is temporary. It must enter the ordinary staged
            // artifact writer, not become source-resident replay authority.
            return ByteResponse(
              bytes: response.bytes, statusCode: response.statusCode,
              rangeStart: response.rangeStart, totalLength: response.totalLength,
              validators: response.validators, rangeSupported: response.rangeSupported,
              flowControl: response.flowControl,
              onDiscard: () => response.discard(control: control),
            );
          },
        ),
    });
    return _startDownload(entry, importTransport: transport);
  }

  Future<void> _startDownload(ImportedLibraryEntry entry, {
    Transport? importTransport,
  }) {
    _requireOpen();
    final identity = _identity(entry);
    final active = _runs[identity];
    if (active != null) {
      return active;
    }
    _activeDownloadEntries[identity] = entry;
    final run = _runDownload(entry, importTransport: importTransport).whenComplete(() {
      _runs.remove(identity);
      _activeDownloadEntries.remove(identity);
      _tokens.remove(identity);
      _startedRuns.remove(identity);
      _deletedIdentities.remove(identity);
      _downloadExecutionChanges.add(null);
    });
    _runs[identity] = run;
    _downloadExecutionChanges.add(null);
    return run;
  }

  Future<Map<int, String>> _predecessorPageIdsByIndex({
    required String sourceId,
    required String comicId,
    required String chapterId,
    required Map<String, Future<Map<int, String>>> cache,
  }) {
    final key = '$sourceId\u0000$comicId\u0000$chapterId';
    return cache.putIfAbsent(key, () async {
        final bindings = await artifactStore._index.listExportPageBindings(
          sourceId: sourceId,
          comicId: comicId,
          chapterId: chapterId,
        );
        final resolved = <int, String>{};
        final ambiguous = <int>{};
        for (final binding in bindings) {
          final previous = resolved[binding.logicalIndex];
          if (previous != null && previous != binding.pageId) {
            ambiguous.add(binding.logicalIndex);
            continue;
          }
          resolved[binding.logicalIndex] = binding.pageId;
        }
        for (final index in ambiguous) {
          resolved.remove(index);
        }
        return Map<int, String>.unmodifiable(resolved);
    });
  }

  Future<({CacheRec record, String proof})?> _resolveReusablePageRecord({
    required ImportedLibraryEntry entry,
    required PageAsset page,
    required int pageIndex,
    required DownloadId targetId,
    required _DurableReadyRecordIndex readyIndex,
    required Map<String, Future<Map<int, String>>> predecessorBindingLookups,
  }) async {
    for (final identity in verifiedPageIdentities(page)) {
      final strong = readyIndex.byVerifiedIdentity(
        sourceId: entry.chapter.sourceId,
        identity: identity,
        excludingKey: targetId.key,
      );
      if (strong != null) {
        return (record: strong, proof: 'strong-media-identity');
      }
    }

    for (final baseline in artifactStore._downloadBaselinePredecessorMappings(
      entry,
    )) {
      final mapping = baseline.mapping;
      if (mapping.successorSourceRevision != entry.chapter.sourceRevision ||
          mapping.predecessorSourceRevision == null) {
        continue;
      }
      final predecessorIndex = mapping
          .uniqueVerifiedPredecessorIndexForSuccessor(pageIndex);
      if (predecessorIndex == null) continue;
      final pageIds = await _predecessorPageIdsByIndex(
        sourceId: entry.chapter.sourceId,
        comicId: baseline.relation.predecessorComicId,
        chapterId: mapping.predecessorChapterId,
        cache: predecessorBindingLookups,
      );
      final predecessorPageId = pageIds[predecessorIndex];
      if (predecessorPageId == null) continue;
      final candidate = readyIndex.byLogicalPage(
        sourceId: entry.chapter.sourceId,
        comicId: baseline.relation.predecessorComicId,
        chapterId: mapping.predecessorChapterId,
        sourceRevision: mapping.predecessorSourceRevision!,
        pageId: predecessorPageId,
      );
      if (candidate != null) {
        return (record: candidate, proof: 'version-page-proof');
      }
    }
    return null;
  }

  /// Lifecycle-edge diagnostic trail only — never progress ticks.
  void _recordCommandTrace(
    String identityHash,
    String stage,
    Map<String, Object?> payload,
  ) {
    try {
      _traceSink.record(
        traceEvent(
          clock: _traceClock,
          sessionId: 'chapter-command',
          kind: TraceEventKind.downloadState,
          identityHash: identityHash,
          payload: <String, Object?>{'stage': stage, ...payload},
        ),
      );
    } on Object {
      // Tracing must never fail the download.
    }
  }

  Future<void> _runDownload(ImportedLibraryEntry entry, {
    Transport? importTransport,
  }) async {
    final identity = _identity(entry);
    _deletedIdentities.remove(identity);
    final token = CancelToken();
    _tokens[identity] = token;
    _cancelled.remove(identity);
    _terminalPhases.remove(identity);
    _startedRuns.remove(identity);
    _recordCommandTrace(identity, 'chapter-run-start', <String, Object?>{
      'pages': entry.chapter.pages.length,
      'comicId': entry.chapter.comicId,
      'chapterId': entry.chapter.chapterId,
    });
    final indexedRecords = await artifactStore.indexedRecordsForEntries(
      [entry], includeComicRecords: true,
    );
    await _emitInspection(
      entry,
      phase: ChapterDownloadPhase.downloading,
      indexedRecords: indexedRecords,
    );
    final progress = _ChapterProgressPublisher(
      () => _emitInspection(
        entry,
        phase: ChapterDownloadPhase.downloading,
        indexedRecords: indexedRecords,
      ),
    );
    final manifest = entry.chapter.toManifest();
    token.throwIfCancelled();
    final structuredComicDirectory = await artifactStore
        .resolveStructuredComicDirectory(
      entry,
      knownRecords: indexedRecords.values,
    );
    _recordCommandTrace(
      identity,
      'structured-directory-resolved',
      <String, Object?>{
      'comicTitle': entry.chapter.comicTitle,
      'structuredComicDirectory': structuredComicDirectory,
      },
    );
    await artifactStore.verifyStructuredDestinationOwner(
      entry,
      comicDirectoryName: structuredComicDirectory,
    );
    token.throwIfCancelled();
    final transports = <Uri, Transport>{
      for (final page in manifest.pages)
        page.uri: importTransport ?? _transportForPage(manifest, page),
    };
    final consumer = transferRuntime.attachConsumer(
      scopeId: 'chapter-command:$identity',
      transportFor: (uri) => transports[uri] ?? _transport,
      consumerTraceSink: _traceSink,
      retry: const RetryPolicy(),
      downloadBucketFor: (_) => 'chapter:${manifest.sourceId}',
      downloadBucketLimitFor: (_) => 2,
    );
    _commandConsumers[identity] = consumer;
    var revision = 0;
    try {
      final existingChapters = artifactStore.downloadedChapterIdsFromRecords(
        indexedRecords.values,
        sourceId: manifest.sourceId,
        comicId: entry.chapter.comicId,
      );
      final hasOtherDownloadedChapters =
          existingChapters.isNotEmpty &&
          !existingChapters.contains(entry.chapter.chapterId);
      final isHighConfidenceMultiChapter =
          entry.chapter.sequence > 1 ||
          hasOtherDownloadedChapters ||
          existingChapters.length > 1;
      final isSingleChapter = !isHighConfidenceMultiChapter;

      if (hasOtherDownloadedChapters) {
        final migrationPlan = await artifactStore.flatChapterMigrationPlan(
          entry: entry,
          comicDirectoryName: structuredComicDirectory,
          existingChapterIds: existingChapters,
        );
        for (final previous in migrationPlan) {
          await artifactStore.migrateSingleChapterToSubdirectory(
            sourceId: manifest.sourceId,
            comicId: entry.chapter.comicId,
            comicTitle: entry.chapter.comicTitle,
            previousChapterId: previous.chapterId,
            previousChapterTitle: previous.title,
            previousSequence: previous.sequence,
            comicDirectoryName: structuredComicDirectory,
            rootLayout: manifest.pages.isEmpty
                ? null
                : artifactStore.layoutFor(
                    _downloadId(manifest, manifest.pages.first),
                  ),
          );
          // Migration rewrites the exact locators and may remove the flat
          // files. Refresh affected snapshot entries before building the reuse
          // index; its strong identity must resolve the current physical file.
          final migratedKeys = indexedRecords.values.where((record) =>
              record.id.content.sourceId == manifest.sourceId &&
              record.id.content.comicId == entry.chapter.comicId &&
              record.id.content.chapterId == previous.chapterId)
            .map((record) => record.key).toList();
          for (final key in migratedKeys) {
            final current = await artifactStore._index.get(key);
            if (current == null) {
              indexedRecords.remove(key);
            } else {
              indexedRecords[key] = current;
            }
          }
        }
      }

      token.throwIfCancelled();
      final chapterDirectoryName = isSingleChapter
          ? null
          : await artifactStore.resolveStructuredChapterDirectory(
              entry,
              comicDirectoryName: structuredComicDirectory,
            );

      final readyIndex = await _DurableReadyRecordIndex.build(
        indexedRecords.values,
        isReady: artifactStore._isVerifiedReadyRecord,
      );
      token.throwIfCancelled();
      final predecessorBindingLookups = <String, Future<Map<int, String>>>{};

      var placement = await artifactStore.resolveDownloadPlacement(
        entry,
        knownRecords: indexedRecords.values,
      );
      placement = await artifactStore.freezeExportPageOrder(
        entry,
        placement,
        isSingleChapter: isSingleChapter,
      );
      final exportOrdinals = await artifactStore.ensureExportPageOrdinals(
        entry,
        placement,
        knownRecords: indexedRecords.values,
      );
      await artifactStore.writeComicFolderManifest(
        entry,
        comicDirectoryName: structuredComicDirectory,
        chapterDirectoryName: chapterDirectoryName,
        knownChapterIds: existingChapters,
      );

      final pendingPages = <
          DownloadId,
          Future<({DownloadId id, Object? failure, StackTrace? failureStack})>
        >{};
      final pendingDemands = <DownloadId, TransferDemand>{};

      Future<({DownloadId id, Object? failure, StackTrace? failureStack})>
          observePendingPage(DownloadId id, Future<void> run) async {
        try {
          await run;
          return (id: id, failure: null, failureStack: null);
        } on Object catch (error, stackTrace) {
          return (id: id, failure: error, failureStack: stackTrace);
        }
      }

      Future<({DownloadId id, Object? failure, StackTrace? failureStack})>
          settleNextPendingPage() async {
        final settled = await Future.any(pendingPages.values);
        pendingPages.remove(settled.id);
        pendingDemands.remove(settled.id);
        consumer.replaceDemands(
          identity,
          ++revision,
          Map<DownloadId, TransferDemand>.of(pendingDemands),
        );
        return settled;
      }

      Future<void> drainPendingPages({
        ({DownloadId id, Object? failure, StackTrace? failureStack})?
            initialFailure,
      }) async {
        Object? failure = initialFailure?.failure;
        StackTrace? failureStack = initialFailure?.failureStack;
        while (pendingPages.isNotEmpty) {
          final settled = await settleNextPendingPage();
          if (failure == null && settled.failure != null) {
            failure = settled.failure;
            failureStack = settled.failureStack;
          }
        }
        if (failure != null) {
          Error.throwWithStackTrace(failure, failureStack!);
        }
      }

      for (var pageIndex = 0; pageIndex < manifest.pages.length; pageIndex++) {
        final page = manifest.pages[pageIndex];
        final logicalPageId = entry.chapter.pages[pageIndex].stablePageId;
        final targetPageNumber = exportOrdinals[logicalPageId];
        if (targetPageNumber == null) {
          throw Failure(
            code: ErrorCode.invalidState,
            message: 'missing frozen export ordinal for $logicalPageId',
          );
        }
        token.throwIfCancelled();
        final id = _downloadId(manifest, page);
        var record = indexedRecords[id.key];
        if (record != null &&
            record.state == CacheState.ready &&
            (record.bytes <= 0 ||
                record.checksum.trim().isEmpty ||
                record.checksumAlgorithm.trim().toLowerCase() != 'crc32')) {
          await artifactStore.forgetUnverifiedReadyRecord(record);
          indexedRecords.remove(id.key);
          record = null;
        }
        var recordReady =
            record != null && artifactStore._isVerifiedReadyRecord(record);

        if (recordReady) {
          final active = transferRuntime.findSession(id);
          final isBusy =
              active != null && (active.activeRun || active.hasWriter);
          final isAlreadyStructured =
              record.pinned && !artifactStore._isAutomaticCacheFinalRecord(record);
          if (!isBusy) {
            // Explicit retry revalidates the exact physical locator even for
            // an already-structured page. openArtifactStream performs the
            // cheap accessibility + exact-length preflight against the sealed
            // record; it does not recompute the whole-file CRC. An externally
            // deleted/truncated file therefore cannot survive retry as exact.
            ArtifactCacheStreamEntry? durable;
            try {
              durable = await artifactStore.openArtifactStream(id);
            } on ArtifactReadFailure catch (error) {
              if (!artifactStore._isStructuralReplicaFailure(error.kind)) {
                rethrow;
              }
              durable = null;
            }
            if (durable == null) {
              indexedRecords.remove(id.key);
              record = null;
              recordReady = false;
            } else if (isAlreadyStructured) {
              continue;
            } else {
              await artifactStore.mirrorPromotedToSafIfConfigured(
                id,
                entry: entry,
                pageIndex: targetPageNumber,
                isSingleChapter: isSingleChapter,
                comicDirectoryName: structuredComicDirectory,
                chapterDirectoryName: chapterDirectoryName,
              );
              final rec = await artifactStore._index.get(id.key);
              if (rec != null) {
                indexedRecords[id.key] = rec;
              }
              progress.schedule();
              continue;
            }
          }
        }

        // Classify from the one run-start index snapshot. The same resolver
        // is shared with management projection; pageId, file name, ordinal,
        // and revision proximity are locator hints only, never reuse proof.
        final reusable = await _resolveReusablePageRecord(
          entry: entry,
          page: page,
          pageIndex: pageIndex,
          targetId: id,
          readyIndex: readyIndex,
          predecessorBindingLookups: predecessorBindingLookups,
        );
        final siblingRecord = reusable?.record;
        final siblingProof = reusable?.proof;
        if (siblingRecord != null) {
          final destPath = await artifactStore
              .materializeSiblingToDestinationIfSeparate(
            siblingRecord: siblingRecord,
            entry: entry,
            pageNumber: targetPageNumber,
            isSingleChapter: isSingleChapter,
            comicDirectoryName: structuredComicDirectory,
            chapterDirectoryName: chapterDirectoryName,
          );
          final adopted = await artifactStore.adoptExistingPageRecord(
            id: id,
            path: destPath,
            bytes: siblingRecord.bytes,
            checksum: siblingRecord.checksum,
            artifactId: destPath == siblingRecord.path
                ? siblingRecord.artifactId
                : null,
            storageRootId: artifactStore.storageRootIdFor(entry),
          );
          indexedRecords[id.key] = adopted;
          _recordCommandTrace(identity, 'page-adopt-sibling', <String, Object?>{
            'page': pageIndex,
            'targetPageNumber': targetPageNumber,
            'bytes': siblingRecord.bytes,
            if (siblingProof != null) 'reuseProof': siblingProof,
            if (siblingRecord.id.content.comicId != entry.chapter.comicId)
              'baselineComicId': siblingRecord.id.content.comicId,
          });
          progress.schedule();
          continue;
        }
        _startedRuns.add(identity);
        _recordCommandTrace(identity, 'page-network', <String, Object?>{
          'page': pageIndex,
          'targetPageNumber': targetPageNumber,
        });
        final expectedChecksum = _sourceCrc32Constraint(page);
        pendingDemands[id] = TransferDemand(
          priority: 120,
          reason: 'chapter-download-command',
          expectedChecksum: expectedChecksum,
          completionIntent: TransferCompletionIntent.required,
        );
        consumer.replaceDemands(
          identity,
          ++revision,
          Map<DownloadId, TransferDemand>.of(pendingDemands),
        );
        // Acquire the physical session only after the claim has passed through
        // the composition resolver. Creating an exact session first would
        // permanently defeat verified transfer-key aliasing for this command.
        final session = transferRuntime.sessionFor(id);
        if (session.state == DownloadState.failed) {
          await session.reset();
        }
        consumer.refreshScheduling();
        final pageRun = _completeNetworkPage(
          entry: entry,
          id: id,
          pageIndex: targetPageNumber - 1,
          isSingleChapter: isSingleChapter,
          comicDirectoryName: structuredComicDirectory,
          chapterDirectoryName: chapterDirectoryName,
          session: session,
          token: token,
          progress: progress,
          consumer: consumer,
        ).then((rec) {
          if (rec != null) {
            indexedRecords[id.key] = rec;
          }
        });
        pendingPages[id] = observePendingPage(id, pageRun);
        if (pendingPages.length >= _chapterNetworkWindow) {
          final settled = await settleNextPendingPage();
          if (settled.failure != null) {
            await drainPendingPages(initialFailure: settled);
          }
        }
      }
      await drainPendingPages();
      await progress.flush();
      progress.close();
      token.throwIfCancelled();
      if (_deletedIdentities.contains(identity)) return;
      await artifactStore.pinExactRecords(
        manifest.pages.map((page) => _downloadId(manifest, page)),
      );
      token.throwIfCancelled();
      if (_deletedIdentities.contains(identity)) return;
      final finalIndexedRecords = await artifactStore.indexedRecordsForEntries(
        [entry], includeComicRecords: true,
      );
      final finalChapterIds = artifactStore.downloadedChapterIdsFromRecords(
        finalIndexedRecords.values,
        sourceId: manifest.sourceId,
        comicId: entry.chapter.comicId,
      );
      await artifactStore.writeComicFolderManifest(
        entry,
        comicDirectoryName: structuredComicDirectory,
        chapterDirectoryName: chapterDirectoryName,
        knownChapterIds: finalChapterIds,
      );
      if (_deletedIdentities.contains(identity)) return;
      _terminalPhases[identity] = ChapterDownloadPhase.complete;
      _startedRuns.add(identity);
      _recordCommandTrace(
        identity,
        'chapter-run-complete',
        const <String, Object?>{},
      );
      await _emitInspection(
        entry,
        phase: ChapterDownloadPhase.complete,
        indexedRecords: finalIndexedRecords,
      );
    } on Failure catch (error) {
      await progress.flush();
      progress.close();
      if (_deletedIdentities.contains(identity)) return;
      if (error.code == ErrorCode.cancelled || token.cancelled) {
        _cancelled.add(identity);
        _terminalPhases[identity] = ChapterDownloadPhase.cancelled;
        _recordCommandTrace(
          identity,
          'chapter-run-cancelled',
          const <String, Object?>{},
        );
        await _emitInspection(entry, phase: ChapterDownloadPhase.cancelled);
        return;
      }
      _terminalPhases[identity] = ChapterDownloadPhase.failed;
      _recordCommandTrace(identity, 'chapter-run-failed', <String, Object?>{
        'error': error.toString(),
        for (final key in const <String>[
          'sourceSemanticAcceptedPlans',
          'sourceSemanticSameUrlPlans',
          'sourceSemanticChangedUrlPlans',
          'sourceSemanticRuntimeTransformPlans',
          'sourceSemanticFreshResolvePlans',
          'sourceSemanticRecoveryUnavailable',
          'sourceResourcePlanReplayEligible',
          'sourceResourcePlanReplayAttempted',
          'sourceResourcePlanReplayUnavailable',
        ])
          if (error.details.containsKey(key)) key: error.details[key],
      });
      await _emitInspection(
        entry,
        phase: ChapterDownloadPhase.failed,
        failure: error.toString(),
      );
      rethrow;
    } on Object catch (error) {
      await progress.flush();
      progress.close();
      if (_deletedIdentities.contains(identity)) return;
      if (token.cancelled) {
        _cancelled.add(identity);
        _terminalPhases[identity] = ChapterDownloadPhase.cancelled;
        _recordCommandTrace(
          identity,
          'chapter-run-cancelled',
          const <String, Object?>{},
        );
        await _emitInspection(entry, phase: ChapterDownloadPhase.cancelled);
        return;
      }
      _terminalPhases[identity] = ChapterDownloadPhase.failed;
      _recordCommandTrace(identity, 'chapter-run-failed', <String, Object?>{
        'error': error.toString(),
      });
      await _emitInspection(
        entry,
        phase: ChapterDownloadPhase.failed,
        failure: error.toString(),
      );
      rethrow;
    } finally {
      progress.close();
      if (identical(_commandConsumers[identity], consumer)) {
        _commandConsumers.remove(identity);
      }
      await consumer.dispose();
    }
  }

  Future<CacheRec?> _completeNetworkPage({
    required ImportedLibraryEntry entry,
    required DownloadId id,
    required int pageIndex,
    required bool isSingleChapter,
    required String comicDirectoryName,
    required String? chapterDirectoryName,
    required DownloadSession session,
    required CancelToken token,
    required _ChapterProgressPublisher progress,
    required DownloadTransferConsumer consumer,
  }) async {
    final snapshot = await _waitForPagePromotion(
      session,
      token: token,
      progress: progress,
      consumer: consumer,
    );
    token.throwIfCancelled();
    if (snapshot.state != DownloadState.promoted) {
      final failure = snapshot.failure;
      if (failure is Failure) {
        if (failure.code == ErrorCode.source &&
            _isSourceOwnedResource(entry.chapter.sourceId, id.canonicalUri)) {
          _failedSourceResourceLocators
              .putIfAbsent(_identity(entry), () => <Uri>{})
              .add(id.canonicalUri);
        }
        throw failure;
      }
      throw Failure(
        code: ErrorCode.network,
        message: 'physical transfer did not promote ${id.key}',
      );
    }
    await transferRuntime.persistPromoted(id);
    await artifactStore.mirrorPromotedToSafIfConfigured(
      id,
      entry: entry,
      pageIndex: pageIndex + 1,
      isSingleChapter: isSingleChapter,
      comicDirectoryName: comicDirectoryName,
      chapterDirectoryName: chapterDirectoryName,
    );
    if (await artifactStore.openArtifactStream(id) == null) {
      throw StateError(
        'chapter command completed physical transfer without durable artifact: '
        '${id.key}',
      );
    }
    return artifactStore._index.get(id.key);
  }

  /// Waits for [session] to reach a terminal state. The stall timer is
  /// re-armed by every non-terminal snapshot; a fully silent window resets
  /// the session so a fresh task can be admitted, and after
  /// [_maxPromotionStallReclaims] reclaims the failure propagates.
  Future<DownloadSnapshot> _waitForPagePromotion(
    DownloadSession session, {
    required CancelToken token,
    required _ChapterProgressPublisher progress,
    required DownloadTransferConsumer consumer,
  }) async {
    void record(String stage, Map<String, Object?> payload) =>
        _recordCommandTrace(session.id.key, stage, payload);

    var round = Completer<DownloadSnapshot>();
    Timer? stallTimer;
    void armStall() {
      final completer = round;
      final baseline = session.snapshot;
      stallTimer?.cancel();
      stallTimer = Timer(_pageStallTimeout, () {
        if (completer.isCompleted) {
          return;
        }
        final current = session.snapshot;
        final transportProgressed =
            current.networkAttemptSequence == baseline.networkAttemptSequence &&
                current.networkCursorLength > baseline.networkCursorLength;
        final artifactProgressed =
            current.committedLength > baseline.committedLength;
        final lowerAttemptOwnsStall =
            current.activeRun &&
            transferRuntime.readStallTimeout > Duration.zero &&
            (current.state == DownloadState.queued ||
                current.networkAttemptActive);
        if (transportProgressed ||
            artifactProgressed ||
            lowerAttemptOwnsStall) {
          armStall();
          return;
        }
        completer.completeError(
          const Failure(
          code: ErrorCode.network,
          message: _promotionStallMessage,
          ),
        );
      });
    }

    void listener(DownloadSnapshot snapshot) {
      progress.schedule();
      final completer = round;
      if (completer.isCompleted) {
        return;
      }
      if (snapshot.state == DownloadState.promoted ||
          snapshot.state == DownloadState.failed ||
          snapshot.state == DownloadState.disposed) {
        completer.complete(snapshot);
        return;
      }
      armStall();
    }

    session.addSnapshotListener(listener);
    if (session.snapshot.state == DownloadState.promoted ||
        session.snapshot.state == DownloadState.failed ||
        session.snapshot.state == DownloadState.disposed) {
      if (!round.isCompleted) {
        round.complete(session.snapshot);
      }
    } else {
      armStall();
    }
    try {
      var stallReclaims = 0;
      while (true) {
        try {
          return await Future.any<DownloadSnapshot>(<Future<DownloadSnapshot>>[
            round.future,
            token.whenCancelled.then<DownloadSnapshot>(
              (_) => throw const Failure(
                  code: ErrorCode.cancelled,
                  message: 'download cancelled',
              ),
            ),
          ]);
        } on Failure catch (error) {
          if (error.code != ErrorCode.network ||
              error.message != _promotionStallMessage ||
              ++stallReclaims > _maxPromotionStallReclaims) {
            if (error.message == _promotionStallMessage) {
              record('page-promotion-stall-gave-up', <String, Object?>{
                'reclaims': stallReclaims - 1,
                'state': session.state.name,
                'committedLength': session.committedLength,
                'activeRun': session.activeRun,
                'hasWriter': session.hasWriter,
              });
            }
            rethrow;
          }
          // Reset drops the stale writer/epoch so a fresh task can be
          // admitted after the stall.
          record('page-promotion-stall-reclaim', <String, Object?>{
            'attempt': stallReclaims,
            'state': session.state.name,
            'committedLength': session.committedLength,
            'activeRun': session.activeRun,
            'hasWriter': session.hasWriter,
          });
          await session.reset();
          consumer.refreshScheduling();
          round = Completer<DownloadSnapshot>();
          record('page-promotion-reclaim-rewait', <String, Object?>{
            'attempt': stallReclaims,
            'state': session.state.name,
          });
          if (session.snapshot.state == DownloadState.promoted ||
              session.snapshot.state == DownloadState.failed ||
              session.snapshot.state == DownloadState.disposed) {
            if (!round.isCompleted) {
              round.complete(session.snapshot);
            }
          } else {
            armStall();
          }
        }
      }
    } finally {
      stallTimer?.cancel();
      session.removeSnapshotListener(listener);
    }
  }

  Transport _transportForPage(ChapterManifest manifest, PageAsset page) {
    if (!_isSourceOwnedResource(manifest.sourceId, page.uri)) {
      return _transport;
    }
    final access = _resourceAccess;
    final stream = access?.openResponse;
    final controlledStream = access?.openControlledResponse;
    final loader = access?.loadBytes;
    final controlledLoader = access?.loadBytesControlled;
    if (stream == null &&
        controlledStream == null &&
        loader == null &&
        controlledLoader == null) {
      return _transport;
    }
    return LoaderTransport(<Uri, LoaderTransportSource>{
      page.uri: LoaderTransportSource(
        revision: '${manifest.chapter.sourceRevision}:${page.pageId}',
        openResponse: stream == null
            ? null
            : ({ByteRange? range, Validators? validators}) async =>
                _observeVerifiedPageReuseIdentity(
                  manifest,
                  page,
                  await stream(
                    manifest.sourceId,
                    page.uri,
                    range: range,
                    validators: validators,
                  ),
                ),
        openControlledResponse: controlledStream == null
            ? null
            : ({
                ByteRange? range,
                Validators? validators,
                TaskControl? control,
              }) async => _observeVerifiedPageReuseIdentity(
                  manifest,
                  page,
                  await controlledStream(
                    manifest.sourceId,
                    page.uri,
                    range: range,
                    validators: validators,
                    control: control,
                  ),
                ),
        selfBoundedOpen:
            access?.selfBoundsOpen?.call(manifest.sourceId, page.uri) ?? false,
        loadBytesControlled: controlledLoader == null
            ? null
            : ({TaskControl? control}) => controlledLoader(
                  manifest.sourceId,
                  page.uri,
                  control: control,
                ),
        loadBytes: loader == null
            ? null
            : () => loader(manifest.sourceId, page.uri),
      ),
    });
  }

  ByteResponse _observeVerifiedPageReuseIdentity(
    ChapterManifest manifest,
    PageAsset page,
    ByteResponse response,
  ) {
    final identity = response.diagnostics['sourceVerifiedReuseIdentity'];
    if (identity is String && identity.isNotEmpty) {
      try {
        _resourceAccess?.onVerifiedPageReuseIdentity?.call(
          manifest,
          page,
          identity,
        );
      } on Object {
        // Optional version evidence must never change transport success.
      }
    }
    return response;
  }

  bool _isSourceOwnedResource(String sourceId, Uri uri) {
    if (sourceId.startsWith('mihon:') || sourceId.startsWith('venera:')) {
      return true;
    }
    return uri.scheme == 'mihon' || uri.scheme == 'venera-resource';
  }

  @override
  Future<void> cancel(ImportedLibraryEntry entry) async {
    _requireOpen();
    // Exact chapter prefix: source+comic+chapter, every revision.
    final chapterPrefix = _chapterDownloadPrefix(entry);
    final matchedTokens = <String>[];
    for (final identity in List.of(_tokens.keys)) {
      if (!identity.startsWith(chapterPrefix)) continue;
      matchedTokens.add(identity);
      _cancelled.add(identity);
      _tokens[identity]?.cancel();
    }
    for (final identity in List.of(_commandConsumers.keys)) {
      if (!identity.startsWith(chapterPrefix)) continue;
      final consumer = _commandConsumers.remove(identity);
      await consumer?.dispose();
    }
    final activeRuns = List.of(
      _runs.keys.where((id) => id.startsWith(chapterPrefix)),
    );
    _recordCommandTrace(
      _identity(entry),
      'chapter-run-cancel-requested',
      <String, Object?>{
        'matchedRuns': activeRuns.length,
        'matchedTokens': matchedTokens.length,
        'requestedComicId': entry.chapter.comicId,
        'requestedChapterId': entry.chapter.chapterId,
      },
    );
    if (activeRuns.isEmpty) {
      _terminalPhases[_identity(entry)] = ChapterDownloadPhase.cancelled;
      await _emitInspection(entry, phase: ChapterDownloadPhase.cancelled);
      return;
    }
    for (final active in activeRuns) {
      try {
        // The run observes the token at its next checkpoint; a bounded wait
        // keeps a run stuck in pre-network IO from hanging the stop tap —
        // the run still exits and emits its cancelled state on its own.
        await _runs[active]?.timeout(const Duration(seconds: 10));
      } on Object {
        // The authoritative state is emitted by the task itself.
      }
    }
  }

  @override
  Future<ChapterDeleteImpactProjection> inspectDeleteImpact(
    ImportedLibraryEntry entry,
  ) async {
    _requireOpen();
    final manifest = entry.chapter.toManifest();
    return artifactStore.inspectChapterDeleteImpact(
      entry,
      targetIds: <DownloadId>[
        for (final page in manifest.pages) _downloadId(manifest, page),
      ],
    );
  }

  @override
  Future<void> delete(ImportedLibraryEntry entry) async {
    _requireOpen();
    final wasSingleChapter = await _isSingleChapterFor(entry);
    final chapterPrefix = _chapterDownloadPrefix(entry);
    _deletedIdentities.addAll(
      _runs.keys.where((id) => id.startsWith(chapterPrefix)),
    );
    final identity = _identity(entry);
    _deletedIdentities.add(identity);
    await cancel(entry);
    final manifest = entry.chapter.toManifest();
    for (final page in manifest.pages) {
      final id = _downloadId(manifest, page);
      var session = transferRuntime.registry.find(id);
      if (session != null && (session.activeRun || session.hasWriter)) {
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          session = transferRuntime.registry.find(id);
          if (session == null || (!session.activeRun && !session.hasWriter)) {
            break;
          }
        }
      }
      if (session != null && (session.activeRun || session.hasWriter)) {
        try {
          await session.reset();
        } on Object {
          // ignore error if reset cannot complete cleanly
        }
      }
      // The persistent artifact owner decides whether the physical session
      // can be retired after its path/reference check. Retire only the
      // transfer-runtime object afterwards; its blind registry eviction would
      // otherwise delete a shared final path the durable owner deliberately
      // kept.
      await artifactStore.evict(id);
      // The backend eviction removes durable bytes, but the composition cache
      // owns an independent hot copy. Invalidate it as part of the same exact
      // logical delete so a subsequent Reader lookup cannot resurrect the
      // deleted page from memory.
      await artifactCacheManager.invalidate(id);
      await transferRuntime.retirePhysicalAfterDelete(id);
    }
    // The export cleanup is a DeletePlan operation: it consults the index
    // after removing this exact logical version and never deletes a shared
    // structured path still referenced by another revision.
    try {
      final comicDirName = await artifactStore.resolveStructuredComicDirectory(
        entry,
      );
      final chapterDirName = wasSingleChapter
          ? null
          : await artifactStore.resolveStructuredChapterDirectory(
              entry,
              comicDirectoryName: comicDirName,
            );
      await artifactStore.cleanupStructuredChapterExport(
        entry,
        comicDirectoryName: comicDirName,
        chapterDirectoryName: chapterDirName,
        isSingleChapter: wasSingleChapter,
      );
      await artifactStore.removeChapterFromComicFolderManifest(
        entry,
        comicDirectoryName: comicDirName,
      );
      final remainingAll = (await artifactStore.indexedRecords(scopes: [
        CacheBindingScope(sourceId: entry.chapter.sourceId, comicId: entry.chapter.comicId),
      ])).values.any((
        record,
      ) {
          final content = record.id.content;
          return content.sourceId == entry.chapter.sourceId &&
              content.comicId == entry.chapter.comicId &&
              record.bytes > 0 &&
              (record.state == CacheState.ready ||
                  record.state == CacheState.partial);
      });
      if (!remainingAll) {
        await artifactStore.removeStructuredPlacement(
          sourceId: entry.chapter.sourceId,
          comicId: entry.chapter.comicId,
        );
      }
    } catch (_) {
      // Non-critical directory cleanup error
    }
    _startedRuns.removeWhere(
      (id) => id.startsWith(chapterPrefix) || id == identity,
    );
    _cancelled.removeWhere(
      (id) => id.startsWith(chapterPrefix) || id == identity,
    );
    _terminalPhases.removeWhere(
      (k, _) => k.startsWith(chapterPrefix) || k == identity,
    );
    _failedSourceResourceLocators.removeWhere(
      (k, _) => k.startsWith(chapterPrefix) || k == identity,
    );
    _emit(ChapterDownloadSnapshot.idle(entry));
  }

  @override
  Future<ChapterDownloadSnapshot> inspect(ImportedLibraryEntry entry) async {
    _requireOpen();
    return _buildSnapshot(
      entry,
      physicalState: await _loadManagementPhysicalState(),
    );
  }

  @override
  Future<DownloadExistenceReport> probeExistingDownloads(
    DownloadExistenceQuery query,
  ) async {
    _requireOpen();
    bool identityMatches(String identity) {
      final segments = identity.split('\u0000');
      if (segments.length < 3) return false;
      final sourceId = segments[0];
      final comicId = segments[1];
      final chapterId = segments[2];
      if (sourceId != query.sourceId) {
        final pluginId = query.pluginId;
        if (pluginId == null || !sourceId.startsWith('$pluginId:')) {
          return false;
        }
      }
      if (query.comicId != null && comicId != query.comicId) {
        return false;
      }
      if (query.chapterId != null && chapterId != query.chapterId) {
        return false;
      }
      return true;
    }

    final liveRunIdentities = List.of(_runs.keys.where(identityMatches));
    final liveRunStarted = liveRunIdentities.any(_startedRuns.contains);
    final records = await artifactStore.indexedRecords();
    var indexedReadyPages = 0;
    var urlMatchedPages = 0;
    for (final record in records.values) {
      if (!artifactStore._isVerifiedReadyRecord(record)) {
        continue;
      }
      final content = record.id.content;
      if (content.sourceId != query.sourceId) {
        final pluginId = query.pluginId;
        if (pluginId == null || !content.sourceId.startsWith('$pluginId:')) {
          continue;
        }
      }
      if (query.comicId != null && content.comicId != query.comicId) {
        continue;
      }
      if (query.chapterId != null && content.chapterId != query.chapterId) {
        continue;
      }
      indexedReadyPages++;
      if (query.url != null && record.id.canonicalUri.toString() == query.url) {
        urlMatchedPages++;
      }
    }
    return DownloadExistenceReport(
      liveRunIdentities: List.unmodifiable(liveRunIdentities),
      liveRunStarted: liveRunStarted,
      indexedReadyPages: indexedReadyPages,
      urlMatchedPages: urlMatchedPages,
    );
  }

  @override
  Future<ChapterFileAuditReport> auditChapterFiles(
    ImportedLibraryEntry entry,
  ) {
    _requireOpen();
    final identity = _identity(entry);
    final active = _auditRuns[identity];
    if (active != null) return active;
    final token = CancelToken();
    _auditTokens[identity] = token;
    late final Future<ChapterFileAuditReport> run;
    run = _runChapterFileAudit(entry, control: token).whenComplete(() {
      if (identical(_auditRuns[identity], run)) {
        _auditRuns.remove(identity);
        _auditTokens.remove(identity);
      }
    });
    _auditRuns[identity] = run;
    return run;
  }

  Future<ChapterFileAuditReport> _runChapterFileAudit(
    ImportedLibraryEntry entry, {
    required TaskControl control,
  }) async {
    _requireOpen();
    control.throwIfCancelled();
    final manifest = entry.chapter.toManifest();
    var records = await artifactStore.indexedRecordsForEntries(
      [entry], includeComicRecords: true,
    );
    var indexedReadyPages = 0;
    var verifiedIndexedPages = 0;
    var invalidIndexedPages = 0;

    var repairedAuthority = false;
    try {
      for (final page in manifest.pages) {
        control.throwIfCancelled();
        final id = _downloadId(manifest, page);
        final record = records[id.key];
        if (record == null || !artifactStore._isVerifiedReadyRecord(record)) {
          continue;
        }
        indexedReadyPages++;
        final stream = await artifactStore.openArtifactStream(id);
        if (stream == null) {
          invalidIndexedPages++;
          continue;
        }
        try {
          final controlled = stream.readAllControlled;
          if (controlled != null) {
            await controlled(control: control);
          } else if (stream.readAll case final readAll?) {
            await readAll();
            control.throwIfCancelled();
          } else {
            await for (final _ in stream.open(start: 0)) {
              control.throwIfCancelled();
            }
          }
          verifiedIndexedPages++;
        } on Failure catch (error) {
          if (error.code == ErrorCode.cancelled) rethrow;
          if (error.code != ErrorCode.artifactCorruption) rethrow;
          invalidIndexedPages++;
        } on ArtifactReadFailure catch (error) {
          control.throwIfCancelled();
          if (!artifactStore._isStructuralReplicaFailure(error.kind)) rethrow;
          invalidIndexedPages++;
        }
      }

      control.throwIfCancelled();
      records = await artifactStore.indexedRecordsForEntries(
        [entry], includeComicRecords: true,
      );
      final comicDirectoryName = await artifactStore
          .resolveStructuredComicDirectory(entry, knownRecords: records.values);
      final disk = await artifactStore.scanExistingPages(
        comicTitle: entry.chapter.comicTitle,
        chapterTitle: entry.chapter.displayName,
        sequence: entry.chapter.sequence,
        isSingleChapter: await _isSingleChapterFor(entry),
        comicDirectoryName: comicDirectoryName,
        control: control,
        layoutId: manifest.pages.isEmpty
            ? null
            : _downloadId(manifest, manifest.pages.first),
      );
      var scannedBytes = 0;
      var repairedPages = 0;
      var unprovenPages = 0;
      var sourceMismatchPages = 0;
      var extraPages = 0;

      for (final candidate in disk.entries) {
        control.throwIfCancelled();
        scannedBytes += candidate.value.bytes;
        final pageIndex = candidate.key - 1;
        if (pageIndex < 0 || pageIndex >= manifest.pages.length) {
          extraPages++;
          continue;
        }
        final page = manifest.pages[pageIndex];
        final id = _downloadId(manifest, page);
        final current = records[id.key];
        if (current != null && artifactStore._isVerifiedReadyRecord(current)) {
          continue;
        }
        final expectedChecksum = _sourceCrc32Constraint(page);
        if (expectedChecksum == null) {
          final proof = await artifactStore._artifactProof(
            candidate.value.path,
            control: control,
          );
          if (proof.bytes == candidate.value.bytes) {
            unprovenPages++;
          } else {
            sourceMismatchPages++;
          }
          continue;
        }
        final expectedLength = page.byteLength;
        if (expectedLength != null && expectedLength != candidate.value.bytes) {
          sourceMismatchPages++;
          continue;
        }
        try {
          final adopted = await artifactStore.adoptExistingPageRecord(
            id: id,
            path: candidate.value.path,
            bytes: candidate.value.bytes,
            checksum: expectedChecksum,
            storageRootId: artifactStore.storageRootIdFor(entry),
            control: control,
          );
          records[id.key] = adopted;
          repairedPages++;
          repairedAuthority = true;
        } on Failure catch (error) {
          if (error.code == ErrorCode.cancelled) rethrow;
          if (error.code == ErrorCode.artifactCorruption) {
            sourceMismatchPages++;
            continue;
          }
          rethrow;
        }
      }

      return ChapterFileAuditReport(
        manifestPages: manifest.pages.length,
        indexedReadyPages: indexedReadyPages,
        verifiedIndexedPages: verifiedIndexedPages,
        invalidIndexedPages: invalidIndexedPages,
        scannedImagePages: disk.length,
        scannedBytes: scannedBytes,
        repairedPages: repairedPages,
        unprovenPages: unprovenPages,
        sourceMismatchPages: sourceMismatchPages,
        extraPages: extraPages,
      );

    } finally {
      if (repairedAuthority) {
        _handleArtifactManagementProjectionChanged();
      }
    }
  }

  @override
  Future<void> cancelChapterFileAudit(ImportedLibraryEntry entry) async {
    _requireOpen();
    final chapterPrefix = _chapterDownloadPrefix(entry);
    final active = <Future<ChapterFileAuditReport>>[];
    for (final identity in List<String>.of(_auditTokens.keys)) {
      if (!identity.startsWith(chapterPrefix)) continue;
      _auditTokens[identity]?.cancel();
      final run = _auditRuns[identity];
      if (run != null) active.add(run);
    }
    for (final run in active) {
      try {
        await run.timeout(const Duration(seconds: 10));
      } on Object {
        // Cancellation remains authoritative even if provider I/O is still
        // unwinding; the run observes its token at the next bounded checkpoint.
      }
    }
  }

  Future<bool> _isSingleChapterFor(ImportedLibraryEntry entry) async {
    final existingChapters = await artifactStore.downloadedChapterIds(
      sourceId: entry.chapter.sourceId,
      comicId: entry.chapter.comicId,
    );
    final hasOtherDownloadedChapters =
        existingChapters.isNotEmpty &&
        !existingChapters.contains(entry.chapter.chapterId);
    return !(entry.chapter.sequence > 1 ||
        hasOtherDownloadedChapters ||
        existingChapters.length > 1);
  }

  @override
  Future<List<ImportedLibraryEntry>> discoverOrphanedEntries(
    Iterable<ImportedLibraryEntry> knownEntries,
  ) async {
    _requireOpen();
    final records = await artifactStore.indexedRecords();
    return _discoverOrphanedEntriesFromRecords(knownEntries, records);
  }

  @override
  Future<List<ChapterDownloadSnapshot>> inspectMany(
    Iterable<ImportedLibraryEntry> entries,
  ) async {
    _requireOpen();
    final requested = entries.toList(growable: false);
    if (requested.isEmpty) {
      return const <ChapterDownloadSnapshot>[];
    }
    final startedUs = _traceClock.nowMicros();
    final indexed = await artifactStore.indexedRecordsForEntries(requested);
    final indexedUs = _traceClock.nowMicros() - startedUs;
    final physicalStartedUs = _traceClock.nowMicros();
    final physicalState = await _loadManagementPhysicalState();
    final physicalUs = _traceClock.nowMicros() - physicalStartedUs;
    final snapshotStartedUs = _traceClock.nowMicros();
    final snapshots = await _inspectManyFromRecords(
      requested,
      indexed,
      physicalState: physicalState,
    );
    _recordCommandTrace(
      'download-management',
      'targeted-projection-built',
      <String, Object?>{
        'knownEntries': requested.length,
        'indexedRecords': indexed.length,
        'indexedUs': indexedUs,
        'physicalUs': physicalUs,
        'snapshotUs': _traceClock.nowMicros() - snapshotStartedUs,
        'totalUs': _traceClock.nowMicros() - startedUs,
      },
    );
    return snapshots;
  }

  @override
  Future<ChapterCacheManagementProjection> inspectCacheManagement(
    Iterable<ImportedLibraryEntry> knownEntries,
  ) async {
    _requireOpen();
    final startedUs = _traceClock.nowMicros();
    final known = knownEntries.toList(growable: false);
    final indexedStartedUs = _traceClock.nowMicros();
    final indexed = await artifactStore.indexedRecords();
    final indexedUs = _traceClock.nowMicros() - indexedStartedUs;
    final physicalStartedUs = _traceClock.nowMicros();
    final physicalState = await _loadManagementPhysicalState();
    final physicalUs = _traceClock.nowMicros() - physicalStartedUs;
    final orphanStartedUs = _traceClock.nowMicros();
    final orphaned = _discoverOrphanedEntriesFromRecords(
      known,
      indexed,
      compactEntriesAreKnown: true,
    );
    final orphanUs = _traceClock.nowMicros() - orphanStartedUs;
    final visibleEntries = <ImportedLibraryEntry>[...known, ...orphaned];
    final cacheStartedUs = _traceClock.nowMicros();
    final cache = _buildCacheManagementProjection(
      visibleEntries,
      indexed,
      physicalState,
    );
    final cacheProjectionUs = _traceClock.nowMicros() - cacheStartedUs;
    _recordCommandTrace(
      'download-management',
      'cache-management-projection-built',
      <String, Object?>{
        'knownEntries': known.length,
        'orphanedEntries': orphaned.length,
        'indexedRecords': indexed.length,
        'physicalArtifacts': physicalState.artifacts.length,
        'physicalPartials': physicalState.partials.length,
        'canonicalProjections': physicalState.projections.length,
        'canonicalRows': cache.canonical.length,
        'exactRows': cache.exact.length,
        'visiblePages': visibleEntries.fold<int>(
          0,
          (total, entry) => total + entry.chapter.pages.length,
        ),
        'indexedUs': indexedUs,
        'physicalUs': physicalUs,
        'orphanUs': orphanUs,
        'cacheProjectionUs': cacheProjectionUs,
        'totalUs': _traceClock.nowMicros() - startedUs,
      },
    );
    return cache;
  }

  @override
  Future<ChapterDownloadManagementProjection> inspectDownloadManagement(
    Iterable<ImportedLibraryEntry> knownEntries,
  ) async {
    _requireOpen();
    final startedUs = _traceClock.nowMicros();
    final known = knownEntries.toList(growable: false);
    final indexedStartedUs = _traceClock.nowMicros();
    final indexed = await artifactStore.indexedRecords();
    final indexedUs = _traceClock.nowMicros() - indexedStartedUs;
    final physicalStartedUs = _traceClock.nowMicros();
    final physicalState = await _loadManagementPhysicalState();
    final physicalUs = _traceClock.nowMicros() - physicalStartedUs;
    final projectStartedUs = _traceClock.nowMicros();
    final orphanStartedUs = _traceClock.nowMicros();
    final orphaned = _discoverOrphanedEntriesFromRecords(
      known,
      indexed,
      compactEntriesAreKnown: true,
    );
    final orphanUs = _traceClock.nowMicros() - orphanStartedUs;
    final visibleEntries = <ImportedLibraryEntry>[...known, ...orphaned];
    final snapshotStartedUs = _traceClock.nowMicros();
    final snapshots = await _inspectManyFromRecords(
      visibleEntries,
      indexed,
      physicalState: physicalState,
    );
    final snapshotUs = _traceClock.nowMicros() - snapshotStartedUs;
    final cacheStartedUs = _traceClock.nowMicros();
    final cache = _buildCacheManagementProjection(
      visibleEntries,
      indexed,
      physicalState,
    );
    final cacheProjectionUs = _traceClock.nowMicros() - cacheStartedUs;
    final projectUs = _traceClock.nowMicros() - projectStartedUs;
    _recordCommandTrace(
      'download-management',
      'management-projection-built',
      <String, Object?>{
        'knownEntries': known.length,
        'orphanedEntries': orphaned.length,
        'indexedRecords': indexed.length,
        'physicalArtifacts': physicalState.artifacts.length,
        'physicalPartials': physicalState.partials.length,
        'canonicalProjections': physicalState.projections.length,
        'canonicalRows': cache.canonical.length,
        'exactRows': cache.exact.length,
        'visiblePages': visibleEntries.fold<int>(
          0,
          (total, entry) => total + entry.chapter.pages.length,
        ),
        'indexedUs': indexedUs,
        'physicalUs': physicalUs,
        'orphanUs': orphanUs,
        'snapshotUs': snapshotUs,
        'cacheProjectionUs': cacheProjectionUs,
        'projectUs': projectUs,
        'totalUs': _traceClock.nowMicros() - startedUs,
      },
    );
    return ChapterDownloadManagementProjection(
      orphanedEntries: orphaned,
      snapshots: snapshots,
      cache: cache,
    );
  }

  List<ImportedLibraryEntry> _discoverOrphanedEntriesFromRecords(
    Iterable<ImportedLibraryEntry> knownEntries,
    Map<String, CacheRec> records, {
    bool compactEntriesAreKnown = false,
  }) {
    final knownChapterKeys = <String>{
      for (final entry in knownEntries)
        if (compactEntriesAreKnown || !_isCompactProjectionEntry(entry))
          '${entry.chapter.sourceId}\u0000${entry.chapter.comicId}\u0000${entry.chapter.chapterId}\u0000${entry.chapter.sourceRevision}',
    };
    final orphanedGroups = <String, List<CacheRec>>{};
    for (final record in records.values) {
      if (!artifactStore._isVerifiedReadyRecord(record)) {
        continue;
      }
      final content = record.id.content;
      final chapterKey =
          '${content.sourceId}\u0000${content.comicId}\u0000${content.chapterId}\u0000${record.id.sourceRevision}';
      if (knownChapterKeys.contains(chapterKey)) {
        continue;
      }
      orphanedGroups.putIfAbsent(chapterKey, () => <CacheRec>[]).add(record);
    }

    final orphaned = <ImportedLibraryEntry>[];
    for (final group in orphanedGroups.values) {
      if (group.isEmpty) {
        continue;
      }
      final firstRecord = group.first;
      final content = firstRecord.id.content;
      final revision = firstRecord.id.sourceRevision;
      orphaned.add(
        ImportedLibraryEntry(
          chapter: ImportedChapterRecord(
            directoryId: 'orphaned:${content.comicId}:$revision',
            displayName: '未关联章节',
            sourceId: content.sourceId,
            comicId: content.comicId,
            comicTitle: '未关联漫画',
            chapterId: content.chapterId,
            sourceRevision: revision,
            pages: <ImportedPageRecord>[
              for (final record in group)
                ImportedPageRecord(
                  displayName: record.id.content.pageId,
                  sourceId: record.id.canonicalUri.toString(),
                  pageId: record.id.content.pageId,
                  contentKindHint: ContentKindHint.unknown,
                  byteLength: record.bytes,
                ),
            ],
          ),
        ),
      );
    }
    return List<ImportedLibraryEntry>.unmodifiable(orphaned);
  }

  String _logicalChapterManagementKey(
    String sourceId,
    String comicId,
    String chapterId,
  ) =>
      '$sourceId\u0000$comicId\u0000$chapterId';

  Map<String, ImportedChapterRecord> _managementDisplayMetadata(
    Iterable<ImportedLibraryEntry> entries,
  ) {
    final metadata = <String, ImportedChapterRecord>{};
    for (final entry in entries) {
      if (entry.chapter.directoryId.startsWith('orphaned:')) continue;
      metadata.putIfAbsent(
        _logicalChapterManagementKey(
          entry.chapter.sourceId,
          entry.chapter.comicId,
          entry.chapter.chapterId,
        ),
        () => entry.chapter,
      );
    }
    return metadata;
  }

  ChapterCacheManagementProjection _buildCacheManagementProjection(
    Iterable<ImportedLibraryEntry> entries,
    Map<String, CacheRec> indexed,
    _DownloadManagementPhysicalState physicalState,
  ) {
    final visibleEntries = entries.toList(growable: false);
    final displayMetadataByLogicalChapter =
        _managementDisplayMetadata(visibleEntries);
    final canonicalBuilders = physicalState.canonicalInventoryBuilders();
    final exactBuilders = <String, _ExactChapterCacheSnapshotBuilder>{};
    final exactRecordsByChapter = <String, List<CacheRec>>{};
    for (final record in indexed.values) {
      final ready = artifactStore._isVerifiedReadyRecord(record);
      final partial = record.state == CacheState.partial && record.bytes > 0;
      if (!ready && !partial) continue;
      final content = record.id.content;
      final chapterKey =
          '${content.sourceId}\u0000${content.comicId}\u0000${content.chapterId}\u0000${record.id.sourceRevision}';
      exactRecordsByChapter
          .putIfAbsent(chapterKey, () => <CacheRec>[])
          .add(record);
    }
    final canonicalArtifactIds = <String>{
      for (final record in physicalState.artifacts.values)
        if (record.id.kind == PhysicalMediaIdKind.canonical) record.artifactId,
    };

    for (final entry in visibleEntries) {
      final manifest = entry.chapter.toManifest();
      final displayMetadata = displayMetadataByLogicalChapter[
        _logicalChapterManagementKey(
          entry.chapter.sourceId,
          entry.chapter.comicId,
          entry.chapter.chapterId,
        )
      ];
      final projection = physicalState.projectionFor(entry);
      final canonicalBuilder = projection == null
          ? null
          : canonicalBuilders[
              _canonicalCacheGroupKey(
                projection.familyId,
                projection.canonicalChapterId,
              )
            ];
      canonicalBuilder?.addMember(_identity(entry));

      _ExactChapterCacheSnapshotBuilder? exactBuilder;
      if (_isCompactProjectionEntry(entry)) {
        final chapterKey =
            '${entry.chapter.sourceId}\u0000${entry.chapter.comicId}\u0000${entry.chapter.chapterId}\u0000${entry.chapter.sourceRevision}';
        for (final record in exactRecordsByChapter[chapterKey] ??
            const <CacheRec>[]) {
          final ready = artifactStore._isVerifiedReadyRecord(record);
          final manualReferenced = ready &&
              (record.pinned ||
                  !artifactStore._isAutomaticCacheFinalRecord(record));
          if (manualReferenced) continue;
          if (ready &&
              record.artifactId.isNotEmpty &&
              canonicalArtifactIds.contains(record.artifactId)) {
            continue;
          }
          exactBuilder ??= _ExactChapterCacheSnapshotBuilder(
            entry,
            displayMetadata: displayMetadata,
          );
          exactBuilder.addPage(ready: ready, bytes: record.bytes);
        }
        if (exactBuilder != null && exactBuilder.cachedPages > 0) {
          exactBuilders[exactBuilder.identity] = exactBuilder;
        }
        continue;
      }
      for (var index = 0; index < manifest.pages.length; index++) {
        final page = manifest.pages[index];
        final id = _downloadId(manifest, page);
        final exactIndexed = indexed[id.key];
        final exactReady = exactIndexed != null &&
            artifactStore._isVerifiedReadyRecord(exactIndexed);
        final physical = physicalState.pageState(
          entry: entry,
          page: page,
          pageIndex: index,
        );
        // Cache management is a durable-inventory projection. A hot transfer
        // session may be promoted while its body is still owned by a reopenable
        // source (notably a local SAF document), or may only have an in-memory
        // prefix. Neither is an app-owned cache artifact. Only the durable exact
        // index and durable physical artifact/partial inventory may create rows.
        final ready = exactReady || physical?.artifact != null;
        final bytes = exactIndexed?.bytes ??
            physical?.artifact?.bytes ??
            physical?.partial?.bytes ??
            0;
        final partial = !ready && bytes > 0;
        if (!ready && !partial) continue;

        final manualReferenced = exactReady &&
            (exactIndexed.pinned ||
                !artifactStore._isAutomaticCacheFinalRecord(exactIndexed));
        final coordinate = projection?.coordinateForPageIndexOrNull(index);
        if (coordinate != null && canonicalBuilder != null) {
          final physicalId = PhysicalMediaId.canonical(coordinate.stableKey);
          final hasCanonicalPhysical =
              physicalState.artifacts.containsKey(physicalId) ||
              physicalState.partials.containsKey(physicalId);
          final active = physicalState.isProjectionActive(
            entry: entry,
            pageIndex: index,
          );
          if (hasCanonicalPhysical || (active && exactReady)) {
            canonicalBuilder.addPage(
              physicalId: physicalId,
              ready: ready,
              bytes: bytes,
              manualReferenced: manualReferenced,
            );
            continue;
          }
        }

        // Exact manual/offline ownership belongs on the manual tab. The cache
        // remainder contains only pages that still have no canonical media
        // coordinate and are not protected solely by an exact download.
        if (manualReferenced) continue;
        exactBuilder ??= _ExactChapterCacheSnapshotBuilder(
          entry,
          displayMetadata: displayMetadata,
        );
        exactBuilder.addPage(ready: ready, bytes: bytes);
      }
      if (exactBuilder != null && exactBuilder.cachedPages > 0) {
        exactBuilders[exactBuilder.identity] = exactBuilder;
      }
    }

    final canonical = <CanonicalChapterCacheSnapshot>[
      for (final builder in canonicalBuilders.values)
        if (builder.cachedPages > 0) builder.build(),
    ]..sort((left, right) => left.identity.compareTo(right.identity));
    final exact = <ExactChapterCacheSnapshot>[
      for (final builder in exactBuilders.values) builder.build(),
    ]..sort((left, right) => left.identity.compareTo(right.identity));
    return ChapterCacheManagementProjection(canonical: canonical, exact: exact);
  }

  Future<List<ChapterDownloadSnapshot>> _inspectManyFromRecords(
    Iterable<ImportedLibraryEntry> entries,
    Map<String, CacheRec> indexed, {
    _DownloadManagementPhysicalState? physicalState,
  }) async {
    final visibleEntries = entries.toList(growable: false);
    final displayMetadataByLogicalChapter =
        _managementDisplayMetadata(visibleEntries);
    final recordsByChapter = <String, List<CacheRec>>{};
    final workBudget = _DownloadProjectionWorkBudget();
    final readyIndex = await _DurableReadyRecordIndex.build(
      indexed.values,
      isReady: artifactStore._isVerifiedReadyRecord,
      workBudget: workBudget,
    );
    for (final record in indexed.values) {
      if (workBudget.exhausted) await workBudget.yieldTurn();
      if (!artifactStore._isVerifiedReadyRecord(record)) {
        continue;
      }
      final content = record.id.content;
      final chapterKey =
          '${content.sourceId}\u0000${content.comicId}\u0000${content.chapterId}\u0000${record.id.sourceRevision}';
      recordsByChapter.putIfAbsent(chapterKey, () => <CacheRec>[]).add(record);
    }
    final snapshots = <ChapterDownloadSnapshot>[];
    for (final entry in visibleEntries) {
      final chapterKey =
          '${entry.chapter.sourceId}\u0000${entry.chapter.comicId}\u0000${entry.chapter.chapterId}\u0000${entry.chapter.sourceRevision}';
      snapshots.add(
        await _buildSnapshot(
          entry,
          displayMetadata: displayMetadataByLogicalChapter[
            _logicalChapterManagementKey(
              entry.chapter.sourceId,
              entry.chapter.comicId,
              entry.chapter.chapterId,
            )
          ],
          indexedRecords: indexed,
          chapterRecords: recordsByChapter[chapterKey],
          workBudget: workBudget,
          readyIndex: readyIndex,
          physicalState: physicalState,
        ),
      );
    }
    return List<ChapterDownloadSnapshot>.unmodifiable(snapshots);
  }

  Future<ChapterDownloadSnapshot> _buildSnapshot(
    ImportedLibraryEntry entry, {
    ImportedChapterRecord? displayMetadata,
    ChapterDownloadPhase? phase,
    String? failure,
    Map<String, CacheRec>? indexedRecords,
    Iterable<CacheRec>? chapterRecords,
    _DurableReadyRecordIndex? readyIndex,
    _DownloadManagementPhysicalState? physicalState,
    _DownloadProjectionWorkBudget? workBudget,
  }) async {
    final budget = workBudget ?? _DownloadProjectionWorkBudget();
    final manifest = entry.chapter.toManifest();
    final records =
        indexedRecords ??
        (chapterRecords == null
            ? await artifactStore.indexedRecordsForEntries([entry])
            : const <String, CacheRec>{});
    final recordsByPage = <String, CacheRec>{};
    final targetRecords = chapterRecords ?? records.values;
    for (final rec in targetRecords) {
      if (budget.exhausted) await budget.yieldTurn();
      if (!artifactStore._isVerifiedReadyRecord(rec) ||
          rec.id.sourceRevision != entry.chapter.sourceRevision) {
        continue;
      }
      if (rec.id.content.sourceId == entry.chapter.sourceId &&
          rec.id.content.comicId == entry.chapter.comicId &&
          rec.id.content.chapterId == entry.chapter.chapterId) {
        // Compact Home placeholders need a deterministic page list, but only
        // records from the current exact source revision may shape it.
        recordsByPage.putIfAbsent(rec.id.content.pageId, () => rec);
      }
    }
    final resolvedReadyIndex =
        readyIndex ??
        await _DurableReadyRecordIndex.build(
          records.values,
          isReady: artifactStore._isVerifiedReadyRecord,
          workBudget: budget,
        );
    final predecessorBindingLookups = <String, Future<Map<int, String>>>{};
    var exactCompletedPages = 0;
    var completedPages = 0;
    var pinnedPages = 0;
    var receivedBytes = 0;
    var totalBytes = 0;
    var knowsTotalBytes = true;
    var pageProgressUnits = 0.0;
    String? sessionFailure;
    var hasFailedSession = false;
    final effectivePages = _isCompactProjectionEntry(entry)
        ? _effectiveCompactPages(
            manifest.pages,
            recordsByPage.values,
            chapterId: entry.chapter.chapterId,
          )
        : manifest.pages;
    for (var index = 0; index < effectivePages.length; index++) {
      if (budget.exhausted) await budget.yieldTurn();
      final page = effectivePages[index];
      final id = _downloadId(manifest, page);
      final resolvedSessionSnapshot = transferRuntime.registry
          .find(id)
          ?.snapshot;
      final snapshot =
          resolvedSessionSnapshot != null &&
              (resolvedSessionSnapshot.state != DownloadState.idle ||
                  resolvedSessionSnapshot.activeRun ||
                  resolvedSessionSnapshot.hasWriter)
          ? resolvedSessionSnapshot
          : null;
      final exactSessionSnapshot = transferRuntime.registry
          .findExact(id)
          ?.snapshot;
      final exactIndexed = records[id.key];
      final reusable = exactIndexed == null
          ? await _resolveReusablePageRecord(
              entry: entry,
              page: page,
              pageIndex: index,
              targetId: id,
              readyIndex: resolvedReadyIndex,
              predecessorBindingLookups: predecessorBindingLookups,
            )
          : null;
      final indexed = exactIndexed ?? reusable?.record;
      final physical = physicalState?.pageState(
        entry: entry,
        page: page,
        pageIndex: index,
      );
      final physicalArtifact = physical?.artifact;
      final physicalPartial = physical?.partial;
      final committedLength =
          snapshot?.committedLength ??
          indexed?.bytes ??
          physicalArtifact?.bytes ??
          physicalPartial?.bytes ??
          0;
      receivedBytes += committedLength;
      final exactPromoted =
          exactSessionSnapshot?.state == DownloadState.promoted ||
          (exactIndexed != null &&
              artifactStore._isVerifiedReadyRecord(exactIndexed));
      final promoted =
          snapshot?.state == DownloadState.promoted ||
          exactPromoted ||
          (indexed != null && artifactStore._isVerifiedReadyRecord(indexed)) ||
          physicalArtifact != null;
      final isExactPinned =
          exactIndexed != null &&
          artifactStore._isVerifiedReadyRecord(exactIndexed) &&
          (exactIndexed.pinned ||
              !artifactStore._isAutomaticCacheFinalRecord(exactIndexed));
      if (isExactPinned) {
        pinnedPages++;
      }
      if (exactPromoted) {
        exactCompletedPages++;
      }
      if (promoted) {
        completedPages++;
        pageProgressUnits += 1;
      }
      final knownLength =
          snapshot?.totalLength ??
          (index < entry.chapter.pages.length
              ? entry.chapter.pages[index].byteLength
              : null) ??
          indexed?.bytes ??
          physicalArtifact?.bytes;
      if (knownLength == null) {
        knowsTotalBytes = false;
      } else {
        totalBytes += knownLength;
        if (!promoted && knownLength > 0 && committedLength > 0) {
          pageProgressUnits += (committedLength / knownLength)
              .clamp(0, 1)
              .toDouble();
        }
      }
      if (snapshot?.state == DownloadState.failed) {
        hasFailedSession = true;
        sessionFailure ??= snapshot?.failure?.toString();
      }
    }
    final identity = _identity(entry);
    final hasActiveRun =
        _runs.containsKey(identity) ||
        _runs.keys.any((k) => k.startsWith(_chapterDownloadPrefix(entry)));
    final runStarted =
        _startedRuns.contains(identity) || _startedRunsKeysAnyPrefix(entry);
    final isExplicitlyTracked =
        pinnedPages > 0 || runStarted || _terminalPhases.containsKey(identity);
    final resolvedPhase =
        phase ??
        _terminalPhases[identity] ??
        (hasActiveRun
            ? ChapterDownloadPhase.downloading
            : (exactCompletedPages == effectivePages.length &&
                    effectivePages.isNotEmpty &&
                    !_deletedIdentities.contains(identity) &&
                    isExplicitlyTracked)
                ? ChapterDownloadPhase.complete
                : _cancelled.contains(identity)
                    ? ChapterDownloadPhase.cancelled
                    : hasFailedSession
                        ? ChapterDownloadPhase.failed
                        : ChapterDownloadPhase.idle);
    final displayChapter = displayMetadata ?? entry.chapter;
    final orphanMetadata = displayChapter.directoryId.startsWith('orphaned:');
    return ChapterDownloadSnapshot(
      sourceId: entry.chapter.sourceId,
      comicId: entry.chapter.comicId,
      comicTitle: orphanMetadata ? '未关联漫画' : displayChapter.comicTitle,
      chapterId: entry.chapter.chapterId,
      sourceRevision: entry.chapter.sourceRevision,
      title: orphanMetadata ? '未关联章节' : displayChapter.displayName,
      completedPages: completedPages,
      totalPages: effectivePages.length,
      receivedBytes: receivedBytes,
      pinnedPages: pinnedPages,
      exactCompletedPages: exactCompletedPages,
      totalBytes: knowsTotalBytes ? totalBytes : null,
      pageProgressUnits: pageProgressUnits,
      phase: resolvedPhase,
      failure: failure ?? sessionFailure,
      started: runStarted,
    );
  }

  /// Any revision of this chapter already admitted a page task.
  bool _startedRunsKeysAnyPrefix(ImportedLibraryEntry entry) {
    final prefix = _chapterDownloadPrefix(entry);
    return _startedRuns.any((identity) => identity.startsWith(prefix));
  }

  Future<void> _emitInspection(
    ImportedLibraryEntry entry, {
    ChapterDownloadPhase? phase,
    String? failure,
    Map<String, CacheRec>? indexedRecords,
  }) async {
    if (_deletedIdentities.contains(_identity(entry))) return;
    _emit(
      await _buildSnapshot(
        entry,
        phase: phase,
        failure: failure,
        // Command page completions mutate their inventory while this
        // projection yields. Inspect one stable set of immutable records.
        indexedRecords: indexedRecords == null
            ? null
            : Map<String, CacheRec>.of(indexedRecords),
      ),
    );
  }

  @override
  Future<bool> isDownloaded(ImportedLibraryEntry entry) async =>
      (await inspect(entry)).isComplete;

  @override
  Future<ComicConflictReport> inspectComicConflicts({
    required String sourceId,
    String? sourceDisplayName,
    required String comicId,
    required String comicTitle,
    Set<String>? knownPredecessorComicIds,
    Set<String>? knownSuccessorComicIds,
    Set<String>? requiredDirectoryNames,
  }) => artifactStore.inspectComicConflicts(
        sourceId: sourceId,
        sourceDisplayName: sourceDisplayName,
        comicId: comicId,
        comicTitle: comicTitle,
        knownPredecessorComicIds: knownPredecessorComicIds,
        knownSuccessorComicIds: knownSuccessorComicIds,
        requiredDirectoryNames: requiredDirectoryNames,
      );

  @override
  Future<Set<int>> readyPageIndices(ImportedLibraryEntry entry) async {
    _requireOpen();
    final manifest = entry.chapter.toManifest();
    final total = manifest.pages.length;
    if (total == 0) return const <int>{};
    final indexedRecords = await artifactStore.indexedRecordsForEntries([entry]);
    final ready = <int>{};
    final missing = <int>[];
    for (var i = 0; i < total; i++) {
      final page = manifest.pages[i];
      final id = _downloadId(manifest, page);
      final rec = indexedRecords[id.key];
      if (rec != null && artifactStore._isVerifiedReadyRecord(rec)) {
        ready.add(i);
      } else {
        missing.add(i);
      }
    }
    if (missing.isEmpty) {
      return ready;
    }
    final readyIndex = await _DurableReadyRecordIndex.build(
      indexedRecords.values,
      isReady: artifactStore._isVerifiedReadyRecord,
    );
    final predecessorBindingLookups = <String, Future<Map<int, String>>>{};
    for (final i in missing) {
      final page = manifest.pages[i];
      final id = _downloadId(manifest, page);
      final reusable = await _resolveReusablePageRecord(
        entry: entry,
        page: page,
        pageIndex: i,
        targetId: id,
        readyIndex: readyIndex,
        predecessorBindingLookups: predecessorBindingLookups,
      );
      if (reusable != null) ready.add(i);
    }
    return ready;
  }

  @override
  Future<bool> hasReadyPage(ImportedLibraryEntry entry, int pageIndex) async {
    _requireOpen();
    final manifest = entry.chapter.toManifest();
    if (pageIndex < 0 || pageIndex >= manifest.pages.length) return false;
    final page = manifest.pages[pageIndex];
    final id = _downloadId(manifest, page);
    final direct = await artifactStore.openArtifactStream(id);
    return direct != null;
  }

  @override
  Future<Uint8List> readPage(ImportedLibraryEntry entry, int pageIndex) async {
    _requireOpen();
    final manifest = entry.chapter.toManifest();
    if (pageIndex < 0 || pageIndex >= manifest.pages.length) {
      throw RangeError.index(pageIndex, manifest.pages, 'pageIndex');
    }
    final page = manifest.pages[pageIndex];
    final id = _downloadId(manifest, page);
    return artifactStore.readPromoted(id);
  }

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) =>
      artifactStore.openArtifactStream(id);

  @override
  Future<PartialDownloadMetadata?> inspectPartialDownloadMetadata(
    DownloadId id,
  ) => artifactStore.inspectPartialDownloadMetadata(id);

  @override
  Future<PartialDownloadEntry?> openPhysicalPartialDownload({
    required PhysicalMediaId physicalId,
    required DownloadId requestId,
  }) => artifactStore.openPhysicalPartialDownload(
    physicalId: physicalId,
    requestId: requestId,
  );

  @override
  Future<void> storePhysicalPartialDownload({
    required PhysicalMediaId physicalId,
    required DownloadId providerHint,
    required PartialDownloadEntry entry,
    bool preferDirectStaging = false,
  }) => artifactStore.storePhysicalPartialDownload(
    physicalId: physicalId,
    providerHint: providerHint,
    entry: entry,
    preferDirectStaging: preferDirectStaging,
  );

  @override
  Future<void> invalidatePhysicalPartialDownload(PhysicalMediaId physicalId) =>
      artifactStore.invalidatePhysicalPartialDownload(physicalId);

  @override
  Future<PartialDownloadEntry?> openPartialDownload(DownloadId id) =>
      artifactStore.openPartialDownload(id);

  @override
  Future<void> storePartialDownload({
    required DownloadId id,
    required PartialDownloadEntry entry,
  }) => artifactStore.storePartialDownload(id: id, entry: entry);

  @override
  Future<void> invalidatePartialDownload(DownloadId id) =>
      artifactStore.invalidatePartialDownload(id);

  @override
  Future<bool> bindExistingArtifact({
    required DownloadId sourceId,
    required DownloadId targetId,
  }) => artifactStore.bindExistingArtifact(
        sourceId: sourceId,
        targetId: targetId,
      );

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) => artifactStore.storePromotedArtifact(id: id, bytes: bytes);

  @override
  Future<void> invalidateArtifact(DownloadId id) =>
      artifactStore.invalidateArtifact(id);

  @override
  Future<ArtifactCacheUsage> inspectArtifacts() =>
      artifactStore.inspectArtifacts();

  @override
  Future<ArtifactCacheReport> trimArtifacts({
    required int maxBytes,
    required int targetBytes,
  }) async {
    final report = await artifactStore.trimArtifacts(
      maxBytes: maxBytes,
      targetBytes: targetBytes,
    );
    _forgetDerivedCompletePhases();
    return report;
  }

  @override
  Future<ArtifactCacheReport> clearArtifacts() async {
    final report = await artifactStore.clearArtifacts();
    _forgetDerivedCompletePhases();
    return report;
  }

  void _forgetDerivedCompletePhases() {
    _terminalPhases.removeWhere(
      (_, phase) => phase == ChapterDownloadPhase.complete,
    );
  }

  @override
  Future<void> close() async {
    if (!_closed) {
      _closed = true;
      _resourceAccess = null;
      await _artifactManagementProjectionSubscription?.cancel();
      _artifactManagementProjectionSubscription = null;
      for (final token in _tokens.values) {
        token.cancel();
      }
      for (final token in _auditTokens.values) {
        token.cancel();
      }
      for (final run in _runs.values.toList(growable: false)) {
        try {
          await run;
        } on Object {
          // Closing discards task failures after cancellation.
        }
      }
      for (final run in _auditRuns.values.toList(growable: false)) {
        try {
          await run;
        } on Object {
          // Closing discards audit failures after cancellation.
        }
      }
      for (final consumer in _commandConsumers.values.toList(growable: false)) {
        await consumer.dispose();
      }
      _commandConsumers.clear();
      _deletedIdentities.clear();
      _transport.close(force: true);
      await _changes.close();
      await _downloadExecutionChanges.close();
      await _managementProjectionChanges.close();
    }
    if (_ownsTransferComposition && !_ownedTransferCompositionDisposed) {
      if (transferRuntime.hasConsumers) {
        throw StateError(
          'cannot close owned download composition with active transfer consumers',
        );
      }
      await transferRuntime.dispose();
      await artifactStore.close();
      _ownedTransferCompositionDisposed = true;
    }
  }

  void _emit(ChapterDownloadSnapshot snapshot) {
    if (!_changes.isClosed) {
      _changes.add(snapshot);
    }
  }

  DownloadId _downloadId(ChapterManifest manifest, PageAsset page) =>
      DownloadId(
        content: ContentId(
          sourceId: manifest.sourceId,
          comicId: manifest.comicId,
          chapterId: page.chapterId,
          pageId: page.pageId,
        ),
        sourceRevision: manifest.chapter.sourceRevision,
        canonicalUri: page.uri,
        pageIndexHint: page.index,
      );

  void _requireOpen() {
    if (_closed) {
      throw StateError('chapter download service is closed');
    }
  }
}

// Immediate cache/SQLite Futures only yield microtasks. A large management
// projection or canonical cache backfill must also let platform reads, UI
// frames and other event work run.
// This bounds computation, not transport admission or Reader eligibility.
final class _DownloadProjectionWorkBudget {
  final Stopwatch _watch = Stopwatch()..start();
  int _units = 0;

  bool get exhausted => ++_units >= 64 || _watch.elapsedMicroseconds >= 4000;

  Future<void> yieldTurn() async {
    await Future<void>.delayed(Duration.zero);
    _units = 0;
    _watch.reset();
  }
}

final class _DurableReadyRecordIndex {
  _DurableReadyRecordIndex._();

  static Future<_DurableReadyRecordIndex> build(
    Iterable<CacheRec> records, {
    required bool Function(CacheRec record) isReady,
    _DownloadProjectionWorkBudget? workBudget,
  }) async {
    final index = _DurableReadyRecordIndex._();
    final budget = workBudget ?? _DownloadProjectionWorkBudget();
    for (final record in records) {
      if (budget.exhausted) await budget.yieldTurn();
      if (!isReady(record)) continue;
      final content = record.id.content;
      for (final identity in verifiedRecordIdentities(record)) {
        index._byVerifiedIdentity
            .putIfAbsent(
              '${content.sourceId}\u0000$identity',
              () => <CacheRec>[],
            )
            .add(record);
      }
      final logicalKey = _logicalPageKey(
        sourceId: content.sourceId,
        comicId: content.comicId,
        chapterId: content.chapterId,
        sourceRevision: record.id.sourceRevision,
        pageId: content.pageId,
      );
      final existing = index._byLogicalPage[logicalKey];
      if (existing == null) {
        if (!index._ambiguousLogicalPages.contains(logicalKey)) {
          index._byLogicalPage[logicalKey] = record;
        }
      } else if (existing.id != record.id) {
        index._byLogicalPage.remove(logicalKey);
        index._ambiguousLogicalPages.add(logicalKey);
      }
    }
    for (final candidates in index._byVerifiedIdentity.values) {
      if (budget.exhausted) await budget.yieldTurn();
      candidates.sort(
        (left, right) => right.createdUs.compareTo(left.createdUs),
      );
    }
    return index;
  }

  final Map<String, List<CacheRec>> _byVerifiedIdentity =
      <String, List<CacheRec>>{};
  final Map<String, CacheRec> _byLogicalPage = <String, CacheRec>{};
  final Set<String> _ambiguousLogicalPages = <String>{};

  CacheRec? byVerifiedIdentity({
    required String sourceId,
    required String identity,
    required String excludingKey,
  }) {
    final candidates = _byVerifiedIdentity['$sourceId\u0000$identity'];
    if (candidates == null) return null;
    for (final candidate in candidates) {
      if (candidate.id.key != excludingKey) return candidate;
    }
    return null;
  }

  CacheRec? byLogicalPage({
    required String sourceId,
    required String comicId,
    required String chapterId,
    required String sourceRevision,
    required String pageId,
  }) {
    final key = _logicalPageKey(
      sourceId: sourceId,
      comicId: comicId,
      chapterId: chapterId,
      sourceRevision: sourceRevision,
      pageId: pageId,
    );
    if (_ambiguousLogicalPages.contains(key)) return null;
    return _byLogicalPage[key];
  }

  static String _logicalPageKey({
    required String sourceId,
    required String comicId,
    required String chapterId,
    required String sourceRevision,
    required String pageId,
  }) =>
      '$sourceId\u0000$comicId\u0000$chapterId\u0000$sourceRevision\u0000$pageId';
}

final class _ChapterProgressPublisher {
  _ChapterProgressPublisher(this._publish);

  static const Duration _minimumInterval = Duration(milliseconds: 80);

  final Future<void> Function() _publish;
  Future<void>? _active;
  bool _dirty = false;
  bool _force = false;
  bool _closed = false;
  DateTime? _lastPublished;

  void schedule() {
    if (_closed) return;
    _dirty = true;
    _active ??= _drain();
  }

  Future<void> flush() async {
    if (_closed) return;
    _force = true;
    schedule();
    while (true) {
      final active = _active;
      if (active == null) return;
      await active;
    }
  }

  Future<void> _drain() async {
    try {
      while (_dirty && !_closed) {
        _dirty = false;
        final force = _force;
        _force = false;
        final last = _lastPublished;
        if (!force && last != null) {
          final remaining = _minimumInterval - DateTime.now().difference(last);
          if (remaining > Duration.zero) {
            await Future<void>.delayed(remaining);
          }
        }
        if (_closed) return;
        try {
          await _publish();
        } on Object {
          // Progress is a projection. A transient index/UI read must not fail
          // the authoritative DownloadSession writer or discard valid bytes.
        }
        _lastPublished = DateTime.now();
      }
    } finally {
      _active = null;
      if (_dirty && !_closed) {
        schedule();
      }
    }
  }

  void close() {
    _closed = true;
    _dirty = false;
  }
}
