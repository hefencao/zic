part of 'chapter_downloads.dart';

extension _PersistentDownloadCacheAdoption on PersistentChapterDownloadService {
  bool _isCurrentDownloadCacheChapter(CacheBindingScope scope) {
    // These are resolved manual-head relations, not discovery/cache history.
    // Match the manager's chapter folding; unmapped chapters remain exact.
    for (final relation in artifactStore._downloadHeadRelations) {
      if (relation.sourceId != scope.sourceId || relation.predecessorComicId != scope.comicId ||
          relation.successorComicId == scope.comicId) continue;
      if (relation.pageMappings.isEmpty || relation.pageMappings.any((mapping) =>
          mapping.predecessorChapterId == scope.chapterId)) return false;
    }
    return true;
  }

  ({CanonicalMediaChapterAuthority authority, List<ComicVersionRelation> relations})
      _downloadCacheAuthority(ImportedLibraryEntry entry,
        VersionChapterCanonicalProjection? projection) {
    final relations = _cacheVersionRelations;
    final manifest = entry.chapter.toManifest();
    final key = canonicalMediaExactChapterKey(sourceId: manifest.sourceId,
      comicId: manifest.comicId, chapterId: manifest.chapter.chapterId,
      sourceRevision: manifest.chapter.sourceRevision);
    final ranges = canonicalMediaActiveRangesFromRelations(relations)[key] ?? const [];
    return (authority: CanonicalMediaChapterAuthority(manifest: manifest,
      projection: projection,
      activeProjectionRanges: ranges.where((range) => range.endExclusive <= manifest.pages.length)),
      relations: relations);
  }

  ({PhysicalMediaArtifactRecord? artifact, PhysicalPartialRecord? partial})?
      _downloadCachePhysicalPage(_DownloadManagementPhysicalState state,
        ({CanonicalMediaChapterAuthority authority, List<ComicVersionRelation> relations}) proof,
        DownloadId id) {
    // Inventory visibility is not reuse authority. Follow the same live
    // manifest/range or strong-identity proof as the transfer owner.
    final runtimeId = transferRuntime.physicalMediaIdFor(id);
    final physicalId = runtimeId.isExactFallback
        ? (identical(proof.relations, _cacheVersionRelations) ? proof.authority.resolve(id) : null)
        : runtimeId;
    if (physicalId == null) return null;
    final artifact = state.artifacts[physicalId];
    final partial = artifact == null ? state.partials[physicalId] : null;
    return artifact == null && partial == null ? null : (artifact: artifact, partial: partial);
  }

  void _scheduleDownloadCacheAdoption({Duration delay = const Duration(milliseconds: 120)}) {
    if (_closed || _summaryChapterLookup == null) return;
    if (_downloadCacheAdoption != null) {
      _downloadCacheAdoptionDirty = true;
      return;
    }
    if (_downloadCacheAdoptionTimer != null) return;
    _downloadCacheAdoptionTimer = Timer(delay, () {
      _downloadCacheAdoptionTimer = null;
      if (_closed) return;
      unawaited(_adoptDownloadCache(const []).then<void>((_) {}).catchError((Object error, StackTrace stack) {
        _recordCommandTrace('download-management', 'chapter-cache-adoption-failed',
          <String, Object?>{'error': error.toString()});
      }));
    });
  }

  Future<bool> _adoptDownloadCache(List<ImportedLibraryEntry> known, {
    _DownloadManagementPhysicalState? physicalState,
    Map<String, CacheRec>? indexedRecords,
  }) {
    final active = _downloadCacheAdoption;
    if (active != null) {
      if (physicalState == null) return active;
      return active.then((changed) async =>
        await _adoptDownloadCache(known, physicalState: physicalState) || changed);
    }
    if (_closed) return Future<bool>.value(false);
    _downloadCacheAdoptionTimer?.cancel();
    _downloadCacheAdoptionTimer = null;
    _downloadCacheAdoptionDirty = false;
    late final Future<bool> run;
    run = _adoptDownloadCacheOnce(known, physicalState: physicalState,
        indexedRecords: indexedRecords).whenComplete(() {
      if (identical(_downloadCacheAdoption, run)) {
        _downloadCacheAdoption = null;
        if (_downloadCacheAdoptionDirty) _scheduleDownloadCacheAdoption();
      }
    });
    _downloadCacheAdoption = run;
    return run;
  }

  Future<bool> _adoptDownloadCacheOnce(List<ImportedLibraryEntry> known, {
    _DownloadManagementPhysicalState? physicalState,
    Map<String, CacheRec>? indexedRecords,
  }) async {
    if (physicalState == null && _cacheOnlyRuns.isNotEmpty) return false;
    // The index selects only exact chapters with actual download ownership and
    // unpinned bytes or retained physical READY bodies. No version traversal,
    // source request or page fetch.
    final index = artifactStore._index;
    final candidates = <String, CacheBindingScope>{};
    void addScope(CacheBindingScope scope) {
      if (!_isCurrentDownloadCacheChapter(scope)) return;
      candidates[chapterDownloadIdentity(scope.sourceId, scope.comicId,
          scope.chapterId!, scope.sourceRevision!)] = scope;
    }
    for (final scope in await index.readDownloadCacheAdoptionScopes()) {
      addScope(scope);
    }
    // Manager prewarm already has physical inventory. Intersect it only with
    // actual manual owners; do not hydrate every version to find canonical bytes.
    if (physicalState != null) {
      for (final scope in await index.readDownloadCacheOwnershipScopes()) {
        final key = canonicalMediaExactChapterKey(sourceId: scope.sourceId,
          comicId: scope.comicId, chapterId: scope.chapterId!, sourceRevision: scope.sourceRevision!);
        final projection = physicalState.projections[key];
        if (projection != null &&
            physicalState.materializedPageIndicesFor(projection).isNotEmpty) addScope(scope);
      }
    }
    var changed = false;
    final workBudget = _DownloadProjectionWorkBudget();
    for (final scope in candidates.values) {
      if (workBudget.exhausted) await workBudget.yieldTurn();
      if (_closed) return changed;
      final identity = chapterDownloadIdentity(scope.sourceId, scope.comicId,
          scope.chapterId!, scope.sourceRevision!);
      if (!_isCurrentDownloadCacheChapter(scope) ||
          _runs.containsKey(identity) || _deletedIdentities.contains(identity) ||
          _cacheAdoptionRetryRequired.contains(identity)) continue;
      ImportedLibraryEntry? entry;
      for (final candidate in known) {
        if (_identity(candidate) == identity &&
            !candidate.chapter.directoryId.startsWith('orphaned:')) {
          entry = candidate;
          break;
        }
      }
      if (entry == null || _isCompactProjectionEntry(entry)) {
        entry = await _summaryChapterLookup?.call(scope.sourceId, scope.chapterId!);
      }
      if (_closed) return changed;
      if (entry == null || _isCompactProjectionEntry(entry) ||
          entry.chapter.directoryId.startsWith('orphaned:') ||
          _identity(entry) != identity || _deletedIdentities.contains(identity) ||
          !_isCurrentDownloadCacheChapter(scope)) continue;
      final records = indexedRecords ?? await artifactStore.indexedRecordsForEntries([entry]);
      final retainedPhysical = await index.readRetainedPhysicalCacheKeys();
      final resident = physicalState ?? await _loadTargetedPhysicalState([entry]);
      final projection = resident.projectionFor(entry);
      final manifest = entry.chapter.toManifest();
      final physicalProof = _downloadCacheAuthority(entry, projection);
      var pending = false;
      final physicalKeys = <String>{};
      for (var i = 0; i < manifest.pages.length; i++) {
        if (workBudget.exhausted) await workBudget.yieldTurn();
        final page = manifest.pages[i];
        final record = records[_downloadId(manifest, page).key];
        if (record != null && artifactStore._isVerifiedReadyRecord(record)) {
          if (!record.pinned) pending = true;
          // A redundant physical partial does not create new download work
          // when this exact page is already durably complete.
          continue;
        }
        if (record?.state == CacheState.partial && record!.bytes > 0 &&
            !await index.isExactCacheRetained(record.key)) {
          pending = true;
        }
        final physical = _downloadCachePhysicalPage(resident, physicalProof,
          _downloadId(manifest, page));
        final physicalId = physical?.artifact?.id ?? physical?.partial?.id;
        if (physicalId != null) {
          // Admission can precede another chapter's export. A held READY body
          // still needs materialization; a held partial only needs protection.
          if (physical?.artifact != null &&
              (record == null || record.state == CacheState.ready)) pending = true;
          if (!retainedPhysical.contains(physicalId.key)) {
            pending = true;
            physicalKeys.add(physicalId.key);
          }
        }
      }
      if (pending && !await index.hasDownloadCacheOwnership(scope)) pending = false;
      if (_closed) return changed;
      if (!pending || !_isCurrentDownloadCacheChapter(scope) ||
          _runs.containsKey(identity) || _deletedIdentities.contains(identity)) continue;
      final hadIntent = await index.hasDownloadCacheIntent(scope);
      if (_closed) return changed;
      if (_deletedIdentities.contains(identity) || !_isCurrentDownloadCacheChapter(scope)) continue;
      await index.retainDownloadCache(sourceId: scope.sourceId, comicId: scope.comicId,
        chapterId: scope.chapterId!, sourceRevision: scope.sourceRevision!);
      for (final key in physicalKeys) {
        await index.retainDownloadCache(sourceId: scope.sourceId, comicId: scope.comicId,
          chapterId: scope.chapterId!, sourceRevision: scope.sourceRevision!, physicalKey: key);
      }
      changed = changed || !hadIntent || physicalKeys.isNotEmpty;
      if (_closed) return changed;
      if (_cacheOnlyRuns.isEmpty && !_runs.containsKey(identity) &&
          !_deletedIdentities.contains(identity) && _isCurrentDownloadCacheChapter(scope)) {
        // Admit ownership before projecting cache inventory. Export runs in
        // the existing owner, one local chapter at a time; the UI never waits
        // for its bytes, and missing pages never publish transport demands.
        unawaited(_startDownload(entry, cacheOnly: true).catchError((Object error, StackTrace stack) {
          _cacheAdoptionRetryRequired.add(identity);
          _recordCommandTrace(identity, 'chapter-cache-adoption-failed',
            <String, Object?>{'error': error.toString()});
        }));
      }
    }
    return changed;
  }
}
