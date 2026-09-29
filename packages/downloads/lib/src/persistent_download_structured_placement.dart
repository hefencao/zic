part of 'chapter_downloads.dart';

mixin _PersistentDownloadStructuredPlacementMixin {
  SqliteIndex get _index;
  DownloadRegistry get _registry;
  TraceSink get _traceSink;
  MonoClock get _clock;
  List<ComicVersionRelation> get _downloadHeadRelations;
  SafTreeIo? get safTreeIo;
  String? get safTreeUri;
  CacheLayout get layout;

  CacheLayout layoutFor(DownloadId id);
  CacheLayout layoutForSource(String sourceId);
  CacheLayout _layoutForEntryPage(ImportedLibraryEntry entry, int pageIndex);
  String storageRootIdFor(ImportedLibraryEntry entry);
  Future<StorageCleanupDebtRecord> _registerTemporaryCleanupDebt(
    String accessLocator, {
    required String storageRootId,
  });
  Future<void> _forgetStorageCleanupDebt(String accessLocator);
  Future<void> _writeBytesToSafTracked(
    SafTreeIo io,
    String relativePath,
    Uint8List bytes,
  );
  ArtifactBytes get _bytes;
  bool _isVerifiedReadyRecord(CacheRec record);
  String _storageRootIdForPath(String path, {DownloadId? id});
  Future<({int bytes, String checksum})> _artifactProof(String path);
  bool _proofMatchesRecord(
    ({int bytes, String checksum}) proof,
    CacheRec record,
  );
  Future<Uint8List> _readArtifactBytes(String path);
  Future<Map<String, CacheRec>> indexedRecords();
  Future<ArtifactReplicaMigrationResult> migrateArtifactReplica({
    required DownloadId id,
    required String replicaId,
    required String destinationAccessLocator,
    required String destinationStorageRootId,
    TaskControl? control,
  });
  Future<T> _withStorageWriteQuantum<T>(
    Future<T> Function() operation, {
    TaskControl? control,
  });
  Future<T> _commitAuthoritySwitchWithObsoleteSealedCleanup<T>({
    required String oldAccessLocator,
    required String oldStorageRootId,
    required int expectedBytes,
    required String expectedChecksum,
    required String expectedChecksumAlgorithm,
    required Future<T> Function() commit,
  });
  Future<T> _serializeArtifactMutation<T>(
    DownloadId id,
    Future<T> Function() operation,
  );
  void _requireOpen();

  final Map<String, Future<void>> _structuredWriteTails =
      <String, Future<void>>{};
  final Map<String, String> _structuredDirectoriesByOwner = <String, String>{};
  final Map<String, String> _structuredOwnersByDirectory = <String, String>{};
  final Map<String, DownloadPlacement> _claimedPlacementsByOwner =
      <String, DownloadPlacement>{};
  final Set<String> _sessionPlacementClaims = <String>{};
  bool _placementClaimsLoaded = false;
  final Map<String, Future<void>> _placementWrites = <String, Future<void>>{};

  /// Migrates user-materialized direct-root artifacts without moving mutable
  /// transfer spools or automatic-cache-only replicas.
  ///
  /// Each sealed replica uses the schema-9 migration protocol: destination
  /// bytes are verified before authority moves and source cleanup happens only
  /// afterwards. Placement and manifest roots are switched only after every
  /// selected replica has committed, so a failed attempt remains resumable
  /// from the persisted pending root intent instead of exposing half-rewritten
  /// metadata.
  Future<({int replicas, int placements})> migrateStructuredDirectRoot({
    required String sourceRoot,
    required String destinationRoot,
    TaskControl? control,
  }) async {
    _requireOpen();
    final rawSource = sourceRoot.trim();
    final rawDestination = destinationRoot.trim();
    if (rawSource.startsWith('saf://') ||
        rawDestination.startsWith('saf://')) {
      throw const Failure(
        code: ErrorCode.policy,
        message: 'structured direct-root migration requires direct roots',
      );
    }
    final source = Directory(rawSource).absolute.path;
    final destination = Directory(rawDestination).absolute.path;
    if (source == destination) return (replicas: 0, placements: 0);

    String? relativeTo(String root, String path) {
      final separator = Platform.pathSeparator;
      final prefix = root.endsWith(separator) ? root : '$root$separator';
      if (path == root) return '';
      if (!path.startsWith(prefix)) return null;
      return path.substring(prefix.length);
    }

    String atDestination(String relative) {
      if (relative.isEmpty) return destination;
      return '$destination${Platform.pathSeparator}$relative';
    }

    void rejectDestinationLinks(String path) {
      var current = File(path).absolute.path;
      while (true) {
        if (FileSystemEntity.typeSync(current, followLinks: false) ==
            FileSystemEntityType.link) {
          throw const Failure(
            code: ErrorCode.artifactCorruption,
            message: 'root migration destination contains a symbolic link',
          );
        }
        if (current == destination) break;
        final parent = Directory(current).parent.path;
        if (parent == current || !parent.startsWith(destination)) break;
        current = parent;
      }
    }

    final selected = <
        String,
        ({
          CacheRec record,
          ArtifactReplicaRecord replica,
          String destination,
        })>{};
    final sourcePlacementOwners = <String>{};
    for (final record in await _index.list(state: CacheState.ready)) {
      control?.throwIfCancelled();
      if (!record.pinned || !_isVerifiedReadyRecord(record)) continue;
      final recordRelative = relativeTo(source, record.path);
      if (recordRelative == null) continue;
      final replicas = await _index.listArtifactReplicas(
        record.effectiveArtifactId,
      );
      final primary = replicas
          .where((value) => value.replicaId == record.effectiveArtifactId)
          .firstOrNull;
      if (primary == null) {
        throw const Failure(
          code: ErrorCode.policy,
          message: 'manual artifact has no primary replica authority',
        );
      }
      final replicaRelative = relativeTo(source, primary.accessLocator);
      if (replicaRelative == null || replicaRelative != recordRelative) {
        throw const Failure(
          code: ErrorCode.policy,
          message: 'manual artifact replica disagrees with its direct root',
        );
      }
      selected.putIfAbsent(
        primary.replicaId,
        () => (
          record: record,
          replica: primary,
          destination: atDestination(replicaRelative),
        ),
      );
      sourcePlacementOwners.add(
        '${record.id.content.sourceId}\u0000${record.id.content.comicId}',
      );
    }

    final placements = (await _index.listPlacements())
        .where(
          (placement) =>
              placement.storageRootId == source ||
              (placement.storageRootId == 'default' &&
                  sourcePlacementOwners.contains(placement.ownerKey)),
        )
        .toList(growable: false);

    // Deterministic destination conflicts are rejected before any authority
    // move. Runtime I/O failures after this point are safe because every
    // replica migration is independently durable and resumable.
    for (final candidate in selected.values) {
      control?.throwIfCancelled();
      final file = File(candidate.destination);
      if (!await file.exists()) continue;
      final proof = await _artifactProof(candidate.destination);
      if (!_proofMatchesRecord(proof, candidate.record)) {
        throw Failure(
          code: ErrorCode.policy,
          message:
              'root migration destination contains different bytes: '
              '${candidate.destination}',
        );
      }
    }
    for (final placement in placements) {
      final relativeDirectory = _requireSafeComicDirectoryName(
        placement.relativeDirectory,
      );
      final sourceManifest = File(
        '$source${Platform.pathSeparator}$relativeDirectory'
        '${Platform.pathSeparator}$comicManifestFileName',
      );
      final sourceType = await FileSystemEntity.type(
        sourceManifest.path,
        followLinks: false,
      );
      if (sourceType == FileSystemEntityType.notFound) continue;
      if (sourceType != FileSystemEntityType.file) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'root migration source manifest is not a regular file',
        );
      }
      final destinationManifest = File(
        '$destination${Platform.pathSeparator}$relativeDirectory'
        '${Platform.pathSeparator}$comicManifestFileName',
      );
      final destinationType = await FileSystemEntity.type(
        destinationManifest.path,
        followLinks: false,
      );
      if (destinationType == FileSystemEntityType.notFound) continue;
      if (destinationType != FileSystemEntityType.file) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'root migration destination manifest is not a regular file',
        );
      }
      final sourceBytes = await sourceManifest.readAsBytes();
      final destinationBytes = await destinationManifest.readAsBytes();
      if (!_bytesEqual(sourceBytes, destinationBytes)) {
        throw Failure(
          code: ErrorCode.policy,
          message:
              'root migration destination contains a different comic manifest: '
              '${placement.relativeDirectory}',
        );
      }
    }

    var migratedReplicas = 0;
    for (final candidate in selected.values) {
      control?.throwIfCancelled();
      await migrateArtifactReplica(
        id: candidate.record.id,
        replicaId: candidate.replica.replicaId,
        destinationAccessLocator: candidate.destination,
        destinationStorageRootId: destination,
        control: control,
      );
      migratedReplicas++;
    }

    for (final placement in placements) {
      control?.throwIfCancelled();
      final relativeDirectory = _requireSafeComicDirectoryName(
        placement.relativeDirectory,
      );
      final sourceManifest = File(
        '$source${Platform.pathSeparator}$relativeDirectory'
        '${Platform.pathSeparator}$comicManifestFileName',
      );
      if (await sourceManifest.exists()) {
        final destinationManifest = File(
          '$destination${Platform.pathSeparator}$relativeDirectory'
          '${Platform.pathSeparator}$comicManifestFileName',
        );
        if (!await destinationManifest.exists()) {
          await _withStorageWriteQuantum(() async {
            rejectDestinationLinks(destinationManifest.path);
            await destinationManifest.parent.create(recursive: true);
          }, control: control);
          final temporary = File(
            '${destinationManifest.path}.zic-tmp-'
            '${DateTime.now().microsecondsSinceEpoch}',
          );
          await _registerTemporaryCleanupDebt(
            temporary.path,
            storageRootId: destination,
          );
          try {
            final sourceBytes = await sourceManifest.readAsBytes();
            await _withStorageWriteQuantum(
              () => temporary.writeAsBytes(sourceBytes, flush: true),
              control: control,
            );
            final temporaryBytes = await temporary.readAsBytes();
            if (!_bytesEqual(sourceBytes, temporaryBytes)) {
              throw const Failure(
                code: ErrorCode.artifactCorruption,
                message: 'root migration manifest copy failed verification',
              );
            }
            await _withStorageWriteQuantum(
              () => temporary.rename(destinationManifest.path),
              control: control,
            );
          } finally {
            if (await temporary.exists()) {
              await _withStorageWriteQuantum(
                temporary.delete,
                control: control,
              );
            }
            if (!await temporary.exists()) {
              await _forgetStorageCleanupDebt(temporary.path);
            }
          }
        }
      }
    }

    final now = DateTime.now().toUtc();
    for (final placement in placements) {
      control?.throwIfCancelled();
      await _index.putPlacement(
        placement.copyWith(
          storageRootId: destination,
          generation: placement.generation + 1,
          updatedAt: now,
        ),
      );
      // This source manifest stops being ownership only after its placement
      // commit. Cleanup is deliberately best-effort and must never roll back
      // the destination placement/replica authority.
      final relativeDirectory = _requireSafeComicDirectoryName(
        placement.relativeDirectory,
      );
      final sourceManifest = File(
        '$source${Platform.pathSeparator}$relativeDirectory'
        '${Platform.pathSeparator}$comicManifestFileName',
      );
      if (!await sourceManifest.exists()) continue;
      try {
        await _withStorageWriteQuantum(sourceManifest.delete, control: control);
      } on Object {
        // Stale source metadata is harmless after the placement commit.
      }
    }
    return (replicas: migratedReplicas, placements: placements.length);
  }

  bool _bytesEqual(List<int> first, List<int> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }

  Future<T> _serializeStructuredWrite<T>(
    String path,
    Future<T> Function() operation,
  ) {
    final previous = _structuredWriteTails[path] ?? Future<void>.value();
    final current = previous.then<T>(
      (_) => operation(),
      onError: (Object _, StackTrace __) => operation(),
    );
    late final Future<void> tail;
    tail = current.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _structuredWriteTails[path] = tail;
    return current.whenComplete(() {
      if (identical(_structuredWriteTails[path], tail)) {
        _structuredWriteTails.remove(path);
      }
    });
  }

  Future<T> _withStructuredManifestLock<T>(
    ImportedLibraryEntry entry,
    String comicDirectoryName,
    Future<T> Function() operation,
  ) async {
    final safIo = safTreeIo;
    if (safIo != null && safTreeUri != null) return operation();
    final root = entry.chapter.pages.isEmpty
        ? layout.root
        : _layoutForEntryPage(entry, 0).root;
    final lock = File('$root/$comicDirectoryName/.zic.lock');
    _rejectLocalPathLinks(lock.path);
    await lock.parent.create(recursive: true);
    final handle = await lock.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
      try {
        return await operation();
      } finally {
        await handle.unlock();
      }
    } finally {
      await handle.close();
    }
  }

  Future<T> _withStructuredPlacementAllocationLock<T>(
    String rootId,
    Future<T> Function() operation,
  ) async {
    final safIo = safTreeIo;
    if (safIo != null && safTreeUri != null) return operation();
    final lock = File('$rootId${Platform.pathSeparator}.zic-placement.lock');
    _rejectLocalPathLinks(lock.path);
    await lock.parent.create(recursive: true);
    final handle = await lock.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
      try {
        return await operation();
      } finally {
        await handle.unlock();
      }
    } finally {
      await handle.close();
    }
  }

  String? _extractComicDirNameFromRecordPath(
    String path, {
    DownloadId? id,
    String? storageRootId,
  }) {
    if (path.startsWith('saf:')) {
      final parsed = parseSafRecordPath(path);
      if (parsed == null ||
          (safTreeUri != null && parsed.treeUri != safTreeUri)) {
        return null;
      }
      final segments = parsed.relativePath.split('/');
      if (segments.isNotEmpty &&
          segments.first.isNotEmpty &&
          !segments.first.startsWith('.') &&
          segments.first != 'final' &&
          segments.first != 'partial') {
        return segments.first;
      }
      return null;
    }
    final root =
        storageRootId != null &&
            storageRootId.isNotEmpty &&
            storageRootId != 'default'
        ? storageRootId
        : id == null
            ? layout.root
            : layoutFor(id).root;
    if (path.startsWith('$root/')) {
      final rel = path.substring(root.length + 1);
      final segments = rel.split('/');
      if (segments.isNotEmpty &&
          segments.first.isNotEmpty &&
          !segments.first.startsWith('.') &&
          segments.first != 'final' &&
          segments.first != 'partial') {
        return segments.first;
      }
    }
    return null;
  }

  String _structuredDirectoryKey(String rootId, String directory) =>
      '$rootId\u0000$directory';

  void _rememberPlacementClaim(DownloadPlacement placement) {
    final directory = placement.relativeDirectory.trim();
    if (!_isSafeComicDirectoryName(directory)) return;
    final rootId = placement.storageRootId == 'default'
        ? layout.root
        : placement.storageRootId;
    final key = _structuredDirectoryKey(rootId, directory);
    final previous = _structuredOwnersByDirectory[key];
    if (previous == null || previous == placement.ownerKey) {
      _structuredOwnersByDirectory[key] = placement.ownerKey;
    } else {
      _structuredOwnersByDirectory[key] = '\u0000conflicting-placement';
    }
  }

  Future<void> _refreshPersistedPlacementClaims() async {
    final pendingWrites = _placementWrites.values.toList(growable: false);
    if (pendingWrites.isNotEmpty) {
      await Future.wait<void>(pendingWrites);
    }
    // Rebuild rather than only adding rows. Placements can be removed after a
    // chapter/comic delete, and retaining the old in-memory directory claim
    // would make a later owner look like a collision until process restart.
    _claimedPlacementsByOwner.clear();
    _structuredDirectoriesByOwner.clear();
    _structuredOwnersByDirectory.clear();
    for (final placement in await _index.listPlacements()) {
      final owner = placement.ownerKey;
      final directory = placement.relativeDirectory.trim();
      if (!_isSafeComicDirectoryName(directory)) continue;
      _claimedPlacementsByOwner[owner] = placement;
      _structuredDirectoriesByOwner[owner] = directory;
      _rememberPlacementClaim(placement);
    }
  }

  Future<void> _loadPersistedPlacementClaims() async {
    if (_placementClaimsLoaded) return;
    await _refreshPersistedPlacementClaims();
    _placementClaimsLoaded = true;
  }

  Future<T> _withStructuredDirectoryLock<T>(
    String rootId,
    String directory,
    Future<T> Function() operation,
  ) async {
    if (safTreeIo != null && safTreeUri != null) return operation();
    final lock = File(
      '$rootId${Platform.pathSeparator}$directory${Platform.pathSeparator}.zic.lock',
    );
    _rejectLocalPathLinks(lock.path);
    await lock.parent.create(recursive: true);
    final handle = await lock.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
      try {
        return await operation();
      } finally {
        await handle.unlock();
      }
    } finally {
      await handle.close();
    }
  }

  Future<DownloadPlacement> resolveDownloadPlacement(
    ImportedLibraryEntry entry, {
    DownloadPlacement? requestedPlacement,
    Iterable<CacheRec>? knownRecords,
  }) async {
    _requireOpen();
    await _loadPersistedPlacementClaims();
    final owner = '${entry.chapter.sourceId}\u0000${entry.chapter.comicId}';
    final currentRootId = storageRootIdFor(entry);
    final isSessionClaim = _sessionPlacementClaims.contains(owner);
    final activeClaim = _claimedPlacementsByOwner[owner];

    _traceSink.record(
      traceEvent(
        clock: _clock,
        sessionId: 'chapter-placement:${entry.chapter.sourceId}',
        kind: TraceEventKind.downloadState,
        identityHash: owner,
        payload: <String, Object?>{
          'stage': 'resolve-placement-start',
          'comicId': entry.chapter.comicId,
          'comicTitle': entry.chapter.comicTitle,
          'requestedPlacement': requestedPlacement?.relativeDirectory,
          'activeClaim': activeClaim?.relativeDirectory,
          'isSessionClaim': isSessionClaim,
        },
      ),
    );

    if (requestedPlacement != null) {
      final placement = requestedPlacement.copyWith(
        storageRootId: currentRootId,
        relativeDirectory: _requireSafeComicDirectoryName(
          requestedPlacement.relativeDirectory,
        ),
      );
      await _persistPlacement(placement);
      _claimedPlacementsByOwner[owner] = placement;
      _structuredDirectoriesByOwner[owner] = placement.relativeDirectory;
      _structuredOwnersByDirectory[_structuredDirectoryKey(
            currentRootId,
            placement.relativeDirectory,
          )] =
          owner;
      return placement;
    }

    if (activeClaim != null) {
      final directory = _requireSafeComicDirectoryName(
        activeClaim.relativeDirectory,
      );
      var effectiveClaim = activeClaim;
      if (effectiveClaim.pageOrder == ComicPageOrder.auto) {
        final diskManifest = await _readComicFolderManifest(
          directory,
          rootLayout: entry.chapter.pages.isEmpty
              ? layoutForSource(entry.chapter.sourceId)
              : _layoutForEntryPage(entry, 0),
        );
        if (diskManifest?.pageOrder != null &&
            diskManifest!.pageOrder != ComicPageOrder.auto) {
          effectiveClaim = effectiveClaim.copyWith(
            pageOrder: diskManifest.pageOrder,
          );
        }
      }
      final bindingChanged =
          activeClaim.storageRootId != currentRootId ||
          directory != activeClaim.relativeDirectory ||
          effectiveClaim.pageOrder != activeClaim.pageOrder;
      final normalized = bindingChanged
          ? effectiveClaim.copyWith(
              relativeDirectory: directory,
              storageRootId: currentRootId,
              generation: activeClaim.generation + 1,
              updatedAt: DateTime.now().toUtc(),
            )
          : effectiveClaim;
      if (bindingChanged) {
        await _persistPlacement(normalized);
      }
      _claimedPlacementsByOwner[owner] = normalized;
      _structuredDirectoriesByOwner[owner] = normalized.relativeDirectory;
      _structuredOwnersByDirectory[_structuredDirectoryKey(
            currentRootId,
            normalized.relativeDirectory,
          )] =
          owner;
      return normalized;
    }

    final allRecords =
        knownRecords?.toList(growable: false) ?? await _index.list();
    final hasRecords = allRecords.any(
      (r) =>
        r.id.content.sourceId == entry.chapter.sourceId &&
        r.id.content.comicId == entry.chapter.comicId &&
          r.bytes > 0,
    );

    if (hasRecords) {
      final legacyDirectories = <String>{};
      for (final record in allRecords) {
        final content = record.id.content;
        if (content.sourceId != entry.chapter.sourceId ||
            content.comicId != entry.chapter.comicId) {
          continue;
        }
        final directory = _extractComicDirNameFromRecordPath(
          record.path,
          id: record.id,
          storageRootId: record.storageRootId,
        );
        if (directory != null) legacyDirectories.add(directory);
      }
      _traceSink.record(
        traceEvent(
          clock: _clock,
          sessionId: 'chapter-placement:${entry.chapter.sourceId}',
          kind: TraceEventKind.downloadState,
          identityHash: owner,
          payload: <String, Object?>{
            'stage': 'resolve-placement-legacy-check',
            'comicId': entry.chapter.comicId,
            'hasRecords': hasRecords,
            'legacyDirectories': legacyDirectories.toList(),
          },
        ),
      );
      if (legacyDirectories.length == 1) {
        final directory = legacyDirectories.single;
        final root = entry.chapter.pages.isEmpty
            ? layout.root
            : _layoutForEntryPage(entry, 0).root;
        final isSaf = safTreeIo != null && safTreeUri != null;
        final dirExists = isSaf
            ? await safTreeIo!.exists(directory)
            : await Directory('$root/$directory').exists();
        if (dirExists) {
          final diskManifest = await _readComicFolderManifest(
            directory,
            rootLayout: entry.chapter.pages.isEmpty
                ? layoutForSource(entry.chapter.sourceId)
                : _layoutForEntryPage(entry, 0),
          );
          final effectivePageOrder =
              diskManifest?.pageOrder != null &&
                  diskManifest!.pageOrder != ComicPageOrder.auto
              ? diskManifest.pageOrder
              : ComicPageOrder.auto;
          final migrated = DownloadPlacement(
            placementId: owner,
            sourceId: entry.chapter.sourceId,
            comicId: entry.chapter.comicId,
            comicTitle: entry.chapter.comicTitle,
            mode: DownloadPlacementMode.incremental,
            relativeDirectory: _requireSafeComicDirectoryName(directory),
            storageRootId: currentRootId,
            pageOrder: effectivePageOrder,
            createdAt: DateTime.now().toUtc(),
            updatedAt: DateTime.now().toUtc(),
          );
          await _persistPlacement(migrated);
          _claimedPlacementsByOwner[owner] = migrated;
          _structuredDirectoriesByOwner[owner] = directory;
          _structuredOwnersByDirectory[_structuredDirectoryKey(
                currentRootId,
                directory,
              )] =
              owner;
          return migrated;
        }
      }
    }

    final base = buildComicDirectoryName(comicTitle: entry.chapter.comicTitle);

    return _withStructuredPlacementAllocationLock(
      currentRootId,
      () => _serializeStructuredWrite('comic-directory:$base', () async {
        var candidate = base;
        var sequence = 1;
      while (true) {
          final reservedOwner =
              _structuredOwnersByDirectory[_structuredDirectoryKey(
                currentRootId,
                candidate,
              )];
        final diskManifest = await _readComicFolderManifest(
          candidate,
          rootLayout: entry.chapter.pages.isEmpty
              ? layoutForSource(entry.chapter.sourceId)
              : _layoutForEntryPage(entry, 0),
        );
        final manifestOwner = diskManifest == null
            ? null
            : '${diskManifest.sourceId}\u0000${diskManifest.comicId}';
        var claimedOwner = reservedOwner ?? manifestOwner;
        if (claimedOwner != null && claimedOwner != owner) {
          final root = entry.chapter.pages.isEmpty
              ? layout.root
              : _layoutForEntryPage(entry, 0).root;
          final isSaf = safTreeIo != null && safTreeUri != null;
          final dirExists = isSaf
              ? await safTreeIo!.exists(candidate)
              : await Directory('$root/$candidate').exists();
          if (!dirExists) {
              final isSessionClaim = _sessionPlacementClaims.contains(
                claimedOwner,
              );
            if (!isSessionClaim) {
              claimedOwner = null;
            }
          } else {
            var hasRealImages = false;
            if (isSaf) {
              final files = await safTreeIo!.list(candidate);
                hasRealImages = files.any(
                  (f) =>
                  !f.isDirectory &&
                  !f.name.endsWith('.zic.lock') &&
                  !f.name.endsWith(comicManifestFileName) &&
                      f.length > 0,
                );
            } else {
              final dir = Directory('$root/$candidate');
              final entities = await dir.list(followLinks: false).toList();
              for (final e in entities) {
                if (e is File &&
                    !e.path.endsWith('.zic.lock') &&
                    !e.path.endsWith(comicManifestFileName)) {
                  if (await e.length() > 0) {
                    hasRealImages = true;
                    break;
                  }
                }
              }
            }
            if (!hasRealImages) {
                final isSessionClaim = _sessionPlacementClaims.contains(
                  claimedOwner,
                );
              if (!isSessionClaim) {
                claimedOwner = null;
              }
            }
          }
          if (claimedOwner == null) {
            _structuredOwnersByDirectory.remove(
              _structuredDirectoryKey(currentRootId, candidate),
            );
            if (reservedOwner != null) {
              _claimedPlacementsByOwner.remove(reservedOwner);
              final parts = reservedOwner.split('\u0000');
              if (parts.length == 2) {
                await _index.removePlacement(
                  sourceId: parts[0],
                  comicId: parts[1],
                );
              }
            }
          }
        }
        final accepted = claimedOwner == null || claimedOwner == owner;
        _traceSink.record(
          traceEvent(
            clock: _clock,
            sessionId: 'chapter-placement:${entry.chapter.sourceId}',
            kind: TraceEventKind.downloadState,
            identityHash: owner,
            payload: <String, Object?>{
              'stage': 'candidate-inspection',
              'comicId': entry.chapter.comicId,
              'comicTitle': entry.chapter.comicTitle,
              'candidate': candidate,
              'sequence': sequence,
              'reservedOwner': reservedOwner,
              'manifestOwner': manifestOwner,
              'claimedOwner': claimedOwner,
              'accepted': accepted,
            },
          ),
        );
        if (accepted) {
            final effectivePageOrder =
                diskManifest?.pageOrder != null &&
                  diskManifest!.pageOrder != ComicPageOrder.auto
              ? diskManifest.pageOrder
              : ComicPageOrder.auto;
          final placement = DownloadPlacement(
            placementId: owner,
            sourceId: entry.chapter.sourceId,
            comicId: entry.chapter.comicId,
            comicTitle: entry.chapter.comicTitle,
            mode: DownloadPlacementMode.createNew,
            relativeDirectory: candidate,
            storageRootId: currentRootId,
            pageOrder: effectivePageOrder,
            createdAt: DateTime.now().toUtc(),
            updatedAt: DateTime.now().toUtc(),
          );
          await _persistPlacement(placement);
          _sessionPlacementClaims.add(owner);
          _claimedPlacementsByOwner[owner] = placement;
          _structuredDirectoriesByOwner[owner] = candidate;
            _structuredOwnersByDirectory[_structuredDirectoryKey(
                  currentRootId,
                  candidate,
                )] =
                owner;
          return placement;
        }
        sequence++;
        final suffix = _structuredComicOwnerSuffix(entry);
        candidate = buildComicDirectoryName(
          comicTitle: entry.chapter.comicTitle,
            conflictSourceSuffix: sequence == 2
                ? suffix
                : '$suffix ${sequence - 1}',
        );
      }
      }),
    );
  }

  Future<String> resolveStructuredComicDirectory(
    ImportedLibraryEntry entry, {
    Iterable<CacheRec>? knownRecords,
  }) async {
    final placement = await resolveDownloadPlacement(
      entry,
      knownRecords: knownRecords,
    );
    return placement.relativeDirectory;
  }

  bool _mappingIsPureFrontPrepend(ComicVersionPageMapping mapping) =>
      mapping.successorOffset > 0 &&
      mapping.successorPageCount ==
          mapping.predecessorPageCount + mapping.successorOffset;

  List<({ComicVersionRelation relation, ComicVersionPageMapping mapping})>
  _downloadBaselinePredecessorMappings(ImportedLibraryEntry entry) {
    final chapter = entry.chapter;
    final matches =
        <({ComicVersionRelation relation, ComicVersionPageMapping mapping})>[];
    for (final relation in _downloadHeadRelations) {
      if (relation.sourceId != chapter.sourceId ||
          relation.successorComicId != chapter.comicId) {
        continue;
      }
      for (final mapping in relation.pageMappings) {
        if (mapping.successorChapterId == chapter.chapterId &&
            mapping.successorPageCount == chapter.pages.length) {
          matches.add((relation: relation, mapping: mapping));
        }
      }
    }
    matches.sort((left, right) {
      final pages = right.mapping.predecessorPageCount.compareTo(
        left.mapping.predecessorPageCount,
      );
      if (pages != 0) return pages;
      return left.relation.predecessorComicId.compareTo(
        right.relation.predecessorComicId,
      );
    });
    return matches;
  }

  bool _hasVerifiedFrontPrependEvidence(ImportedLibraryEntry entry) =>
      _downloadBaselinePredecessorMappings(
        entry,
      ).any((candidate) => _mappingIsPureFrontPrepend(candidate.mapping));

  Future<DownloadPlacement> freezeExportPageOrder(
    ImportedLibraryEntry entry,
    DownloadPlacement placement, {
    required bool isSingleChapter,
  }) async {
    if (placement.pageOrder != ComicPageOrder.auto) return placement;
    final resolved = isSingleChapter && _hasVerifiedFrontPrependEvidence(entry)
        ? ComicPageOrder.chronological
        : ComicPageOrder.origin;
    return resolveDownloadPlacement(
      entry,
      requestedPlacement: placement.copyWith(
        pageOrder: resolved,
        generation: placement.generation + 1,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }

  bool _recordBelongsToExportPlacement(
    CacheRec record,
    DownloadPlacement placement,
  ) {
    final parsed = parseSafRecordPath(record.path);
    if (parsed != null) {
      return parsed.relativePath == placement.relativeDirectory ||
          parsed.relativePath.startsWith('${placement.relativeDirectory}/');
    }
    final root = placement.storageRootId == 'default'
        ? layoutFor(record.id).root
        : placement.storageRootId;
    final prefix = '$root/${placement.relativeDirectory}';
    return record.path == prefix || record.path.startsWith('$prefix/');
  }

  Future<Map<int, int>> _inheritedChronologicalOrdinals(
    ImportedLibraryEntry entry,
  ) async {
    final chapter = entry.chapter;
    var best = const <int, int>{};
    for (final candidate in _downloadBaselinePredecessorMappings(entry)) {
      final mapping = candidate.mapping;
      if (!_mappingIsPureFrontPrepend(mapping)) continue;
      final predecessorComicId = candidate.relation.predecessorComicId;
      final placement = await _index.getPlacement(
        sourceId: chapter.sourceId,
        comicId: predecessorComicId,
      );
      if (placement?.pageOrder != ComicPageOrder.chronological) continue;
      final bindings = await _index.listExportPageBindings(
        sourceId: chapter.sourceId,
        comicId: predecessorComicId,
        chapterId: mapping.predecessorChapterId,
      );
      if (bindings.length != mapping.predecessorPageCount) continue;
      final byIndex = <int, int>{
        for (final binding in bindings)
          binding.logicalIndex: binding.exportOrdinal,
      };
      if (byIndex.length != mapping.predecessorPageCount ||
          !Iterable<int>.generate(
            mapping.predecessorPageCount,
          ).every(byIndex.containsKey)) {
        continue;
      }
      final inherited = <int, int>{};
      for (
        var currentIndex = 0;
          currentIndex < chapter.pages.length;
        currentIndex++
      ) {
        final verifiedIntervals = mapping.effectiveVerifiedIntervals;
        final predecessorIndex = verifiedIntervals.isEmpty
            ? currentIndex - mapping.successorOffset
            : mapping.uniqueVerifiedPredecessorIndexForSuccessor(currentIndex);
        final ordinal = predecessorIndex == null
            ? null
            : byIndex[predecessorIndex];
        if (ordinal != null) inherited[currentIndex] = ordinal;
      }
      if (inherited.length > best.length) best = inherited;
    }
    return best;
  }

  Future<Map<String, int>> ensureExportPageOrdinals(
    ImportedLibraryEntry entry,
    DownloadPlacement placement, {
    Iterable<CacheRec>? knownRecords,
  }) async {
    if (placement.pageOrder == ComicPageOrder.auto) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'export page order must be frozen before page materialization',
      );
    }
    final chapter = entry.chapter;
    final pages = chapter.pages;
    final pageIndexById = <String, int>{
      for (var index = 0; index < pages.length; index++)
        pages[index].stablePageId: index,
    };
    final durable = await _index.listExportPageBindings(
      sourceId: chapter.sourceId,
      comicId: chapter.comicId,
      chapterId: chapter.chapterId,
    );
    final bindingsByPage = <String, ExportPageBinding>{
      for (final binding in durable) binding.pageId: binding,
    };

    // Compatibility migration: if structured files predate export bindings,
    // preserve their already-visible ordinals instead of renumbering them.
    final indexed = knownRecords ?? await _index.list();
    for (final record in indexed) {
      if (record.id.content.sourceId != chapter.sourceId ||
          record.id.content.comicId != chapter.comicId ||
          record.id.content.chapterId != chapter.chapterId ||
          !_recordBelongsToExportPlacement(record, placement)) {
        continue;
      }
      final logicalIndex = pageIndexById[record.id.content.pageId];
      if (logicalIndex == null ||
          bindingsByPage.containsKey(record.id.content.pageId)) {
        continue;
      }
      final ordinal = parsePageIndexFromFileName(record.path);
      if (ordinal == null || ordinal <= 0) continue;
      bindingsByPage[record.id.content.pageId] = ExportPageBinding(
        sourceId: chapter.sourceId,
        comicId: chapter.comicId,
        chapterId: chapter.chapterId,
        pageId: record.id.content.pageId,
        logicalIndex: logicalIndex,
        exportOrdinal: ordinal,
        placementGeneration: placement.generation,
      );
    }

    if (placement.pageOrder == ComicPageOrder.chronological &&
        bindingsByPage.values.every(
          (binding) => !pageIndexById.containsKey(binding.pageId),
        )) {
      final inherited = await _inheritedChronologicalOrdinals(entry);
      for (final inheritedEntry in inherited.entries) {
        final pageId = pages[inheritedEntry.key].stablePageId;
        bindingsByPage.putIfAbsent(
          pageId,
          () => ExportPageBinding(
            sourceId: chapter.sourceId,
            comicId: chapter.comicId,
            chapterId: chapter.chapterId,
            pageId: pageId,
            logicalIndex: inheritedEntry.key,
            exportOrdinal: inheritedEntry.value,
            placementGeneration: placement.generation,
          ),
        );
      }
    }

    final usedOrdinals = <int>{
      for (final binding in bindingsByPage.values) binding.exportOrdinal,
    };
    final currentBindings = <int, ExportPageBinding>{};
    for (var index = 0; index < pages.length; index++) {
      final binding = bindingsByPage[pages[index].stablePageId];
      if (binding != null) currentBindings[index] = binding;
    }

    if (placement.pageOrder == ComicPageOrder.origin) {
      for (var index = 0; index < pages.length; index++) {
        final expectedOrdinal = index + 1;
        final existing = currentBindings[index];
        if (existing != null && existing.exportOrdinal != expectedOrdinal) {
          throw Failure(
            code: ErrorCode.policy,
            message:
                'origin export layout changed and requires explicit relayout',
            details: <String, Object?>{
              'pageId': pages[index].stablePageId,
              'existingOrdinal': existing.exportOrdinal,
              'expectedOrdinal': expectedOrdinal,
            },
          );
        }
        if (existing == null && usedOrdinals.contains(expectedOrdinal)) {
          throw Failure(
            code: ErrorCode.policy,
            message:
                'origin export ordinal is occupied by a stale page binding',
            details: <String, Object?>{'exportOrdinal': expectedOrdinal},
          );
        }
        currentBindings[index] = ExportPageBinding(
          sourceId: chapter.sourceId,
          comicId: chapter.comicId,
          chapterId: chapter.chapterId,
          pageId: pages[index].stablePageId,
          logicalIndex: index,
          exportOrdinal: expectedOrdinal,
          placementGeneration: placement.generation,
        );
        usedOrdinals.add(expectedOrdinal);
      }
    } else {
      final orderedExistingIndexes = currentBindings.keys.toList()..sort();
      for (var cursor = 1; cursor < orderedExistingIndexes.length; cursor++) {
        final previous = currentBindings[orderedExistingIndexes[cursor - 1]]!;
        final next = currentBindings[orderedExistingIndexes[cursor]]!;
        if (previous.exportOrdinal <= next.exportOrdinal) {
          throw const Failure(
            code: ErrorCode.policy,
            message: 'chronological export bindings are not reverse-monotonic',
          );
        }
      }
      if (currentBindings.isEmpty) {
        var ordinal = 1;
        for (var index = pages.length - 1; index >= 0; index--) {
          currentBindings[index] = ExportPageBinding(
            sourceId: chapter.sourceId,
            comicId: chapter.comicId,
            chapterId: chapter.chapterId,
            pageId: pages[index].stablePageId,
            logicalIndex: index,
            exportOrdinal: ordinal++,
            placementGeneration: placement.generation,
          );
        }
      } else {
        final firstExisting = currentBindings.keys.reduce(
          (left, right) => left < right ? left : right,
        );
        for (var index = firstExisting; index < pages.length; index++) {
          if (!currentBindings.containsKey(index)) {
            throw Failure(
              code: ErrorCode.policy,
              message:
                  'chronological export changed outside a front-prepend prefix',
              details: <String, Object?>{'logicalIndex': index},
            );
          }
        }
        var nextOrdinal = usedOrdinals.isEmpty
            ? 1
            : usedOrdinals.reduce(
                    (left, right) => left > right ? left : right,
                  ) +
                  1;
        for (var index = firstExisting - 1; index >= 0; index--) {
          final existing = currentBindings[index];
          if (existing != null) continue;
          currentBindings[index] = ExportPageBinding(
            sourceId: chapter.sourceId,
            comicId: chapter.comicId,
            chapterId: chapter.chapterId,
            pageId: pages[index].stablePageId,
            logicalIndex: index,
            exportOrdinal: nextOrdinal++,
            placementGeneration: placement.generation,
          );
        }
      }
      // Refresh logical indexes after a front-prepend without changing ordinal.
      for (var index = 0; index < pages.length; index++) {
        final binding = currentBindings[index]!;
        currentBindings[index] = ExportPageBinding(
          sourceId: binding.sourceId,
          comicId: binding.comicId,
          chapterId: binding.chapterId,
          pageId: binding.pageId,
          logicalIndex: index,
          exportOrdinal: binding.exportOrdinal,
          placementGeneration: placement.generation,
        );
      }
    }

    await _index.putExportPageBindings(currentBindings.values);
    return <String, int>{
      for (final entry in currentBindings.entries)
        pages[entry.key].stablePageId: entry.value.exportOrdinal,
    };
  }

  /// Resolves a chapter export directory without allowing two chapters with
  /// the same cleaned title to share page filenames. Existing manifests and
  /// physical directories are considered together so this remains stable
  /// across restarts and across old v1 manifests.
  Future<String> resolveStructuredChapterDirectory(
    ImportedLibraryEntry entry, {
    required String comicDirectoryName,
  }) async {
    final base = buildChapterDirectoryName(
      entry.chapter.displayName,
      fallbackIndex: entry.chapter.sequence,
    );
    final rootLayout = entry.chapter.pages.isEmpty
        ? layout
        : _layoutForEntryPage(entry, 0);
    final manifest = await _readComicFolderManifest(
      comicDirectoryName,
      rootLayout: rootLayout,
    );
    if (manifest?.chapters.contains(entry.chapter.chapterId) == true) {
      final mapped = manifest?.chapterDirectories[entry.chapter.chapterId];
      return mapped == null || mapped.isEmpty
          ? base
          : _requireManifestDirectoryName(mapped);
    }
    final used = <String>{...?manifest?.chapterDirectories.values};
    final safIo = safTreeIo;
    if (safIo != null && safTreeUri != null) {
      for (final item in await safIo.list(comicDirectoryName)) {
        if (item.isDirectory) used.add(item.name);
      }
    } else {
      final directory = Directory('${rootLayout.root}/$comicDirectoryName');
      if (await directory.exists()) {
        await for (final item in directory.list(followLinks: false)) {
          if (item is Directory) {
            used.add(item.path.substring(directory.path.length + 1));
          }
        }
      }
    }
    if (!used.contains(base)) return base;
    final suffix = sanitizePathSegment(
      entry.chapter.chapterId,
      fallback: 'chapter',
      maxLength: 24,
    );
    var candidate = '$base ($suffix)';
    var sequence = 2;
    while (used.contains(candidate)) {
      candidate = '$base ($suffix $sequence)';
      sequence++;
    }
    return candidate;
  }

  Future<void> claimStructuredComicDirectory({
    required String sourceId,
    required String comicId,
    required String directoryName,
    String? comicTitle,
    DownloadPlacementMode mode = DownloadPlacementMode.createNew,
    String? observedOwnerKey,
    ComicPageOrder pageOrder = ComicPageOrder.auto,
  }) async {
    await _loadPersistedPlacementClaims();
    final clean = _requireSafeComicDirectoryName(directoryName);
    final owner = '$sourceId\u0000$comicId';
    final rootId = safTreeUri ?? layoutForSource(sourceId).root;
    await _withStructuredDirectoryLock<void>(rootId, clean, () async {
      await _refreshPersistedPlacementClaims();
      final claimedOwner =
          _structuredOwnersByDirectory[_structuredDirectoryKey(rootId, clean)];
      final replacesObservedOwner =
          mode == DownloadPlacementMode.overwrite &&
          observedOwnerKey != null &&
          observedOwnerKey == claimedOwner;
      final displacedPlacement = replacesObservedOwner
          ? _claimedPlacementsByOwner[claimedOwner]
          : null;
      if (claimedOwner != null &&
          claimedOwner != owner &&
          !replacesObservedOwner) {
        throw Failure(
          code: ErrorCode.policy,
          message: 'download placement directory is already claimed',
          details: <String, Object?>{
            'directory': clean,
            'existingOwner': claimedOwner,
            'requestOwner': owner,
          },
        );
      }
      _traceSink.record(
        traceEvent(
          clock: _clock,
          sessionId: 'chapter-placement:$sourceId',
          kind: TraceEventKind.downloadState,
          identityHash: owner,
          payload: <String, Object?>{
            'stage': 'claim-comic-directory',
            'comicId': comicId,
            'comicTitle': comicTitle,
            'directoryName': clean,
            'mode': mode.name,
            'observedOwnerKey': observedOwnerKey,
          },
        ),
      );
      if (displacedPlacement != null) {
        _claimedPlacementsByOwner.remove(displacedPlacement.ownerKey);
        _structuredDirectoriesByOwner.remove(displacedPlacement.ownerKey);
      }
      _structuredDirectoriesByOwner[owner] = clean;
      _structuredOwnersByDirectory[_structuredDirectoryKey(rootId, clean)] =
          owner;
      final previousOwnerPlacement = _claimedPlacementsByOwner[owner];
      final effectivePageOrder = pageOrder != ComicPageOrder.auto
          ? pageOrder
          : (previousOwnerPlacement?.pageOrder ?? ComicPageOrder.auto);
      final placement = DownloadPlacement(
        placementId: owner,
        sourceId: sourceId,
        comicId: comicId,
        comicTitle: comicTitle ?? clean,
        mode: mode,
        relativeDirectory: clean,
        storageRootId: rootId,
        observedOwnerKey: observedOwnerKey,
        generation: (previousOwnerPlacement?.generation ?? -1) + 1,
        pageOrder: effectivePageOrder,
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );
      _claimedPlacementsByOwner[owner] = placement;
      await _persistPlacement(placement);
      if (displacedPlacement != null) {
        await _index.removePlacement(
          sourceId: displacedPlacement.sourceId,
          comicId: displacedPlacement.comicId,
        );
      }
    });
  }

  Future<void> removeStructuredPlacement({
    required String sourceId,
    required String comicId,
  }) async {
    final owner = '$sourceId\u0000$comicId';
    await _index.removePlacement(sourceId: sourceId, comicId: comicId);
    final placement = _claimedPlacementsByOwner.remove(owner);
    _structuredDirectoriesByOwner.remove(owner);
    _sessionPlacementClaims.remove(owner);
    if (placement != null) {
      final rootId = placement.storageRootId == 'default'
          ? layout.root
          : placement.storageRootId;
      _structuredOwnersByDirectory.remove(
        _structuredDirectoryKey(rootId, placement.relativeDirectory),
      );
    }
    _structuredOwnersByDirectory.removeWhere((_, o) => o == owner);
    _traceSink.record(
      traceEvent(
        clock: _clock,
        sessionId: 'chapter-placement:$sourceId',
        kind: TraceEventKind.downloadState,
        identityHash: owner,
        payload: <String, Object?>{
          'stage': 'remove-structured-placement',
          'sourceId': sourceId,
          'comicId': comicId,
          'removedDirectory': placement?.relativeDirectory,
        },
      ),
    );
  }

  Future<DownloadPlacement?> getDownloadPlacement({
    required String sourceId,
    required String comicId,
  }) async {
    final owner = '$sourceId\u0000$comicId';
    await _placementWrites[owner];
    final mem = _claimedPlacementsByOwner[owner];
    final sqlite = await _index.getPlacement(
      sourceId: sourceId,
      comicId: comicId,
    );
    final result = mem ?? sqlite;
    _traceSink.record(
      traceEvent(
        clock: _clock,
        sessionId: 'chapter-placement:$sourceId',
        kind: TraceEventKind.downloadState,
        identityHash: owner,
        payload: <String, Object?>{
          'stage': 'get-download-placement-detail',
          'sourceId': sourceId,
          'comicId': comicId,
          'hasMemoryClaim': mem != null,
          'memoryDirectory': mem?.relativeDirectory,
          'hasSqlitePlacement': sqlite != null,
          'sqliteDirectory': sqlite?.relativeDirectory,
          'resultDirectory': result?.relativeDirectory,
          'resultMode': result?.mode.name,
        },
      ),
    );
    return result;
  }

  Future<void> verifyStructuredDestinationOwner(
    ImportedLibraryEntry entry, {
    String? comicDirectoryName,
  }) async {
    final placement = await resolveDownloadPlacement(entry);
    final comicDir = _requireSafeComicDirectoryName(
      comicDirectoryName ?? placement.relativeDirectory,
    );
    final existing = await _readComicFolderManifest(
      comicDir,
      rootLayout: entry.chapter.pages.isEmpty
          ? layout
          : _layoutForEntryPage(entry, 0),
    );
    if (existing != null &&
        (existing.sourceId != entry.chapter.sourceId ||
            existing.comicId != entry.chapter.comicId)) {
      if (placement.mode == DownloadPlacementMode.overwrite &&
          placement.observedOwnerKey != null &&
          placement.observedOwnerKey ==
              '${existing.sourceId}\u0000${existing.comicId}') {
        // Explicitly authorized overwrite by user placement contract
        return;
      }
      throw Failure(
        code: ErrorCode.policy,
        message:
            'download placement directory conflict: $comicDir is owned by '
            '${existing.sourceId}:${existing.comicId}',
        details: <String, Object?>{
          'directory': comicDir,
          'existingOwner': '${existing.sourceId}\u0000${existing.comicId}',
          'requestOwner':
              '${entry.chapter.sourceId}\u0000${entry.chapter.comicId}',
        },
      );
    }
  }

  Future<void> writeComicFolderManifest(
    ImportedLibraryEntry entry, {
    String? comicDirectoryName,
    String? chapterDirectoryName,
    Iterable<String>? knownChapterIds,
  }) async {
    final comicDir = _requireSafeComicDirectoryName(
      comicDirectoryName ?? await resolveStructuredComicDirectory(entry),
    );
    final safeChapterDirectoryName = chapterDirectoryName == null
        ? null
        : _requireSafeComicDirectoryName(chapterDirectoryName);
    final manifestPath = '$comicDir/$comicManifestFileName';
    await _serializeStructuredWrite(
      manifestPath,
      () => _withStructuredManifestLock(entry, comicDir, () async {
      await verifyStructuredDestinationOwner(
        entry,
        comicDirectoryName: comicDir,
      );
      final rootLayout = entry.chapter.pages.isEmpty
          ? layout
          : _layoutForEntryPage(entry, 0);
      final previous = await _readComicFolderManifest(
        comicDir,
        rootLayout: rootLayout,
      );
        final isSameComic =
            previous != null &&
          previous.sourceId == entry.chapter.sourceId &&
          previous.comicId == entry.chapter.comicId;
        final indexedChapterIds =
            knownChapterIds ??
          await downloadedChapterIds(
            sourceId: entry.chapter.sourceId,
            comicId: entry.chapter.comicId,
          );
      final chapters = <String>{
        if (isSameComic) ...previous.chapters,
        ...indexedChapterIds,
        entry.chapter.chapterId,
      };
      final orderedChapters = chapters.toList(growable: true)..sort();
      final directories = <String, String>{
        if (isSameComic) ...previous.chapterDirectories,
      };
      final titles = <String, String>{
        if (isSameComic) ...previous.chapterTitles,
      };
      final sequences = <String, int>{
        if (isSameComic) ...previous.chapterSequences,
      };
      titles[entry.chapter.chapterId] = entry.chapter.displayName;
      sequences[entry.chapter.chapterId] = entry.chapter.sequence;
      if (orderedChapters.length > 1) {
        final usedDirectories = <String>{};
        for (final chapterId in orderedChapters) {
          final title = titles[chapterId] ?? chapterId;
          final sequence = sequences[chapterId] ?? 1;
          var candidate = directories[chapterId]?.isNotEmpty == true
              ? directories[chapterId]!
              : (chapterId == entry.chapter.chapterId &&
                      chapterDirectoryName != null
                  ? safeChapterDirectoryName!
                  : buildChapterDirectoryName(
                      title,
                      fallbackIndex: sequence,
                    ));
          if (!usedDirectories.add(candidate)) {
            final suffix = sanitizePathSegment(
              chapterId,
              fallback: 'chapter',
              maxLength: 24,
            );
            var serial = 2;
            final base = candidate;
            candidate = '$base ($suffix)';
            while (!usedDirectories.add(candidate)) {
              candidate = '$base ($suffix $serial)';
              serial++;
            }
          }
          directories[chapterId] = candidate;
        }
      } else {
        // A one-chapter comic is intentionally flat. Keep title/sequence
        // metadata so a later multi-chapter transition can migrate it.
        directories.remove(entry.chapter.chapterId);
      }
      final placement = await resolveDownloadPlacement(entry);
      final draft = ComicFolderManifest(
        comicTitle: entry.chapter.comicTitle,
        comicId: entry.chapter.comicId,
        sourceId: entry.chapter.sourceId,
        chapters: orderedChapters,
        chapterDirectories: directories,
        chapterTitles: titles,
        chapterSequences: sequences,
          generation:
              (isSameComic ? previous.generation : placement.generation) + 1,
        pageOrder: placement.pageOrder,
        updatedAt: DateTime.now(),
      );
      final manifest = ComicFolderManifest(
        format: draft.format,
        sourceId: draft.sourceId,
        sourceDisplayName: draft.sourceDisplayName,
        comicId: draft.comicId,
        comicTitle: draft.comicTitle,
        chapters: draft.chapters,
        chapterDirectories: draft.chapterDirectories,
        chapterTitles: draft.chapterTitles,
        chapterSequences: draft.chapterSequences,
        generation: draft.generation,
        fingerprint: draft.computedFingerprint,
        pageOrder: draft.pageOrder,
        updatedAt: draft.updatedAt,
      );
      final safIo = safTreeIo;
      if (safIo != null && safTreeUri != null) {
        await _writeBytesToSafTracked(
          safIo,
          manifestPath,
          Uint8List.fromList(utf8.encode(manifest.encode())),
        );
        final committedPlacement = placement.copyWith(
          generation: manifest.generation,
          fingerprint: manifest.fingerprint,
        );
        await _persistPlacement(committedPlacement);
        _claimedPlacementsByOwner[placement.ownerKey] = committedPlacement;
        return;
      }
      final root = entry.chapter.pages.isEmpty
          ? layout.root
          : _layoutForEntryPage(entry, 0).root;
      final file = File('$root/$manifestPath');
      await file.parent.create(recursive: true);
      final temporary = File(
        '${file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
      );
      await _registerTemporaryCleanupDebt(
        temporary.path,
        storageRootId: root,
      );
      try {
        await temporary.writeAsString(manifest.encode(), flush: true);
        await temporary.rename(file.path);
      } finally {
        if (await temporary.exists()) {
          await temporary.delete();
        }
        if (!await temporary.exists()) {
          await _forgetStorageCleanupDebt(temporary.path);
        }
      }
      final committedPlacement = placement.copyWith(
        generation: manifest.generation,
        fingerprint: manifest.fingerprint,
      );
      await _persistPlacement(committedPlacement);
      _claimedPlacementsByOwner[placement.ownerKey] = committedPlacement;
      }),
    );
  }

  Future<void> cleanupStructuredChapterExport(
    ImportedLibraryEntry entry, {
    required String comicDirectoryName,
    String? chapterDirectoryName,
    required bool isSingleChapter,
  }) async {
    final safeComicDirectoryName = _requireSafeComicDirectoryName(
      comicDirectoryName,
    );
    final safeChapterDirectoryName = chapterDirectoryName == null
        ? null
        : _requireSafeComicDirectoryName(chapterDirectoryName);
    final rootLayout = entry.chapter.pages.isEmpty
        ? layout
        : _layoutForEntryPage(entry, 0);
    final prefix = isSingleChapter
        ? '$safeComicDirectoryName/'
        : '$safeComicDirectoryName/$safeChapterDirectoryName/';
    final manifest = await _readComicFolderManifest(
      safeComicDirectoryName,
      rootLayout: rootLayout,
    );
    final isOwner =
        manifest != null &&
        manifest.sourceId == entry.chapter.sourceId &&
        manifest.comicId == entry.chapter.comicId;
    if (manifest != null && !isOwner) {
      return;
    }
    final referenced = (await _index.list()).any((record) {
      if (record.state != CacheState.ready &&
          record.state != CacheState.partial) {
        return false;
      }
      final parsed = parseSafRecordPath(record.path);
      if (parsed != null) {
        return safTreeUri == parsed.treeUri &&
            (parsed.relativePath == safeComicDirectoryName ||
                parsed.relativePath.startsWith(prefix));
      }
      final root = '${rootLayout.root}/';
      return record.path == '${root}$safeComicDirectoryName' ||
          record.path.startsWith('$root$prefix');
    });
    if (referenced) return;
    final safIo = safTreeIo;
    if (safIo != null && safTreeUri != null) {
      await safIo.delete(
        isSingleChapter
            ? safeComicDirectoryName
            : '$safeComicDirectoryName/$safeChapterDirectoryName',
      );
      return;
    }
    final target = Directory(
      isSingleChapter
          ? '${rootLayout.root}/$safeComicDirectoryName'
          : '${rootLayout.root}/$safeComicDirectoryName/$safeChapterDirectoryName',
    );
    if (await target.exists()) await target.delete(recursive: true);
  }

  Future<void> removeChapterFromComicFolderManifest(
    ImportedLibraryEntry entry, {
    String? comicDirectoryName,
  }) async {
    final comicDir = _requireSafeComicDirectoryName(
      comicDirectoryName ?? await resolveStructuredComicDirectory(entry),
    );
    final rootLayout = entry.chapter.pages.isEmpty
        ? layout
        : _layoutForEntryPage(entry, 0);
    await _serializeStructuredWrite(
      '$comicDir/$comicManifestFileName',
      () => _withStructuredManifestLock(entry, comicDir, () async {
      final existing = await _readComicFolderManifest(
        comicDir,
        rootLayout: rootLayout,
      );
      if (existing == null ||
          existing.sourceId != entry.chapter.sourceId ||
          existing.comicId != entry.chapter.comicId) {
        // Never delete or rewrite a manifest owned by another comic/source,
        // even if a stale placement points this entry at the same directory.
        return;
      }
      final remaining = (await _index.list())
          .where((record) {
            final content = record.id.content;
            return content.sourceId == entry.chapter.sourceId &&
                content.comicId == entry.chapter.comicId &&
                record.bytes > 0 &&
                (record.state == CacheState.ready ||
                    record.state == CacheState.partial);
          })
          .map((record) => record.id.content.chapterId)
          .toSet();
      final chapters = existing.chapters
          .where(remaining.contains)
          .toList(growable: false);
      if (chapters.isEmpty) {
        final safIo = safTreeIo;
        if (safIo != null && safTreeUri != null) {
          await safIo.delete('$comicDir/$comicManifestFileName');
          await safIo.delete(comicDir);
        } else {
          final file = File(
            '${rootLayout.root}/$comicDir/$comicManifestFileName',
          );
          if (await file.exists()) await file.delete();
          final dir = Directory('${rootLayout.root}/$comicDir');
          if (await dir.exists()) {
            final entities = await dir.list(followLinks: false).toList();
              final nonLock = entities
                  .where((e) => !e.path.endsWith('.zic.lock'))
                  .toList();
            if (nonLock.isEmpty) {
              await dir.delete(recursive: true);
            }
          }
        }
          final owner =
              '${entry.chapter.sourceId}\u0000${entry.chapter.comicId}';
        await _index.removePlacement(
          sourceId: entry.chapter.sourceId,
          comicId: entry.chapter.comicId,
        );
        _claimedPlacementsByOwner.remove(owner);
        _structuredDirectoriesByOwner.remove(owner);
        _structuredOwnersByDirectory.remove(
          _structuredDirectoryKey(storageRootIdFor(entry), comicDir),
        );
        return;
      }
      final directories = <String, String>{
        for (final id in chapters)
          if (existing.chapterDirectories[id] != null)
            id: existing.chapterDirectories[id]!,
      };
      final titles = <String, String>{
        for (final id in chapters)
            if (existing.chapterTitles[id] != null)
              id: existing.chapterTitles[id]!,
      };
      final sequences = <String, int>{
        for (final id in chapters)
          if (existing.chapterSequences[id] != null)
            id: existing.chapterSequences[id]!,
      };
      final draft = ComicFolderManifest(
        format: existing.format,
        sourceId: existing.sourceId,
        sourceDisplayName: existing.sourceDisplayName,
        comicId: existing.comicId,
        comicTitle: existing.comicTitle,
        chapters: chapters,
        chapterDirectories: directories,
        chapterTitles: titles,
        chapterSequences: sequences,
        generation: existing.generation + 1,
        updatedAt: DateTime.now(),
      );
      final next = ComicFolderManifest(
        format: draft.format,
        sourceId: draft.sourceId,
        sourceDisplayName: draft.sourceDisplayName,
        comicId: draft.comicId,
        comicTitle: draft.comicTitle,
        chapters: draft.chapters,
        chapterDirectories: draft.chapterDirectories,
        chapterTitles: draft.chapterTitles,
        chapterSequences: draft.chapterSequences,
        generation: draft.generation,
        fingerprint: draft.computedFingerprint,
        updatedAt: draft.updatedAt,
      );
      final bytes = Uint8List.fromList(utf8.encode(next.encode()));
      final safIo = safTreeIo;
      if (safIo != null && safTreeUri != null) {
          await _writeBytesToSafTracked(
            safIo,
            '$comicDir/$comicManifestFileName',
            bytes,
          );
      } else {
        final file = File(
          '${rootLayout.root}/$comicDir/$comicManifestFileName',
        );
        await file.parent.create(recursive: true);
        final temporary = File(
          '${file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
        );
        await _registerTemporaryCleanupDebt(
          temporary.path,
          storageRootId: rootLayout.root,
        );
        try {
          await temporary.writeAsString(next.encode(), flush: true);
          await temporary.rename(file.path);
        } finally {
          if (await temporary.exists()) await temporary.delete();
          if (!await temporary.exists()) {
            await _forgetStorageCleanupDebt(temporary.path);
          }
        }
      }
      final placement = await resolveDownloadPlacement(entry);
      final committedPlacement = placement.copyWith(
        generation: next.generation,
        fingerprint: next.fingerprint,
      );
      await _persistPlacement(committedPlacement);
      _claimedPlacementsByOwner[placement.ownerKey] = committedPlacement;
      }),
    );
  }

  void _rejectLocalPathLinks(String path) {
    var current = File(path).absolute.path;
    final root = Directory(layout.root).absolute.path;
    while (true) {
      if (FileSystemEntity.typeSync(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'structured download path contains a symbolic link',
        );
      }
      if (current == root) break;
      final parent = Directory(current).parent.path;
      if (parent == current) break;
      current = parent;
    }
  }

  Future<ComicFolderManifest?> _readComicFolderManifest(
    String comicDir, {
    CacheLayout? rootLayout,
  }) async {
    final manifestPath = '$comicDir/$comicManifestFileName';
    final safIo = safTreeIo;
    if (safIo != null && safTreeUri != null) {
      if (!await safIo.exists(manifestPath)) return null;
      final handle = await safIo.open(manifestPath, mode: SafWriteMode.read);
      if (handle == null) return null;
      try {
        final length = await safIo.length(handle) ?? 0;
        if (length <= 0) {
          throw const Failure(
            code: ErrorCode.artifactCorruption,
            message: 'comic folder manifest is empty',
          );
        }
        final bytes = await safIo.read(handle, length);
        final manifest = ComicFolderManifest.decode(utf8.decode(bytes));
        if (manifest == null) {
          throw const Failure(
            code: ErrorCode.artifactCorruption,
            message: 'comic folder manifest is invalid',
          );
        }
        if (!manifest.fingerprintValid) {
          throw const Failure(
            code: ErrorCode.artifactCorruption,
            message: 'comic folder manifest fingerprint mismatch',
          );
        }
        _validateComicFolderManifest(manifest);
        return manifest;
      } finally {
        await safIo.close(handle);
      }
    }
    final file = File(
      '${(rootLayout ?? _registry.layout).root}/$comicDir/$comicManifestFileName',
    );
    _rejectLocalPathLinks(file.path);
    if (!await file.exists()) return null;
    final manifest = ComicFolderManifest.decode(await file.readAsString());
    if (manifest == null) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'comic folder manifest is invalid',
      );
    }
    if (!manifest.fingerprintValid) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'comic folder manifest fingerprint mismatch',
      );
    }
    _validateComicFolderManifest(manifest);
    return manifest;
  }

  void _validateComicFolderManifest(ComicFolderManifest manifest) {
    if (manifest.format != comicManifestFormatV1 ||
        manifest.sourceId.trim().isEmpty ||
        manifest.comicId.trim().isEmpty ||
        manifest.generation < 0) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'comic folder manifest has invalid ownership metadata',
      );
    }
    for (final directory in manifest.chapterDirectories.values) {
      if (!_isSafeComicDirectoryName(directory)) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'comic folder manifest contains an unsafe directory name',
        );
      }
    }
  }

  Future<void> _persistPlacement(DownloadPlacement placement) {
    final owner = placement.ownerKey;
    _sessionPlacementClaims.add(owner);
    final previous = _placementWrites[owner] ?? Future<void>.value();
    final current = previous.then<void>(
      (_) async {
        final existing = await _index.getPlacement(
          sourceId: placement.sourceId,
          comicId: placement.comicId,
        );
        final toWrite =
            existing != null && existing.generation >= placement.generation
            ? placement.copyWith(generation: existing.generation + 1)
            : placement;
        await _index.putPlacement(toWrite);
      },
      onError: (Object _, StackTrace __) async {
        final existing = await _index.getPlacement(
          sourceId: placement.sourceId,
          comicId: placement.comicId,
        );
        final toWrite =
            existing != null && existing.generation >= placement.generation
            ? placement.copyWith(generation: existing.generation + 1)
            : placement;
        await _index.putPlacement(toWrite);
      },
    );
    late final Future<void> tail;
    tail = current.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _placementWrites[owner] = tail;
    return current.whenComplete(() {
      if (identical(_placementWrites[owner], tail)) {
        _placementWrites.remove(owner);
      }
    });
  }

  bool _isSafeComicDirectoryName(String value) {
    final clean = value.trim();
    return clean.isNotEmpty &&
        clean != '.' &&
        clean != '..' &&
        !clean.startsWith('.') &&
        !clean.contains('/') &&
        !clean.contains('\\');
  }

  String _requireSafeComicDirectoryName(String value) {
    final clean = value.trim();
    if (!_isSafeComicDirectoryName(clean)) {
      throw ArgumentError.value(
        value,
        'directoryName',
        'must be one safe relative directory name',
      );
    }
    return clean;
  }

  String _requireManifestDirectoryName(String value) {
    final clean = value.trim();
    if (!_isSafeComicDirectoryName(clean)) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'comic folder manifest contains an unsafe directory name',
      );
    }
    return clean;
  }

  String _structuredComicOwnerSuffix(ImportedLibraryEntry entry) {
    final source = sanitizePathSegment(
      entry.chapter.sourceId,
      fallback: 'source',
      maxLength: 40,
    );
    var hash = 0x811c9dc5;
    final identity = '${entry.chapter.sourceId}\u0000${entry.chapter.comicId}';
    for (final unit in identity.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return '$source-${hash.toRadixString(16).padLeft(8, '0')}';
  }
  Future<void> _copyFileIntoSafTracked(
    SafTreeIo io,
    File sourceFile,
    String relativePath,
  ) {
    final treeUri = safTreeUri;
    if (treeUri == null) {
      throw StateError('tracked SAF copy requires a configured tree');
    }
    return copyFileIntoSaf(
      io,
      sourceFile,
      relativePath,
      beforeTemporaryCreate: (temporaryPath) =>
          _registerTemporaryCleanupDebt(
        encodeSafRecordPath(treeUri: treeUri, relativePath: temporaryPath),
        storageRootId: treeUri,
      ),
      afterTemporaryAbsent: (temporaryPath) => _forgetStorageCleanupDebt(
        encodeSafRecordPath(treeUri: treeUri, relativePath: temporaryPath),
      ),
    );
  }

  List<String> downloadedChapterIdsFromRecords(
    Iterable<CacheRec> records, {
    required String sourceId,
    required String comicId,
  }) {
    final chapters = <String>{};
    for (final record in records) {
      final content = record.id.content;
      if (content.sourceId == sourceId &&
          content.comicId == comicId &&
          _isVerifiedReadyRecord(record)) {
        chapters.add(content.chapterId);
      }
    }
    return chapters.toList(growable: false);
  }

  Future<List<String>> downloadedChapterIds({
    required String sourceId,
    required String comicId,
  }) async {
    _requireOpen();
    return downloadedChapterIdsFromRecords(
      (await indexedRecords()).values,
      sourceId: sourceId,
      comicId: comicId,
    );
  }

  Future<List<({String chapterId, String title, int sequence})>>
      flatChapterMigrationPlan({
    required ImportedLibraryEntry entry,
    required String comicDirectoryName,
    required Iterable<String> existingChapterIds,
  }) async {
    _requireOpen();
    final currentChapterId = entry.chapter.chapterId;
    final previousIds = existingChapterIds
        .where((chapterId) => chapterId != currentChapterId)
        .toSet();
    if (previousIds.isEmpty) {
      return const <({String chapterId, String title, int sequence})>[];
    }
    final rootLayout = entry.chapter.pages.isEmpty
        ? layout
        : _layoutForEntryPage(entry, 0);
    final manifest = await _readComicFolderManifest(
      comicDirectoryName,
      rootLayout: rootLayout,
    );

    // A directory mapping is the layout commit marker for that chapter.
    // Current writers create mappings for every chapter once the comic becomes
    // multi-chapter, while the intentional one-chapter flat manifest keeps no
    // mapping. An interrupted first transition therefore re-enters exactly the
    // still-unmapped chapter. Older manifests may omit chapterDirectories even
    // when they already list multiple chapters, so missing mappings must keep
    // the historical recovery path instead of being treated as committed.
    final sameComic =
        manifest != null &&
        manifest.sourceId == entry.chapter.sourceId &&
        manifest.comicId == entry.chapter.comicId;
    if (sameComic && manifest.chapters.isNotEmpty) {
      final manifestChapters = manifest.chapters.toSet();
      return <({String chapterId, String title, int sequence})>[
        for (final chapterId in previousIds)
          if (!manifestChapters.contains(chapterId) ||
              manifest.chapterDirectories[chapterId]?.isNotEmpty != true)
            (
              chapterId: chapterId,
              title: manifest.chapterTitles[chapterId] ?? '第 1 话',
              sequence: manifest.chapterSequences[chapterId] ?? 1,
            ),
      ];
    }

    // Legacy stores may predate .zic.json entirely. Preserve the historical
    // recovery behavior there instead of assuming that every old chapter is
    // already in a subdirectory.
    return <({String chapterId, String title, int sequence})>[
      for (final chapterId in previousIds)
        (chapterId: chapterId, title: '第 1 话', sequence: 1),
    ];
  }

  /// When a comic with a single chapter directly at root transitions to having
  /// multiple chapters, migrates existing root-level page files of previous
  /// chapters into their dedicated chapter subdirectories.
  Future<void> migrateSingleChapterToSubdirectory({
    required String sourceId,
    required String comicId,
    required String comicTitle,
    String? conflictSourceSuffix,
    required String previousChapterId,
    required String previousChapterTitle,
    int previousSequence = 1,
    String? comicDirectoryName,
    CacheLayout? rootLayout,
  }) async {
    _requireOpen();
    final comicDir = _requireSafeComicDirectoryName(
      comicDirectoryName ??
          buildComicDirectoryName(
            comicTitle: comicTitle,
            conflictSourceSuffix: conflictSourceSuffix,
          ),
    );
    final rootId = safTreeUri ?? (rootLayout ?? layoutForSource(sourceId)).root;
    await _serializeStructuredWrite(
      'structured-migration:$rootId/$comicDir',
      () => _withStructuredDirectoryLock(
        rootId,
        comicDir,
        () => _migrateSingleChapterToSubdirectory(
          sourceId: sourceId,
          comicId: comicId,
          comicTitle: comicTitle,
          conflictSourceSuffix: conflictSourceSuffix,
          previousChapterId: previousChapterId,
          previousChapterTitle: previousChapterTitle,
          previousSequence: previousSequence,
          comicDirectoryName: comicDir,
          rootLayout: rootLayout,
        ),
      ),
    );
  }

  Future<void> _migrateSingleChapterToSubdirectory({
    required String sourceId,
    required String comicId,
    required String comicTitle,
    String? conflictSourceSuffix,
    required String previousChapterId,
    required String previousChapterTitle,
    int previousSequence = 1,
    String? comicDirectoryName,
    CacheLayout? rootLayout,
  }) async {
    _requireOpen();
    final safIo = safTreeIo;
    final treeUri = this.safTreeUri;
    final comicDir = _requireSafeComicDirectoryName(
      comicDirectoryName ??
          buildComicDirectoryName(
            comicTitle: comicTitle,
            conflictSourceSuffix: conflictSourceSuffix,
          ),
    );
    final previousManifest = await _readComicFolderManifest(
      comicDir,
      rootLayout: rootLayout,
    );
    final mappedChapterDir =
        previousManifest?.chapterDirectories[previousChapterId];
    final chapterDir = mappedChapterDir != null && mappedChapterDir.isNotEmpty
        ? _requireManifestDirectoryName(mappedChapterDir)
        : buildChapterDirectoryName(
            previousChapterTitle,
            fallbackIndex: previousSequence,
          );
    final candidates =
        <
          ({
      CacheRec record,
      String destinationPath,
      File? destinationFile,
      String? sourceRelative,
      String? destinationRelative,
      bool destinationExisted,
          })
        >[];

    for (final record in await _index.list()) {
      final content = record.id.content;
      if (content.sourceId != sourceId ||
          content.comicId != comicId ||
          content.chapterId != previousChapterId ||
          !_isVerifiedReadyRecord(record)) {
        continue;
      }

      final parsed = parseSafRecordPath(record.path);
      if (parsed != null &&
          safIo != null &&
          treeUri != null &&
          parsed.treeUri == treeUri) {
        final segments = parsed.relativePath.split('/');
        if (segments.length != 2 || segments[0] != comicDir) continue;
        final newRel = '$comicDir/$chapterDir/${segments[1]}';
        candidates.add((
          record: record,
          destinationPath: encodeSafRecordPath(
            treeUri: treeUri,
            relativePath: newRel,
          ),
          destinationFile: null,
          sourceRelative: parsed.relativePath,
          destinationRelative: newRel,
          destinationExisted: await safIo.exists(newRel),
        ));
        continue;
      }

      if (record.path.isEmpty) continue;
      final sourceFile = File(record.path);
      final expectedParent = '${(rootLayout ?? layout).root}/$comicDir';
      if (!await sourceFile.exists() ||
          sourceFile.parent.path != expectedParent) {
        continue;
      }
      final destinationFile = File(
        '${sourceFile.parent.path}/$chapterDir/${sourceFile.uri.pathSegments.last}',
      );
      candidates.add((
        record: record,
        destinationPath: destinationFile.path,
        destinationFile: destinationFile,
        sourceRelative: null,
        destinationRelative: null,
        destinationExisted: await destinationFile.exists(),
      ));
    }

    // Validate every source and pre-existing destination before moving any
    // bytes. A metadata-only ready record is not sufficient for migration;
    // otherwise a same-length corruption could be moved while retaining its
    // old checksum proof.
    for (final candidate in candidates) {
      final sourceProof = await _artifactProof(candidate.record.path);
      if (!_proofMatchesRecord(sourceProof, candidate.record)) {
        throw Failure(
          code: ErrorCode.artifactCorruption,
          message:
              'structured migration source failed content verification: '
              '${candidate.record.path}',
        );
      }
      if (candidate.destinationExisted) {
        final destinationProof = await _artifactProof(
          candidate.destinationPath,
        );
        if (!_proofMatchesRecord(destinationProof, candidate.record)) {
          throw Failure(
            code: ErrorCode.artifactCorruption,
            message:
                'structured migration destination conflicts with source: '
                '${candidate.destinationPath}',
          );
        }
      }
    }

    for (final candidate in candidates) {
      final record = candidate.record;
      final destinationPath = candidate.destinationPath;
      final destinationRelative = candidate.destinationRelative;
      if (destinationRelative != null &&
          safIo != null &&
          treeUri != null &&
          candidate.sourceRelative != null) {
        var createdDestination = false;
        if (!candidate.destinationExisted) {
          await _writeBytesToSafTracked(
            safIo,
            destinationRelative,
            await _readArtifactBytes(record.path),
          );
          createdDestination = true;
          final destinationProof = await _artifactProof(destinationPath);
          if (!_proofMatchesRecord(destinationProof, record)) {
            if (createdDestination) {
              await safIo.delete(destinationRelative);
            }
            throw Failure(
              code: ErrorCode.artifactCorruption,
              message:
                  'structured migration destination failed content '
                  'verification: $destinationPath',
            );
          }
        }
        try {
          await _commitAuthoritySwitchWithObsoleteSealedCleanup<void>(
            oldAccessLocator: record.path,
            oldStorageRootId: record.storageRootId,
            expectedBytes: record.bytes,
            expectedChecksum: record.checksum,
            expectedChecksumAlgorithm: record.checksumAlgorithm,
            commit: () => _index.put(record.copyWith(path: destinationPath)),
          );
        } catch (_) {
          if (createdDestination) {
            try {
              await safIo.delete(destinationRelative);
            } catch (_) {}
          }
          rethrow;
        }
        continue;
      }

      final destinationFile = candidate.destinationFile;
      if (destinationFile == null) continue;
      final sourceFile = File(record.path);
      var moved = false;
      if (!candidate.destinationExisted) {
        await destinationFile.parent.create(recursive: true);
        await sourceFile.rename(destinationFile.path);
        moved = true;
        final movedProof = await _artifactProof(destinationFile.path);
        if (!_proofMatchesRecord(movedProof, record)) {
          try {
            await destinationFile.rename(sourceFile.path);
          } catch (_) {}
          throw Failure(
            code: ErrorCode.artifactCorruption,
            message:
                'structured migration destination changed during move: '
                '${destinationFile.path}',
          );
        }
      } else {
        final destinationProof = await _artifactProof(destinationFile.path);
        if (!_proofMatchesRecord(destinationProof, record)) {
          throw Failure(
            code: ErrorCode.artifactCorruption,
            message:
                'structured migration destination changed before move: '
                '${destinationFile.path}',
          );
        }
        final sourceProof = await _artifactProof(sourceFile.path);
        if (!_proofMatchesRecord(sourceProof, record)) {
          throw Failure(
            code: ErrorCode.artifactCorruption,
            message:
                'structured migration source changed before move: '
                '${sourceFile.path}',
          );
        }
      }

      if (moved) {
        try {
          await _index.put(record.copyWith(path: destinationFile.path));
        } catch (_) {
          if (await destinationFile.exists() && !await sourceFile.exists()) {
            try {
              await destinationFile.rename(sourceFile.path);
            } catch (_) {}
          }
          rethrow;
        }
      } else {
        await _commitAuthoritySwitchWithObsoleteSealedCleanup<void>(
          oldAccessLocator: record.path,
          oldStorageRootId: record.storageRootId,
          expectedBytes: record.bytes,
          expectedChecksum: record.checksum,
          expectedChecksumAlgorithm: record.checksumAlgorithm,
          commit: () async {
            await _index.put(record.copyWith(path: destinationFile.path));
            final sourceProof = await _artifactProof(sourceFile.path);
            if (!_proofMatchesRecord(sourceProof, record)) {
              throw Failure(
                code: ErrorCode.artifactCorruption,
                message:
                    'structured migration source changed before cleanup: '
                    '${sourceFile.path}',
              );
            }
          },
        );
      }
    }
  }

  /// Inspects candidate comic directories and existing files prior to download.
  Future<ComicConflictReport> inspectComicConflicts({
    required String sourceId,
    String? sourceDisplayName,
    required String comicId,
    required String comicTitle,
    Set<String>? knownPredecessorComicIds,
    Set<String>? knownSuccessorComicIds,
  }) async {
    _requireOpen();
    final preds = <String>{
      ...?knownPredecessorComicIds,
      for (final rel in _downloadHeadRelations)
        if (rel.sourceId == sourceId && rel.successorComicId == comicId)
          rel.predecessorComicId,
    };
    final succs = <String>{
      ...?knownSuccessorComicIds,
      for (final rel in _downloadHeadRelations)
        if (rel.sourceId == sourceId && rel.predecessorComicId == comicId)
          rel.successorComicId,
    };
    final knownOwners = <String, ({String sourceId, String comicId})>{};
    final relatedComicIds = <String>{comicId, ...preds, ...succs};
    for (final relComicId in relatedComicIds) {
      final p = await _index.getPlacement(
        sourceId: sourceId,
        comicId: relComicId,
      );
      if (p != null && p.relativeDirectory.isNotEmpty) {
        knownOwners[p.relativeDirectory] = (
          sourceId: sourceId,
          comicId: relComicId,
        );
      }
    }
    final records = await _index.list();
    for (final rec in records) {
      final dir = _extractComicDirNameFromRecordPath(rec.path);
      if (dir != null && dir.isNotEmpty) {
        knownOwners.putIfAbsent(
          dir,
          () => (
            sourceId: rec.id.content.sourceId,
            comicId: rec.id.content.comicId,
          ),
        );
      }
    }
    final safIo = safTreeIo;
    final treeUri = this.safTreeUri;
    if (safIo != null && treeUri != null) {
      return inspectSafComicConflicts(
        safIo: safIo,
        safTreeUri: treeUri,
        sourceId: sourceId,
        sourceDisplayName: sourceDisplayName,
        comicId: comicId,
        comicTitle: comicTitle,
        knownPredecessorComicIds: preds.isNotEmpty ? preds : null,
        knownSuccessorComicIds: succs.isNotEmpty ? succs : null,
        knownDirectoryOwners: knownOwners,
      );
    }
    final rootDir = _registry.layoutForSource(sourceId).root;
    return inspectPosixComicConflicts(
      rootDirectory: rootDir,
      sourceId: sourceId,
      sourceDisplayName: sourceDisplayName,
      comicId: comicId,
      comicTitle: comicTitle,
      knownPredecessorComicIds: preds.isNotEmpty ? preds : null,
      knownSuccessorComicIds: succs.isNotEmpty ? succs : null,
      knownDirectoryOwners: knownOwners,
    );
  }

  /// Scans the target comic folder (and chapter subfolder) on disk (or in SAF)
  /// and returns a map of existing page numbers (1-based) to their paths and byte sizes.
  Future<Map<int, ({String path, int bytes})>> scanExistingPages({
    required String comicTitle,
    required String chapterTitle,
    int sequence = 1,
    bool isSingleChapter = false,
    String? comicDirectoryName,
    String? chapterDirectoryName,
    CancelToken? cancelToken,
    DownloadId? layoutId,
  }) async {
    _requireOpen();
    final result = <int, ({String path, int bytes})>{};
    final comicDir = _requireSafeComicDirectoryName(
      comicDirectoryName ?? buildComicDirectoryName(comicTitle: comicTitle),
    );
    final chapterDir = _requireSafeComicDirectoryName(
      chapterDirectoryName ??
          buildChapterDirectoryName(chapterTitle, fallbackIndex: sequence),
    );
    final safIo = safTreeIo;
    final treeUri = this.safTreeUri;

    if (safIo != null && treeUri != null) {
      final targetRelPath = isSingleChapter
          ? comicDir
          : '$comicDir/$chapterDir';
      final entries = await safIo.list(targetRelPath);
      for (final entry in entries) {
        cancelToken?.throwIfCancelled();
        if (entry.isDirectory) continue;
        final pageNum = parsePageIndexFromFileName(entry.name);
        if (pageNum != null && entry.length > 0) {
          final relPath = '$targetRelPath/${entry.name}';
          final handle = await safIo.open(relPath, mode: SafWriteMode.read);
          if (handle != null) {
            try {
              final header = await safIo.read(handle, 32);
              if (sniffImageExtensionFromBytes(header) != 'bin') {
                final recPath = encodeSafRecordPath(
                  treeUri: treeUri,
                  relativePath: relPath,
                );
                result[pageNum] = (path: recPath, bytes: entry.length);
              }
            } catch (_) {
              // Ignore unreadable entries
            } finally {
              await safIo.close(handle);
            }
          }
        }
      }
      return result;
    }

    final rootDir =
        (layoutId == null ? _registry.layout : _registry.layoutFor(layoutId))
        .root;
    final targetPath = isSingleChapter
        ? '$rootDir/$comicDir'
        : '$rootDir/$comicDir/$chapterDir';
    _rejectLocalPathLinks(targetPath);
    final targetDir = Directory(targetPath);
    if (!await targetDir.exists()) {
      return result;
    }

    try {
      await for (final entity in targetDir.list(followLinks: false)) {
        cancelToken?.throwIfCancelled();
        if (entity is File) {
          final fileName = entity.uri.pathSegments.isNotEmpty
              ? entity.uri.pathSegments.last
              : entity.path.split('/').last;
          final pageNum = parsePageIndexFromFileName(fileName);
          if (pageNum != null) {
            final len = await entity.length();
            if (len > 0) {
              final ext = await sniffImageExtension(entity);
              if (ext != 'bin') {
                result[pageNum] = (path: entity.path, bytes: len);
              }
            }
          }
        }
      }
    } catch (e) {
      if (e is Failure && e.code == ErrorCode.cancelled) rethrow;
    }

    return result;
  }

  /// Registers an already-present page file into the index without a
  /// network download. Returns the record so callers can update an in-memory
  /// index projection without a full re-scan.
  Future<CacheRec> adoptExistingPageRecord({
    required DownloadId id,
    required String path,
    required int bytes,
    required String checksum,
    String? artifactId,
    String? storageRootId,
  }) => _serializeArtifactMutation(
        id,
        () => _serializeStructuredWrite(
          path,
          () => _adoptExistingPageRecord(
            id: id,
            path: path,
            bytes: bytes,
            checksum: checksum,
            artifactId: artifactId,
            storageRootId: storageRootId,
          ),
        ),
      );

  Future<CacheRec> _adoptExistingPageRecord({
    required DownloadId id,
    required String path,
    required int bytes,
    required String checksum,
    String? artifactId,
    String? storageRootId,
  }) async {
    _requireOpen();
    final normalizedChecksum = checksum.trim().toLowerCase();
    if (bytes <= 0 || !RegExp(r'^[0-9a-f]{8}$').hasMatch(normalizedChecksum)) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'cannot adopt an artifact without content proof',
      );
    }
    final proof = await _artifactProof(path);
    if (proof.bytes != bytes || proof.checksum != normalizedChecksum) {
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message: 'artifact changed before adoption: $path',
      );
    }
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    final rec = CacheRec(
      id: id,
      state: CacheState.ready,
      path: path,
      bytes: bytes,
      checksum: normalizedChecksum,
      createdUs: nowUs,
      touchedUs: nowUs,
      pinned: true,
      artifactId: artifactId ?? '',
      storageRootId: storageRootId ?? _storageRootIdForPath(path, id: id),
    );
    await _index.put(rec);
    return rec;
  }

  /// Mirrors a freshly promoted local final into the configured SAF tree or
  /// structured POSIX comic folder and rewrites the index record to its path.
  Future<void> mirrorPromotedToSafIfConfigured(
    DownloadId id, {
    ImportedLibraryEntry? entry,
    int? pageIndex,
    bool isSingleChapter = false,
    String? comicDirectoryName,
    String? chapterDirectoryName,
  }) => _serializeArtifactMutation(
        id,
        () => _mirrorPromotedToSafIfConfigured(
          id,
          entry: entry,
          pageIndex: pageIndex,
          isSingleChapter: isSingleChapter,
          comicDirectoryName: comicDirectoryName,
          chapterDirectoryName: chapterDirectoryName,
        ),
      );

  Future<void> _mirrorPromotedToSafIfConfigured(
    DownloadId id, {
    ImportedLibraryEntry? entry,
    int? pageIndex,
    bool isSingleChapter = false,
    String? comicDirectoryName,
    String? chapterDirectoryName,
  }) async {
    final rec = (await _index.get(id.key));
    if (rec == null || parseSafRecordPath(rec.path) != null) return;
    final local = File(rec.path);
    if (rec.bytes <= 0 || !await local.exists()) return;
    final ext = await sniffImageExtension(local);
    if (entry != null && pageIndex != null && ext == 'bin') {
      final obviousText = await isHtmlOrTextFile(local);
      try {
        await local.delete();
      } on Object {}
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message: obviousText
            ? 'downloaded page payload is HTML or non-image text: ${local.path}'
            : 'downloaded page payload has no supported image signature: ${local.path}',
      );
    }
    final token = _registry.layout.tokenFor(id);

    final safIo = safTreeIo;
    final treeUri = this.safTreeUri;

    if (safIo != null && treeUri != null) {
      final String relativePath;
      if (entry != null && pageIndex != null) {
        final comicDir = _requireSafeComicDirectoryName(
          comicDirectoryName ??
              buildComicDirectoryName(comicTitle: entry.chapter.comicTitle),
        );
        final pageFileName = buildPageFileName(
          pageIndex: pageIndex,
          extension: ext,
        );
        if (isSingleChapter) {
          relativePath = '$comicDir/$pageFileName';
        } else {
          final chapterDir = _requireSafeComicDirectoryName(
            chapterDirectoryName ??
                buildChapterDirectoryName(
                  entry.chapter.displayName,
                  fallbackIndex: entry.chapter.sequence,
                ),
          );
          relativePath = '$comicDir/$chapterDir/$pageFileName';
        }
      } else {
        relativePath = 'final/$token.$ext';
      }

      final recordPath = encodeSafRecordPath(
        treeUri: treeUri,
        relativePath: relativePath,
      );
      await _serializeStructuredWrite(recordPath, () async {
        final siblings = (await _index.listPathBindings(
          recordPath,
          excludingKey: id.key,
        )).where(_isVerifiedReadyRecord);
        final safExists = await safIo.exists(relativePath);
        if (safExists) {
          final proof = await _artifactProof(recordPath);
          if (_proofMatchesRecord(proof, rec)) {
            await _commitAuthoritySwitchWithObsoleteSealedCleanup<void>(
              oldAccessLocator: rec.path,
              oldStorageRootId: rec.storageRootId,
              expectedBytes: rec.bytes,
              expectedChecksum: rec.checksum,
              expectedChecksumAlgorithm: rec.checksumAlgorithm,
              commit: () => _adoptExistingPageRecord(
                id: id,
                path: recordPath,
                bytes: rec.bytes,
                checksum: rec.checksum,
                artifactId: rec.artifactId,
                storageRootId: entry == null
                    ? safTreeUri
                    : storageRootIdFor(entry),
              ),
            );
            return;
          }
        }
        final placement = entry == null
            ? null
            : await resolveDownloadPlacement(entry);
        if (siblings.isNotEmpty || safExists) {
          if (placement?.mode != DownloadPlacementMode.overwrite &&
              placement?.mode != DownloadPlacementMode.incremental) {
            throw Failure(
              code: ErrorCode.policy,
              message:
                  'structured download destination contains different bytes: '
                  '$relativePath',
            );
          }
          if (siblings.any(
            (candidate) => !_bindingMayBeReplaced(candidate, id, placement),
          )) {
            throw Failure(
              code: ErrorCode.policy,
              message:
                  'structured target is still referenced by another owner: '
                  '$relativePath',
            );
          }
        }
        await _copyFileIntoSafTracked(safIo, local, relativePath);
        final proof = await _artifactProof(recordPath);
        if (!_proofMatchesRecord(proof, rec)) {
          await _bytes.delete(recordPath);
          throw Failure(
            code: ErrorCode.artifactCorruption,
            message: 'structured target failed verification: $relativePath',
          );
        }
        final committed = rec.copyWith(
          path: recordPath,
          pinned: true,
          storageRootId: entry == null ? safTreeUri! : storageRootIdFor(entry),
        );
        await _commitAuthoritySwitchWithObsoleteSealedCleanup<void>(
          oldAccessLocator: rec.path,
          oldStorageRootId: rec.storageRootId,
          expectedBytes: rec.bytes,
          expectedChecksum: rec.checksum,
          expectedChecksumAlgorithm: rec.checksumAlgorithm,
          commit: () async {
            if (placement?.mode == DownloadPlacementMode.overwrite) {
              await _index.replacePathBindings(
                record: committed,
                path: recordPath,
              );
            } else {
              await _index.put(committed);
            }
          },
        );
      });
    } else if (entry != null && pageIndex != null) {
      final rootDir = _layoutForEntryPage(entry, pageIndex - 1).root;
      final comicDir = _requireSafeComicDirectoryName(
        comicDirectoryName ??
            buildComicDirectoryName(comicTitle: entry.chapter.comicTitle),
      );
      final pageFileName = buildPageFileName(
        pageIndex: pageIndex,
        extension: ext,
      );
      final String relativePath;
      if (isSingleChapter) {
        relativePath = '$comicDir/$pageFileName';
      } else {
        final chapterDir = _requireSafeComicDirectoryName(
          chapterDirectoryName ??
              buildChapterDirectoryName(
                entry.chapter.displayName,
                fallbackIndex: entry.chapter.sequence,
              ),
        );
        relativePath = '$comicDir/$chapterDir/$pageFileName';
      }
      final destFile = File('$rootDir/$relativePath');
      _rejectLocalPathLinks(destFile.path);
      if (destFile.path != local.path) {
        await _serializeStructuredWrite(destFile.path, () async {
          final siblings = (await _index.listPathBindings(
            destFile.path,
            excludingKey: id.key,
          )).where(_isVerifiedReadyRecord);
          final destExists = await destFile.exists();
          if (destExists) {
            final proof = await _artifactProof(destFile.path);
            if (_proofMatchesRecord(proof, rec)) {
              await _commitAuthoritySwitchWithObsoleteSealedCleanup<void>(
                oldAccessLocator: rec.path,
                oldStorageRootId: rec.storageRootId,
                expectedBytes: rec.bytes,
                expectedChecksum: rec.checksum,
                expectedChecksumAlgorithm: rec.checksumAlgorithm,
                commit: () => _adoptExistingPageRecord(
                  id: id,
                  path: destFile.path,
                  bytes: rec.bytes,
                  checksum: rec.checksum,
                  artifactId: rec.artifactId,
                  storageRootId: storageRootIdFor(entry),
                ),
              );
              return;
            }
          }
          final placement = await resolveDownloadPlacement(entry);
          if (siblings.isNotEmpty || destExists) {
            if (placement.mode != DownloadPlacementMode.overwrite &&
                placement.mode != DownloadPlacementMode.incremental) {
              throw Failure(
                code: ErrorCode.policy,
                message:
                    'structured download destination contains different bytes: '
                    '${destFile.path}',
              );
            }
            if (siblings.any(
              (candidate) => !_bindingMayBeReplaced(candidate, id, placement),
            )) {
              throw Failure(
                code: ErrorCode.policy,
                message:
                    'structured target is still referenced by another owner: '
                    '${destFile.path}',
              );
            }
          }
          if (!await destFile.parent.exists()) {
            await destFile.parent.create(recursive: true);
          }
          await local.rename(destFile.path);
          final committed = rec.copyWith(
            path: destFile.path,
            pinned: true,
            storageRootId: storageRootIdFor(entry),
          );
          try {
            if (placement.mode == DownloadPlacementMode.overwrite) {
              await _index.replacePathBindings(
                record: committed,
                path: destFile.path,
              );
            } else {
              await _index.put(committed);
            }
          } catch (_) {
            // Keep the original staging/index authority when the logical
            // binding commit fails. Without this rollback the destination
            // file is unindexed and the next scanner pass can delete it.
            if (await destFile.exists() && !await local.exists()) {
              try {
                await destFile.rename(local.path);
              } catch (_) {}
            }
            rethrow;
          }
        });
      }
    }
  }

  /// Materializes a sibling page file to this task's destination directory if
  /// the task uses a separate structured folder (e.g. createNew mode).
  Future<String> materializeSiblingToDestinationIfSeparate({
    required CacheRec siblingRecord,
    required ImportedLibraryEntry entry,
    required int pageNumber,
    bool isSingleChapter = false,
    String? comicDirectoryName,
    String? chapterDirectoryName,
  }) async {
    if (!_isVerifiedReadyRecord(siblingRecord)) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'sibling artifact has no durable content proof',
      );
    }
    final placement = await resolveDownloadPlacement(entry);
    final comicDir = _requireSafeComicDirectoryName(
      comicDirectoryName ?? placement.relativeDirectory,
    );
    final siblingPath = siblingRecord.path;
    final ext = await _sniffArtifactExtension(siblingPath);
    final pageFileName = buildPageFileName(
      pageIndex: pageNumber,
      extension: ext,
    );
    final safIo = safTreeIo;
    final treeUri = this.safTreeUri;
    final String relativePath;
    if (isSingleChapter) {
      relativePath = '$comicDir/$pageFileName';
    } else {
      final chapterDir = _requireSafeComicDirectoryName(
        chapterDirectoryName ??
            buildChapterDirectoryName(
              entry.chapter.displayName,
              fallbackIndex: entry.chapter.sequence,
            ),
      );
      relativePath = '$comicDir/$chapterDir/$pageFileName';
    }
    final targetPath = safIo != null && treeUri != null
        ? encodeSafRecordPath(treeUri: treeUri, relativePath: relativePath)
        : '${_layoutForEntryPage(entry, pageNumber - 1).root}/$relativePath';
    if (targetPath == siblingPath) return siblingPath;
    if (safIo == null || treeUri == null) {
      _rejectLocalPathLinks(targetPath);
    }

    await _serializeStructuredWrite(targetPath, () async {
      if (await _bytes.exists(targetPath)) {
        final targetProof = await _artifactProof(targetPath);
        if (_proofMatchesRecord(targetProof, siblingRecord)) return;
        throw Failure(
          code: ErrorCode.artifactCorruption,
          message: 'materialized target contains different bytes: $targetPath',
        );
      }
      if (safIo != null && treeUri != null) {
        await _copyArtifactToSaf(
          siblingRecord,
          targetPath: targetPath,
          relativePath: relativePath,
        );
      } else {
        await _copyArtifactToLocal(
          siblingRecord,
          targetPath,
          storageRootId: _layoutForEntryPage(entry, pageNumber - 1).root,
        );
      }
      final targetProof = await _artifactProof(targetPath);
      if (!_proofMatchesRecord(targetProof, siblingRecord)) {
        await _bytes.delete(targetPath);
        throw Failure(
          code: ErrorCode.artifactCorruption,
          message:
              'materialized target failed content verification: $targetPath',
        );
      }
    });
    return targetPath;
  }

  Future<String> _sniffArtifactExtension(String path) async {
    await for (final chunk in _bytes.readChunks(
      path,
      start: 0,
      endExclusive: 32,
    )) {
      final extension = sniffImageExtensionFromBytes(chunk);
      if (extension != 'bin') return extension;
      break;
    }
    return 'jpg';
  }

  Future<void> _copyArtifactToLocal(
    CacheRec source,
    String targetPath, {
    required String storageRootId,
  }) async {
    _rejectLocalPathLinks(targetPath);
    final target = File(targetPath);
    await target.parent.create(recursive: true);
    final temporary = File(
      '$targetPath.zic-tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    await _registerTemporaryCleanupDebt(
      temporary.path,
      storageRootId: storageRootId,
    );
    final sink = temporary.openWrite();
    final crc = Crc32();
    var bytes = 0;
    try {
      await for (final chunk in _bytes.readChunks(source.path, start: 0)) {
        sink.add(chunk);
        crc.add(chunk);
        bytes += chunk.lengthInBytes;
      }
      await sink.flush();
      await sink.close();
      if (bytes != source.bytes || crc.hex != source.checksum) {
        throw Failure(
          code: ErrorCode.artifactCorruption,
          message:
              'sibling artifact changed during materialization: ${source.path}',
        );
      }
      await temporary.rename(targetPath);
    } on Object {
      try {
        await sink.close();
      } on Object {}
      if (await temporary.exists()) {
        await temporary.delete();
      }
      if (!await temporary.exists()) {
        await _forgetStorageCleanupDebt(temporary.path);
      }
      rethrow;
    }
    if (!await temporary.exists()) {
      await _forgetStorageCleanupDebt(temporary.path);
    }
  }

  Future<void> _copyArtifactToSaf(
    CacheRec source, {
    required String targetPath,
    required String relativePath,
  }) async {
    final io = safTreeIo!;
    final treeUri = safTreeUri!;
    final temporaryPath =
        '$relativePath.zic-tmp-${DateTime.now().microsecondsSinceEpoch}';
    final temporaryRecordPath = encodeSafRecordPath(
      treeUri: treeUri,
      relativePath: temporaryPath,
    );
    await _registerTemporaryCleanupDebt(
      temporaryRecordPath,
      storageRootId: treeUri,
    );
    final handle = await io.open(
      temporaryPath,
      mode: SafWriteMode.writeTruncate,
    );
    if (handle == null) {
      throw StateError('SAF tree refused create for $temporaryPath');
    }
    final crc = Crc32();
    var bytes = 0;
    try {
      await for (final chunk in _bytes.readChunks(source.path, start: 0)) {
        await io.write(handle, chunk);
        crc.add(chunk);
        bytes += chunk.lengthInBytes;
      }
    } finally {
      await io.close(handle);
    }
    try {
      if (bytes != source.bytes || crc.hex != source.checksum) {
        throw Failure(
          code: ErrorCode.artifactCorruption,
          message:
              'sibling artifact changed during materialization: ${source.path}',
        );
      }
      final proof = await _artifactProof(temporaryRecordPath);
      if (!_proofMatchesRecord(proof, source)) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'SAF temporary artifact failed content verification',
        );
      }
      await commitSafTemporary(io, temporaryPath, relativePath);
    } finally {
      if (await io.exists(temporaryPath)) {
        await io.delete(temporaryPath);
      }
      if (!await io.exists(temporaryPath)) {
        await _forgetStorageCleanupDebt(temporaryRecordPath);
      }
    }
  }

  bool _bindingMayBeReplaced(
    CacheRec candidate,
    DownloadId id,
    DownloadPlacement? placement,
  ) {
    final candidateOwner =
        '${candidate.id.content.sourceId}\u0000${candidate.id.content.comicId}';
    final currentOwner = '${id.content.sourceId}\u0000${id.content.comicId}';
    return candidateOwner == currentOwner ||
        (placement?.mode == DownloadPlacementMode.overwrite &&
            placement?.observedOwnerKey == candidateOwner);
  }


}
