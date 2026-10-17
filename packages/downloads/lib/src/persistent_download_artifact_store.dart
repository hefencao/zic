part of 'chapter_downloads.dart';

/// Durable storage owner for promoted image artifacts and cold partials.
///
/// This object never opens a source/network transfer. It owns only the
/// persistent SQLite/file representation used by [ArtifactCacheManager] and
/// [PartialDownloadStore]. Explicit chapter commands and Reader consumers
/// share a separate [CompositionDownloadTransferRuntime].
final class _DeleteImpactPhysicalGroup {
  final Set<String> artifactIds = <String>{};
  final Set<String> paths = <String>{};
  int bytes = 0;

  void add(CacheRec record) {
    artifactIds.add(record.effectiveArtifactId);
    paths.add(record.path);
    if (record.bytes > bytes) bytes = record.bytes;
  }

  void absorb(_DeleteImpactPhysicalGroup other) {
    artifactIds.addAll(other.artifactIds);
    paths.addAll(other.paths);
    if (other.bytes > bytes) bytes = other.bytes;
  }
}

final class _ArtifactAccessRecord {
  const _ArtifactAccessRecord({
    required this.artifactId,
    required this.replicaId,
    required this.accessLocator,
    required this.bytes,
    required this.checksum,
    required this.checksumAlgorithm,
    required this.storageRootId,
  });

  factory _ArtifactAccessRecord.fromBinding(CacheRec record) =>
      _ArtifactAccessRecord(
        artifactId: record.effectiveArtifactId,
        replicaId: record.effectiveArtifactId,
        accessLocator: record.path,
        bytes: record.bytes,
        checksum: record.checksum,
        checksumAlgorithm: record.checksumAlgorithm,
        storageRootId: record.storageRootId,
      );

  final String artifactId;
  final String replicaId;
  final String accessLocator;
  final int bytes;
  final String checksum;
  final String checksumAlgorithm;
  final String storageRootId;
}

final class _ArtifactAccessCandidate {
  const _ArtifactAccessCandidate({required this.access, this.rootAccess});

  final _ArtifactAccessRecord access;
  final StorageAccessLocatorRecord? rootAccess;
}

final class _PersistentBoundRangeReader
    implements ArtifactCacheBoundRangeReader {
  _PersistentBoundRangeReader({
    required ArtifactByteRangeReader primary,
    required Future<Uint8List> Function(int start, int endExclusive) fallback,
  }) : _primary = primary,
       _fallback = fallback;

  ArtifactByteRangeReader? _primary;
  final Future<Uint8List> Function(int start, int endExclusive) _fallback;
  Future<void> _tail = Future<void>.value();
  bool _closed = false;

  @override
  String get accessMode => _primary?.accessMode ?? 'fallback';

  @override
  String? get directFilePath => _primary?.directFilePath;

  @override
  Future<Uint8List> readRange(int start, int endExclusive) {
    final result = Completer<Uint8List>();
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    unawaited(() async {
      try {
        await previous;
        if (_closed) {
          throw StateError('artifact bound range reader is closed');
        }
        final primary = _primary;
        if (primary != null) {
          try {
            result.complete(await primary.readRange(start, endExclusive));
            return;
          } on Object {
            _primary = null;
            try {
              await primary.close();
            } on Object {
              // The stateless fallback below remains the correctness owner.
            }
          }
        }
        result.complete(await _fallback(start, endExclusive));
      } catch (error, stackTrace) {
        if (!result.isCompleted) result.completeError(error, stackTrace);
      } finally {
        if (!done.isCompleted) done.complete();
      }
    }());
    return result.future;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _tail;
    final primary = _primary;
    _primary = null;
    if (primary != null) await primary.close();
  }
}

final class ArtifactReplicaMigrationResult {
  const ArtifactReplicaMigrationResult({
    required this.replica,
    required this.sourceCleanupComplete,
  });

  final ArtifactReplicaRecord replica;

  /// False means destination authority is already committed but best-effort
  /// cleanup of the former physical location did not complete.
  final bool sourceCleanupComplete;
}

final class PersistentDownloadArtifactStore
    with _PersistentDownloadStructuredPlacementMixin
    implements
        ArtifactCacheBackend,
        ArtifactCacheRetentionQuery,
        ArtifactCacheBindingBackend,
        HistoricalArtifactCarrierQueryBackend,
        DownloadCacheMutationOwner,
        PhysicalArtifactCacheBackend,
        PhysicalArtifactBoundReplayBackend,
        PhysicalArtifactCandidateBindingBackend,
        PhysicalArtifactExactBindingBackend,
        PhysicalPartialDownloadStore,
        PartialDownloadStore,
        TransferStagingPartialDownloadStore,
        PartialDownloadMetadataStore,
        ArtifactCacheMaintenance {
  PersistentDownloadArtifactStore._({
    required DownloadRegistry registry,
    required SqliteIndex index,
    required CacheOps cacheOps,
    required ArtifactBytes bytes,
    required File recoveryMarker,
    required RandomAccessFile metadataOwnerLock,
    required String metadataOwnerKey,
    required this._storageWriteScheduler,
    this.safTreeIo,
    required this.safTreeUri,
    this.presentationFileLeaseFactory,
    TraceSink? traceSink,
    MonoClock? clock,
  })  : _registry = registry,
        _index = index,
        _cacheOps = cacheOps,
        _bytes = bytes,
        _recoveryMarker = recoveryMarker,
        _metadataOwnerLock = metadataOwnerLock,
        _metadataOwnerKey = metadataOwnerKey,
        _traceSink = traceSink ?? const NoopTraceSink(),
        _clock = clock ?? const SystemClock();

  final TraceSink _traceSink;
  final MonoClock _clock;
  final StreamController<void> _managementProjectionChanges =
      StreamController<void>.broadcast(sync: true);

  Stream<void> get managementProjectionChanges =>
      _managementProjectionChanges.stream;

  void _notifyManagementProjectionChanged() {
    if (!_managementProjectionChanges.isClosed) {
      _managementProjectionChanges.add(null);
    }
  }

  Future<T> _notifyManagementAfter<T>(
    Future<T> operation, {
    bool Function(T result)? when,
  }) async {
    final result = await operation;
    if (when == null || when(result)) {
      _notifyManagementProjectionChanged();
    }
    return result;
  }

  List<ComicVersionRelation> _downloadHeadRelations =
      const <ComicVersionRelation>[];
  void updateVersionBaselines(List<ComicVersionRelation> relations) {
    _downloadHeadRelations = List<ComicVersionRelation>.unmodifiable(relations);
  }

  void updateCacheVersionRelations(List<ComicVersionRelation> relations) {
    // Cache-version fallback belongs to ArtifactCacheManager's verified
    // direct/lazy equivalence resolvers. The persistent backend is exact-only.
  }

  static Future<PersistentDownloadArtifactStore> open(
    String root, {
    String? directory,
    String? indexPath,
    CacheLayout? Function(DownloadId id)? layoutResolver,
    ArtifactBytes? bytes,
    StorageWriteScheduler? storageWriteScheduler,
    SafTreeIo? safMirror,
    String? safTreeUri,
    ArtifactPresentationFileLeaseFactory? presentationFileLeaseFactory,
    TraceSink? traceSink,
    MonoClock? clock,
  }) async {
    final layout = CacheLayout(
      directory ?? defaultChapterDownloadDirectory(root),
    );
    final resolvedIndexPath = File(indexPath ?? layout.dbPath).absolute.path;
    if (!_processMetadataOwners.add(resolvedIndexPath)) {
      throw StateError(
        'persistent download metadata is already owned in this process: '
        '$resolvedIndexPath',
      );
    }
    final metadataOwnerFile = File('$resolvedIndexPath.owner.lock');
    RandomAccessFile? metadataOwnerLock;
    try {
      await metadataOwnerFile.parent.create(recursive: true);
      metadataOwnerLock = await metadataOwnerFile.open(mode: FileMode.append);
      await metadataOwnerLock.lock(FileLock.exclusive);
    } on FileSystemException catch (error) {
      await metadataOwnerLock?.close();
      _processMetadataOwners.remove(resolvedIndexPath);
      throw StateError(
        'persistent download metadata owner lock failed: '
        '$resolvedIndexPath ($error)',
      );
    } on Object {
      await metadataOwnerLock?.close();
      _processMetadataOwners.remove(resolvedIndexPath);
      rethrow;
    }
    final ownerLock = metadataOwnerLock;
    final index = SqliteIndex(resolvedIndexPath);
    try {
      await index.open();
    final resolvedClock = clock ?? const SystemClock();
    final registry = DownloadRegistry(
      layout: layout,
      clock: resolvedClock,
      index: index,
      layoutResolver: layoutResolver,
    );
    final recoveryMarker = File(
      '${layout.root}${Platform.pathSeparator}$_recoveryMarkerName',
    );
    final recoveryRequired = await recoveryMarker.exists();
    if (recoveryRequired) {
      // Marker contents are not live-owner evidence. Existence alone means the
      // previous lifecycle did not reach clean close; process ownership is
      // exclusively enforced by the metadata owner acquired above.
      try {
        await StartupRecovery(
          layout: layout,
          index: index,
          clock: resolvedClock,
          traceSink: traceSink ?? const NoopTraceSink(),
        ).run();
      } on Object {
        await registry.dispose();
        await index.close();
        rethrow;
      }
    }
    // Promotion recovery can mutate artifact/replica authority. Run it only
    // after the metadata process owner above has ruled out a concurrent store
    // owner. The recovery marker is crash evidence only; it is not a live-owner
    // lock. Dirty StartupRecovery already protects both journal locators, so
    // ordering this after its orphan pass is safe and avoids a second opener
    // committing another owner's in-flight promotion.
    await _ArtifactPromotionRecovery._recoverPendingArtifactPromotions(index);
    await recoveryMarker.parent.create(recursive: true);
    // This marker protects process-crash recovery, not sudden-power-loss
    // durability. Waiting for an fsync on the byte/cache root here puts
    // removable/emulated-storage latency directly on every clean app open.
    // File.writeAsString still completes the write before open returns, so a
    // later process can observe an unclean owner without taxing startup with
    // a synchronous storage flush.
    await recoveryMarker.writeAsString(_processRecoveryOwner);
    final resolvedBytes =
        bytes ??
        (safMirror == null
            ? const LocalArtifactBytes()
            : CompositeArtifactBytes(
                local: const LocalArtifactBytes(),
                saf: SafArtifactBytes(safMirror, treeUri: safTreeUri),
              ));
    final resolvedStorageWriteScheduler =
        storageWriteScheduler ??
        StorageWriteScheduler(localReadScheduler: ArtifactCacheReadScheduler());
    late final PersistentDownloadArtifactStore resolved;
    resolved = PersistentDownloadArtifactStore._(
      registry: registry,
      index: index,
      cacheOps: CacheOps(
        index: index,
        registry: registry,
        clock: resolvedClock,
        evictRecordWithSnapshot: (id, expected) =>
            resolved._evictCacheRecord(id, expected: expected),
      ),
      bytes: resolvedBytes,
      recoveryMarker: recoveryMarker,
      metadataOwnerLock: ownerLock,
      metadataOwnerKey: resolvedIndexPath,
      storageWriteScheduler: resolvedStorageWriteScheduler,
      safTreeIo: safMirror,
      safTreeUri: safTreeUri,
      presentationFileLeaseFactory: presentationFileLeaseFactory,
      traceSink: traceSink,
      clock: resolvedClock,
    );
    await resolved._recoverSafBodyTransactions();
    await resolved._recoverStructuredSafManifestTransactions();
    resolved._scheduleCleanupDebtDrain();
    resolved._scheduleRedundantPhysicalPartialSweep();
    return resolved;
    } on Object {
      try {
        await index.close();
      } on Object {
        // Preserve the original open failure.
      }
      try {
        await ownerLock.unlock();
      } on Object {
        // A failed open never hands the owner lock to a store instance.
      }
      await ownerLock.close();
      _processMetadataOwners.remove(resolvedIndexPath);
      rethrow;
    }
  }

  /// The SAF tree finals mirror into; null keeps everything local.
  final String? safTreeUri;

  String get storageRootId => safTreeUri ?? layout.root;

  Future<StorageRootRecord> registerStorageRootAccessAliasProof(
    StorageRootAccessAliasProof proof,
  ) async {
    _requireOpen();
    final root = await _index.registerStorageRootAccessAliasProof(
      proof,
      verifiedUs: DateTime.now().toUtc().microsecondsSinceEpoch,
    );
    _scheduleCleanupDebtDrain();
    return root;
  }

  Future<StorageRootRecord?> storageRootForAccess(String identity) {
    _requireOpen();
    return _index.getStorageRoot(identity);
  }

  Future<List<ArtifactReplicaRecord>> artifactReplicasFor(DownloadId id) async {
    _requireOpen();
    final record = await _index.get(id.key);
    if (record == null || record.id != id) {
      return const <ArtifactReplicaRecord>[];
    }
    return _index.listArtifactReplicas(record.effectiveArtifactId);
  }

  Future<ArtifactReplicaRecord> registerVerifiedArtifactReplica({
    required DownloadId id,
    required String accessLocator,
    required String storageRootId,
  }) => _serializeArtifactMutation(id, () async {
        _requireOpen();
        final record = await _index.get(id.key);
        if (record == null || !_isVerifiedReadyRecord(record) || record.id != id) {
          throw const Failure(
            code: ErrorCode.policy,
            message: 'replica registration requires an existing ready artifact',
          );
        }
        final normalizedLocator = accessLocator.trim();
        final normalizedRoot = storageRootId.trim();
        if (normalizedLocator.isEmpty || normalizedRoot.isEmpty) {
          throw ArgumentError('replica locator and storage root must not be empty');
        }

        // A proven Direct/SAF alternate access path to an existing physical
        // replica is not a second copy. Reuse that replica identity.
        final existing = await _resolveArtifactReplicas(record);
        for (final replica in existing) {
          final aliases = await _artifactAccessCandidates(replica);
          for (final alias in aliases) {
            if (alias.access.accessLocator == normalizedLocator) {
          return (await _index.listArtifactReplicas(
            record.effectiveArtifactId,
          )).firstWhere((value) => value.replicaId == replica.replicaId);
            }
          }
        }

        final candidate = _ArtifactAccessRecord(
          artifactId: record.effectiveArtifactId,
          replicaId: record.effectiveArtifactId,
          accessLocator: normalizedLocator,
          bytes: record.bytes,
          checksum: record.checksum,
          checksumAlgorithm: record.checksumAlgorithm,
          storageRootId: normalizedRoot,
        );
        if (!await _artifactRecordExists(candidate)) {
          throw ArtifactReadFailure(
            kind: ArtifactReadFailureKind.missing,
            accessLocator: normalizedLocator,
            replicaId: record.effectiveArtifactId,
            failedOffset: 0,
            bytesEmitted: 0,
            expectedLength: record.bytes,
            observedLength: 0,
          );
        }
        final length = await _artifactRecordLength(candidate);
        if (length != record.bytes) {
          throw ArtifactReadFailure(
            kind: ArtifactReadFailureKind.lengthChanged,
            accessLocator: normalizedLocator,
            replicaId: record.effectiveArtifactId,
            failedOffset: 0,
            bytesEmitted: 0,
            expectedLength: record.bytes,
            observedLength: length,
          );
        }
        final crc = Crc32();
        var consumed = 0;
        await for (final chunk in _bytes.readChunks(
          normalizedLocator,
          start: 0,
          endExclusive: record.bytes,
        )) {
          consumed += chunk.lengthInBytes;
          crc.add(chunk);
        }
        if (consumed != record.bytes ||
            record.checksumAlgorithm.toLowerCase() != 'crc32' ||
            crc.hex != record.checksum.trim().toLowerCase()) {
          throw const Failure(
            code: ErrorCode.artifactCorruption,
            message: 'replica candidate does not match immutable artifact proof',
          );
        }
        final nowUs = DateTime.now().toUtc().microsecondsSinceEpoch;
        return _index.putArtifactReplica(
          artifactId: record.effectiveArtifactId,
          accessLocator: normalizedLocator,
          storageRootId: normalizedRoot,
          createdUs: nowUs,
          touchedUs: nowUs,
        );
      });

  @override
  Future<void> _copyStructuredCompanion(String source, String destination,
      {required String storageRootId}) =>
      _copyCompanionLocators([source], destination, storageRootId: storageRootId);

  @override
  Future<void> _deleteStructuredCompanion(String source) =>
      _withStorageWriteQuantum(() => _deleteCompanionData(source));

  /// Moves one sealed physical replica while preserving [replicaId].
  ///
  /// Destination bytes are materialized and fully read-back verified before
  /// metadata authority moves. Source bytes are deleted only after that
  /// authority commit, so cancellation/failure cannot remove the last valid
  /// replica. Direct/SAF aliases already proven to address the same physical
  /// root are treated as the existing replica rather than copied.
  Future<ArtifactReplicaMigrationResult> migrateArtifactReplica({
    required DownloadId id,
    required String replicaId,
    required String destinationAccessLocator,
    required String destinationStorageRootId,
    TaskControl? control,
  }) => _serializeArtifactMutation(id, () async {
    _requireOpen();
    control?.throwIfCancelled();
    final record = await _index.get(id.key);
    if (record == null || !_isVerifiedReadyRecord(record) || record.id != id) {
      throw const Failure(
        code: ErrorCode.policy,
        message: 'replica migration requires an existing ready artifact',
      );
    }
    final normalizedReplicaId = replicaId.trim();
    final destinationLocator = destinationAccessLocator.trim();
    final destinationRoot = destinationStorageRootId.trim();
    if (normalizedReplicaId.isEmpty ||
        destinationLocator.isEmpty ||
        destinationRoot.isEmpty) {
      throw ArgumentError(
        'replica identity, destination locator, and destination root must not be empty',
      );
    }
    return _serializeArtifactReplicaMutation(
      record.effectiveArtifactId,
      () async {
        var pendingMigration = await _index.getArtifactReplicaMigration(
          normalizedReplicaId,
        );
        var effectiveDestinationLocator = destinationLocator;
        var effectiveDestinationRoot = destinationRoot;
        if (pendingMigration?.phase == ArtifactReplicaMigrationPhase.copying) {
          pendingMigration = await _rebindCopyingMigrationForCurrentAccess(
            pendingMigration!,
            requestedDestinationAccessLocator: destinationLocator,
            requestedDestinationStorageRootId: destinationRoot,
          );
          effectiveDestinationLocator = pendingMigration.destinationAccessLocator;
          effectiveDestinationRoot = pendingMigration.destinationStorageRootId;
        }
        return _serializeStructuredWrite(
          effectiveDestinationLocator,
          () async {
            if (pendingMigration?.phase ==
                ArtifactReplicaMigrationPhase.cleanupPending) {
              final cleanupComplete = await _cleanupCommittedReplicaMigration(
                pendingMigration!,
              );
              final current = await _index.getArtifactReplica(
                normalizedReplicaId,
              );
              if (current == null) {
                throw const Failure(
                  code: ErrorCode.policy,
                  message: 'cleanup debt refers to a missing artifact replica',
                );
              }
              final requestedRoot = await _index.getStorageRoot(destinationRoot);
              final requestedRootId = requestedRoot?.rootId ?? destinationRoot;
              if (current.accessLocator == destinationLocator &&
                  current.storageRootId == requestedRootId) {
                return ArtifactReplicaMigrationResult(
                  replica: current,
                  sourceCleanupComplete: cleanupComplete,
                );
              }
              if (!cleanupComplete) {
                throw const Failure(
                  code: ErrorCode.policy,
                  message: 'artifact replica has unresolved migration cleanup debt',
                );
              }
            }
            final replicas = await _resolveArtifactReplicas(record);
            final source = replicas
                .where(
                  (candidate) => candidate.replicaId == normalizedReplicaId,
                )
                .firstOrNull;
            if (source == null) {
              throw Failure(
                code: ErrorCode.policy,
                message: 'artifact replica does not exist: $normalizedReplicaId',
              );
            }
            final sourceAliases = await _artifactAccessCandidates(source);
            if (sourceAliases.any(
              (candidate) =>
                  candidate.access.accessLocator == effectiveDestinationLocator,
            )) {
              final current = await _index.getArtifactReplica(
                normalizedReplicaId,
              );
              if (current == null) {
                throw const Failure(
                  code: ErrorCode.policy,
                  message: 'artifact replica disappeared during migration',
                );
              }
              return ArtifactReplicaMigrationResult(
                replica: current,
                sourceCleanupComplete: true,
              );
            }
            for (final replica in replicas) {
              if (replica.replicaId == normalizedReplicaId) continue;
              final aliases = await _artifactAccessCandidates(replica);
              if (aliases.any(
                (candidate) =>
                    candidate.access.accessLocator == effectiveDestinationLocator,
              )) {
                throw const Failure(
                  code: ErrorCode.policy,
                  message:
                      'migration destination is already owned by another replica',
                );
              }
            }
            await _validateReplicaDestinationRoot(
              effectiveDestinationLocator,
              effectiveDestinationRoot,
            );
            await _ensureReplicaDestinationUnowned(
              currentReplicaId: normalizedReplicaId,
              accessLocator: effectiveDestinationLocator,
              storageRootId: effectiveDestinationRoot,
            );

            final temporaryLocator =
                pendingMigration?.phase == ArtifactReplicaMigrationPhase.copying
                ? pendingMigration!.temporaryAccessLocator
                : _replicaMigrationTemporaryLocator(
                    replicaId: normalizedReplicaId,
                    destinationAccessLocator: effectiveDestinationLocator,
                  );
            final migration = await _index.beginArtifactReplicaMigration(
              replicaId: normalizedReplicaId,
              sourceAccessLocator: source.accessLocator,
              sourceStorageRootId: source.storageRootId,
              destinationAccessLocator: effectiveDestinationLocator,
              destinationStorageRootId: effectiveDestinationRoot,
              temporaryAccessLocator: temporaryLocator,
              touchedUs: DateTime.now().toUtc().microsecondsSinceEpoch,
            );

            await _materializeReplicaDestination(
              record: record,
              sourceCandidates: sourceAliases,
              destinationAccessLocator: effectiveDestinationLocator,
              temporaryAccessLocator: migration.temporaryAccessLocator,
              control: control,
            );
            control?.throwIfCancelled();
            await _verifyReplicaDestination(
              record,
              effectiveDestinationLocator,
              control: control,
            );
            await _copyCompanionData(sourceAliases, effectiveDestinationLocator,
              storageRootId: effectiveDestinationRoot, control: control);
            control?.throwIfCancelled();
            final moved = await _index.commitArtifactReplicaMigration(
              replicaId: normalizedReplicaId,
              touchedUs: DateTime.now().toUtc().microsecondsSinceEpoch,
            );
            final sourceCleanupComplete =
                await _cleanupCommittedReplicaMigration(migration);
            return ArtifactReplicaMigrationResult(
              replica: moved,
              sourceCleanupComplete: sourceCleanupComplete,
            );
          },
        );
      },
    );
  });

  Future<void> _materializeReplicaDestination({
    required CacheRec record,
    required List<_ArtifactAccessCandidate> sourceCandidates,
    required String destinationAccessLocator,
    required String temporaryAccessLocator,
    TaskControl? control,
  }) async {
    final safDestination = parseSafRecordPath(destinationAccessLocator);
    final safTemporary = parseSafRecordPath(temporaryAccessLocator);
    if (safDestination == null) {
      if (safTemporary != null) {
        throw const Failure(
          code: ErrorCode.policy,
          message: 'direct replica migration requires a direct temporary path',
        );
      }
      _rejectLocalPathLinks(destinationAccessLocator);
      _rejectLocalPathLinks(temporaryAccessLocator);
    } else if (safTreeIo == null ||
        safTreeUri == null ||
        safDestination.treeUri != safTreeUri ||
        safTemporary == null ||
        safTemporary.treeUri != safDestination.treeUri) {
      throw const Failure(
        code: ErrorCode.policy,
        message: 'replica migration cannot write an unavailable SAF tree',
      );
    }

    final destinationExists = await _withStorageWriteQuantum(
      () => _bytes.exists(destinationAccessLocator),
      control: control,
    );
    if (destinationExists) {
      await _verifyReplicaDestination(
        record,
        destinationAccessLocator,
        control: control,
      );
      return;
    }

    var resumeOffset = await _validatedMigrationResumeOffset(
      record: record,
      sourceCandidates: sourceCandidates,
      temporaryAccessLocator: temporaryAccessLocator,
      control: control,
    );
    StreamIterator<Uint8List>? iterator;
    Object? primaryError;
    StackTrace? primaryStack;

    if (safDestination == null) {
      final destination = File(destinationAccessLocator);
      final temporary = File(temporaryAccessLocator);
      RandomAccessFile? writer;
      try {
        await _withStorageWriteQuantum(() async {
          await destination.parent.create(recursive: true);
          writer = await temporary.open(
            mode: resumeOffset == 0 ? FileMode.write : FileMode.append,
          );
          final actualLength = await writer!.length();
          if (actualLength != resumeOffset) {
            await writer!.close();
            writer = await temporary.open(mode: FileMode.write);
            resumeOffset = 0;
          }
        }, control: control);
        iterator = StreamIterator<Uint8List>(
          _readArtifactCandidates(
            sourceCandidates,
            start: resumeOffset,
            endExclusive: record.bytes,
          ),
        );
        while (true) {
          final lease = await _storageWriteScheduler.acquireQuantum(
            control: control,
          );
          try {
            control?.throwIfCancelled();
            if (!await _moveNextMigrationChunk(iterator, control)) break;
            await writer!.writeFrom(iterator.current);
          } finally {
            lease.release();
          }
        }
        await _withStorageWriteQuantum(() async {
          await writer!.flush();
          await writer!.close();
          writer = null;
        }, control: control);
        await _verifyReplicaDestination(
          record,
          temporaryAccessLocator,
          control: control,
        );
        control?.throwIfCancelled();
        final destinationAppeared = await _withStorageWriteQuantum(
          destination.exists,
          control: control,
        );
        if (destinationAppeared) {
          await _verifyReplicaDestination(
            record,
            destinationAccessLocator,
            control: control,
          );
          return;
        }
        await _withStorageWriteQuantum(
          () => temporary.rename(destinationAccessLocator),
          control: control,
        );
        return;
      } catch (error, stackTrace) {
        primaryError = error;
        primaryStack = stackTrace;
      } finally {
        if (writer != null) {
          try {
            await _withStorageWriteQuantum(writer!.close);
          } on Object {
            // Keep durable temporary bytes for the next resume attempt.
          }
        }
        if (iterator != null) {
          try {
            await iterator.cancel();
          } on Object catch (error, stackTrace) {
            if (primaryError == null) {
              primaryError = error;
              primaryStack = stackTrace;
            }
          }
        }
      }
    } else {
      final io = safTreeIo!;
      final temporaryRelative = safTemporary!.relativePath;
      int? writer;
      try {
        writer = await _withStorageWriteQuantum(
          () => io.open(
            temporaryRelative,
            mode: resumeOffset == 0
                ? SafWriteMode.writeTruncate
                : SafWriteMode.writeAppend,
          ),
          control: control,
        );
        if (writer == null) {
          throw StateError('SAF tree refused replica migration temporary');
        }
        final actualLength = await _withStorageWriteQuantum(
          () => io.length(writer!),
          control: control,
        );
        if (actualLength != resumeOffset) {
          await _withStorageWriteQuantum(
            () => io.close(writer!),
            control: control,
          );
          final restarted = await _withStorageWriteQuantum(
            () => io.open(temporaryRelative, mode: SafWriteMode.writeTruncate),
            control: control,
          );
          if (restarted == null) {
            throw StateError('SAF tree refused replica migration restart');
          }
          writer = restarted;
          resumeOffset = 0;
        }
        iterator = StreamIterator<Uint8List>(
          _readArtifactCandidates(
            sourceCandidates,
            start: resumeOffset,
            endExclusive: record.bytes,
          ),
        );
        while (true) {
          final lease = await _storageWriteScheduler.acquireQuantum(
            control: control,
          );
          try {
            control?.throwIfCancelled();
            if (!await _moveNextMigrationChunk(iterator, control)) break;
            await io.write(writer, iterator.current);
          } finally {
            lease.release();
          }
        }
        await _withStorageWriteQuantum(() async {
          await io.close(writer!);
          writer = null;
        }, control: control);
        await _verifyReplicaDestination(
          record,
          temporaryAccessLocator,
          control: control,
        );
        control?.throwIfCancelled();
        final destinationAppeared = await _withStorageWriteQuantum(
          () => io.exists(safDestination.relativePath),
          control: control,
        );
        if (destinationAppeared) {
          await _verifyReplicaDestination(
            record,
            destinationAccessLocator,
            control: control,
          );
          return;
        }
        final committed = await _withStorageWriteQuantum(
          () => io.rename(temporaryRelative, safDestination.relativePath),
          control: control,
        );
        if (!committed) {
          final racedDestination = await _withStorageWriteQuantum(
            () => io.exists(safDestination.relativePath),
            control: control,
          );
          if (racedDestination) {
            await _verifyReplicaDestination(
              record,
              destinationAccessLocator,
              control: control,
            );
            return;
          }
          throw StateError(
            'SAF tree refused no-replace replica migration commit',
          );
        }
        return;
      } catch (error, stackTrace) {
        primaryError = error;
        primaryStack = stackTrace;
      } finally {
        if (writer != null) {
          try {
            await _withStorageWriteQuantum(() => io.close(writer!));
          } on Object {
            // Keep durable temporary bytes for the next resume attempt.
          }
        }
        if (iterator != null) {
          try {
            await iterator.cancel();
          } on Object catch (error, stackTrace) {
            if (primaryError == null) {
              primaryError = error;
              primaryStack = stackTrace;
            }
          }
        }
      }
    }
    Error.throwWithStackTrace(primaryError!, primaryStack!);
  }

  Future<int> _validatedMigrationResumeOffset({
    required CacheRec record,
    required List<_ArtifactAccessCandidate> sourceCandidates,
    required String temporaryAccessLocator,
    TaskControl? control,
  }) async {
    final preflight = await _withStorageWriteQuantum(() async {
      final exists = await _bytes.exists(temporaryAccessLocator);
      final length = exists ? await _bytes.length(temporaryAccessLocator) : 0;
      return (exists: exists, length: length);
    }, control: control);
    if (!preflight.exists || preflight.length == 0) return 0;
    if (preflight.length < 0 || preflight.length > record.bytes) {
      await _deleteMigrationTemporary(temporaryAccessLocator, control: control);
      return 0;
    }
    final temporaryChecksum = await _migrationRangeChecksum(
      _bytes.readChunks(
        temporaryAccessLocator,
        start: 0,
        endExclusive: preflight.length,
      ),
      expectedBytes: preflight.length,
      control: control,
    );
    final sourceChecksum = await _migrationRangeChecksum(
      _readArtifactCandidates(
        sourceCandidates,
        start: 0,
        endExclusive: preflight.length,
      ),
      expectedBytes: preflight.length,
      control: control,
    );
    if (temporaryChecksum != sourceChecksum) {
      await _deleteMigrationTemporary(temporaryAccessLocator, control: control);
      return 0;
    }
    return preflight.length;
  }

  Future<String> _migrationRangeChecksum(
    Stream<Uint8List> chunks, {
    required int expectedBytes,
    TaskControl? control,
  }) async {
    final iterator = StreamIterator<Uint8List>(chunks);
    final crc = Crc32();
    var consumed = 0;
    Object? primaryError;
    StackTrace? primaryStack;
    try {
      while (true) {
        final lease = await _storageWriteScheduler.acquireQuantum(
          control: control,
        );
        try {
          control?.throwIfCancelled();
          if (!await _moveNextMigrationChunk(iterator, control)) break;
          final chunk = iterator.current;
          crc.add(chunk);
          consumed += chunk.length;
        } finally {
          lease.release();
        }
      }
    } catch (error, stackTrace) {
      primaryError = error;
      primaryStack = stackTrace;
    }
    try {
      await iterator.cancel();
    } on Object catch (error, stackTrace) {
      if (primaryError == null) {
        primaryError = error;
        primaryStack = stackTrace;
      }
    }
    if (primaryError != null) {
      Error.throwWithStackTrace(primaryError, primaryStack!);
    }
    if (consumed != expectedBytes) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'migration resume prefix length changed during verification',
      );
    }
    return crc.hex;
  }

  Future<void> _deleteMigrationTemporary(
    String accessLocator, {
    TaskControl? control,
  }) async {
    try {
      await _withStorageWriteQuantum(
        () => _bytes.delete(accessLocator),
        control: control,
      );
    } on Object {
      // The durable migration row still owns this non-authoritative temp. If
      // truncation cannot be established now, the next attempt will re-check.
    }
  }

  String _replicaMigrationTemporaryLocator({
    required String replicaId,
    required String destinationAccessLocator,
  }) {
    final token = defaultArtifactIdForPath(
      'replica-migration:$replicaId:$destinationAccessLocator',
    );
    final saf = parseSafRecordPath(destinationAccessLocator);
    if (saf != null) {
      return encodeSafRecordPath(
        treeUri: saf.treeUri,
        relativePath: '${saf.relativePath}.zic-migrate-$token.part',
      );
    }
    return '$destinationAccessLocator.zic-migrate-$token.part';
  }

  Future<bool> _cleanupCommittedReplicaMigration(
    ArtifactReplicaMigrationRecord migration,
  ) async {
    var complete = true;
    if (migration.sourceAccessLocator != migration.destinationAccessLocator) {
      final currentReplica = await _index.getArtifactReplica(migration.replicaId);
      final object = currentReplica == null
          ? null
          : await _index.getArtifactObject(currentReplica.artifactId);
      if (currentReplica == null || object == null) {
        complete = false;
      } else {
        final prepared = await _prepareObsoleteSealedReplicaCleanupDebt(
          replica: ArtifactReplicaRecord(
            replicaId: currentReplica.replicaId,
            artifactId: currentReplica.artifactId,
            accessLocator: migration.sourceAccessLocator,
            storageRootId: migration.sourceStorageRootId,
            createdUs: currentReplica.createdUs,
            touchedUs: currentReplica.touchedUs,
          ),
          expectedBytes: object.bytes,
          expectedChecksum: object.checksum,
          expectedChecksumAlgorithm: object.checksumAlgorithm,
        );
        if (!prepared.safeToRetire) {
          complete = false;
        } else if (prepared.debt != null &&
            !await _cleanupObsoleteSourceNow(prepared.debt!)) {
          complete = false;
        }
      }
    }
    if (migration.temporaryAccessLocator !=
            migration.destinationAccessLocator &&
        migration.temporaryAccessLocator != migration.sourceAccessLocator) {
      if (!await _cleanupMigrationOwnedLocatorAcrossAliases(
        migration.temporaryAccessLocator,
        migration.destinationStorageRootId,
      )) {
        complete = false;
      }
    }
    if (complete) {
      await _index.finishArtifactReplicaMigrationCleanup(migration.replicaId);
    }
    return complete;
  }

  Future<bool> _cleanupMigrationOwnedLocatorAcrossAliases(
    String accessLocator,
    String storageRootId,
  ) async {
    for (final candidate in await _equivalentStorageRootLocators(
      accessLocator: accessLocator,
      storageRootId: storageRootId,
    )) {
      if (!await _cleanupLocatorIsAvailable(
        candidate.accessLocator,
        candidate.storageRootId,
      )) {
        continue;
      }
      try {
        return await _withStorageWriteQuantum(() async {
          if (await _bytes.exists(candidate.accessLocator)) {
            await _bytes.delete(candidate.accessLocator);
          }
          return !await _bytes.exists(candidate.accessLocator);
        });
      } on Object {
        // Try another proven access alias for the same migration-owned temp.
      }
    }
    return false;
  }

  Future<void> _verifyReplicaDestination(
    CacheRec record,
    String accessLocator, {
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    if (record.checksumAlgorithm.trim().toLowerCase() != 'crc32') {
      throw const Failure(
        code: ErrorCode.policy,
        message: 'replica migration currently requires crc32 artifact proof',
      );
    }
    final preflight = await _withStorageWriteQuantum(() async {
      final exists = await _bytes.exists(accessLocator);
      final length = exists ? await _bytes.length(accessLocator) : 0;
      return (exists: exists, length: length);
    }, control: control);
    if (!preflight.exists) {
      throw ArtifactReadFailure(
        kind: ArtifactReadFailureKind.missing,
        accessLocator: accessLocator,
        replicaId: record.effectiveArtifactId,
        failedOffset: 0,
        bytesEmitted: 0,
        expectedLength: record.bytes,
        observedLength: 0,
      );
    }
    final length = preflight.length;
    if (length != record.bytes) {
      throw ArtifactReadFailure(
        kind: ArtifactReadFailureKind.lengthChanged,
        accessLocator: accessLocator,
        replicaId: record.effectiveArtifactId,
        failedOffset: 0,
        bytesEmitted: 0,
        expectedLength: record.bytes,
        observedLength: length,
      );
    }
    final iterator = StreamIterator<Uint8List>(
      _bytes.readChunks(accessLocator, start: 0, endExclusive: record.bytes),
    );
    final crc = Crc32();
    var verified = 0;
    Object? primaryError;
    StackTrace? primaryStack;
    try {
      while (true) {
        final lease = await _storageWriteScheduler.acquireQuantum(
          control: control,
        );
        try {
          control?.throwIfCancelled();
          if (!await _moveNextMigrationChunk(iterator, control)) break;
          final chunk = iterator.current;
          crc.add(chunk);
          verified += chunk.length;
        } finally {
          lease.release();
        }
      }
    } catch (error, stackTrace) {
      primaryError = error;
      primaryStack = stackTrace;
    }
    try {
      await iterator.cancel();
    } catch (error, stackTrace) {
      if (primaryError == null) {
        primaryError = error;
        primaryStack = stackTrace;
      }
    }
    if (primaryError != null) {
      Error.throwWithStackTrace(primaryError, primaryStack!);
    }
    _requireReplicaCopyProof(record, copied: verified, checksum: crc.hex);
  }

  void _requireReplicaCopyProof(
    CacheRec record, {
    required int copied,
    required String checksum,
  }) {
    if (copied != record.bytes ||
        checksum != record.checksum.trim().toLowerCase()) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message:
            'replica migration bytes do not match immutable artifact proof',
      );
    }
  }

  Future<T> _withStorageWriteQuantum<T>(
    Future<T> Function() operation, {
    TaskControl? control,
  }) async {
    final lease = await _storageWriteScheduler.acquireQuantum(control: control);
    try {
      control?.throwIfCancelled();
      return await operation();
    } finally {
      lease.release();
    }
  }

  Future<StorageCleanupDebtRecord> _registerStorageCleanupDebt(
    String accessLocator, {
    required String storageRootId,
    required StorageCleanupDebtKind kind,
  }) async {
    final nowUs = DateTime.now().toUtc().microsecondsSinceEpoch;
    final debt = StorageCleanupDebtRecord(
      accessLocator: accessLocator,
      storageRootId: storageRootId,
      kind: kind,
      createdUs: nowUs,
      touchedUs: nowUs,
    );
    await _index.putStorageCleanupDebt(debt);
    return debt;
  }

  Future<StorageCleanupDebtRecord> _registerTemporaryCleanupDebt(
    String accessLocator, {
    required String storageRootId,
  }) =>
      _registerStorageCleanupDebt(
        accessLocator,
        storageRootId: storageRootId,
        kind: StorageCleanupDebtKind.temporary,
      );

  Future<StorageCleanupDebtRecord> _registerActiveTemporaryCleanupDebt(
    String accessLocator, {
    required String storageRootId,
  }) async {
    _activeTemporaryCleanupLocators.add(accessLocator);
    try {
      return await _registerTemporaryCleanupDebt(
        accessLocator,
        storageRootId: storageRootId,
      );
    } on Object {
      _activeTemporaryCleanupLocators.remove(accessLocator);
      rethrow;
    }
  }

  Future<StorageCleanupDebtRecord> _registerObsoleteSealedSourceCleanupDebt(
    String accessLocator, {
    required String storageRootId,
    required int expectedBytes,
    required String expectedChecksum,
    required String expectedChecksumAlgorithm,
  }) async {
    final nowUs = DateTime.now().toUtc().microsecondsSinceEpoch;
    final debt = StorageCleanupDebtRecord(
      accessLocator: accessLocator,
      storageRootId: storageRootId,
      kind: StorageCleanupDebtKind.obsoleteSealedSource,
      createdUs: nowUs,
      touchedUs: nowUs,
      expectedBytes: expectedBytes,
      expectedChecksum: expectedChecksum.trim().toLowerCase(),
      expectedChecksumAlgorithm:
          expectedChecksumAlgorithm.trim().toLowerCase(),
    );
    await _index.putStorageCleanupDebt(debt);
    return debt;
  }

  Future<({bool safeToRetire, StorageCleanupDebtRecord? debt})>
      _prepareObsoleteSealedReplicaCleanupDebt({
    required ArtifactReplicaRecord replica,
    required int expectedBytes,
    required String expectedChecksum,
    required String expectedChecksumAlgorithm,
  }) async {
    final checksum = expectedChecksum.trim().toLowerCase();
    final algorithm = expectedChecksumAlgorithm.trim().toLowerCase();
    if (expectedBytes <= 0 || checksum.isEmpty || algorithm != 'crc32') {
      return (safeToRetire: false, debt: null);
    }
    final base = _ArtifactAccessRecord(
      artifactId: replica.artifactId,
      replicaId: replica.replicaId,
      accessLocator: replica.accessLocator,
      bytes: expectedBytes,
      checksum: checksum,
      checksumAlgorithm: algorithm,
      storageRootId: replica.storageRootId,
    );
    for (final candidate in await _artifactAccessCandidates(base)) {
      final access = candidate.access;
      if (!await _cleanupLocatorIsAvailable(
        access.accessLocator,
        access.storageRootId,
      )) {
        continue;
      }
      try {
        if (!await _artifactRecordExists(access)) {
          return (safeToRetire: true, debt: null);
        }
        final length = await _artifactPreflightLength(
          access,
          expectedLength: expectedBytes,
        );
        if (length != expectedBytes) {
          return (safeToRetire: true, debt: null);
        }
        final actualChecksum = await _migrationRangeChecksum(
          _bytes.readChunks(
            access.accessLocator,
            start: 0,
            endExclusive: expectedBytes,
          ),
          expectedBytes: expectedBytes,
        );
        if (actualChecksum != checksum) {
          return (safeToRetire: true, debt: null);
        }
        final debt = await _registerObsoleteSealedSourceCleanupDebt(
          access.accessLocator,
          storageRootId: access.storageRootId,
          expectedBytes: expectedBytes,
          expectedChecksum: checksum,
          expectedChecksumAlgorithm: algorithm,
        );
        return (safeToRetire: true, debt: debt);
      } on Object {
        // Try another proven access alias. If none are currently readable,
        // keep metadata authority rather than orphaning a possibly present copy.
      }
    }
    return (safeToRetire: false, debt: null);
  }

  Future<void> _forgetStorageCleanupDebts(
    Iterable<StorageCleanupDebtRecord> debts,
  ) async {
    for (final debt in debts) {
      await _forgetStorageCleanupDebt(debt.accessLocator);
    }
  }

  Future<StorageCleanupDebtRecord> _registerObsoletePartialSourceCleanupDebt({
    required String accessLocator,
    required String storageRootId,
    required int expectedBytes,
    required String checksum,
  }) async {
    final nowUs = DateTime.now().toUtc().microsecondsSinceEpoch;
    final debt = StorageCleanupDebtRecord(
      accessLocator: accessLocator,
      storageRootId: storageRootId,
      kind: StorageCleanupDebtKind.obsoletePartialSource,
      createdUs: nowUs,
      touchedUs: nowUs,
      expectedBytes: expectedBytes,
      expectedChecksum: checksum.trim().toLowerCase(),
      expectedChecksumAlgorithm: 'crc32',
    );
    await _index.putStorageCleanupDebt(debt);
    return debt;
  }

  Future<StorageCleanupDebtRecord?> _snapshotObsoletePartialSourceCleanupDebt({
    required String accessLocator,
    required String storageRootId,
  }) async {
    if (!await _cleanupLocatorIsAvailable(accessLocator, storageRootId)) {
      return null;
    }
    if (!await _bytes.exists(accessLocator)) return null;
    final actualBytes = await _bytes.length(accessLocator);
    if (actualBytes <= 0) return null;
    final checksum = await _migrationRangeChecksum(
      _bytes.readChunks(
        accessLocator,
        start: 0,
        endExclusive: actualBytes,
      ),
      expectedBytes: actualBytes,
    );
    return _registerObsoletePartialSourceCleanupDebt(
      accessLocator: accessLocator,
      storageRootId: storageRootId,
      expectedBytes: actualBytes,
      checksum: checksum,
    );
  }

  Future<void> _forgetStorageCleanupDebt(String accessLocator) async {
    _activeTemporaryCleanupLocators.remove(accessLocator);
    try {
      await _index.removeStorageCleanupDebt(accessLocator);
    } on Object catch (error, stackTrace) {
      _recordCleanupDebtFailure(
        stage: 'cleanup-debt-forget',
        accessLocator: accessLocator,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<T> _commitAuthoritySwitchWithObsoleteSealedCleanup<T>({
    required String oldAccessLocator,
    required String oldStorageRootId,
    required int expectedBytes,
    required String expectedChecksum,
    required String expectedChecksumAlgorithm,
    required Future<T> Function() commit,
  }) async {
    final debt = await _registerObsoleteSealedSourceCleanupDebt(
      oldAccessLocator,
      storageRootId: oldStorageRootId,
      expectedBytes: expectedBytes,
      expectedChecksum: expectedChecksum,
      expectedChecksumAlgorithm: expectedChecksumAlgorithm,
    );
    late final T result;
    try {
      result = await commit();
    } on Object {
      await _forgetStorageCleanupDebt(oldAccessLocator);
      rethrow;
    }
    await _cleanupObsoleteSourceNow(debt);
    return result;
  }

  Future<bool> _cleanupObsoleteSourceNow(
    StorageCleanupDebtRecord debt,
  ) async {
    if (debt.kind == StorageCleanupDebtKind.temporary) return false;
    if (debt.kind == StorageCleanupDebtKind.obsoleteSealedSource) {
      return _cleanupObsoleteSealedSourceAcrossAliases(debt);
    }
    try {
      if (await _index.isStorageAccessLocatorAuthoritative(
        debt.accessLocator,
      )) {
        await _index.removeStorageCleanupDebt(debt.accessLocator);
        return true;
      }
      if (!await _cleanupLocatorIsAvailable(
        debt.accessLocator,
        debt.storageRootId,
      )) {
        return false;
      }
      if (!await _obsoleteCleanupDebtStillMatches(debt)) {
        await _index.removeStorageCleanupDebt(debt.accessLocator);
        return true;
      }
      if (await _index.isStorageAccessLocatorAuthoritative(
        debt.accessLocator,
      )) {
        await _index.removeStorageCleanupDebt(debt.accessLocator);
        return true;
      }
      final absent = await _withStorageWriteQuantum(() async {
        if (await _bytes.exists(debt.accessLocator)) {
          await _bytes.delete(debt.accessLocator);
        }
        await _deleteArtifactSidecar(debt.accessLocator);
        return !await _bytes.exists(debt.accessLocator) &&
            !await _artifactSidecarExists(debt.accessLocator);
      });
      if (absent) {
        await _index.removeStorageCleanupDebt(debt.accessLocator);
      }
      return absent;
    } on Object catch (error, stackTrace) {
      _recordCleanupDebtFailure(
        stage: 'obsolete-source-cleanup-after-commit',
        accessLocator: debt.accessLocator,
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<bool> _cleanupObsoleteSealedSourceAcrossAliases(
    StorageCleanupDebtRecord debt,
  ) async {
    final expectedBytes = debt.expectedBytes;
    final expectedChecksum = debt.expectedChecksum?.trim().toLowerCase();
    final algorithm = debt.expectedChecksumAlgorithm?.trim().toLowerCase();
    if (expectedBytes == null ||
        expectedBytes <= 0 ||
        expectedChecksum == null ||
        expectedChecksum.isEmpty ||
        algorithm != 'crc32') {
      return false;
    }
    try {
      for (final candidate in await _equivalentStorageRootLocators(
        accessLocator: debt.accessLocator,
        storageRootId: debt.storageRootId,
      )) {
        if (!await _cleanupLocatorIsAvailable(
          candidate.accessLocator,
          candidate.storageRootId,
        )) {
          continue;
        }
        if (await _index.isStorageAccessLocatorAuthoritative(
          candidate.accessLocator,
        )) {
          await _index.removeStorageCleanupDebt(debt.accessLocator);
          return true;
        }
        final exists = await _withStorageWriteQuantum(
          () => _bytes.exists(candidate.accessLocator),
        );
        if (!exists) {
          await _index.removeStorageCleanupDebt(debt.accessLocator);
          return true;
        }
        final length = await _withStorageWriteQuantum(
          () => _bytes.length(candidate.accessLocator),
        );
        if (length != expectedBytes) {
          await _index.removeStorageCleanupDebt(debt.accessLocator);
          return true;
        }
        final checksum = await _migrationRangeChecksum(
          _bytes.readChunks(
            candidate.accessLocator,
            start: 0,
            endExclusive: expectedBytes,
          ),
          expectedBytes: expectedBytes,
        );
        if (checksum != expectedChecksum) {
          await _index.removeStorageCleanupDebt(debt.accessLocator);
          return true;
        }
        if (await _index.isStorageAccessLocatorAuthoritative(
          candidate.accessLocator,
        )) {
          await _index.removeStorageCleanupDebt(debt.accessLocator);
          return true;
        }
        final absent = await _withStorageWriteQuantum(() async {
          await _bytes.delete(candidate.accessLocator);
          await _deleteArtifactSidecar(candidate.accessLocator);
          return !await _bytes.exists(candidate.accessLocator) &&
              !await _artifactSidecarExists(candidate.accessLocator);
        });
        if (absent) {
          await _index.removeStorageCleanupDebt(debt.accessLocator);
        }
        return absent;
      }
      return false;
    } on Object catch (error, stackTrace) {
      _recordCleanupDebtFailure(
        stage: 'obsolete-sealed-source-cleanup',
        accessLocator: debt.accessLocator,
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<bool> _cleanupTemporaryDebtAcrossAliases(
    StorageCleanupDebtRecord debt,
  ) async {
    if (debt.kind != StorageCleanupDebtKind.temporary ||
        !_isGeneratedTemporaryLocator(debt.accessLocator) ||
        _activeTemporaryCleanupLocators.contains(debt.accessLocator)) {
      return false;
    }
    for (final candidate in await _equivalentStorageRootLocators(
      accessLocator: debt.accessLocator,
      storageRootId: debt.storageRootId,
    )) {
      if (!_isGeneratedTemporaryLocator(candidate.accessLocator) ||
          !await _cleanupLocatorIsAvailable(
            candidate.accessLocator,
            candidate.storageRootId,
          )) {
        continue;
      }
      try {
        final absent = await _withStorageWriteQuantum(() async {
          if (await _bytes.exists(candidate.accessLocator)) {
            await _bytes.delete(candidate.accessLocator);
          }
          return !await _bytes.exists(candidate.accessLocator);
        });
        if (absent) {
          await _index.removeStorageCleanupDebt(debt.accessLocator);
        }
        return absent;
      } on Object {
        // A later proven alias or a later drain may still reach the same temp.
      }
    }
    return false;
  }

  Future<StorageCleanupDebtRecord?> _registerMigrationTemporaryCleanupDebt(
    ArtifactReplicaMigrationRecord migration,
  ) async {
    final temporary = migration.temporaryAccessLocator;
    if (temporary == migration.sourceAccessLocator ||
        temporary == migration.destinationAccessLocator ||
        !_isGeneratedTemporaryLocator(temporary)) {
      return null;
    }
    return _registerTemporaryCleanupDebt(
      temporary,
      storageRootId: migration.destinationStorageRootId,
    );
  }

  Future<void> _writeBytesToSafTracked(
    SafTreeIo io,
    String relativePath,
    Uint8List bytes, {
    bool replaceNonAuthoritative = false,
  }) async {
    final treeUri = safTreeUri;
    if (treeUri == null) {
      throw StateError('tracked SAF write requires a configured tree');
    }
    if (replaceNonAuthoritative && await io.exists(relativePath)) {
      await io.delete(relativePath);
      if (await io.exists(relativePath)) {
        throw StateError('SAF metadata target could not be retired: $relativePath');
      }
    }
    await writeBytesToSaf(
      io,
      relativePath,
      bytes,
      beforeTemporaryCreate: (temporaryPath) =>
          _registerActiveTemporaryCleanupDebt(
        encodeSafRecordPath(treeUri: treeUri, relativePath: temporaryPath),
        storageRootId: treeUri,
      ),
      afterTemporaryAbsent: (temporaryPath) => _forgetStorageCleanupDebt(
        encodeSafRecordPath(treeUri: treeUri, relativePath: temporaryPath),
      ),
    );
  }

  void _recordCleanupDebtFailure({
    required String stage,
    required String accessLocator,
    required Object error,
    required StackTrace stackTrace,
  }) {
    try {
      _traceSink.record(
        traceEvent(
          clock: _clock,
          sessionId: 'persistent-artifact-store',
          kind: TraceEventKind.taskFailed,
          payload: <String, Object?>{
            'stage': stage,
            'accessLocator': accessLocator,
            'error': '$error',
            'stackTrace': '$stackTrace',
          },
        ),
      );
    } on Object {
      // Diagnostics never own durable cleanup state.
    }
  }

  void _scheduleRedundantPhysicalPartialSweep() {
    if (_closed || _redundantPhysicalPartialSweep != null) return;
    late final Future<void> sweep;
    sweep = Future<void>.delayed(Duration.zero, () async {
      if (_closed) return;
      final artifacts = <PhysicalMediaId, PhysicalMediaArtifactRecord>{
        for (final artifact in await _index.listPhysicalMediaArtifacts())
          artifact.id: artifact,
      };
      if (_closed || artifacts.isEmpty) return;
      final partials = await _index.listPhysicalPartials();
      if (_closed) return;
      for (final partial in partials) {
        final artifact = artifacts[partial.id];
        if (artifact == null) continue;
        _scheduleRedundantPhysicalPartialRetirement(
          partial.id,
          expectedArtifactId: artifact.artifactId,
        );
      }
    }).catchError((Object error, StackTrace stackTrace) {
      _recordCleanupDebtFailure(
        stage: 'redundant-physical-partial-sweep',
        accessLocator: '',
        error: error,
        stackTrace: stackTrace,
      );
    }).whenComplete(() {
      if (identical(_redundantPhysicalPartialSweep, sweep)) {
        _redundantPhysicalPartialSweep = null;
      }
    });
    _redundantPhysicalPartialSweep = sweep;
  }

  void _scheduleCleanupDebtDrain() {
    if (_cleanupDebtDrain != null) {
      _cleanupDebtDrainRerunRequested = true;
      return;
    }
    late final Future<void> drain;
    drain = Future<void>.delayed(Duration.zero, _drainCleanupDebt).catchError(
      (Object error, StackTrace stackTrace) {
        _recordCleanupDebtFailure(
          stage: 'cleanup-debt-drain',
          accessLocator: '',
          error: error,
          stackTrace: stackTrace,
        );
      },
    ).whenComplete(() {
      if (!identical(_cleanupDebtDrain, drain)) return;
      _cleanupDebtDrain = null;
      if (_cleanupDebtDrainRerunRequested) {
        _cleanupDebtDrainRerunRequested = false;
        _scheduleCleanupDebtDrain();
      }
    });
    _cleanupDebtDrain = drain;
  }

  Future<void> _drainCleanupDebt() async {
    for (final debt in await _index.listStorageCleanupDebts()) {
      await _drainStorageCleanupDebtRecord(debt);
    }
    final migrations = await _index.listArtifactReplicaMigrations(
      phase: ArtifactReplicaMigrationPhase.cleanupPending,
    );
    for (final migration in migrations) {
      if (!await _migrationCleanupIsAvailable(migration)) continue;
      try {
        await _cleanupCommittedReplicaMigration(migration);
      } on Object catch (error, stackTrace) {
        _recordCleanupDebtFailure(
          stage: 'replica-migration-cleanup-retry',
          accessLocator: migration.temporaryAccessLocator,
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  Future<void> _drainStorageCleanupDebtRecord(
    StorageCleanupDebtRecord debt,
  ) async {
    try {
      if (debt.kind == StorageCleanupDebtKind.temporary) {
        if (!_isGeneratedTemporaryLocator(debt.accessLocator)) return;
        await _cleanupTemporaryDebtAcrossAliases(debt);
        return;
      }
      await _cleanupObsoleteSourceNow(debt);
    } on Object catch (error, stackTrace) {
      _recordCleanupDebtFailure(
        stage: switch (debt.kind) {
          StorageCleanupDebtKind.temporary => 'temporary-cleanup-retry',
          StorageCleanupDebtKind.obsoleteSealedSource =>
            'obsolete-source-cleanup-retry',
          StorageCleanupDebtKind.obsoletePartialSource =>
            'obsolete-partial-cleanup-retry',
        },
        accessLocator: debt.accessLocator,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<bool> _obsoleteCleanupDebtStillMatches(
    StorageCleanupDebtRecord debt,
  ) async {
    final expectedBytes = debt.expectedBytes;
    final expectedChecksum = debt.expectedChecksum?.trim().toLowerCase();
    final algorithm = debt.expectedChecksumAlgorithm?.trim().toLowerCase();
    if (expectedBytes == null ||
        expectedBytes <= 0 ||
        expectedChecksum == null ||
        expectedChecksum.isEmpty ||
        algorithm != 'crc32') {
      return false;
    }
    final exists = await _withStorageWriteQuantum(
      () => _bytes.exists(debt.accessLocator),
    );
    if (!exists) return true;
    final length = await _withStorageWriteQuantum(
      () => _bytes.length(debt.accessLocator),
    );
    if (length != expectedBytes) return false;
    final checksum = await _migrationRangeChecksum(
      _bytes.readChunks(
        debt.accessLocator,
        start: 0,
        endExclusive: expectedBytes,
      ),
      expectedBytes: expectedBytes,
    );
    return checksum == expectedChecksum;
  }

  bool _isGeneratedTemporaryLocator(String accessLocator) {
    final saf = parseSafRecordPath(accessLocator);
    final path = saf?.relativePath ?? accessLocator;
    if (RegExp(r'\.(?:zic-tmp|tmp)-[0-9]+$').hasMatch(path)) {
      return true;
    }
    final migration = RegExp(
      r'\.zic-migrate-([0-9a-f-]{16,17})\.part$',
    ).firstMatch(path);
    if (migration == null) return false;
    final token = migration.group(1)!;
    if (RegExp(r'^[0-9a-f]{16}$').hasMatch(token)) return true;
    if (!RegExp(r'^0*-[0-9a-f]+$').hasMatch(token)) return false;
    return token.length == 16 ||
        (token.length == 17 && token.startsWith('-'));
  }

  Future<bool> _cleanupLocatorIsAvailable(
    String accessLocator,
    String storageRootId,
  ) async {
    final saf = parseSafRecordPath(accessLocator);
    if (saf != null) {
      if (safTreeIo == null || safTreeUri != saf.treeUri) return false;
      if (storageRootId == saf.treeUri) return true;
      final root = await _index.getStorageRoot(storageRootId);
      return root?.accessLocators.any(
            (locator) =>
                locator.kind == StorageAccessLocatorKind.saf &&
                locator.locator == saf.treeUri,
          ) ==
          true;
    }

    final path = File(accessLocator).absolute.path;
    final roots = <String>[];
    if (storageRootId == 'default' || storageRootId.isEmpty) {
      roots.add(layout.root);
    } else {
      final registered = await _index.getStorageRoot(storageRootId);
      if (registered != null) {
        roots.addAll(
          registered.accessLocators
              .where(
                (locator) => locator.kind == StorageAccessLocatorKind.direct,
              )
              .map((locator) => locator.locator),
        );
      }
      if (storageRootId.startsWith('/')) roots.add(storageRootId);
    }
    roots.sort((left, right) => right.length.compareTo(left.length));
    for (final candidateRoot in roots.toSet()) {
      if (_relativeDirectArtifactPath(
            root: candidateRoot,
            artifactPath: path,
          ) ==
          null) {
        continue;
      }
      final root = Directory(candidateRoot).absolute.path;
      if (!await Directory(root).exists()) continue;
      var current = path;
      var safe = true;
      while (current != root) {
        if (FileSystemEntity.typeSync(current, followLinks: false) ==
            FileSystemEntityType.link) {
          safe = false;
          break;
        }
        final parent = Directory(current).parent.path;
        if (parent == current ||
            (parent != root &&
                !parent.startsWith('$root${Platform.pathSeparator}'))) {
          safe = false;
          break;
        }
        current = parent;
      }
      if (safe) return true;
    }
    return false;
  }

  Future<bool> _migrationCleanupIsAvailable(
    ArtifactReplicaMigrationRecord migration,
  ) async => migration.phase == ArtifactReplicaMigrationPhase.cleanupPending;

  Future<bool> _moveNextMigrationChunk(
    StreamIterator<Uint8List> iterator,
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
            message: 'artifact replica migration was cancelled',
          );
        }),
      ]);
    } catch (error, stackTrace) {
      if (control.cancelled) control.throwIfCancelled();
      throw Error.throwWithStackTrace(error, stackTrace);
    }
  }

  void setSafTree(String treeUri) {
    if (safTreeUri != null && safTreeUri != treeUri) {
      throw StateError('SAF tree identity cannot change on an open store');
    }
  }

  final DownloadRegistry _registry;
  final SqliteIndex _index;
  final CacheOps _cacheOps;
  final ArtifactBytes _bytes;
  final File _recoveryMarker;
  final RandomAccessFile _metadataOwnerLock;
  final String _metadataOwnerKey;
  final StorageWriteScheduler _storageWriteScheduler;
  final _StoreLifetimeTaskControl _deferredRecencyTouchControl =
      _StoreLifetimeTaskControl();
  final Map<DownloadId, ({String artifactId, int touchedUs})>
      _pendingExactArtifactTouches =
      <DownloadId, ({String artifactId, int touchedUs})>{};
  final Map<DownloadId, Future<void>> _exactArtifactTouchDrains =
      <DownloadId, Future<void>>{};
  Future<void>? _cleanupDebtDrain;
  bool _cleanupDebtDrainRerunRequested = false;
  Future<void>? _redundantPhysicalPartialSweep;

  StorageWriteScheduler get storageWriteScheduler => _storageWriteScheduler;

  /// When set, freshly promoted finals are mirrored into the SAF tree and
  /// their index records switch to `saf:` paths; the local staging copy is
  /// removed afterwards. Reading follows the record path scheme.
  final SafTreeIo? safTreeIo;

  Future<bool> prewarmLocalReadBackend() async {
    final io = safTreeIo;
    if (io is! SafTreeReadPrewarmer) return false;
    try {
      return await (io as SafTreeReadPrewarmer).prewarmReadProvider();
    } on Object {
      // Acceleration only. The first real artifact open remains authoritative
      // and must retain its normal typed failure/fallback semantics.
      return false;
    }
  }

  /// Optional platform adapter for engine-readable file/descriptor leases.
  /// The store remains authoritative for replica selection; the adapter only
  /// pins the selected physical locator for presentation.
  final ArtifactPresentationFileLeaseFactory? presentationFileLeaseFactory;
  final Map<DownloadId, Future<void>> _artifactWrites =
      <DownloadId, Future<void>>{};
  final Map<DownloadId, ({int length, String checksum})> _artifactWriteProofs =
      <DownloadId, ({int length, String checksum})>{};
  final Map<DownloadId, Future<void>> _artifactMutationTails =
      <DownloadId, Future<void>>{};
  final Map<PhysicalMediaId, Future<void>> _physicalPartialMutationTails =
      <PhysicalMediaId, Future<void>>{};
  final Map<PhysicalMediaId, Future<void>> _physicalArtifactMutationTails =
      <PhysicalMediaId, Future<void>>{};
  final Set<PhysicalMediaId> _redundantPhysicalPartialRetirements =
      <PhysicalMediaId>{};
  final Map<String, Future<void>> _artifactReplicaMutationTails =
      <String, Future<void>>{};
  static final Object _artifactReplicaMutationZoneKey = Object();
  final Set<DownloadId> _borrowedPartialIds = <DownloadId>{};
  final Set<PhysicalMediaId> _borrowedPhysicalPartialIds = <PhysicalMediaId>{};
  final Set<String> _activeTemporaryCleanupLocators = <String>{};
  bool _closed = false;

  static const String _recoveryMarkerName = '.zic-cache-recovery-required';
  static final Set<String> _processMetadataOwners = <String>{};
  static final RegExp _crc32ChecksumPattern = RegExp(r'^[0-9a-fA-F]{8}$');
  static final String _processRecoveryOwner =
      '${pid}-${DateTime.now().toUtc().microsecondsSinceEpoch}';

  int get materializedSessionCount => _registry.sessions.length;

  CacheLayout get layout => _registry.layout;

  CacheLayout layoutFor(DownloadId id) => _registry.layoutFor(id);

  bool _isAutomaticCacheFinalRecord(CacheRec record) {
    if (parseSafRecordPath(record.path) != null) return false;
    final root = record.storageRootId.trim();
    final recordLayout = root.isEmpty || root == 'default'
        ? layoutFor(record.id)
        : CacheLayout(root);
    return recordLayout.containsFinalArtifactPath(record.path);
  }

  CacheLayout layoutForSource(String sourceId) =>
      _registry.layoutForSource(sourceId);

  CacheLayout _layoutForEntryPage(ImportedLibraryEntry entry, int pageIndex) {
    final page =
        entry.chapter.pages[pageIndex.clamp(0, entry.chapter.pages.length - 1)];
    return layoutFor(
      DownloadId(
        content: ContentId(
          sourceId: entry.chapter.sourceId,
          comicId: entry.chapter.comicId,
          chapterId: entry.chapter.chapterId,
          pageId: page.stablePageId,
        ),
        sourceRevision: entry.chapter.sourceRevision,
        canonicalUri: page.uri,
      ),
    );
  }

  String storageRootIdFor(ImportedLibraryEntry entry) => safTreeUri != null
      ? safTreeUri!
      : entry.chapter.pages.isEmpty
          ? layoutForSource(entry.chapter.sourceId).root
          : _layoutForEntryPage(entry, 0).root;

  CacheIndex get index => _index;

  Future<List<VersionChapterCanonicalProjection>>
  loadCanonicalMediaProjections() async {
    final projectionIndex = _index as PhysicalMediaProjectionIndex;
    final projections = <VersionChapterCanonicalProjection>[];
    for (final record in await projectionIndex.listPhysicalMediaProjections()) {
      try {
        projections.add(_decodeCanonicalMediaProjection(record));
      } on Object {
        // A malformed control-plane row is never enough authority to merge
        // two exact versions. Ignore it for runtime reuse; persist below will
        // refuse to overwrite the malformed row, keeping repair explicit.
      }
    }
    return List<VersionChapterCanonicalProjection>.unmodifiable(projections);
  }

  Future<void> persistCanonicalMediaProjection(
    VersionChapterCanonicalProjection projection,
  ) => persistCanonicalMediaProjections(
    <VersionChapterCanonicalProjection>[projection],
  );

  Future<void> persistCanonicalMediaProjections(
    Iterable<VersionChapterCanonicalProjection> projections,
  ) async {
    _requireOpen();
    final values = projections.toList(growable: false);
    if (values.isEmpty) return;
    final exactKeys = <String>{};
    for (final projection in values) {
      if (!exactKeys.add(projection.exactKey)) {
        throw StateError(
          'canonical projection batch contains duplicate ${projection.exactKey}',
        );
      }
    }

    final projectionIndex = _index as PhysicalMediaProjectionIndex;
    final nowUs = DateTime.now().toUtc().microsecondsSinceEpoch;
    final records = <PhysicalMediaProjectionRecord>[];
    for (final projection in values) {
      final existingRecord = await projectionIndex.getPhysicalMediaProjection(
        projection.exactKey,
      );
      if (existingRecord != null) {
        final existing = _decodeCanonicalMediaProjection(existingRecord);
        if (!_isMonotonicCanonicalProjectionExpansion(existing, projection)) {
          throw const Failure(
            code: ErrorCode.policy,
            message: 'canonical media projection cannot rebase existing media',
          );
        }
      }
      records.add(
        PhysicalMediaProjectionRecord(
          exactKey: projection.exactKey,
          familyKey: projection.familyId.value,
          projectionJson: jsonEncode(projection.toJson()),
          createdUs: existingRecord?.createdUs ?? nowUs,
          touchedUs: nowUs,
        ),
      );
    }
    await projectionIndex.putPhysicalMediaProjections(records);
    _notifyManagementProjectionChanged();
  }

  VersionChapterCanonicalProjection _decodeCanonicalMediaProjection(
    PhysicalMediaProjectionRecord record,
  ) {
    final decoded = jsonDecode(record.projectionJson);
    if (decoded is! Map) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'canonical media projection is malformed',
      );
    }
    final projection = VersionChapterCanonicalProjection.fromJson(
      Map<String, Object?>.from(decoded),
    );
    if (projection.exactKey != record.exactKey ||
        projection.familyId.value != record.familyKey) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'canonical media projection ownership metadata mismatches',
      );
    }
    return projection;
  }

  Future<Map<String, CacheRec>> indexedRecords() async => <String, CacheRec>{
        for (final record in await _index.list()) record.key: record,
      };

  Future<ChapterDeleteImpactProjection> inspectChapterDeleteImpact(
    ImportedLibraryEntry entry, {
    required Iterable<DownloadId> targetIds,
  }) async {
    _requireOpen();
    final records = await _index.list();
    final requestedKeys = <String>{for (final id in targetIds) id.key};
    final target = records
        .where(
          (record) => requestedKeys.contains(record.key) && record.bytes > 0,
        )
        .toList(growable: false);
    final targetKeys = <String>{for (final record in target) record.key};
    final outside = records
        .where((record) => !targetKeys.contains(record.key))
        .toList(growable: false);
    final canonical = await _index.listPhysicalMediaArtifacts();

    final groups = <_DeleteImpactPhysicalGroup>[];
    for (final record in target) {
      final artifactId = record.effectiveArtifactId;
      final matching = <_DeleteImpactPhysicalGroup>[
        for (final group in groups)
          if (group.artifactIds.contains(artifactId) ||
              group.paths.contains(record.path))
            group,
      ];
      final group = matching.isEmpty
          ? _DeleteImpactPhysicalGroup()
          : matching.first;
      if (matching.isEmpty) groups.add(group);
      for (final duplicate in matching.skip(1).toList(growable: false)) {
        group.absorb(duplicate);
        groups.remove(duplicate);
      }
      group.add(record);
    }

    var reclaimableObjects = 0;
    var sharedObjects = 0;
    var reclaimableBytes = 0;
    var sharedBytes = 0;
    for (final group in groups) {
      final sharedByExactBinding = outside.any(
        (record) =>
            group.paths.contains(record.path) ||
            group.artifactIds.contains(record.effectiveArtifactId),
      );
      final sharedByCanonicalBinding = canonical.any(
        (record) =>
            group.paths.contains(record.accessLocator) ||
            group.artifactIds.contains(record.artifactId),
      );
      if (sharedByExactBinding || sharedByCanonicalBinding) {
        sharedObjects++;
        sharedBytes += group.bytes;
      } else {
        reclaimableObjects++;
        reclaimableBytes += group.bytes;
      }
    }

    return ChapterDeleteImpactProjection(
      sourceId: entry.chapter.sourceId,
      comicId: entry.chapter.comicId,
      chapterId: entry.chapter.chapterId,
      sourceRevision: entry.chapter.sourceRevision,
      exactBindings: target.length,
      affectedPages: <String>{
        for (final record in target) record.id.content.pageId,
      }.length,
      reclaimablePhysicalObjects: reclaimableObjects,
      sharedPhysicalObjects: sharedObjects,
      reclaimableBytes: reclaimableBytes,
      sharedBytes: sharedBytes,
    );
  }

  Future<int> backfillCanonicalReadyArtifacts(
    Iterable<CanonicalMediaChapterAuthority> authorities,
  ) async {
    _requireOpen();
    final authorityList = authorities.toList(growable: false);
    if (authorityList.isEmpty) return 0;

    final readyByChapter = <String, List<CacheRec>>{};
    for (final record in await _index.list(state: CacheState.ready)) {
      if (!_isVerifiedReadyRecord(record)) continue;
      readyByChapter
          .putIfAbsent(
            canonicalMediaExactChapterKeyForDownload(record.id),
            () => <CacheRec>[],
          )
          .add(record);
    }
    if (readyByChapter.isEmpty) return 0;

    final candidatesByPhysical = <PhysicalMediaId, Map<String, DownloadId>>{};
    for (final authority in authorityList) {
      final records = readyByChapter[authority.exactKey];
      if (records == null || records.isEmpty) continue;
      final manifest = authority.manifest;
      final exactPages = <String, DownloadId>{};
      for (final page in manifest.pages) {
        final exactId = readerPageDownloadId(manifest, page);
        exactPages[exactId.key] = exactId;
      }
      for (final record in records) {
        final exactId = exactPages[record.id.key];
        if (exactId == null) continue;
        final physicalId = authority.resolve(exactId);
        if (physicalId == null || physicalId.isExactFallback) continue;
        candidatesByPhysical
            .putIfAbsent(physicalId, () => <String, DownloadId>{})
            .putIfAbsent(exactId.key, () => exactId);
      }
    }

    var newlyBound = 0;
    for (final entry in candidatesByPhysical.entries) {
      if (await _index.getPhysicalMediaArtifact(entry.key) != null) continue;
      final bound = await bindPhysicalArtifactFromCandidates(
        physicalId: entry.key,
        candidates: entry.value.values,
      );
      if (bound) newlyBound++;
    }
    return newlyBound;
  }


  /// Migrates legacy exact mutable prefixes into the canonical physical
  /// partial owner when the current composition authority proves that exact
  /// page belongs to a canonical media coordinate.
  ///
  /// This is deliberately a bounded cache-residency pass: it scans only
  /// existing exact partial rows, never the source chapter page space. The
  /// physical prefix is committed before the exact row is retired, so a crash
  /// can leave a harmless duplicate but cannot destroy the only durable copy.
  /// Gap / revoked-proof rows are skipped because [CanonicalMediaChapterAuthority]
  /// refuses to resolve them.
  Future<int> backfillCanonicalPartials(
    Iterable<CanonicalMediaChapterAuthority> authorities,
  ) async {
    _requireOpen();
    final authorityList = authorities.toList(growable: false);
    if (authorityList.isEmpty) return 0;

    final partialByChapter = <String, List<CacheRec>>{};
    for (final record in await _index.list(state: CacheState.partial)) {
      if (record.bytes <= 0) continue;
      partialByChapter
          .putIfAbsent(
            canonicalMediaExactChapterKeyForDownload(record.id),
            () => <CacheRec>[],
          )
          .add(record);
    }
    if (partialByChapter.isEmpty) return 0;

    final candidatesByPhysical =
        <PhysicalMediaId, List<({CacheRec record, DownloadId id})>>{};
    for (final authority in authorityList) {
      final records = partialByChapter[authority.exactKey];
      if (records == null || records.isEmpty) continue;
      final exactPages = <String, DownloadId>{};
      for (final page in authority.manifest.pages) {
        final exactId = readerPageDownloadId(authority.manifest, page);
        exactPages[exactId.key] = exactId;
      }
      for (final record in records) {
        // Rebuild from the current exact manifest rather than trusting legacy
        // pageIndexHint metadata; the download key remains the exact identity.
        final exactId = exactPages[record.id.key];
        if (exactId == null) continue;
        final physicalId = authority.resolve(exactId);
        if (physicalId == null || physicalId.isExactFallback) continue;
        candidatesByPhysical
            .putIfAbsent(
              physicalId,
              () => <({CacheRec record, DownloadId id})>[],
            )
            .add((record: record, id: exactId));
      }
    }

    var retiredExactPartials = 0;
    for (final entry in candidatesByPhysical.entries) {
      // Start from the longest known prefix. Shorter duplicate exact prefixes
      // can then retire without copying over a longer canonical body.
      final candidates = entry.value
        ..sort((left, right) => right.record.bytes.compareTo(left.record.bytes));
      for (final candidate in candidates) {
        final retired = await _serializeArtifactMutation(candidate.id, () async {
          // Hold the existing per-exact mutation boundary across source
          // validation, canonical copy and exact retirement. Without this,
          // expected-record eviction can avoid deleting a newer row but the
          // physical copy itself can still observe a moving exact partial.
          final source = await _openPartialDownload(candidate.id);
          if (source == null || source.length <= 0) return false;
          final openedRecord = await _index.get(candidate.id.key);
          if (openedRecord == null ||
              openedRecord.state != CacheState.partial ||
              openedRecord.bytes != source.length) {
            return false;
          }
          await storePhysicalPartialDownload(
            physicalId: entry.key,
            providerHint: candidate.id,
            entry: source,
          );
          final canonicalArtifact =
              await _index.getPhysicalMediaArtifact(entry.key);
          final canonicalPartial = await _index.getPhysicalPartial(entry.key);
          final safelyCovered = canonicalArtifact != null ||
              (canonicalPartial != null &&
                  canonicalPartial.bytes >= openedRecord.bytes);
          if (!safelyCovered) return false;
          final current = await _index.get(candidate.id.key);
          if (current == null || !_sameIndexedRecord(openedRecord, current)) {
            return false;
          }
          await _invalidateIndexedArtifact(
            candidate.id,
            record: openedRecord,
          );
          return await _index.get(candidate.id.key) == null;
        });
        if (retired) retiredExactPartials++;
      }
    }
    return retiredExactPartials;
  }

  /// Batched exact-key existence query used by temporary version-cache alias
  /// restoration. This mirrors VibeVenera's `findExistingKeys`, extended for
  /// zic's streaming Reader: an indexed non-empty partial is also reusable
  /// evidence, while final body validation remains owned by openPartialDownload.
  Future<({Set<String> readyKeys, Set<String> partialKeys})>
      findExistingReusableKeys(Iterable<String> keys) async {
    final readyKeys = <String>{};
    final partialKeys = <String>{};
    for (final record in await _index.getMany(keys)) {
      if (_isVerifiedReadyRecord(record)) {
        readyKeys.add(record.key);
      } else if (record.state == CacheState.partial && record.bytes > 0) {
        partialKeys.add(record.key);
      }
    }
    return (readyKeys: readyKeys, partialKeys: partialKeys);
  }

  /// Returns whether this exact chapter revision currently owns any reusable
  /// READY artifact or non-empty indexed partial. The query scales with actual
  /// cache bindings, never with the source chapter's page count; callers use
  /// it only as a cheap reason to perform bounded version-page verification.
  Future<bool> hasReusableChapterState({
    required String sourceId,
    required String comicId,
    required String chapterId,
    required String sourceRevision,
  }) async {
    for (final record in await _index.list()) {
      final id = record.id;
      if (id.content.sourceId != sourceId ||
          id.content.comicId != comicId ||
          id.content.chapterId != chapterId ||
          id.sourceRevision != sourceRevision) {
        continue;
      }
      if (_isVerifiedReadyRecord(record) ||
          (record.state == CacheState.partial && record.bytes > 0)) {
        return true;
      }
    }
    return false;
  }

  /// Mirrors a freshly promoted local final into the configured SAF tree and
  /// rewrites the index record to its `saf:` path, removing the local staging
  /// copy. Failures keep the local copy authoritative so downloads never
  /// lose bytes to a transient SAF error.
  /// Returns the distinct chapter IDs currently downloaded for [comicId] from [sourceId].
  bool _isVerifiedReadyRecord(CacheRec record) =>
      record.state == CacheState.ready &&
      record.bytes > 0 &&
      _crc32ChecksumPattern.hasMatch(record.checksum.trim()) &&
      record.checksumAlgorithm.trim().toLowerCase() == 'crc32';

  String _storageRootIdForPath(String path, {DownloadId? id}) {
    final parsed = parseSafRecordPath(path);
    if (parsed != null) return parsed.treeUri;
    final candidate = id == null ? layout.root : layoutFor(id).root;
    return path == candidate || path.startsWith('$candidate/')
        ? candidate
        : layout.root;
  }

  Future<void> forgetUnverifiedReadyRecord(CacheRec record) =>
      _serializeArtifactMutation(record.id, () async {
        _requireOpen();
        final current = await _index.get(record.key);
        if (current == null || !_sameIndexedRecord(record, current)) return;
        if (record.state == CacheState.ready &&
            !_isVerifiedReadyRecord(record)) {
          await _index.remove(record.key);
        }
      });

  Future<({int bytes, String checksum})> _artifactProof(
    String path, {
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    if (parseSafRecordPath(path) == null) {
      _rejectLocalPathLinks(path);
    }
    if (!await _bytes.exists(path)) {
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message: 'artifact file is missing: $path',
      );
    }
    final crc = Crc32();
    var bytes = 0;
    await for (final chunk in _bytes.readChunks(path, start: 0)) {
      control?.throwIfCancelled();
      crc.add(chunk);
      bytes += chunk.lengthInBytes;
    }
    control?.throwIfCancelled();
    return (bytes: bytes, checksum: crc.hex);
  }

  Future<Uint8List> _readArtifactBytes(String path) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in _bytes.readChunks(path, start: 0)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  bool _proofMatchesRecord(
    ({int bytes, String checksum}) proof,
    CacheRec record,
  ) =>
      _isVerifiedReadyRecord(record) &&
      proof.bytes == record.bytes &&
      proof.checksum == record.checksum.trim().toLowerCase();

  Future<T> _serializeArtifactMutation<T>(
    DownloadId id,
    Future<T> Function() operation,
  ) {
    final previous = _artifactMutationTails[id] ?? Future<void>.value();
    final current = previous.then<T>(
      (_) => operation(),
      onError: (Object _, StackTrace __) => operation(),
    );
    late final Future<void> tail;
    tail = current.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _artifactMutationTails[id] = tail;
    return current.whenComplete(() {
      if (identical(_artifactMutationTails[id], tail)) {
        _artifactMutationTails.remove(id);
      }
    });
  }

  Future<T> _serializePhysicalPartialMutation<T>(
    PhysicalMediaId id,
    Future<T> Function() operation,
  ) {
    final previous = _physicalPartialMutationTails[id] ?? Future<void>.value();
    final current = previous.then<T>(
      (_) => operation(),
      onError: (Object _, StackTrace __) => operation(),
    );
    late final Future<void> tail;
    tail = current.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _physicalPartialMutationTails[id] = tail;
    return current.whenComplete(() {
      if (identical(_physicalPartialMutationTails[id], tail)) {
        _physicalPartialMutationTails.remove(id);
      }
    });
  }

  Future<T> _serializePhysicalArtifactMutation<T>(
    PhysicalMediaId id,
    Future<T> Function() operation,
  ) {
    final previous = _physicalArtifactMutationTails[id] ?? Future<void>.value();
    final current = previous.then<T>(
      (_) => operation(),
      onError: (Object _, StackTrace __) => operation(),
    );
    late final Future<void> tail;
    tail = current.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _physicalArtifactMutationTails[id] = tail;
    return current.whenComplete(() {
      if (identical(_physicalArtifactMutationTails[id], tail)) {
        _physicalArtifactMutationTails.remove(id);
      }
    });
  }

  Future<T> _serializeArtifactReplicaMutation<T>(
    String artifactId,
    Future<T> Function() operation,
  ) {
    if (Zone.current[_artifactReplicaMutationZoneKey] == artifactId) {
      return operation();
    }
    final previous =
        _artifactReplicaMutationTails[artifactId] ?? Future<void>.value();
    final current = previous.then<T>(
      (_) => runZoned(
        operation,
        zoneValues: <Object?, Object?>{
          _artifactReplicaMutationZoneKey: artifactId,
        },
      ),
      onError: (Object _, StackTrace __) => runZoned(
        operation,
        zoneValues: <Object?, Object?>{
          _artifactReplicaMutationZoneKey: artifactId,
        },
      ),
    );
    late final Future<void> tail;
    tail = current.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _artifactReplicaMutationTails[artifactId] = tail;
    return current.whenComplete(() {
      if (identical(_artifactReplicaMutationTails[artifactId], tail)) {
        _artifactReplicaMutationTails.remove(artifactId);
      }
    });
  }

  /// Marks only the exact logical bindings completed by one explicit
  /// download command as retained offline pages. Version siblings, Reader
  /// cache pages and other records that merely share a chapter id are not
  /// download intent and must remain evictable.
  Future<int> pinExactRecords(Iterable<DownloadId> ids) async {
    _requireOpen();
    var pinnedCount = 0;
    final seen = <String>{};
    for (final id in ids) {
      if (!seen.add(id.key)) continue;
      final pinned = await _serializeArtifactMutation(id, () async {
        final record = await _index.get(id.key);
        if (record == null ||
            !_isVerifiedReadyRecord(record) ||
            record.id != id ||
            record.pinned) {
          return false;
        }
        await _index.put(record.copyWith(pinned: true));
        return true;
      });
      if (pinned) pinnedCount++;
    }
    return pinnedCount;
  }

  DownloadSession sessionFor(DownloadId id) => _registry.get(id);
  DownloadSession? findSession(DownloadId id) => _registry.find(id);

  bool _ownsBorrowedSessionBacking(DownloadSession session) =>
      _borrowedPartialIds.contains(session.id) ||
      _borrowedPhysicalPartialIds.contains(session.physicalId);

  Future<T> _serializeBorrowedSessionCacheMutation<T>(
    DownloadSession session, {
    required bool exactBinding,
    required bool physicalPartial,
    required bool physicalArtifact,
    required Future<T> Function() operation,
  }) {
    Future<T> runPhysicalPartial() {
      if (!physicalPartial || session.physicalId.isExactFallback) {
        return operation();
      }
      return _serializePhysicalPartialMutation(
        session.physicalId,
        operation,
      );
    }

    Future<T> runExactBinding() {
      if (!exactBinding) return runPhysicalPartial();
      return _serializeArtifactMutation(session.id, runPhysicalPartial);
    }

    if (!physicalArtifact || session.physicalId.isExactFallback) {
      return runExactBinding();
    }
    return _serializePhysicalArtifactMutation(
      session.physicalId,
      runExactBinding,
    );
  }

  @override
  Future<bool> beginDownloadCachePromotion(
    DownloadSession session, {
    required SourceEpoch expectedEpoch,
  }) {
    if (session.index == null) return Future<bool>.value(false);
    return _serializeBorrowedSessionCacheMutation<bool>(
      session,
      exactBinding: true,
      physicalPartial: !session.physicalId.isExactFallback,
      physicalArtifact: !session.physicalId.isExactFallback,
      operation: () async {
        _requireOpen();
        if (!_ownsBorrowedSessionBacking(session)) {
          throw StateError(
            'persistent promotion requires a borrowed session backing',
          );
        }
        if (session.epoch != expectedEpoch ||
            session.state == DownloadState.disposed ||
            session.artifact.state != ArtifactState.sealed ||
            session.committedLength <= 0) {
          return false;
        }
        await _index.beginArtifactPromotion(
          id: session.id,
          physicalId: session.physicalId,
          sourceAccessLocator: session.artifact.partialPath,
          destinationAccessLocator: session.artifact.finalPath,
          bytes: session.committedLength,
          checksum: session.artifact.checksum,
          storageRootId: session.storageRootId,
        );
        return true;
      },
    );
  }

  @override
  Future<void> commitDownloadCachePromotion(
    DownloadSession session, {
    required SourceEpoch expectedEpoch,
  }) =>
      _serializeBorrowedSessionCacheMutation<void>(
        session,
        exactBinding: true,
        physicalPartial: !session.physicalId.isExactFallback,
        physicalArtifact: !session.physicalId.isExactFallback,
        operation: () async {
          _requireOpen();
          if (!_ownsBorrowedSessionBacking(session)) {
            throw StateError(
              'persistent promotion requires a borrowed session backing',
            );
          }
          if (session.epoch != expectedEpoch ||
              session.state == DownloadState.disposed) {
            return;
          }
          await _index.commitArtifactPromotion(session.physicalId.key);
        },
      );

  @override
  Future<void> abortDownloadCachePromotion(DownloadSession session) =>
      _serializeBorrowedSessionCacheMutation<void>(
        session,
        exactBinding: session.index != null,
        physicalPartial: !session.physicalId.isExactFallback,
        physicalArtifact: !session.physicalId.isExactFallback,
        operation: () =>
            _index.removeArtifactPromotion(session.physicalId.key),
      );

  @override
  Future<void> syncDownloadCache(
    DownloadSession session,
    CacheState state, {
    required SourceEpoch expectedEpoch,
    int? committedLength,
  }) {
    final physicalPartial = state == CacheState.partial &&
        !session.physicalId.isExactFallback;
    final exactBinding = !physicalPartial && session.index != null;
    final physicalArtifact = state == CacheState.ready &&
        !session.physicalId.isExactFallback &&
        session.index != null;
    return _serializeBorrowedSessionCacheMutation<void>(
      session,
      exactBinding: exactBinding,
      physicalPartial: physicalPartial || physicalArtifact,
      physicalArtifact: physicalArtifact,
      operation: () => _syncBorrowedSessionCacheUnserialized(
        session,
        state,
        expectedEpoch: expectedEpoch,
        committedLength: committedLength,
      ),
    );
  }

  Future<void> _syncBorrowedSessionCacheUnserialized(
    DownloadSession session,
    CacheState state, {
    required SourceEpoch expectedEpoch,
    int? committedLength,
  }) async {
    _requireOpen();
    if (committedLength != null && state != CacheState.partial) {
      throw StateError('explicit committed length is only valid for partial cache sync');
    }
    if (!_ownsBorrowedSessionBacking(session)) {
      throw StateError(
        'persistent cache mutation requires a borrowed session backing',
      );
    }
    if (session.epoch != expectedEpoch ||
        session.state == DownloadState.disposed ||
        session.artifact.state == ArtifactState.empty) {
      return;
    }
    final persistedLength = committedLength ?? session.committedLength;
    if (persistedLength < 0 || persistedLength > session.committedLength) {
      throw StateError('cache sync length exceeds committed session prefix');
    }
    if (state == CacheState.partial && persistedLength == 0) return;

    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    if (state == CacheState.partial && !session.physicalId.isExactFallback) {
      final existingPhysical =
          await _index.getPhysicalPartial(session.physicalId);
      if (session.epoch != expectedEpoch ||
          session.state == DownloadState.disposed) {
        return;
      }
      final writtenPhysical = PhysicalPartialRecord(
        id: session.physicalId,
        path: session.artifact.partialPath,
        bytes: persistedLength,
        checksum: session.artifact.checksum,
        createdUs: existingPhysical?.createdUs ?? now,
        touchedUs: now,
        checksumAlgorithm: existingPhysical?.checksumAlgorithm ?? 'crc32',
        storageRootId: session.storageRootId,
      );
      await _index.putPhysicalPartial(writtenPhysical);
      if (session.epoch != expectedEpoch ||
          session.state == DownloadState.disposed) {
        final current = await _index.getPhysicalPartial(session.physicalId);
        if (current == writtenPhysical) {
          await _index.removePhysicalPartial(session.physicalId);
        }
        return;
      }
      _notifyManagementProjectionChanged();
      return;
    }

    // A transfer-staging physical partial deliberately keeps exact-cache
    // ownership with this store instead of lending it to the session. Its
    // later promotion is materialized by PromotedArtifactCacheHandoff, not by
    // DownloadSession itself.
    if (session.index == null) return;
    final existing = await _index.get(session.id.key);
    if (session.epoch != expectedEpoch ||
        session.state == DownloadState.disposed) {
      return;
    }
    final writtenPath = state == CacheState.ready
        ? session.artifact.finalPath
        : session.artifact.partialPath;
    final written = CacheRec(
      id: session.id,
      state: state,
      path: writtenPath,
      bytes: persistedLength,
      checksum: session.artifact.checksum,
      createdUs: existing?.createdUs ?? now,
      touchedUs: now,
      pinned: existing?.pinned ?? false,
      checksumAlgorithm: existing?.checksumAlgorithm ?? 'crc32',
      artifactId: existing?.path == writtenPath ? existing!.artifactId : '',
      storageRootId: session.storageRootId,
    );
    await _index.put(written);
    if (state == CacheState.ready && !session.physicalId.isExactFallback) {
      await _index.putPhysicalMediaArtifactBinding(
        id: session.physicalId,
        artifactId: written.effectiveArtifactId,
        createdUs: written.createdUs,
        touchedUs: written.touchedUs,
      );
      if (session.epoch == expectedEpoch &&
          session.state != DownloadState.disposed) {
        await _index.removePhysicalPartial(session.physicalId);
      }
    }
    if (session.epoch != expectedEpoch ||
        session.state == DownloadState.disposed) {
      final current = await _index.get(session.id.key);
      if (current != null && _sameIndexedRecord(current, written)) {
        await _index.remove(session.id.key);
      }
      if (!session.physicalId.isExactFallback) {
        final currentPhysical =
            await _index.getPhysicalMediaArtifact(session.physicalId);
        if (currentPhysical?.artifactId == written.effectiveArtifactId) {
          await _index.removePhysicalMediaArtifactBinding(session.physicalId);
        }
      }
      return;
    }
    _notifyManagementProjectionChanged();
  }

  @override
  Future<void> clearDownloadCache(
    DownloadSession session, {
    required bool removeCacheRecord,
    required bool deleteFinalArtifact,
  }) => _serializeBorrowedSessionCacheMutation<void>(
        session,
        exactBinding: removeCacheRecord && session.index != null,
        physicalPartial: !session.physicalId.isExactFallback,
        physicalArtifact:
            deleteFinalArtifact && !session.physicalId.isExactFallback,
        operation: () async {
          _requireOpen();
          if (!_ownsBorrowedSessionBacking(session)) {
            throw StateError(
              'persistent cache clear requires a borrowed session backing',
            );
          }
          if (!session.physicalId.isExactFallback) {
            await _index.removePhysicalPartial(session.physicalId);
          }
          if (deleteFinalArtifact && !session.physicalId.isExactFallback) {
            final record =
                await _index.getPhysicalMediaArtifact(session.physicalId);
            if (record != null) {
              // The original borrower has already reset its hot body. Retire
              // its canonical READY through this lending owner's cleanup
              // boundary, preserving replicas still owned by exact bindings.
              await _invalidatePhysicalArtifactRecord(record);
            }
          }
          if (removeCacheRecord && session.index != null) {
            await _index.remove(session.id.key);
          }
        },
      );

  Future<void> evict(DownloadId id) =>
      _serializeArtifactMutation(id, () => _evictUnserialized(id));

  Future<void> _evictUnserialized(DownloadId id) async {
    if (_borrowedPartialIds.contains(id)) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'durable partial is borrowed by the active transfer owner',
      );
    }
    var session = _registry.find(id);
    if (session != null && (session.activeRun || session.hasWriter)) {
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        session = _registry.find(id);
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
    final record = await _index.get(id.key);
    if (record != null) {
      final deletedPhysical = await _invalidateIndexedArtifact(
        id,
        record: record,
      );
      if (deletedPhysical && _registry.find(id) != null) {
        await _registry.evict(id);
      }
    } else if (session != null &&
        !session.activeRun &&
        !session.hasWriter &&
        session.state != DownloadState.disposed) {
      final finalPath = session.artifact.finalPath;
      final shared = await _index.isPathOrArtifactReferenced(
        path: finalPath,
        artifactId: '',
        excludingKey: id.key,
      );
      if (shared) {
        await session.resetIfIdle(removeCacheRecord: false);
      } else {
        await _registry.evict(id);
      }
    }
  }

  @override
  Future<HistoricalArtifactCarrierCandidates> historicalArtifactCarriers(
    DownloadId id,
  ) async {
    _requireOpen();
    // This query uses touched_us as the carrier preference order. Ordinary
    // artifact opens deliberately schedule recency maintenance without waiting
    // for storage-write capacity, but a recency-sensitive query must observe
    // touches that were already admitted before the query started. Wait only
    // for matching logical-page drains; do not turn every cache hit into a
    // storage barrier or add a second in-memory ordering authority.
    await _settleExactArtifactTouchesFor(
      content: id.content,
      sourceRevision: id.sourceRevision,
    );
    final records = await _index.listLogicalBindings(
      content: id.content,
      sourceRevision: id.sourceRevision,
      state: CacheState.ready,
    );
    final usable = records
        .where((record) => record.id != id && _isVerifiedReadyRecord(record))
        .toList(growable: false);
    final signatures = <(int, String, String)>{
      for (final record in usable)
        (
          record.bytes,
          record.checksumAlgorithm.trim().toLowerCase(),
          record.checksum.trim().toLowerCase(),
        ),
    };
    return HistoricalArtifactCarrierCandidates(
      ids: List<DownloadId>.unmodifiable(
        usable.map((record) => record.id),
      ),
      readyRecordCount: usable.length,
      signatureCount: signatures.length,
    );
  }

  Future<void> _settleExactArtifactTouchesFor({
    required ContentId content,
    required String sourceRevision,
  }) async {
    final ids = <DownloadId>{
      for (final id in _exactArtifactTouchDrains.keys)
        if (id.content == content && id.sourceRevision == sourceRevision) id,
      for (final id in _pendingExactArtifactTouches.keys)
        if (id.content == content && id.sourceRevision == sourceRevision) id,
    };
    for (final id in ids) {
      while (!_closed) {
        final drain = _exactArtifactTouchDrains[id];
        if (drain == null) {
          if (!_pendingExactArtifactTouches.containsKey(id)) break;
          _startExactArtifactTouchDrain(id);
          continue;
        }
        try {
          await drain;
        } on Object {
          // Recency is best-effort. A failed touch must not make an otherwise
          // valid historical carrier unreadable.
        }
        if (!_exactArtifactTouchDrains.containsKey(id) &&
            !_pendingExactArtifactTouches.containsKey(id)) {
          break;
        }
      }
    }
  }

  @override
  Future<bool> isPinnedExactArtifact(DownloadId id) async {
    _requireOpen();
    final record = await _index.get(id.key);
    return record != null &&
        record.id == id &&
        record.pinned &&
        _isVerifiedReadyRecord(record);
  }

  Future<Uint8List> readPromoted(DownloadId id) async {
    final entry = await openArtifactStream(id);
    if (entry == null) {
      throw StateError('requested page is not downloaded');
    }
    final readAll = entry.readAll;
    if (readAll != null) return readAll();
    final builder = BytesBuilder(copy: false);
    await for (final chunk in entry.open(start: 0)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  Future<ArtifactCacheStreamEntry?> openPhysicalArtifact(
    PhysicalMediaId id,
  ) async {
    _requireOpen();
    final record = await _index.getPhysicalMediaArtifact(id);
    if (record == null || record.bytes <= 0) return null;
    final durableReplicas = await _index.listArtifactReplicas(
      record.artifactId,
    );
    if (durableReplicas.isEmpty) {
      await _index.removePhysicalMediaArtifactBinding(id);
      _notifyManagementProjectionChanged();
      return null;
    }
    final replicas = durableReplicas
        .where((replica) => replica.accessLocator.isNotEmpty)
        .map(
          (replica) => _ArtifactAccessRecord(
            artifactId: record.artifactId,
            replicaId: replica.replicaId,
            accessLocator: replica.accessLocator,
            bytes: record.bytes,
            checksum: record.checksum,
            checksumAlgorithm: record.checksumAlgorithm,
            storageRootId: replica.storageRootId,
          ),
        )
        .toList(growable: false);
    if (replicas.isEmpty) return null;

    ArtifactReadFailure? lastFailure;
    for (final replica in replicas) {
      if (!await _artifactReplicaIsAccessible(replica)) continue;
      final candidates = await _artifactAccessCandidates(replica);
      late final ({_ArtifactAccessCandidate candidate, int length}) selected;
      try {
        selected = await _selectReadableArtifactAccess(
          candidates,
          skipExistsProbe: candidates.every(
            (candidate) =>
                parseSafRecordPath(candidate.access.accessLocator) == null,
          ),
        );
      } on ArtifactReadFailure catch (error) {
        lastFailure = error;
        if (_isStructuralReplicaFailure(error.kind)) {
          await _retireArtifactReplica(
            replica.artifactId,
            replica.replicaId,
            replica.accessLocator,
          );
        }
        continue;
      }
      final selectedAccess = selected.candidate.access;
      _schedulePhysicalArtifactTouch(id, record.artifactId);
      _scheduleRedundantPhysicalPartialRetirement(
        id,
        expectedArtifactId: record.artifactId,
      );
      if (selectedAccess.checksumAlgorithm.toLowerCase() != 'crc32') {
        await _retireArtifactReplica(
          selectedAccess.artifactId,
          selectedAccess.replicaId,
          selectedAccess.accessLocator,
        );
        continue;
      }
      final selectedCandidates = <_ArtifactAccessCandidate>[
        selected.candidate,
        ...candidates.where(
          (candidate) =>
              candidate.access.accessLocator != selectedAccess.accessLocator,
        ),
      ];
      return ArtifactCacheStreamEntry(
        length: selected.length,
        open: ({required int start, int? endExclusive}) =>
            _readArtifactCandidates(
              selectedCandidates,
              start: start,
              endExclusive: endExclusive,
            ),
        readAll: () => _readArtifactAllVerifiedForArtifact(
          artifactId: selectedAccess.artifactId,
          preferredCandidates: selectedCandidates,
          length: selected.length,
          expectedChecksum: selectedAccess.checksum.trim().toLowerCase(),
          checksumAlgorithm:
              selectedAccess.checksumAlgorithm.trim().toLowerCase(),
        ),
        readAllControlled: ({required control}) =>
            _readArtifactAllVerifiedForArtifact(
              artifactId: selectedAccess.artifactId,
              preferredCandidates: selectedCandidates,
              length: selected.length,
              expectedChecksum: selectedAccess.checksum.trim().toLowerCase(),
              checksumAlgorithm:
                  selectedAccess.checksumAlgorithm.trim().toLowerCase(),
              control: control,
            ),
        openBoundRangeReader: () => _openBoundArtifactRangeReader(
          selectedCandidates,
          expectedLength: selected.length,
        ),
        openPresentationFile: presentationFileLeaseFactory == null
            ? null
            : () => presentationFileLeaseFactory!.open(
                selectedAccess.accessLocator,
                expectedLength: selected.length,
              ),
        accessMode: parseSafRecordPath(selectedAccess.accessLocator) == null
            ? 'direct'
            : 'saf',
        sealedChecksum: selectedAccess.checksum.trim().toLowerCase(),
        sealedChecksumAlgorithm:
            selectedAccess.checksumAlgorithm.trim().toLowerCase(),
        streamIntegrity: ArtifactReadIntegrityBasis.sealedMetadataLength,
        fullReadIntegrity: ArtifactReadIntegrityBasis.crc32Verified,
      );
    }
    if ((await _index.listArtifactReplicas(record.artifactId)).isEmpty) {
      await _index.removePhysicalMediaArtifactBinding(id);
      _notifyManagementProjectionChanged();
    }
    if (lastFailure != null) throw lastFailure;
    return null;
  }

  @override
  Future<ArtifactCacheStreamEntry?> openPhysicalArtifactForBoundReplay(
    PhysicalMediaId id,
  ) async {
    _requireOpen();
    final record = await _index.getPhysicalMediaArtifact(id);
    if (record == null || record.bytes <= 0) return null;
    // Non-CRC legacy artifacts keep the ordinary path so its historical
    // retirement/validation behavior remains unchanged.
    if (record.checksumAlgorithm.trim().toLowerCase() != 'crc32') {
      return openPhysicalArtifact(id);
    }
    final durableReplicas = await _index.listArtifactReplicas(record.artifactId);
    if (durableReplicas.isEmpty) {
      await _index.removePhysicalMediaArtifactBinding(id);
      _notifyManagementProjectionChanged();
      return null;
    }

    final candidates = <_ArtifactAccessCandidate>[];
    final seenLocators = <String>{};
    for (final replica in durableReplicas) {
      if (replica.accessLocator.isEmpty) continue;
      final access = _ArtifactAccessRecord(
        artifactId: record.artifactId,
        replicaId: replica.replicaId,
        accessLocator: replica.accessLocator,
        bytes: record.bytes,
        checksum: record.checksum,
        checksumAlgorithm: record.checksumAlgorithm,
        storageRootId: replica.storageRootId,
      );
      if (!await _artifactReplicaIsAccessible(access)) continue;
      for (final candidate in await _artifactAccessCandidates(access)) {
        if (seenLocators.add(candidate.access.accessLocator)) {
          candidates.add(candidate);
        }
      }
    }
    if (candidates.isEmpty) return null;

    final preferredAccess = candidates.first.access;
    _schedulePhysicalArtifactTouch(id, record.artifactId);
    _scheduleRedundantPhysicalPartialRetirement(
      id,
      expectedArtifactId: record.artifactId,
    );
    return ArtifactCacheStreamEntry(
      length: record.bytes,
      open: ({required int start, int? endExclusive}) =>
          _readArtifactCandidates(
            candidates,
            start: start,
            endExclusive: endExclusive,
          ),
      readAll: () => _readArtifactAllVerifiedForArtifact(
        artifactId: record.artifactId,
        preferredCandidates: candidates,
        length: record.bytes,
        expectedChecksum: record.checksum.trim().toLowerCase(),
        checksumAlgorithm: record.checksumAlgorithm.trim().toLowerCase(),
      ),
      readAllControlled: ({required control}) =>
          _readArtifactAllVerifiedForArtifact(
            artifactId: record.artifactId,
            preferredCandidates: candidates,
            length: record.bytes,
            expectedChecksum: record.checksum.trim().toLowerCase(),
            checksumAlgorithm: record.checksumAlgorithm.trim().toLowerCase(),
            control: control,
          ),
      openBoundRangeReader: () async {
        try {
          return await _openBoundArtifactRangeReader(
            candidates,
            expectedLength: record.bytes,
          );
        } on ArtifactReadFailure catch (error) {
          if (_isStructuralReplicaFailure(error.kind) &&
              error.replicaId != null) {
            final failed = candidates
                .where(
                  (candidate) =>
                      candidate.access.replicaId == error.replicaId,
                )
                .firstOrNull;
            if (failed != null) {
              await _retireArtifactReplica(
                failed.access.artifactId,
                failed.access.replicaId,
                failed.access.accessLocator,
              );
            }
          }
          rethrow;
        }
      },
      accessMode: parseSafRecordPath(preferredAccess.accessLocator) == null
          ? 'direct'
          : 'saf',
      sealedChecksum: record.checksum.trim().toLowerCase(),
      sealedChecksumAlgorithm:
          record.checksumAlgorithm.trim().toLowerCase(),
      streamIntegrity: ArtifactReadIntegrityBasis.sealedMetadataLength,
      fullReadIntegrity: ArtifactReadIntegrityBasis.crc32Verified,
    );
  }

  void _scheduleExactArtifactTouch(
    DownloadId id,
    String expectedArtifactId,
  ) {
    if (_closed) return;
    final touchedUs = DateTime.now().toUtc().microsecondsSinceEpoch;
    final pending = _pendingExactArtifactTouches[id];
    if (pending == null || pending.touchedUs < touchedUs) {
      _pendingExactArtifactTouches[id] = (
        artifactId: expectedArtifactId,
        touchedUs: touchedUs,
      );
    }
    if (_exactArtifactTouchDrains.containsKey(id)) return;
    _startExactArtifactTouchDrain(id);
  }

  void _startExactArtifactTouchDrain(DownloadId id) {
    late final Future<void> drain;
    drain = _runDeferredExactArtifactTouches(id).whenComplete(() {
      if (identical(_exactArtifactTouchDrains[id], drain)) {
        _exactArtifactTouchDrains.remove(id);
      }
      if (!_closed && _pendingExactArtifactTouches.containsKey(id)) {
        _startExactArtifactTouchDrain(id);
      }
    });
    _exactArtifactTouchDrains[id] = drain;
  }

  Future<void> _runDeferredExactArtifactTouches(DownloadId id) async {
    while (!_closed && !_deferredRecencyTouchControl.cancelled) {
      var pending = _pendingExactArtifactTouches.remove(id);
      if (pending == null) return;
      final latest = _pendingExactArtifactTouches.remove(id);
      if (latest != null) pending = latest;
      StorageWriteLease? lease;
      try {
        lease = await _storageWriteScheduler.acquireQuantum(
          control: _deferredRecencyTouchControl,
        );
        if (_closed || _deferredRecencyTouchControl.cancelled) return;
        await _index.touchIfArtifactInBackground(
          key: id.key,
          expectedArtifactId: pending.artifactId,
          touchedUs: pending.touchedUs,
        );
      } on Object {
        // Recency metadata is best-effort and never part of artifact authority.
      } finally {
        lease?.release();
      }
    }
  }

  void _schedulePhysicalArtifactTouch(
    PhysicalMediaId id,
    String expectedArtifactId,
  ) {
    final touchedUs = DateTime.now().toUtc().microsecondsSinceEpoch;
    unawaited(
      _runDeferredPhysicalArtifactTouch(
        id,
        expectedArtifactId,
        touchedUs,
      ),
    );
  }

  void _scheduleRedundantPhysicalPartialRetirement(
    PhysicalMediaId id, {
    required String expectedArtifactId,
  }) {
    if (_closed ||
        id.isExactFallback ||
        !_redundantPhysicalPartialRetirements.add(id)) {
      return;
    }
    unawaited(
      _serializePhysicalArtifactMutation(
        id,
        () => _serializePhysicalPartialMutation(id, () async {
          if (_closed || _borrowedPhysicalPartialIds.contains(id)) return;
          final artifact = await _index.getPhysicalMediaArtifact(id);
          if (artifact == null || artifact.artifactId != expectedArtifactId) {
            return;
          }
          final partial = await _index.getPhysicalPartial(id);
          if (partial == null) return;
          await _withStorageWriteQuantum(
            () => _removePhysicalPartialRecord(partial, deleteBody: true),
          );
          _notifyManagementProjectionChanged();
        }),
      ).catchError((Object error, StackTrace stackTrace) {
        _recordCleanupDebtFailure(
          stage: 'redundant-physical-partial-retirement',
          accessLocator: id.key,
          error: error,
          stackTrace: stackTrace,
        );
      }).whenComplete(() {
        _redundantPhysicalPartialRetirements.remove(id);
      }),
    );
  }

  Future<void> _runDeferredPhysicalArtifactTouch(
    PhysicalMediaId id,
    String expectedArtifactId,
    int touchedUs,
  ) async {
    try {
      await _serializePhysicalArtifactMutation(id, () async {
        if (_closed || _deferredRecencyTouchControl.cancelled) return;
        final current = await _index.getPhysicalMediaArtifact(id);
        if (current == null || current.artifactId != expectedArtifactId) return;
        StorageWriteLease? lease;
        try {
          lease = await _storageWriteScheduler.acquireQuantum(
            control: _deferredRecencyTouchControl,
          );
          if (_closed || _deferredRecencyTouchControl.cancelled) return;
          final latest = await _index.getPhysicalMediaArtifact(id);
          if (latest == null || latest.artifactId != expectedArtifactId) return;
          await _index.touchPhysicalMediaArtifact(id, touchedUs);
        } finally {
          lease?.release();
        }
      });
    } on Failure catch (error) {
      if (error.code != ErrorCode.cancelled) {
        // Recency metadata is best-effort and never part of artifact authority.
      }
    } on Object {
      // Recency metadata is best-effort and never part of artifact authority.
    }
  }

  @override
  Future<bool> bindPhysicalArtifact({
    required PhysicalMediaId physicalId,
    required DownloadId sourceId,
  }) => _notifyManagementAfter(
    _serializePhysicalArtifactMutation(
      physicalId,
      () => _serializeArtifactMutation(sourceId, () async {
    _requireOpen();
    final source = await _index.get(sourceId.key);
    if (source == null ||
        source.id != sourceId ||
        !_isVerifiedReadyRecord(source)) {
      return false;
    }
    final existing = await _index.getPhysicalMediaArtifact(physicalId);
    if (existing != null) {
      if (existing.artifactId == source.effectiveArtifactId) {
        _scheduleRedundantPhysicalPartialRetirement(
          physicalId,
          expectedArtifactId: existing.artifactId,
        );
      }
      return existing.artifactId == source.effectiveArtifactId;
    }
    ArtifactCacheStreamEntry? preflight;
    try {
      preflight = await _openArtifactStreamExact(sourceId);
    } on ArtifactReadFailure {
      return false;
    }
    if (preflight == null || preflight.length != source.bytes) return false;
    final current = await _index.get(sourceId.key);
    if (current == null ||
        current.id != sourceId ||
        !_isVerifiedReadyRecord(current) ||
        current.effectiveArtifactId != source.effectiveArtifactId ||
        current.bytes != source.bytes ||
        current.checksum.trim().toLowerCase() !=
            source.checksum.trim().toLowerCase()) {
      return false;
    }
    final nowUs = DateTime.now().toUtc().microsecondsSinceEpoch;
    await _index.putPhysicalMediaArtifactBinding(
      id: physicalId,
      artifactId: current.effectiveArtifactId,
      createdUs: existing?.createdUs ?? nowUs,
      touchedUs: nowUs,
    );
    _scheduleRedundantPhysicalPartialRetirement(
      physicalId,
      expectedArtifactId: current.effectiveArtifactId,
    );
    return true;
      }),
    ),
    when: (changed) => changed,
  );

  @override
  Future<bool> bindExactArtifactFromPhysical({
    required PhysicalMediaId physicalId,
    required DownloadId targetId,
  }) => _notifyManagementAfter(
    _serializeArtifactMutation(targetId, () async {
      _requireOpen();
      if (physicalId.isExactFallback || _borrowedPartialIds.contains(targetId)) {
        return false;
      }
      final existingTarget = await _index.get(targetId.key);
      final initialPhysical = await _index.getPhysicalMediaArtifact(physicalId);
      if (initialPhysical == null) return false;
      if (existingTarget != null) {
        return existingTarget.id == targetId &&
            _isVerifiedReadyRecord(existingTarget) &&
            existingTarget.effectiveArtifactId == initialPhysical.artifactId;
      }

      ArtifactCacheStreamEntry? preflight;
      try {
        preflight = await openPhysicalArtifact(physicalId);
      } on ArtifactReadFailure {
        return false;
      }
      if (preflight == null || preflight.length != initialPhysical.bytes) {
        return false;
      }

      final currentPhysical = await _index.getPhysicalMediaArtifact(physicalId);
      if (currentPhysical == null ||
          currentPhysical.artifactId != initialPhysical.artifactId ||
          currentPhysical.bytes != initialPhysical.bytes ||
          currentPhysical.checksum.trim().toLowerCase() !=
              initialPhysical.checksum.trim().toLowerCase() ||
          currentPhysical.checksumAlgorithm.trim().toLowerCase() !=
              initialPhysical.checksumAlgorithm.trim().toLowerCase()) {
        return false;
      }
      if (await _index.get(targetId.key) != null) return false;

      final nowUs = DateTime.now().toUtc().microsecondsSinceEpoch;
      await _index.putExistingArtifactBinding(
        CacheRec(
          id: targetId,
          state: CacheState.ready,
          path: currentPhysical.accessLocator,
          bytes: currentPhysical.bytes,
          checksum: currentPhysical.checksum,
          createdUs: nowUs,
          touchedUs: nowUs,
          pinned: false,
          checksumAlgorithm: currentPhysical.checksumAlgorithm,
          artifactId: currentPhysical.artifactId,
          storageRootId: currentPhysical.storageRootId,
        ),
      );
      return true;
    }),
    when: (changed) => changed,
  );

  @override
  Future<bool> bindPhysicalArtifactFromCandidates({
    required PhysicalMediaId physicalId,
    required Iterable<DownloadId> candidates,
  }) => _notifyManagementAfter(
    _serializePhysicalArtifactMutation(physicalId, () async {
    _requireOpen();
    if (physicalId.isExactFallback) return false;
    final existing = await _index.getPhysicalMediaArtifact(physicalId);
    if (existing != null) {
      _scheduleRedundantPhysicalPartialRetirement(
        physicalId,
        expectedArtifactId: existing.artifactId,
      );
      return true;
    }

    final query = _index as CacheLogicalBindingQuery;
    var logicalReadyMatches = 0;
    var verifiedReadyMatches = 0;
    var preflightFailures = 0;
    var preflightMisses = 0;
    final candidateOrder = <(String, String), int>{};
    final candidateIds = <DownloadId>[];
    final usable = <CacheRec>[];
    void recordRecovery(String action, {int? signatureCount, int? selectedBytes}) {
      try {
        _traceSink.record(
          traceEvent(
            clock: _clock,
            sessionId: 'physical-artifact-recovery',
            kind: TraceEventKind.artifactSource,
            identityHash: physicalId.key,
            payload: <String, Object?>{
              'action': action,
              'candidateCount': candidateIds.length,
              'logicalReadyMatches': logicalReadyMatches,
              'verifiedReadyMatches': verifiedReadyMatches,
              'preflightFailures': preflightFailures,
              'preflightMisses': preflightMisses,
              'usableCount': usable.length,
              if (signatureCount != null) 'signatureCount': signatureCount,
              if (selectedBytes != null) 'selectedBytes': selectedBytes,
            },
          ),
        );
      } on Object {
        // Recovery diagnostics must never alter cache authority.
      }
    }
    for (final candidate in candidates) {
      final logicalKey = (candidate.content.key, candidate.sourceRevision);
      if (candidateOrder.containsKey(logicalKey)) continue;
      candidateOrder[logicalKey] = candidateIds.length;
      candidateIds.add(candidate);
    }
    if (candidateIds.isEmpty) {
      recordRecovery('no-candidates');
      return false;
    }

    for (final candidate in candidateIds) {
      final records = await query.listLogicalBindings(
        content: candidate.content,
        sourceRevision: candidate.sourceRevision,
        state: CacheState.ready,
      );
      logicalReadyMatches += records.length;
      for (final record in records) {
        if (!_isVerifiedReadyRecord(record)) continue;
        verifiedReadyMatches++;
        ArtifactCacheStreamEntry? preflight;
        try {
          preflight = await _openArtifactStreamExact(record.id);
        } on ArtifactReadFailure {
          preflightFailures++;
          continue;
        }
        if (preflight == null || preflight.length != record.bytes) {
          preflightMisses++;
          continue;
        }
        usable.add(record);
      }
    }
    if (usable.isEmpty) {
      recordRecovery('no-usable-ready');
      return false;
    }

    // URI churn may leave several exact bindings for one logical page.
    // They may all point at the same immutable artifact/content proof. If
    // different byte proofs exist, fail closed rather than guessing which
    // historical URI represents the canonical body.
    final signatures = <(int, String, String)>{
      for (final record in usable)
        (
          record.bytes,
          record.checksumAlgorithm.trim().toLowerCase(),
          record.checksum.trim().toLowerCase(),
        ),
    };
    if (signatures.length != 1) {
      recordRecovery(
        'conflicting-ready-proofs',
        signatureCount: signatures.length,
      );
      return false;
    }

    usable.sort((left, right) {
      int orderFor(CacheRec record) =>
          candidateOrder[(record.id.content.key, record.id.sourceRevision)] ??
          candidateIds.length;
      final order = orderFor(left).compareTo(orderFor(right));
      if (order != 0) return order;
      final exactLeft = candidateIds.any((id) => id == left.id);
      final exactRight = candidateIds.any((id) => id == right.id);
      if (exactLeft != exactRight) return exactLeft ? -1 : 1;
      return right.touchedUs.compareTo(left.touchedUs);
    });
    final selected = usable.first;
    final current = await _index.get(selected.key);
    if (current == null ||
        !_isVerifiedReadyRecord(current) ||
        current.effectiveArtifactId != selected.effectiveArtifactId ||
        current.bytes != selected.bytes ||
        current.checksum.trim().toLowerCase() !=
            selected.checksum.trim().toLowerCase()) {
      recordRecovery('selected-ready-changed', signatureCount: signatures.length);
      return false;
    }
    final nowUs = DateTime.now().toUtc().microsecondsSinceEpoch;
    await _index.putPhysicalMediaArtifactBinding(
      id: physicalId,
      artifactId: current.effectiveArtifactId,
      createdUs: nowUs,
      touchedUs: nowUs,
    );
    _scheduleRedundantPhysicalPartialRetirement(
      physicalId,
      expectedArtifactId: current.effectiveArtifactId,
    );
    recordRecovery(
      'bound-existing-ready',
      signatureCount: signatures.length,
      selectedBytes: current.bytes,
    );
    return true;
  }),
    when: (changed) => changed,
  );

  @override
  Future<void> invalidatePhysicalArtifact(PhysicalMediaId id) =>
      _serializePhysicalArtifactMutation(id, () async {
        _requireOpen();
        final record = await _index.getPhysicalMediaArtifact(id);
        // The borrowing session's reset may already have retired this row.
        // No body mutation remains, even while that session retains its lease.
        if (record == null) return;
        if (_borrowedPhysicalPartialIds.contains(id)) {
          throw const Failure(
            code: ErrorCode.sessionBusy,
            message: 'physical durable body is borrowed by the transfer owner',
          );
        }
        await _invalidatePhysicalArtifactRecord(record);
      });

  Future<void> _invalidatePhysicalArtifactRecord(
    PhysicalMediaArtifactRecord record,
  ) async {
    final replicas = await _index.listArtifactReplicas(record.artifactId);
    final debts = <StorageCleanupDebtRecord>[];
    for (final replica in replicas) {
      final prepared = await _prepareObsoleteSealedReplicaCleanupDebt(
        replica: replica,
        expectedBytes: record.bytes,
        expectedChecksum: record.checksum,
        expectedChecksumAlgorithm: record.checksumAlgorithm,
      );
      if (!prepared.safeToRetire) {
        await _forgetStorageCleanupDebts(debts);
        throw const Failure(
          code: ErrorCode.policy,
          message:
              'physical artifact cleanup access is not currently provable',
        );
      }
      final debt = prepared.debt;
      if (debt != null) debts.add(debt);
    }
    try {
      await _index.removePhysicalMediaArtifactBinding(record.id);
    } on Object {
      await _forgetStorageCleanupDebts(debts);
      rethrow;
    }
    _notifyManagementProjectionChanged();
    if (await _index.getArtifactObject(record.artifactId) != null) {
      await _forgetStorageCleanupDebts(debts);
      return;
    }
    for (final debt in debts) {
      await _cleanupObsoleteSourceNow(debt);
    }
  }

  @override
  Future<bool> bindExistingArtifact({
    required DownloadId sourceId,
    required DownloadId targetId,
  }) => _serializeArtifactMutation(targetId, () async {
    _requireOpen();
    if (sourceId == targetId || _borrowedPartialIds.contains(targetId)) {
      return false;
    }
    final targetSession = _registry.find(targetId);
    if (targetSession != null &&
        targetSession.state != DownloadState.disposed) {
      return false;
    }
    final existingTarget = await _index.get(targetId.key);
    if (existingTarget != null) {
      return existingTarget.id == targetId &&
          _isVerifiedReadyRecord(existingTarget);
    }
    final source = await _index.get(sourceId.key);
    if (source == null ||
        source.id != sourceId ||
        !_isVerifiedReadyRecord(source)) {
      return false;
    }
    final artifactId = source.effectiveArtifactId;
    return _serializeArtifactReplicaMutation(artifactId, () async {
      final targetAfterLock = await _index.get(targetId.key);
      if (targetAfterLock != null) {
        return targetAfterLock.id == targetId &&
            _isVerifiedReadyRecord(targetAfterLock);
      }
      final sourceAfterLock = await _index.get(sourceId.key);
      if (sourceAfterLock == null ||
          sourceAfterLock.id != sourceId ||
          !_isVerifiedReadyRecord(sourceAfterLock) ||
          sourceAfterLock.effectiveArtifactId != artifactId) {
        return false;
      }
      ArtifactCacheStreamEntry? preflight;
      try {
        preflight = await _openArtifactStreamExact(sourceId);
      } on ArtifactReadFailure {
        return false;
      }
      if (preflight == null || preflight.length != sourceAfterLock.bytes) {
        return false;
      }
      final currentSource = await _index.get(sourceId.key);
          if (currentSource == null ||
              currentSource.id != sourceId ||
              !_isVerifiedReadyRecord(currentSource) ||
              currentSource.effectiveArtifactId != artifactId ||
              currentSource.bytes != sourceAfterLock.bytes ||
              currentSource.checksum.trim().toLowerCase() !=
                  sourceAfterLock.checksum.trim().toLowerCase()) {
            return false;
          }
          final nowUs = DateTime.now().toUtc().microsecondsSinceEpoch;
          await _index.putExistingArtifactBinding(
            CacheRec(
              id: targetId,
              state: CacheState.ready,
              path: currentSource.path,
              bytes: currentSource.bytes,
              checksum: currentSource.checksum,
              createdUs: nowUs,
              touchedUs: nowUs,
              pinned: false,
              checksumAlgorithm: currentSource.checksumAlgorithm,
              artifactId: artifactId,
              storageRootId: currentSource.storageRootId,
            ),
          );
          return true;
        });
      });

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) =>
      _serializeArtifactMutation(
        id,
        () => _openAuthoritativeArtifactStream(id),
      );

  Future<ArtifactCacheStreamEntry?> _openAuthoritativeArtifactStream(
    DownloadId id,
  ) async {
    _requireOpen();
    if (_artifactWrites.containsKey(id)) return null;
    final active = _registry.find(id);
    if (active != null && (active.activeRun || active.hasWriter)) return null;
    return _openArtifactStreamExact(id);
  }

  Future<List<_ArtifactAccessRecord>> _resolveArtifactReplicas(
    CacheRec record, {
    ArtifactAuthorityReadSnapshot? authority,
  }
  ) async {
    final fallback = _ArtifactAccessRecord.fromBinding(record);
    final object = authority?.object ??
        await _index.getArtifactObject(record.effectiveArtifactId);
    if (object == null ||
        object.artifactId != record.effectiveArtifactId ||
        object.bytes != record.bytes ||
        object.checksum.trim().toLowerCase() !=
            record.checksum.trim().toLowerCase() ||
        object.checksumAlgorithm.trim().toLowerCase() !=
            record.checksumAlgorithm.trim().toLowerCase()) {
      return <_ArtifactAccessRecord>[fallback];
    }
    final replicas = authority?.replicas ??
        await _index.listArtifactReplicas(object.artifactId);
    if (replicas.isEmpty) {
      // Schema 8 backfills every pre-existing object. An empty replica set
      // therefore means that all physical copies were explicitly retired;
      // artifact_object.path is only a compatibility mirror, not a hidden copy.
      return const <_ArtifactAccessRecord>[];
    }
    return replicas
        .where((replica) => replica.accessLocator.isNotEmpty)
        .map(
          (replica) => _ArtifactAccessRecord(
            artifactId: object.artifactId,
            replicaId: replica.replicaId,
            accessLocator: replica.accessLocator,
            bytes: object.bytes,
            checksum: object.checksum,
            checksumAlgorithm: object.checksumAlgorithm,
            storageRootId: replica.storageRootId,
          ),
        )
        .toList(growable: false);
  }

  Future<bool> _artifactReplicaIsAccessible(
    _ArtifactAccessRecord access, {
    ArtifactAuthorityReadSnapshot? authority,
  }
  ) async {
    final parsed = parseSafRecordPath(access.accessLocator);
    if (parsed == null) {
      // App-private metadata intentionally keeps direct replicas on historical
      // roots readable after the default root changes. Actual permission/IO
      // failure is typed by ArtifactBytes and may fall through a proven SAF alias.
      return true;
    }
    final currentSaf = safTreeUri;
    if (currentSaf == null) return false;
    if (parsed.treeUri == currentSaf) return true;
    final root = authority == null
        ? await _index.getStorageRoot(access.storageRootId)
        : _storageRootFromAuthoritySnapshot(
            authority,
            access.storageRootId,
          );
    return root?.accessLocators.any(
          (locator) =>
              locator.kind == StorageAccessLocatorKind.saf &&
              locator.locator == currentSaf,
        ) ==
        true;
  }

  Future<List<_ArtifactAccessCandidate>> _artifactAccessCandidates(
    _ArtifactAccessRecord base, {
    ArtifactAuthorityReadSnapshot? authority,
  }) async {
    final parsed = parseSafRecordPath(base.accessLocator);
    final rootIdentity = parsed?.treeUri ?? base.storageRootId;
    final root = authority == null
        ? await _index.getStorageRoot(rootIdentity)
        : _storageRootFromAuthoritySnapshot(
            authority,
            rootIdentity,
            fallbackRootId: base.storageRootId,
          );
    if (root == null || root.accessLocators.isEmpty) {
      return <_ArtifactAccessCandidate>[_ArtifactAccessCandidate(access: base)];
    }

    String? relativePath = parsed?.relativePath;
    if (relativePath == null) {
      final directRoots =
          root.accessLocators
              .where(
                (locator) => locator.kind == StorageAccessLocatorKind.direct,
              )
          .map((locator) => locator.locator)
          .toList(growable: false)
        ..sort((left, right) => right.length.compareTo(left.length));
      for (final directRoot in directRoots) {
        final relative = _relativeDirectArtifactPath(
          root: directRoot,
          artifactPath: base.accessLocator,
        );
        if (relative != null) {
          relativePath = relative;
          break;
        }
      }
      relativePath ??= _relativeDirectArtifactPath(
        root: base.storageRootId,
        artifactPath: base.accessLocator,
      );
    }
    if (relativePath == null || relativePath.isEmpty) {
      return <_ArtifactAccessCandidate>[
        _ArtifactAccessCandidate(
          access: base,
          rootAccess: _matchingRootAccess(root, base),
        ),
      ];
    }

    final available =
        root.accessLocators
            .where((locator) {
      if (locator.kind == StorageAccessLocatorKind.saf) {
        return safTreeUri != null && locator.locator == safTreeUri;
      }
      return true;
            })
            .toList(growable: false)
      ..sort(compareStorageAccessPreference);
    final candidates = <_ArtifactAccessCandidate>[];
    final seen = <String>{};
    for (final locator in available) {
      final artifactLocator = switch (locator.kind) {
        StorageAccessLocatorKind.direct => _joinDirectArtifactPath(
            locator.locator,
            relativePath,
          ),
        StorageAccessLocatorKind.saf => encodeSafRecordPath(
            treeUri: locator.locator,
            relativePath: relativePath,
          ),
      };
      if (!seen.add(artifactLocator)) continue;
      candidates.add(
        _ArtifactAccessCandidate(
          access: _ArtifactAccessRecord(
            artifactId: base.artifactId,
            replicaId: base.replicaId,
            accessLocator: artifactLocator,
            bytes: base.bytes,
            checksum: base.checksum,
            checksumAlgorithm: base.checksumAlgorithm,
            storageRootId: root.rootId,
          ),
          rootAccess: locator,
        ),
      );
    }
    if (seen.add(base.accessLocator)) {
      candidates.add(
        _ArtifactAccessCandidate(
          access: base,
          rootAccess: _matchingRootAccess(root, base),
        ),
      );
    }
    return candidates.isEmpty
        ? <_ArtifactAccessCandidate>[_ArtifactAccessCandidate(access: base)]
        : candidates;
  }

  StorageRootRecord? _storageRootFromAuthoritySnapshot(
    ArtifactAuthorityReadSnapshot authority,
    String identity, {
    String? fallbackRootId,
  }) {
    final direct = authority.storageRootsByIdentity[identity] ??
        (fallbackRootId == null
            ? null
            : authority.storageRootsByIdentity[fallbackRootId]);
    if (direct != null) return direct;
    for (final root in authority.storageRootsByIdentity.values) {
      if (root.rootId == identity ||
          root.accessLocators.any((locator) => locator.locator == identity)) {
        return root;
      }
    }
    return null;
  }

  StorageAccessLocatorRecord? _matchingRootAccess(
    StorageRootRecord root,
    _ArtifactAccessRecord access,
  ) {
    final parsed = parseSafRecordPath(access.accessLocator);
    final kind = parsed == null
        ? StorageAccessLocatorKind.direct
        : StorageAccessLocatorKind.saf;
    final locator = parsed?.treeUri ?? access.storageRootId;
    for (final candidate in root.accessLocators) {
      if (candidate.kind == kind && candidate.locator == locator) {
        return candidate;
      }
    }
    return null;
  }


  Future<List<({String accessLocator, String storageRootId})>>
      _equivalentStorageRootLocators({
    required String accessLocator,
    required String storageRootId,
  }) async {
    final parsed = parseSafRecordPath(accessLocator);
    final root = await _index.getStorageRoot(parsed?.treeUri ?? storageRootId);
    if (root == null) {
      return <({String accessLocator, String storageRootId})>[
        (accessLocator: accessLocator, storageRootId: storageRootId),
      ];
    }
    final relative = _relativeReplicaLocatorWithinRoot(
      accessLocator: accessLocator,
      storageRootId: root.rootId,
      root: root,
    );
    if (relative == null) {
      return <({String accessLocator, String storageRootId})>[
        (accessLocator: accessLocator, storageRootId: root.rootId),
      ];
    }
    final accesses = root.accessLocators.toList(growable: false)
      ..sort(compareStorageAccessPreference);
    final values = <({String accessLocator, String storageRootId})>[];
    final seen = <String>{};
    for (final rootAccess in accesses) {
      final locator = switch (rootAccess.kind) {
        StorageAccessLocatorKind.direct => _joinDirectArtifactPath(
            rootAccess.locator,
            relative,
          ),
        StorageAccessLocatorKind.saf => encodeSafRecordPath(
            treeUri: rootAccess.locator,
            relativePath: relative,
          ),
      };
      if (!seen.add(locator)) continue;
      values.add((accessLocator: locator, storageRootId: root.rootId));
    }
    if (seen.add(accessLocator)) {
      values.add((accessLocator: accessLocator, storageRootId: root.rootId));
    }
    return values;
  }

  Future<ArtifactReplicaMigrationRecord>
      _rebindCopyingMigrationForCurrentAccess(
    ArtifactReplicaMigrationRecord migration, {
    required String requestedDestinationAccessLocator,
    required String requestedDestinationStorageRootId,
  }) async {
    if (migration.phase != ArtifactReplicaMigrationPhase.copying) {
      return migration;
    }
    final durableRoot =
        await _index.getStorageRoot(migration.destinationStorageRootId);
    final requestedRoot =
        await _index.getStorageRoot(requestedDestinationStorageRootId);
    final root = durableRoot ?? requestedRoot;
    if (root == null) {
      if (migration.destinationAccessLocator ==
              requestedDestinationAccessLocator &&
          migration.destinationStorageRootId ==
              requestedDestinationStorageRootId) {
        return migration;
      }
      throw const Failure(
        code: ErrorCode.policy,
        message:
            'copying migration destination changed without a proven storage-root alias',
      );
    }
    if (requestedRoot != null && requestedRoot.rootId != root.rootId) {
      throw const Failure(
        code: ErrorCode.policy,
        message: 'copying migration destination moved to a different storage root',
      );
    }
    final durableRelative = _relativeReplicaLocatorWithinRoot(
      accessLocator: migration.destinationAccessLocator,
      storageRootId: root.rootId,
      root: root,
    );
    final requestedRelative = _relativeReplicaLocatorWithinRoot(
      accessLocator: requestedDestinationAccessLocator,
      storageRootId: root.rootId,
      root: root,
    );
    if (durableRelative == null ||
        requestedRelative == null ||
        durableRelative != requestedRelative) {
      throw const Failure(
        code: ErrorCode.policy,
        message:
            'copying migration destination changed relative path during remount',
      );
    }

    String? selectedDestination;
    if (requestedDestinationAccessLocator != migration.destinationAccessLocator &&
        await _cleanupLocatorIsAvailable(
          requestedDestinationAccessLocator,
          root.rootId,
        )) {
      selectedDestination = requestedDestinationAccessLocator;
    }
    if (selectedDestination == null) {
      for (final candidate in await _equivalentStorageRootLocators(
        accessLocator: migration.destinationAccessLocator,
        storageRootId: root.rootId,
      )) {
        if (await _cleanupLocatorIsAvailable(
          candidate.accessLocator,
          candidate.storageRootId,
        )) {
          selectedDestination = candidate.accessLocator;
          break;
        }
      }
    }
    if (selectedDestination == null) {
      throw const Failure(
        code: ErrorCode.policy,
        message: 'copying migration destination root is currently unavailable',
      );
    }

    final temporaryRelative = _relativeReplicaLocatorWithinRoot(
      accessLocator: migration.temporaryAccessLocator,
      storageRootId: root.rootId,
      root: root,
    );
    if (temporaryRelative == null) {
      throw const Failure(
        code: ErrorCode.policy,
        message: 'copying migration temporary is outside its storage root',
      );
    }
    late final String reboundTemporary;
    final selectedSaf = parseSafRecordPath(selectedDestination);
    if (selectedSaf != null) {
      reboundTemporary = encodeSafRecordPath(
        treeUri: selectedSaf.treeUri,
        relativePath: temporaryRelative,
      );
    } else {
      String? selectedDirectRoot;
      final directRoots = root.accessLocators
          .where(
            (locator) => locator.kind == StorageAccessLocatorKind.direct,
          )
          .map((locator) => locator.locator)
          .toList(growable: false)
        ..sort((left, right) => right.length.compareTo(left.length));
      for (final directRoot in directRoots) {
        if (_relativeDirectArtifactPath(
              root: directRoot,
              artifactPath: selectedDestination,
            ) ==
            durableRelative) {
          selectedDirectRoot = directRoot;
          break;
        }
      }
      if (selectedDirectRoot == null) {
        throw const Failure(
          code: ErrorCode.policy,
          message: 'copying migration destination Direct alias is unproven',
        );
      }
      reboundTemporary = _joinDirectArtifactPath(
        selectedDirectRoot,
        temporaryRelative,
      );
    }

    if (selectedDestination == migration.destinationAccessLocator &&
        reboundTemporary == migration.temporaryAccessLocator &&
        migration.destinationStorageRootId == root.rootId) {
      return migration;
    }
    return _index.rebindCopyingArtifactReplicaMigration(
      replicaId: migration.replicaId,
      expectedDestinationAccessLocator: migration.destinationAccessLocator,
      expectedTemporaryAccessLocator: migration.temporaryAccessLocator,
      destinationAccessLocator: selectedDestination,
      destinationStorageRootId: root.rootId,
      temporaryAccessLocator: reboundTemporary,
      touchedUs: DateTime.now().toUtc().microsecondsSinceEpoch,
    );
  }

  Future<void> _validateReplicaDestinationRoot(
    String accessLocator,
    String storageRootId,
  ) async {
    final parsed = parseSafRecordPath(accessLocator);
    if (parsed != null) {
      if (storageRootId == parsed.treeUri) return;
      final root = await _index.getStorageRoot(parsed.treeUri);
      if (root?.rootId == storageRootId) return;
      throw const Failure(
        code: ErrorCode.policy,
        message: 'SAF replica destination does not belong to the declared root',
      );
    }

    if (_relativeDirectArtifactPath(
          root: storageRootId,
          artifactPath: accessLocator,
        ) !=
        null) {
      return;
    }
    final root = await _index.getStorageRoot(storageRootId);
    if (root != null) {
      for (final locator in root.accessLocators) {
        if (locator.kind != StorageAccessLocatorKind.direct) continue;
        if (_relativeDirectArtifactPath(
              root: locator.locator,
              artifactPath: accessLocator,
            ) !=
            null) {
          return;
        }
      }
    }
    throw const Failure(
      code: ErrorCode.policy,
      message:
          'direct replica destination does not belong to the declared root',
    );
  }

  Future<void> _ensureReplicaDestinationUnowned({
    required String currentReplicaId,
    required String accessLocator,
    required String storageRootId,
  }) async {
    final exact = await _index.artifactReplicaForAccessLocator(accessLocator);
    if (exact != null && exact.replicaId != currentReplicaId) {
      throw const Failure(
        code: ErrorCode.policy,
        message: 'migration destination is already owned by another replica',
      );
    }

    final root = await _index.getStorageRoot(storageRootId);
    final canonicalRootId = root?.rootId ?? storageRootId;
    final destinationRelative = _relativeReplicaLocatorWithinRoot(
      accessLocator: accessLocator,
      storageRootId: canonicalRootId,
      root: root,
    );
    if (destinationRelative == null) return;
    final replicas = await _index.listArtifactReplicasForStorageRoot(
      canonicalRootId,
    );
    for (final replica in replicas) {
      if (replica.replicaId == currentReplicaId) continue;
      final relative = _relativeReplicaLocatorWithinRoot(
        accessLocator: replica.accessLocator,
        storageRootId: canonicalRootId,
        root: root,
      );
      if (relative == destinationRelative) {
        throw const Failure(
          code: ErrorCode.policy,
          message: 'migration destination is already owned by another replica',
        );
      }
    }
  }

  String? _relativeReplicaLocatorWithinRoot({
    required String accessLocator,
    required String storageRootId,
    required StorageRootRecord? root,
  }) {
    final parsed = parseSafRecordPath(accessLocator);
    if (parsed != null) return parsed.relativePath;
    final directRoots = <String>[
      if (root != null)
        ...root.accessLocators
            .where((locator) => locator.kind == StorageAccessLocatorKind.direct)
            .map((locator) => locator.locator),
      storageRootId,
    ]..sort((left, right) => right.length.compareTo(left.length));
    for (final directRoot in directRoots) {
      final relative = _relativeDirectArtifactPath(
        root: directRoot,
        artifactPath: accessLocator,
      );
      if (relative != null) return relative;
    }
    return null;
  }

  String? _relativeDirectArtifactPath({
    required String root,
    required String artifactPath,
  }) {
    final normalizedRoot = root.trim();
    if (normalizedRoot.isEmpty || normalizedRoot == 'default') return null;
    final separator = Platform.pathSeparator;
    final prefix = normalizedRoot.endsWith(separator)
        ? normalizedRoot
        : '$normalizedRoot$separator';
    if (artifactPath == normalizedRoot) return '';
    if (!artifactPath.startsWith(prefix)) return null;
    return artifactPath
        .substring(prefix.length)
        .split(separator)
        .where((segment) => segment.isNotEmpty)
        .join('/');
  }

  String _joinDirectArtifactPath(String root, String relativePath) {
    final separator = Platform.pathSeparator;
    final normalizedRoot = root.endsWith(separator)
        ? root.substring(0, root.length - separator.length)
        : root;
    final relative = relativePath.split('/').join(separator);
    return '$normalizedRoot$separator$relative';
  }

  Future<void> _recordStorageAccessHealth(
    _ArtifactAccessCandidate candidate,
    StorageAccessHealth health,
  ) async {
    final locator = candidate.rootAccess;
    if (locator == null || locator.health == health) return;
    await _index.updateStorageAccessHealth(
      kind: locator.kind,
      locator: locator.locator,
      health: health,
      touchedUs: DateTime.now().toUtc().microsecondsSinceEpoch,
    );
  }

  Future<({_ArtifactAccessCandidate candidate, int length})>
  _selectReadableArtifactAccess(
    List<_ArtifactAccessCandidate> candidates, {
    bool skipExistsProbe = false,
  }) async {
    ArtifactReadFailure? accessFailure;
    ArtifactReadFailure? structuralFailure;
    for (final candidate in candidates) {
      final access = candidate.access;
      try {
        if (!skipExistsProbe) {
          final exists = await _artifactRecordExists(access);
          if (!exists) {
            structuralFailure = ArtifactReadFailure(
              kind: ArtifactReadFailureKind.missing,
              accessLocator: access.accessLocator,
              replicaId: access.replicaId,
              failedOffset: 0,
              bytesEmitted: 0,
              expectedLength: access.bytes,
              observedLength: 0,
            );
            continue;
          }
        }
        final length = await _artifactPreflightLength(
          access,
          expectedLength: access.bytes,
        );
        if (length <= 0 || length != access.bytes) {
          structuralFailure = ArtifactReadFailure(
            kind: ArtifactReadFailureKind.lengthChanged,
            accessLocator: access.accessLocator,
            replicaId: access.replicaId,
            failedOffset: 0,
            bytesEmitted: 0,
            expectedLength: access.bytes,
            observedLength: length,
          );
          continue;
        }
        await _recordStorageAccessHealth(
          candidate,
          StorageAccessHealth.healthy,
        );
        return (candidate: candidate, length: length);
      } on ArtifactReadFailure catch (error) {
        final enriched = _enrichArtifactReadFailure(access, error);
        if (_isStructuralReplicaFailure(enriched.kind)) {
          structuralFailure = enriched;
        } else {
          accessFailure ??= enriched;
        }
        if (error.kind == ArtifactReadFailureKind.accessDenied) {
          await _recordStorageAccessHealth(
            candidate,
            StorageAccessHealth.accessDenied,
          );
        }
      }
    }
    throw accessFailure ??
        structuralFailure ??
        const ArtifactReadFailure(
          kind: ArtifactReadFailureKind.missing,
          accessLocator: '',
          failedOffset: 0,
          bytesEmitted: 0,
        );
  }

  Future<ArtifactCacheBoundRangeReader?> _openBoundArtifactRangeReader(
    List<_ArtifactAccessCandidate> candidates, {
    int? expectedLength,
  }) async {
    if (candidates.isEmpty) return null;
    ArtifactReadFailure? accessFailure;
    ArtifactReadFailure? structuralFailure;
    for (var index = 0; index < candidates.length; index++) {
      final candidate = candidates[index];
      final access = candidate.access;
      ArtifactByteRangeReader? reader;
      try {
        reader = await openArtifactByteRangeReader(
          _bytes,
          access.accessLocator,
        );
        if (reader == null) continue;
        if (expectedLength != null) {
          var length = await reader.length();
          if ((length <= 0 || length != expectedLength) &&
              parseSafRecordPath(access.accessLocator) != null) {
            // SAF providers can transiently report a stale/zero stat for one
            // just-opened descriptor. A single metadata observation is not
            // enough authority to delete an otherwise sealed replica. Close
            // that exact descriptor and independently reopen once; only a
            // repeated mismatch is structural. The reopened descriptor is the
            // one retained for subsequent decoder ranges when it validates.
            await reader.close();
            reader = await openArtifactByteRangeReader(
              _bytes,
              access.accessLocator,
            );
            if (reader == null) {
              throw ArtifactReadFailure(
                kind: ArtifactReadFailureKind.ioFailure,
                accessLocator: access.accessLocator,
                replicaId: access.replicaId,
                failedOffset: 0,
                bytesEmitted: 0,
              );
            }
            length = await reader.length();
          }
          if (length <= 0 || length != expectedLength) {
            throw ArtifactReadFailure(
              kind: ArtifactReadFailureKind.lengthChanged,
              accessLocator: access.accessLocator,
              replicaId: access.replicaId,
              failedOffset: 0,
              bytesEmitted: 0,
              expectedLength: expectedLength,
              observedLength: length,
            );
          }
        }
        await _recordStorageAccessHealth(
          candidate,
          StorageAccessHealth.healthy,
        );
        final selected = <_ArtifactAccessCandidate>[
          candidate,
          ...candidates.where(
            (other) => other.access.accessLocator != access.accessLocator,
          ),
        ];
        final retained = reader;
        reader = null;
        return _PersistentBoundRangeReader(
          primary: retained,
          fallback: (start, endExclusive) async {
            final builder = BytesBuilder(copy: false);
            await for (final chunk in _readArtifactCandidates(
              selected,
              start: start,
              endExclusive: endExclusive,
            )) {
              builder.add(chunk);
            }
            final bytes = builder.takeBytes();
            if (bytes.lengthInBytes != endExclusive - start) {
              throw ArtifactReadFailure(
                kind: ArtifactReadFailureKind.shortRead,
                accessLocator: access.accessLocator,
                replicaId: access.replicaId,
                failedOffset: start + bytes.lengthInBytes,
                bytesEmitted: bytes.lengthInBytes,
                expectedLength: endExclusive - start,
                observedLength: bytes.lengthInBytes,
              );
            }
            return bytes;
          },
        );
      } on ArtifactReadFailure catch (error) {
        final enriched = _enrichArtifactReadFailure(access, error);
        if (_isStructuralReplicaFailure(enriched.kind)) {
          structuralFailure = enriched;
        } else {
          accessFailure ??= enriched;
        }
        if (error.kind == ArtifactReadFailureKind.accessDenied) {
          await _recordStorageAccessHealth(
            candidate,
            StorageAccessHealth.accessDenied,
          );
        }
      } on Object catch (error) {
        accessFailure ??= ArtifactReadFailure(
          kind: ArtifactReadFailureKind.ioFailure,
          accessLocator: access.accessLocator,
          replicaId: access.replicaId,
          failedOffset: 0,
          bytesEmitted: 0,
          cause: error,
        );
      } finally {
        if (reader != null) {
          try {
            await reader.close();
          } on Object {
            // A failed preflight already owns the classification. Descriptor
            // cleanup cannot replace that failure.
          }
        }
      }
    }
    final failure = accessFailure ?? structuralFailure;
    if (failure != null) throw failure;
    return null;
  }

  Stream<Uint8List> _readArtifactCandidates(
    List<_ArtifactAccessCandidate> candidates, {
    required int start,
    int? endExclusive,
  }) async* {
    var emitted = 0;
    ArtifactReadFailure? accessFailure;
    ArtifactReadFailure? structuralFailure;
    for (final candidate in candidates) {
      if (endExclusive != null && start + emitted >= endExclusive) return;
      final access = candidate.access;
      try {
        await for (final chunk in _bytes.readChunks(
          access.accessLocator,
          start: start + emitted,
          endExclusive: endExclusive,
        )) {
          emitted += chunk.length;
          yield chunk;
        }
        await _recordStorageAccessHealth(
          candidate,
          StorageAccessHealth.healthy,
        );
        return;
      } on ArtifactReadFailure catch (error) {
        if (error.kind == ArtifactReadFailureKind.accessDenied) {
          await _recordStorageAccessHealth(
            candidate,
            StorageAccessHealth.accessDenied,
          );
        }
        final failure = ArtifactReadFailure(
          kind: error.kind,
          accessLocator: error.accessLocator,
          replicaId: error.replicaId ?? access.replicaId,
          failedOffset: start + emitted,
          bytesEmitted: emitted,
          expectedLength: error.expectedLength,
          observedLength: error.observedLength,
          cause: error.cause,
        );
        if (_isStructuralReplicaFailure(failure.kind)) {
          structuralFailure = failure;
        } else {
          accessFailure ??= failure;
        }
      } on Object catch (error) {
        accessFailure ??= ArtifactReadFailure(
          kind: ArtifactReadFailureKind.ioFailure,
          accessLocator: access.accessLocator,
          replicaId: access.replicaId,
          failedOffset: start + emitted,
          bytesEmitted: emitted,
          cause: error,
        );
      }
    }
    final failure = accessFailure ?? structuralFailure;
    if (failure != null) {
      if (accessFailure == null && _isStructuralReplicaFailure(failure.kind)) {
        await _retireArtifactReplica(
          candidates.first.access.artifactId,
          failure.replicaId,
          failure.accessLocator,
        );
      }
      throw failure;
    }
  }

  bool _isStructuralReplicaFailure(ArtifactReadFailureKind kind) =>
      kind == ArtifactReadFailureKind.missing ||
      kind == ArtifactReadFailureKind.staleLocator ||
      kind == ArtifactReadFailureKind.shortRead ||
      kind == ArtifactReadFailureKind.lengthChanged ||
      kind == ArtifactReadFailureKind.checksumMismatch;

  Future<void> _retireArtifactReplica(
    String artifactId,
    String? replicaId,
    String accessLocator,
  ) async {
    if (replicaId == null || replicaId.isEmpty) return;
    await _serializeArtifactReplicaMutation(artifactId, () async {
      final migration = await _index.getArtifactReplicaMigration(replicaId);
      final migrationTempDebt = migration == null
          ? null
          : await _registerMigrationTemporaryCleanupDebt(migration);
      await _index.removeArtifactReplica(replicaId);
      final authorityRetired =
          await _index.removeArtifactAuthorityIfNoReplicas(artifactId);
      if (authorityRetired) {
        _notifyManagementProjectionChanged();
      }
      if (migrationTempDebt != null) {
        // The replica delete cascades the schema-9 migration row. Do not take
        // StorageWriteScheduler capacity from this structural read-failure
        // stack: a migration iterator may already hold that quantum. Schema-16
        // owns only the generated temp cleanup and drains it asynchronously.
        _scheduleCleanupDebtDrain();
      }
      try {
        await _bytes.delete(accessLocator);
        await _deleteArtifactSidecar(accessLocator);
      } on Object {
        // A structurally failed replica no longer carries the sealed proof
        // required for delayed obsolete-source cleanup. Keep retirement
        // authoritative rather than risking deletion of later path contents.
      }
    });
  }

  ArtifactReadFailure _enrichArtifactReadFailure(
    _ArtifactAccessRecord access,
    ArtifactReadFailure failure,
  ) => failure.replicaId == null
          ? failure.withReplicaId(access.replicaId)
          : failure;

  Future<bool> _artifactRecordExists(_ArtifactAccessRecord access) async {
    try {
      return await _bytes.exists(access.accessLocator);
    } on ArtifactReadFailure catch (error) {
      throw _enrichArtifactReadFailure(access, error);
    } on Object catch (error) {
      throw ArtifactReadFailure(
        kind: ArtifactReadFailureKind.ioFailure,
        accessLocator: access.accessLocator,
        replicaId: access.replicaId,
        failedOffset: 0,
        bytesEmitted: 0,
        cause: error,
      );
    }
  }

  Future<int> _artifactPreflightLength(
    _ArtifactAccessRecord access, {
    required int expectedLength,
  }) async {
    final first = await _artifactRecordLength(access);
    if (parseSafRecordPath(access.accessLocator) == null ||
        first == expectedLength) {
      return first;
    }
    // SAF metadata is provider-observed rather than POSIX inode authority.
    // Reopen/re-stat once before classifying a length mismatch as structural;
    // an access/I/O failure on this independent confirmation remains
    // recoverable and therefore must not be converted into replica retirement.
    return _artifactRecordLength(access);
  }

  Future<int> _artifactRecordLength(_ArtifactAccessRecord access) async {
    try {
      return await _bytes.length(access.accessLocator);
    } on ArtifactReadFailure catch (error) {
      throw _enrichArtifactReadFailure(access, error);
    } on Object catch (error) {
      throw ArtifactReadFailure(
        kind: ArtifactReadFailureKind.ioFailure,
        accessLocator: access.accessLocator,
        replicaId: access.replicaId,
        failedOffset: 0,
        bytesEmitted: 0,
        cause: error,
      );
    }
  }

  Future<ArtifactCacheStreamEntry?> _openArtifactStreamExact(
    DownloadId id, {
    bool skipExistsProbe = false,
  }) async {
    final record = await _index.get(id.key);
    if (record == null || !_isVerifiedReadyRecord(record) || record.id != id) {
      return null;
    }
    final authority = _index.readArtifactAuthoritySnapshot(
      record.effectiveArtifactId,
    );
    final replicas = await _resolveArtifactReplicas(record,
      authority: authority,
    );
    if (replicas.isEmpty) {
      await _forgetIndexedBinding(id, record: record);
      return null;
    }
    if (record.bytes <= 0) {
      await _forgetIndexedBinding(id, record: record);
      return null;
    }

    ArtifactReadFailure? lastFailure;
    for (final replica in replicas) {
      if (!await _artifactReplicaIsAccessible(replica,
        authority: authority,
      )) {
        continue;
      }
      final candidates = await _artifactAccessCandidates(replica,
        authority: authority,
      );
      late final ({_ArtifactAccessCandidate candidate, int length}) selected;
      try {
        selected = await _selectReadableArtifactAccess(
          candidates,
          skipExistsProbe: skipExistsProbe,
        );
      } on ArtifactReadFailure catch (error) {
        lastFailure = error;
        if (_isStructuralReplicaFailure(error.kind)) {
          await _retireArtifactReplica(
            replica.artifactId,
            replica.replicaId,
            replica.accessLocator,
          );
        }
        continue;
      }
      final selectedAccess = selected.candidate.access;
      if (selectedAccess.checksumAlgorithm.toLowerCase() != 'crc32') {
        await _retireArtifactReplica(
          selectedAccess.artifactId,
          selectedAccess.replicaId,
          selectedAccess.accessLocator,
        );
        continue;
      }
      final selectedCandidates = <_ArtifactAccessCandidate>[
        selected.candidate,
        ...candidates.where(
          (candidate) =>
              candidate.access.accessLocator != selectedAccess.accessLocator,
        ),
      ];
      _scheduleExactArtifactTouch(id, record.effectiveArtifactId);
      return ArtifactCacheStreamEntry(
        length: selected.length,
        open: ({required int start, int? endExclusive}) =>
            _readArtifactCandidates(
          selectedCandidates,
          start: start,
          endExclusive: endExclusive,
        ),
        readAll: () => _readArtifactAllVerifiedForArtifact(
          artifactId: selectedAccess.artifactId,
          preferredCandidates: selectedCandidates,
          length: selected.length,
          expectedChecksum: selectedAccess.checksum.trim().toLowerCase(),
          checksumAlgorithm:
              selectedAccess.checksumAlgorithm.trim().toLowerCase(),
        ),
        readAllControlled: ({required control}) =>
            _readArtifactAllVerifiedForArtifact(
              artifactId: selectedAccess.artifactId,
              preferredCandidates: selectedCandidates,
              length: selected.length,
              expectedChecksum: selectedAccess.checksum.trim().toLowerCase(),
              checksumAlgorithm:
                  selectedAccess.checksumAlgorithm.trim().toLowerCase(),
              control: control,
            ),
        openBoundRangeReader: () => _openBoundArtifactRangeReader(
          selectedCandidates,
          expectedLength: selected.length,
        ),
        openPresentationFile: presentationFileLeaseFactory == null
            ? null
            : () => presentationFileLeaseFactory!.open(
                  selectedAccess.accessLocator,
                  expectedLength: selected.length,
                ),
        accessMode: parseSafRecordPath(selectedAccess.accessLocator) == null
            ? 'direct'
            : 'saf',
        sealedChecksum: selectedAccess.checksum.trim().toLowerCase(),
        sealedChecksumAlgorithm:
            selectedAccess.checksumAlgorithm.trim().toLowerCase(),
        streamIntegrity: ArtifactReadIntegrityBasis.sealedMetadataLength,
        fullReadIntegrity: ArtifactReadIntegrityBasis.crc32Verified,
      );
    }

    if ((await _index.listArtifactReplicas(
      record.effectiveArtifactId,
    )).isEmpty) {
      await _forgetIndexedBinding(id, record: record);
    }
    if (lastFailure != null) throw lastFailure;
    return null;
  }

  Future<Uint8List> _readArtifactAllVerifiedForArtifact({
    required String artifactId,
    required List<_ArtifactAccessCandidate> preferredCandidates,
    required int length,
    required String expectedChecksum,
    required String checksumAlgorithm,
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    final replicas = await _index.listArtifactReplicas(artifactId);
    final currentReplicaIds = <String>{
      for (final replica in replicas) replica.replicaId,
    };
    final candidates = <_ArtifactAccessCandidate>[];
    final seen = <String>{};

    void addCandidate(_ArtifactAccessCandidate candidate) {
      if (!currentReplicaIds.contains(candidate.access.replicaId)) return;
      final key =
          '${candidate.access.replicaId}\u0000${candidate.access.accessLocator}';
      if (seen.add(key)) candidates.add(candidate);
    }

    for (final candidate in preferredCandidates) {
      addCandidate(candidate);
    }
    for (final replica in replicas) {
      control?.throwIfCancelled();
      if (replica.accessLocator.isEmpty) continue;
      final access = _ArtifactAccessRecord(
        artifactId: artifactId,
        replicaId: replica.replicaId,
        accessLocator: replica.accessLocator,
        bytes: length,
        checksum: expectedChecksum,
        checksumAlgorithm: checksumAlgorithm,
        storageRootId: replica.storageRootId,
      );
      if (!await _artifactReplicaIsAccessible(access)) continue;
      for (final candidate in await _artifactAccessCandidates(access)) {
        addCandidate(candidate);
      }
    }
    return _readArtifactAllVerified(
      candidates,
      length,
      expectedChecksum,
      control: control,
    );
  }

  Future<Uint8List> _readArtifactAllVerified(
    List<_ArtifactAccessCandidate> candidates,
    int length,
    String expectedChecksum, {
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    final byReplica = <String, List<_ArtifactAccessCandidate>>{};
    for (final candidate in candidates) {
      byReplica
          .putIfAbsent(
            candidate.access.replicaId,
            () => <_ArtifactAccessCandidate>[],
          )
          .add(candidate);
    }
    ArtifactReadFailure? accessFailure;
    ArtifactReadFailure? structuralFailure;
    for (final replicaCandidates in byReplica.values) {
      ArtifactReadFailure? replicaStructuralFailure;
      var replicaHasRecoverableFailure = false;
      for (final candidate in replicaCandidates) {
        try {
          return await _readArtifactCandidateFullyVerified(
            candidate,
            length,
            expectedChecksum,
            control: control,
          );
        } on ArtifactReadFailure catch (error) {
          if (error.kind == ArtifactReadFailureKind.accessDenied) {
            await _recordStorageAccessHealth(
              candidate,
              StorageAccessHealth.accessDenied,
            );
          }
          if (_isStructuralReplicaFailure(error.kind)) {
            replicaStructuralFailure = error;
            structuralFailure ??= error;
          } else {
            replicaHasRecoverableFailure = true;
            accessFailure ??= error;
          }
        } on Object catch (error) {
          control?.throwIfCancelled();
          replicaHasRecoverableFailure = true;
          accessFailure ??= ArtifactReadFailure(
            kind: ArtifactReadFailureKind.ioFailure,
            accessLocator: candidate.access.accessLocator,
            replicaId: candidate.access.replicaId,
            failedOffset: 0,
            bytesEmitted: 0,
            cause: error,
          );
        }
      }
      if (!replicaHasRecoverableFailure &&
          replicaStructuralFailure != null &&
          replicaCandidates.isNotEmpty) {
        final failed = replicaCandidates.first.access;
        await _retireArtifactReplica(
          failed.artifactId,
          failed.replicaId,
          failed.accessLocator,
        );
      }
    }
    throw accessFailure ??
        structuralFailure ??
        const ArtifactReadFailure(
          kind: ArtifactReadFailureKind.missing,
          accessLocator: '',
          failedOffset: 0,
          bytesEmitted: 0,
        );
  }

  Future<Uint8List> _readArtifactCandidateFullyVerified(
    _ArtifactAccessCandidate candidate,
    int length,
    String expectedChecksum, {
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    final access = candidate.access;
    final observedLength = await _artifactPreflightLength(
      access,
      expectedLength: length,
    );
    if (observedLength != length) {
      throw ArtifactReadFailure(
        kind: ArtifactReadFailureKind.lengthChanged,
        accessLocator: access.accessLocator,
        replicaId: access.replicaId,
        failedOffset: 0,
        bytesEmitted: 0,
        expectedLength: length,
        observedLength: observedLength,
      );
    }
    final iterator = StreamIterator<List<int>>(
      _bytes.readChunks(
        access.accessLocator,
        start: 0,
        endExclusive: length,
      ),
    );
    final builder = BytesBuilder(copy: false);
    final crc = Crc32();
    var consumed = 0;
    Object? primaryError;
    StackTrace? primaryStack;
    try {
      while (control == null
          ? await iterator.moveNext()
          : await _moveNextArtifactChunk(iterator, control)) {
        control?.throwIfCancelled();
        final chunk = iterator.current;
        builder.add(chunk);
        crc.add(chunk);
        consumed += chunk.length;
      }
    } catch (error, stackTrace) {
      primaryError = error;
      primaryStack = stackTrace;
    }
    try {
      await iterator.cancel();
    } catch (error, stackTrace) {
      if (primaryError == null) {
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
    if (primaryError != null) {
      if (primaryError is ArtifactReadFailure) {
        throw _enrichArtifactReadFailure(access, primaryError);
      }
      Error.throwWithStackTrace(primaryError, primaryStack!);
    }
    final bytes = builder.takeBytes();
    if (consumed != length || bytes.lengthInBytes != length) {
      throw ArtifactReadFailure(
        kind: ArtifactReadFailureKind.shortRead,
        accessLocator: access.accessLocator,
        replicaId: access.replicaId,
        failedOffset: consumed,
        bytesEmitted: consumed,
        expectedLength: length,
        observedLength: consumed,
      );
    }
    if (crc.hex != expectedChecksum) {
      throw ArtifactReadFailure(
        kind: ArtifactReadFailureKind.checksumMismatch,
        accessLocator: access.accessLocator,
        replicaId: access.replicaId,
        failedOffset: length,
        bytesEmitted: length,
        expectedLength: length,
        observedLength: length,
      );
    }
    await _recordStorageAccessHealth(candidate, StorageAccessHealth.healthy);
    return bytes;
  }

  Future<bool> _moveNextArtifactChunk(
    StreamIterator<List<int>> iterator,
    TaskControl control,
  ) async {
    control.throwIfCancelled();
    try {
      return await Future.any<bool>(<Future<bool>>[
        iterator.moveNext(),
        control.whenCancelled.then<bool>((_) {
          throw const Failure(
            code: ErrorCode.cancelled,
            message: 'artifact cache read was cancelled',
          );
        }),
      ]);
    } catch (error, stackTrace) {
      if (control.cancelled) control.throwIfCancelled();
      throw Error.throwWithStackTrace(error, stackTrace);
    }
  }

  bool _recordBelongsToCurrentRoot(DownloadId id, CacheRec record) {
    if (record.state == CacheState.partial &&
        parseSafRecordPath(record.path) == null &&
        record.storageRootId == layout.root) {
      final staging = layout.artifactForPhysical(PhysicalMediaId.exact(id));
      if (File(record.path).absolute.path ==
          File(staging.partialPath).absolute.path) {
        // Automatic exact-fallback checkpoints deliberately use the
        // App-private base layout even when this source has a separate final
        // placement root. The indexed deterministic path is the staging proof;
        // explicit download placement remains a later promoted-artifact step.
        return true;
      }
    }
    return _artifactAccessBelongsToCurrentRoot(
      id,
      _ArtifactAccessRecord.fromBinding(record),
    );
  }

  bool _artifactAccessBelongsToCurrentRoot(
    DownloadId id,
    _ArtifactAccessRecord access,
  ) {
    final parsed = parseSafRecordPath(access.accessLocator);
    if (parsed != null) {
      return safTreeUri != null && parsed.treeUri == safTreeUri;
    }
    if (access.storageRootId == 'default' || access.storageRootId.isEmpty) {
      return true;
    }
    final root = layoutFor(id).root;
    return access.storageRootId == root &&
        (access.accessLocator == root ||
            access.accessLocator.startsWith('$root/'));
  }

  @override
  Future<PartialDownloadMetadata?> inspectPartialDownloadMetadata(
    DownloadId id,
  ) async {
    _requireOpen();
    if (_artifactWrites.containsKey(id) || _borrowedPartialIds.contains(id)) {
      return null;
    }
    final active = _registry.find(id);
    if (active != null && (active.activeRun || active.hasWriter)) return null;
    final record = await _index.get(id.key);
    if (record == null || record.id != id || record.bytes <= 0) return null;
    if (_isVerifiedReadyRecord(record)) {
      return PartialDownloadMetadata(
        length: record.bytes,
        exactDurableFinal: true,
      );
    }
    if (record.state != CacheState.partial ||
        !_recordBelongsToCurrentRoot(id, record)) {
      return null;
    }
    final parsed = parseSafRecordPath(record.path);
    if (parsed != null &&
        (safTreeUri == null || parsed.treeUri != safTreeUri)) {
      return null;
    }
    return PartialDownloadMetadata(
      length: record.bytes,
      exactDurableFinal: false,
    );
  }

  @override
  Future<PartialDownloadEntry?> openPhysicalPartialDownload({
    required PhysicalMediaId physicalId,
    required DownloadId requestId,
  }) => _serializePhysicalPartialMutation(
    physicalId,
    () => _openPhysicalPartialDownload(
      physicalId: physicalId,
      requestId: requestId,
    ),
  );

  Future<PartialDownloadEntry?> _openPhysicalPartialDownload({
    required PhysicalMediaId physicalId,
    required DownloadId requestId,
  }) async {
    _requireOpen();
    if (_borrowedPhysicalPartialIds.contains(physicalId)) return null;
    final record = await _index.getPhysicalPartial(physicalId);
    if (record == null || record.bytes <= 0) return null;
    final ready = await _index.getPhysicalMediaArtifact(physicalId);
    if (ready != null) {
      _scheduleRedundantPhysicalPartialRetirement(
        physicalId,
        expectedArtifactId: ready.artifactId,
      );
      return null;
    }

    final parsed = parseSafRecordPath(record.path);
    if (parsed != null) {
      if (safTreeUri == null || parsed.treeUri != safTreeUri) return null;
      final directAlias = await _physicalPartialDirectAlias(
        record: record,
        relativePath: parsed.relativePath,
        safTreeUri: parsed.treeUri,
      );
      if (directAlias != null) {
        final resume = await _readPhysicalPartialResumeState(
          directAlias.artifact.partialPath,
          physicalId,
          requestId,
        );
        if (resume.explicitDifferentOwner) {
          await _index.removePhysicalPartial(physicalId);
          return null;
        }
        final touchedUs = DateTime.now().toUtc().microsecondsSinceEpoch;
        final touched = record.copyWith(touchedUs: touchedUs);
        await _index.touchPhysicalPartial(physicalId, touchedUs);
        return PartialDownloadEntry(
          length: record.bytes,
          validators: resume.validators,
          totalLength: resume.totalLength,
          // SAF remains the correctness fallback until POSIX adoption commits.
          // The proven Direct path is only an alternate access capability for
          // this same storage root; it never creates a second physical body.
          open: ({required int start}) => _bytes.readChunks(
            record.path,
            start: start,
            endExclusive: record.bytes,
          ),
          accessMode: 'saf',
          adoptInto: (session, {TaskControl? control}) =>
              _adoptPhysicalSafDirectAlias(
                session,
                expected: touched,
                directRoot: directAlias.directRoot,
                directAccess: directAlias.access,
                control: control,
              ),
        );
      }
      final length = await _bytes.length(record.path);
      if (length < record.bytes) {
        await _removePhysicalPartialRecord(record, deleteBody: true);
        return null;
      }
      final resume = await _readSafPhysicalPartialResumeState(
        record.path,
        physicalId,
        requestId,
      );
      if (resume.explicitDifferentOwner) {
        await _index.removePhysicalPartial(physicalId);
        return null;
      }
      final touchedUs = DateTime.now().toUtc().microsecondsSinceEpoch;
      final touched = record.copyWith(touchedUs: touchedUs);
      await _index.touchPhysicalPartial(physicalId, touchedUs);
      return PartialDownloadEntry(
        length: record.bytes,
        validators: resume.validators,
        totalLength: resume.totalLength,
        open: ({required int start}) => _bytes.readChunks(
          record.path,
          start: start,
          endExclusive: record.bytes,
        ),
        accessMode: 'saf',
        adoptInto: (session, {TaskControl? control}) =>
            _migrateSafPhysicalPartialAndAdopt(
          session,
          expected: touched,
          requestId: requestId,
          control: control,
        ),
      );
    }

    final root = record.storageRootId.trim();
    if (root.isEmpty || root == 'default') return null;
    final expectedArtifact = CacheLayout(root).artifactForPhysical(physicalId);
    if (File(expectedArtifact.partialPath).absolute.path !=
        File(record.path).absolute.path) {
      // A physical partial row may not redirect a stable media id to an
      // arbitrary direct path. Preserve the bytes for diagnostics, but stop
      // advertising this row as canonical authority.
      await _index.removePhysicalPartial(physicalId);
      return null;
    }
    final file = File(record.path);
    if (!await file.exists()) {
      await _removePhysicalPartialRecord(record, deleteBody: true);
      return null;
    }
    final physicalLength = await file.length();
    if (physicalLength < record.bytes) {
      await _removePhysicalPartialRecord(record, deleteBody: true);
      return null;
    }
    final resume = await _readPhysicalPartialResumeState(
      record.path,
      physicalId,
      requestId,
    );
    if (resume.explicitDifferentOwner) {
      await _index.removePhysicalPartial(physicalId);
      return null;
    }
    final touchedUs = DateTime.now().toUtc().microsecondsSinceEpoch;
    final touched = record.copyWith(touchedUs: touchedUs);
    await _index.putPhysicalPartial(touched);
    final transferStaging = safTreeUri != null && root == layout.root;
    return PartialDownloadEntry(
      length: record.bytes,
      validators: resume.validators,
      totalLength: resume.totalLength,
      open: ({required int start}) =>
          _readIndexedChunks(record.path, length: record.bytes, start: start),
      accessMode: 'direct',
      adoptInto: (session, {TaskControl? control}) =>
          _adoptPhysicalPosixPartial(
            session,
            expected: touched,
            transferStaging: transferStaging,
            control: control,
          ),
    );
  }

  Future<({
    String directRoot,
    Artifact artifact,
    StorageAccessLocatorRecord access,
  })?> _physicalPartialDirectAlias({
    required PhysicalPartialRecord record,
    required String relativePath,
    required String safTreeUri,
  }) async {
    final root = await _index.getStorageRoot(safTreeUri);
    if (root == null) return null;
    final directAccesses = root.accessLocators
        .where(
          (access) =>
              access.kind == StorageAccessLocatorKind.direct &&
              access.health != StorageAccessHealth.accessDenied,
        )
        .toList(growable: false)
      ..sort(compareStorageAccessPreference);
    for (final access in directAccesses) {
      final directRoot = access.locator.trim();
      if (directRoot.isEmpty) continue;
      final artifact = CacheLayout(directRoot).artifactForPhysical(record.id);
      final aliasedPath = _joinDirectArtifactPath(directRoot, relativePath);
      if (File(artifact.partialPath).absolute.path !=
          File(aliasedPath).absolute.path) {
        continue;
      }
      try {
        final stat = await File(aliasedPath).stat();
        if (stat.type != FileSystemEntityType.file || stat.size < record.bytes) {
          continue;
        }
        if (access.health != StorageAccessHealth.healthy) {
          await _index.updateStorageAccessHealth(
            kind: access.kind,
            locator: access.locator,
            health: StorageAccessHealth.healthy,
            touchedUs: DateTime.now().toUtc().microsecondsSinceEpoch,
          );
        }
        return (directRoot: directRoot, artifact: artifact, access: access);
      } on FileSystemException catch (error) {
        final code = error.osError?.errorCode;
        if (code == 1 || code == 5 || code == 13) {
          await _index.updateStorageAccessHealth(
            kind: access.kind,
            locator: access.locator,
            health: StorageAccessHealth.accessDenied,
            touchedUs: DateTime.now().toUtc().microsecondsSinceEpoch,
          );
        }
      }
    }
    return null;
  }

  Future<bool> _adoptPhysicalSafDirectAlias(
    DownloadSession target, {
    required PhysicalPartialRecord expected,
    required String directRoot,
    required StorageAccessLocatorRecord directAccess,
    TaskControl? control,
  }) => _serializePhysicalPartialMutation(expected.id, () async {
    _requireOpen();
    control?.throwIfCancelled();
    final physicalId = expected.id;
    if (target.physicalId != physicalId ||
        _borrowedPhysicalPartialIds.contains(physicalId)) {
      return false;
    }
    final current = await _index.getPhysicalPartial(physicalId);
    if (current == null ||
        !_samePhysicalPartialRecord(expected, current) ||
        parseSafRecordPath(current.path) == null) {
      return false;
    }
    final root = await _index.getStorageRoot(current.storageRootId);
    final directStillProven = root?.accessLocators.any(
          (access) =>
              access.kind == StorageAccessLocatorKind.direct &&
              access.locator == directRoot &&
              access.health != StorageAccessHealth.accessDenied,
        ) ==
        true;
    if (!directStillProven) return false;

    final artifact = CacheLayout(directRoot).artifactForPhysical(physicalId);
    _borrowedPhysicalPartialIds.add(physicalId);
    try {
      final resume = await _readPhysicalPartialResumeState(
        artifact.partialPath,
        physicalId,
        target.id,
      );
      if (resume.explicitDifferentOwner) {
        _borrowedPhysicalPartialIds.remove(physicalId);
        return false;
      }
      await target.adoptDurablePartialBacking(
        artifact: artifact,
        index: _index,
        cacheMutationOwner: this,
        storageRootId: directRoot,
        expectedLength: current.bytes,
        validators: resume.validators,
        totalLength: resume.totalLength,
        releaseBacking: () {
          _borrowedPhysicalPartialIds.remove(physicalId);
        },
        control: control,
      );
      if (directAccess.health != StorageAccessHealth.healthy) {
        await _index.updateStorageAccessHealth(
          kind: directAccess.kind,
          locator: directAccess.locator,
          health: StorageAccessHealth.healthy,
          touchedUs: DateTime.now().toUtc().microsecondsSinceEpoch,
        );
      }
      return true;
    } on FileSystemException catch (error) {
      if (!target.hasBorrowedDurableSpool) {
        _borrowedPhysicalPartialIds.remove(physicalId);
      }
      final code = error.osError?.errorCode;
      if (!target.hasBorrowedDurableSpool &&
          (code == 1 || code == 5 || code == 13)) {
        await _index.updateStorageAccessHealth(
          kind: directAccess.kind,
          locator: directAccess.locator,
          health: StorageAccessHealth.accessDenied,
          touchedUs: DateTime.now().toUtc().microsecondsSinceEpoch,
        );
        return false;
      }
      rethrow;
    } catch (_) {
      if (!target.hasBorrowedDurableSpool) {
        // Direct access is only an optimization for a SAF-owned physical
        // partial. Until the session commits the borrowed backing, the SAF
        // entry remains the complete authority and can safely service the
        // existing stream-copy fallback.
        _borrowedPhysicalPartialIds.remove(physicalId);
        return false;
      }
      rethrow;
    }
  });

  Future<bool> _adoptPhysicalPosixPartial(
    DownloadSession target, {
    required PhysicalPartialRecord expected,
    required bool transferStaging,
    TaskControl? control,
  }) => _serializePhysicalPartialMutation(
    expected.id,
    () => _adoptPhysicalPosixPartialUnserialized(
      target,
      expected: expected,
      transferStaging: transferStaging,
      control: control,
    ),
  );

  Future<bool> _migrateSafPhysicalPartialAndAdopt(
    DownloadSession target, {
    required PhysicalPartialRecord expected,
    required DownloadId requestId,
    TaskControl? control,
  }) => _serializePhysicalPartialMutation(expected.id, () async {
    _requireOpen();
    control?.throwIfCancelled();
    final physicalId = expected.id;
    if (target.physicalId != physicalId ||
        _borrowedPhysicalPartialIds.contains(physicalId)) {
      return false;
    }
    final current = await _index.getPhysicalPartial(physicalId);
    if (current == null ||
        !_samePhysicalPartialRecord(expected, current) ||
        parseSafRecordPath(current.path) == null) {
      return false;
    }
    final resume = await _readSafPhysicalPartialResumeState(
      current.path,
      physicalId,
      requestId,
    );
    if (resume.explicitDifferentOwner) {
      await _index.removePhysicalPartial(physicalId);
      return false;
    }
    control?.throwIfCancelled();

    // A SAF partial is already the durable physical authority. Move that same
    // authority to App-private mutable staging before giving it to the hot
    // DownloadSession. Do not stream the body through DownloadSession itself:
    // that would publish receiving-from-zero state for local bytes and can
    // repeat the whole prefix when local preparation is cancelled/revisited.
    final source = PartialDownloadEntry(
      length: current.bytes,
      validators: resume.validators,
      totalLength: resume.totalLength,
      accessMode: 'saf',
      open: ({required int start}) => _bytes.readChunks(
        current.path,
        start: start,
        endExclusive: current.bytes,
      ),
    );
    await _storePhysicalPartialDownload(
      physicalId: physicalId,
      providerHint: requestId,
      entry: source,
      preferDirectStaging: true,
      entryReplaysExistingAuthority: true,
      control: control,
    );
    control?.throwIfCancelled();

    final migrated = await _index.getPhysicalPartial(physicalId);
    if (migrated == null ||
        migrated.bytes < current.bytes ||
        parseSafRecordPath(migrated.path) != null ||
        migrated.storageRootId != layout.root) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'SAF physical partial migration did not publish direct staging',
      );
    }
    final adopted = await _adoptPhysicalPosixPartialUnserialized(
      target,
      expected: migrated,
      transferStaging: true,
      control: control,
    );
    if (!adopted) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'migrated physical partial could not be adopted by its session',
      );
    }
    return true;
  });

  Future<bool> _adoptPhysicalPosixPartialUnserialized(
    DownloadSession target, {
    required PhysicalPartialRecord expected,
    required bool transferStaging,
    TaskControl? control,
  }) async {
    _requireOpen();
    control?.throwIfCancelled();
    final physicalId = expected.id;
    if (target.physicalId != physicalId ||
        _borrowedPhysicalPartialIds.contains(physicalId)) {
      return false;
    }
    final current = await _index.getPhysicalPartial(physicalId);
    if (current == null ||
        !_samePhysicalPartialRecord(expected, current) ||
        parseSafRecordPath(current.path) != null) {
      return false;
    }
    final root = current.storageRootId.trim();
    if (root.isEmpty || root == 'default') return false;
    final adoptedArtifact = CacheLayout(root).artifactForPhysical(physicalId);
    if (File(adoptedArtifact.partialPath).absolute.path !=
        File(current.path).absolute.path) {
      return false;
    }
    final file = File(current.path);
    if (!await file.exists() || await file.length() < current.bytes) {
      return false;
    }
    final resume = await _readPhysicalPartialResumeState(
      current.path,
      physicalId,
      target.id,
    );
    if (resume.explicitDifferentOwner) return false;

    _borrowedPhysicalPartialIds.add(physicalId);
    try {
      await target.adoptDurablePartialBacking(
        artifact: adoptedArtifact,
        index: _index,
        cacheMutationOwner: this,
        storageRootId: current.storageRootId,
        expectedLength: current.bytes,
        validators: resume.validators,
        totalLength: resume.totalLength,
        releaseBacking: () {
          _borrowedPhysicalPartialIds.remove(physicalId);
        },
        transferStaging: transferStaging,
        control: control,
      );
      return true;
    } catch (_) {
      if (!target.hasBorrowedPartialBacking) {
        _borrowedPhysicalPartialIds.remove(physicalId);
      }
      rethrow;
    }
  }

  @override
  Future<void> storePhysicalPartialDownload({
    required PhysicalMediaId physicalId,
    required DownloadId providerHint,
    required PartialDownloadEntry entry,
    bool preferDirectStaging = false,
  }) => _notifyManagementAfter(
    _serializePhysicalPartialMutation(
      physicalId,
      () => _storePhysicalPartialDownload(
        physicalId: physicalId,
        providerHint: providerHint,
        entry: entry,
        preferDirectStaging: preferDirectStaging,
      ),
    ),
  );

  Future<void> _storePhysicalPartialDownload({
    required PhysicalMediaId physicalId,
    required DownloadId providerHint,
    required PartialDownloadEntry entry,
    required bool preferDirectStaging,
    bool entryReplaysExistingAuthority = false,
    TaskControl? control,
  }) async {
    _requireOpen();
    control?.throwIfCancelled();
    if (_borrowedPhysicalPartialIds.contains(physicalId)) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'physical durable partial is borrowed by the transfer owner',
      );
    }
    if (entry.length <= 0) return;
    if (await _index.getPhysicalMediaArtifact(physicalId) != null) return;
    final existing = await _index.getPhysicalPartial(physicalId);
    if (existing != null && existing.bytes > entry.length) return;
    final existingIsPreferredStaging = existing != null &&
        parseSafRecordPath(existing.path) == null &&
        existing.storageRootId == layout.root;
    if (existing != null &&
        existing.bytes == entry.length &&
        (!preferDirectStaging || existingIsPreferredStaging)) {
      return;
    }

    if (preferDirectStaging) {
      // Transfer checkpoints are mutable recovery state, not user-selected
      // final placement. Keep them on the store's App-private direct layout so
      // a later physical session can adopt the same spool without replaying a
      // multi-megabyte SAF body. Legacy SAF/external partials are migrated only
      // when this checkpoint has at least the same authoritative prefix.
      if (existingIsPreferredStaging) {
        await _storePhysicalPartialDirect(
          physicalId: physicalId,
          providerHint: providerHint,
          entry: entry,
          existing: existing,
          targetLayoutOverride: layout,
          control: control,
        );
      } else {
        final obsoleteChecksum =
            existing == null || entryReplaysExistingAuthority
                ? null
                : await _migrationRangeChecksum(
                    _bytes.readChunks(
                      existing.path,
                      start: 0,
                      endExclusive: existing.bytes,
                    ),
                    expectedBytes: existing.bytes,
                    control: control,
                  );
        control?.throwIfCancelled();
        await _storePhysicalPartialDirect(
          physicalId: physicalId,
          providerHint: providerHint,
          entry: entry,
          targetLayoutOverride: layout,
          createdUsOverride: existing?.createdUs,
          obsoleteSource: existing,
          obsoleteSourceChecksum: obsoleteChecksum,
          deriveObsoleteSourceChecksumFromCopy:
              existing != null && entryReplaysExistingAuthority,
          control: control,
        );
      }
      return;
    }

    if (existing != null && parseSafRecordPath(existing.path) != null) {
      await _storePhysicalPartialInSaf(
        physicalId: physicalId,
        providerHint: providerHint,
        entry: entry,
        existing: existing,
      );
      return;
    }
    if (existing == null && safTreeIo != null && safTreeUri != null) {
      await _storePhysicalPartialInSaf(
        physicalId: physicalId,
        providerHint: providerHint,
        entry: entry,
      );
      return;
    }
    await _storePhysicalPartialDirect(
      physicalId: physicalId,
      providerHint: providerHint,
      entry: entry,
      existing: existing,
      control: control,
    );
  }

  Future<void> _storePhysicalPartialDirect({
    required PhysicalMediaId physicalId,
    required DownloadId providerHint,
    required PartialDownloadEntry entry,
    PhysicalPartialRecord? existing,
    CacheLayout? targetLayoutOverride,
    int? createdUsOverride,
    PhysicalPartialRecord? obsoleteSource,
    String? obsoleteSourceChecksum,
    bool deriveObsoleteSourceChecksumFromCopy = false,
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    final CacheLayout targetLayout;
    if (targetLayoutOverride != null) {
      targetLayout = targetLayoutOverride;
    } else if (existing == null) {
      targetLayout = layoutFor(providerHint);
    } else {
      final root = existing.storageRootId.trim();
      if (root.isEmpty || root == 'default') {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'physical partial has no stable direct storage root',
        );
      }
      targetLayout = CacheLayout(root);
    }
    if (obsoleteSource == null) {
      if (obsoleteSourceChecksum != null || deriveObsoleteSourceChecksumFromCopy) {
        throw StateError('partial replacement cleanup proof has no source');
      }
    } else if (deriveObsoleteSourceChecksumFromCopy ==
        (obsoleteSourceChecksum != null)) {
      throw StateError('partial replacement cleanup proof is ambiguous');
    }
    final artifact = targetLayout.artifactForPhysical(physicalId);
    if (existing != null &&
        File(artifact.partialPath).absolute.path !=
            File(existing.path).absolute.path) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'physical partial path disagrees with its stable identity',
      );
    }
    if (existing == null && await artifact.hasRestorableBody()) {
      if (obsoleteSource != null) {
        // A failed prior SAF/external -> App-private staging migration can
        // leave only a non-authoritative deterministic target body. The old
        // indexed source is still the authority, so clear that target before
        // retry rather than treating it as an independent partial owner.
        await artifact.reset(deleteFinal: true);
      } else {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'unindexed body already occupies physical partial path',
        );
      }
    }

    final obsoletePrefixChecksum = deriveObsoleteSourceChecksumFromCopy
        ? Crc32()
        : null;
    var obsoletePrefixChecksumBytes = 0;

    Future<void> commitCurrentPartialAuthority() async {
      StorageCleanupDebtRecord? cleanupDebt;
      if (obsoleteSource != null) {
        if (deriveObsoleteSourceChecksumFromCopy &&
            obsoletePrefixChecksumBytes != obsoleteSource.bytes) {
          throw StateError(
            'partial replacement cleanup proof is incomplete: '
            '$obsoletePrefixChecksumBytes/${obsoleteSource.bytes}',
          );
        }
        cleanupDebt = await _registerObsoletePartialSourceCleanupDebt(
          accessLocator: obsoleteSource.path,
          storageRootId: obsoleteSource.storageRootId,
          expectedBytes: obsoleteSource.bytes,
          checksum: obsoleteSourceChecksum ?? obsoletePrefixChecksum!.hex,
        );
      }
      try {
        await _commitPhysicalPartialMetadata(
          artifact: artifact,
          physicalId: physicalId,
          providerHint: providerHint,
          validators: entry.validators,
          totalLength: entry.totalLength,
          createdUs: existing?.createdUs ?? createdUsOverride,
          storageRootId: targetLayout.root,
        );
      } on Object {
        if (cleanupDebt != null) {
          await _forgetStorageCleanupDebt(cleanupDebt.accessLocator);
        }
        rethrow;
      }
      if (cleanupDebt != null) {
        // The Direct staging body is already authoritative. Retiring the old
        // locator is durable maintenance, not part of the Reader takeover
        // transaction. Keep the cleanup debt's delete-time ownership/length/
        // checksum proof, but do not hold request cancellation behind another
        // full SAF scan.
        _scheduleCleanupDebtDrain();
      }
    }

    try {
      if (existing == null) {
        // A new physical partial normally has no body after the admission probe
        // above, so strict restore adds no checksum work on the ordinary path.
        // Keep the default promoted verification here anyway: another writer or
        // crash-recovery race could materialize a final body between the probe
        // and restore, and that body must not become authority from metadata
        // alone.
        await artifact.restore();
        control?.throwIfCancelled();
      } else {
        final file = File(existing.path);
        if (!await file.exists() || await file.length() != existing.bytes) {
          throw const Failure(
            code: ErrorCode.artifactCorruption,
            message: 'physical partial changed before durable update',
          );
        }
        await artifact.adoptExistingPartial(expectedLength: existing.bytes);
        control?.throwIfCancelled();
      }
      var offset = artifact.committedLength;
      if (deriveObsoleteSourceChecksumFromCopy && offset != 0) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'cross-locator physical partial staging must start at zero',
        );
      }
      try {
        await for (final chunk in entry.open(start: offset)) {
          control?.throwIfCancelled();
          if (chunk.isEmpty) continue;
          await artifact.append(offset, chunk);
          final cleanupProof = obsoletePrefixChecksum;
          if (cleanupProof != null &&
              obsoletePrefixChecksumBytes < obsoleteSource!.bytes) {
            final remaining = obsoleteSource.bytes - obsoletePrefixChecksumBytes;
            if (chunk.length <= remaining) {
              cleanupProof.add(chunk);
              obsoletePrefixChecksumBytes += chunk.length;
            } else {
              cleanupProof.add(chunk.sublist(0, remaining));
              obsoletePrefixChecksumBytes += remaining;
            }
          }
          control?.throwIfCancelled();
          offset += chunk.length;
          if (offset >= entry.length) break;
        }
        if (offset != entry.length) {
          throw StateError(
            'physical partial source changed while storing ${physicalId.key}: '
            '$offset/${entry.length}',
          );
        }
      } catch (error, stackTrace) {
        if (artifact.committedLength > 0) {
          try {
            if (obsoleteSource == null ||
                artifact.committedLength >= obsoleteSource.bytes) {
              await artifact.pause();
              await commitCurrentPartialAuthority();
            } else {
              // A failed cross-locator copy must not replace a longer old
              // authoritative prefix with an inferior staging prefix.
              await artifact.reset(deleteFinal: true);
            }
          } on Object {
            // Preserve the source/store failure. If cleanup of a failed
            // deterministic staging body also fails, the old indexed source
            // remains authority and the next replacement attempt retries the
            // same target cleanup before writing.
          }
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      await artifact.pause();
      await commitCurrentPartialAuthority();
    } finally {
      await artifact.dispose();
    }
  }

  Future<void> _commitPhysicalPartialMetadata({
    required Artifact artifact,
    required PhysicalMediaId physicalId,
    required DownloadId providerHint,
    required Validators validators,
    required int? totalLength,
    required int? createdUs,
    required String storageRootId,
  }) async {
    if (artifact.committedLength <= 0) return;
    await artifact.writeMeta(<String, Object?>{
      'version': 1,
      'physicalMedia': physicalId.toJson(),
      'providerDownload': providerHint.toJson(),
      'validators': validators.toJson(),
      'totalLength': totalLength,
      'validatorRequestUri': providerHint.canonicalUri.toString(),
    });
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    await _index.putPhysicalPartial(
      PhysicalPartialRecord(
        id: physicalId,
        path: artifact.partialPath,
        bytes: artifact.committedLength,
        checksum: artifact.checksum,
        createdUs: createdUs ?? now,
        touchedUs: now,
        storageRootId: storageRootId,
      ),
    );
  }

  Future<void> _storePhysicalPartialInSaf({
    required PhysicalMediaId physicalId,
    required DownloadId providerHint,
    required PartialDownloadEntry entry,
    PhysicalPartialRecord? existing,
  }) async {
    final io = safTreeIo;
    final treeUri = safTreeUri;
    if (io == null || treeUri == null) {
      throw const Failure(
        code: ErrorCode.policy,
        message: 'physical SAF partial is not accessible in this store',
      );
    }
    final existingParsed = existing == null
        ? null
        : parseSafRecordPath(existing.path);
    if (existingParsed != null && existingParsed.treeUri != treeUri) {
      throw const Failure(
        code: ErrorCode.policy,
        message: 'physical SAF partial belongs to an unavailable storage root',
      );
    }
    final relativePath =
        existingParsed?.relativePath ??
        'partial/${layoutFor(providerHint).tokenForPhysical(physicalId)}.part';
    final recordPath = encodeSafRecordPath(
      treeUri: treeUri,
      relativePath: relativePath,
    );
    await _serializeStructuredWrite(recordPath, () async {
      final temporaryPath =
          '$relativePath.zic-tmp-${DateTime.now().microsecondsSinceEpoch}';
      final temporaryRecordPath = encodeSafRecordPath(
        treeUri: treeUri,
        relativePath: temporaryPath,
      );
      await _registerActiveTemporaryCleanupDebt(
        temporaryRecordPath,
        storageRootId: treeUri,
      );
      final handle = await _withStorageWriteQuantum(
        () => io.open(temporaryPath, mode: SafWriteMode.writeTruncate),
      );
      if (handle == null) {
        throw StateError('SAF tree refused create for $temporaryPath');
      }
      final crc = Crc32();
      var written = 0;
      try {
        await for (final chunk in entry.open(start: 0)) {
          if (chunk.isEmpty) continue;
          final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
          crc.add(bytes);
          await _withStorageWriteQuantum(() => io.write(handle, bytes));
          written += chunk.length;
          if (written >= entry.length) break;
        }
      } finally {
        await _withStorageWriteQuantum(() => io.close(handle));
      }
      try {
        if (written != entry.length) {
          throw StateError(
            'physical SAF partial source changed while storing '
            '${physicalId.key}: $written/${entry.length}',
          );
        }
        final now = DateTime.now().toUtc().microsecondsSinceEpoch;
        final authority = PhysicalPartialRecord(
          id: physicalId,
          path: recordPath,
          bytes: written,
          checksum: crc.hex,
          createdUs: existing?.createdUs ?? now,
          touchedUs: now,
          storageRootId: treeUri,
        );
        await _commitSafBodyReplacement<void>(
          targetPath: relativePath,
          temporaryPath: temporaryPath,
          bodyBytes: written,
          bodyChecksum: crc.hex,
          verifyChecksum: false,
          expectedPhysicalAuthority: authority,
          commitAuthority: () => _index.putPhysicalPartial(authority),
        );
      } finally {
        if (await _withStorageWriteQuantum(() => io.exists(temporaryPath))) {
          await _withStorageWriteQuantum(() => io.delete(temporaryPath));
        }
        if (!await _withStorageWriteQuantum(() => io.exists(temporaryPath))) {
          await _forgetStorageCleanupDebt(temporaryRecordPath);
        }
      }
      try {
        await _withStorageWriteQuantum(
          () => _writeBytesToSafTracked(
            io,
            '$relativePath.meta',
            Uint8List.fromList(
              utf8.encode(
                jsonEncode(<String, Object?>{
                  'version': 1,
                  'physicalMedia': physicalId.toJson(),
                  'providerDownload': providerHint.toJson(),
                  'validators': entry.validators.toJson(),
                  'totalLength': entry.totalLength,
                  'validatorRequestUri': providerHint.canonicalUri.toString(),
                }),
              ),
            ),
            replaceNonAuthoritative: true,
          ),
        );
      } on Object {
        // Resume metadata is acceleration only; the indexed body remains the
        // physical partial authority without it.
      }
    });
  }

  Future<_IndexedPartialResumeState> _readSafPhysicalPartialResumeState(
    String path,
    PhysicalMediaId physicalId,
    DownloadId requestId,
  ) async {
    final parsed = parseSafRecordPath(path);
    final io = safTreeIo;
    final treeUri = safTreeUri;
    if (parsed == null ||
        io == null ||
        treeUri == null ||
        parsed.treeUri != treeUri) {
      return const _IndexedPartialResumeState();
    }
    final metadataPath = '${parsed.relativePath}.meta';
    int? handle;
    try {
      // open() already resolves existence and establishes the descriptor used
      // below. A separate SAF exists() probe repeats the same provider path
      // traversal on a cold directory and can dominate Reader local prepare.
      handle = await io.open(metadataPath, mode: SafWriteMode.read);
      if (handle == null) return const _IndexedPartialResumeState();
      final length = await io.length(handle) ?? 0;
      if (length <= 0) return const _IndexedPartialResumeState();
      final bytes = await io.read(handle, length);
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return const _IndexedPartialResumeState();
      return _parsePhysicalPartialResumeState(
        Map<String, Object?>.from(decoded),
        physicalId,
        requestId,
      );
    } on Object {
      // Resume metadata is acceleration only. Missing/stale/temporarily
      // inaccessible sidecars do not invalidate the already length-checked
      // physical media prefix.
      return const _IndexedPartialResumeState();
    } finally {
      if (handle != null) await io.close(handle);
    }
  }

  @override
  Future<void> invalidatePhysicalPartialDownload(PhysicalMediaId physicalId) =>
      _notifyManagementAfter(
        _serializePhysicalPartialMutation(physicalId, () async {
        _requireOpen();
        final record = await _index.getPhysicalPartial(physicalId);
        if (record == null) return;
        if (_borrowedPhysicalPartialIds.contains(physicalId)) {
          throw const Failure(
            code: ErrorCode.sessionBusy,
            message:
                'physical durable partial is borrowed by the transfer owner',
          );
        }
        await _removePhysicalPartialRecord(record, deleteBody: true);
      }),
      );

  Future<void> _deletePhysicalPartialBody(PhysicalPartialRecord record) async {
    await _bytes.delete(record.path);
    await _deleteArtifactSidecar(record.path);
    if (await _bytes.exists(record.path) ||
        await _artifactSidecarExists(record.path)) {
      throw const Failure(
        code: ErrorCode.policy,
        message: 'physical partial cleanup access is not currently provable',
      );
    }
  }

  Future<void> _removePhysicalPartialRecord(
    PhysicalPartialRecord record, {
    required bool deleteBody,
  }) async {
    if (deleteBody) {
      await _deletePhysicalPartialBody(record);
    }
    await _index.removePhysicalPartial(record.id);
  }

  bool _samePhysicalPartialRecord(
    PhysicalPartialRecord first,
    PhysicalPartialRecord second,
  ) => first == second;

  @override
  Future<PartialDownloadEntry?> openPartialDownload(DownloadId id) =>
      _serializeArtifactMutation(id, () => _openPartialDownload(id));

  Future<PartialDownloadEntry?> _openVerifiedReadyPartialEntry(
    DownloadId id,
    CacheRec record,
  ) async {
    final authority = _index.readArtifactAuthoritySnapshot(
      record.effectiveArtifactId,
    );
    final replicas = await _resolveArtifactReplicas(record,
      authority: authority,
    );
    if (replicas.isEmpty) {
      await _forgetIndexedBinding(id, record: record);
      return null;
    }

    final groups =
        <
          ({
            _ArtifactAccessRecord replica,
            List<_ArtifactAccessCandidate> candidates,
          })
        >[];
    for (final replica in replicas) {
      if (!await _artifactReplicaIsAccessible(replica,
        authority: authority,
      )) {
        continue;
      }
      if (replica.checksumAlgorithm.trim().toLowerCase() != 'crc32') {
        await _retireArtifactReplica(
          replica.artifactId,
          replica.replicaId,
          replica.accessLocator,
        );
        continue;
      }
      final candidates = await _artifactAccessCandidates(replica,
        authority: authority,
      );
      if (candidates.isNotEmpty) {
        groups.add((replica: replica, candidates: candidates));
      }
    }
    if (groups.isEmpty) {
      if ((await _index.listArtifactReplicas(
        record.effectiveArtifactId,
      )).isEmpty) {
        await _forgetIndexedBinding(id, record: record);
      }
      return null;
    }

    Stream<List<int>> fallbackRange(int start, int endExclusive) async* {
      final stream = await _openArtifactStreamExact(id);
      if (stream == null) {
        throw ArtifactReadFailure(
          kind: ArtifactReadFailureKind.missing,
          accessLocator: groups.first.replica.accessLocator,
          replicaId: groups.first.replica.replicaId,
          failedOffset: start,
          bytesEmitted: 0,
          expectedLength: endExclusive - start,
          observedLength: 0,
        );
      }
      yield* stream.open(start: start, endExclusive: endExclusive);
    }

    Future<PartialDownloadBoundRangeReader?> openBoundReader() async {
      ArtifactReadFailure? lastFailure;
      for (final group in groups) {
        try {
          final reader = await _openBoundArtifactRangeReader(
            group.candidates,
            expectedLength: record.bytes,
          );
          if (reader == null) continue;
          await _index.touch(
            id.key,
            DateTime.now().toUtc().microsecondsSinceEpoch,
          );
          return (
            accessMode: reader.accessMode,
            directFilePath: reader.directFilePath,
            readRange: reader.readRange,
            close: reader.close,
          );
        } on ArtifactReadFailure catch (error) {
          lastFailure = error;
          if (_isStructuralReplicaFailure(error.kind)) {
            await _retireArtifactReplica(
              group.replica.artifactId,
              group.replica.replicaId,
              group.replica.accessLocator,
            );
          }
        }
      }
      if (lastFailure != null) throw lastFailure;
      return null;
    }

    final firstAccess = groups.first.candidates.first.access.accessLocator;
    return PartialDownloadEntry(
      length: record.bytes,
      validators: Validators(etag: '"${record.bytes}-${id.key}"'),
      totalLength: record.bytes,
      open: ({required int start}) => fallbackRange(start, record.bytes),
      openRange: ({required int start, required int endExclusive}) =>
          fallbackRange(start, endExclusive),
      openBoundRangeReader: openBoundReader,
      accessMode: parseSafRecordPath(firstAccess) == null ? 'direct' : 'saf',
      sealedChecksum: record.checksum.trim().toLowerCase(),
      sealedChecksumAlgorithm: record.checksumAlgorithm.trim().toLowerCase(),
      exactDurableFinal: true,
    );
  }

  Future<PartialDownloadEntry?> _openPartialDownload(DownloadId id) async {
    _requireOpen();
    if (_artifactWrites.containsKey(id) || _borrowedPartialIds.contains(id)) {
      return null;
    }
    final active = _registry.find(id);
    if (active != null && (active.activeRun || active.hasWriter)) return null;

    // Durable partial/artifact lookup is an index/file concern. Do not
    // materialize a synthetic DownloadSession merely to discover whether cold
    // bytes exist. The composition physical session remains the only Reader
    // transfer owner.
    final record = await _index.get(id.key);
    if (record != null &&
        _isVerifiedReadyRecord(record) &&
        record.id == id &&
        record.bytes > 0) {
      final ready = await _openVerifiedReadyPartialEntry(id, record);
      if (ready != null) return ready;
    }
    if (record == null ||
        record.state != CacheState.partial ||
        record.id != id ||
        record.bytes <= 0) {
      return null;
    }
    final parsed = parseSafRecordPath(record.path);
    if (!_recordBelongsToCurrentRoot(id, record)) return null;
    if (parsed != null) {
      if (safTreeUri == null || parsed.treeUri != safTreeUri) return null;
      final length = await _bytes.length(record.path);
      if (length < record.bytes) {
        await _invalidateIndexedArtifact(id, record: record);
        await safTreeIo?.delete('${parsed.relativePath}.meta');
        return null;
      }
      final resume = await _readSafPartialResumeState(record.path, id);
      if (resume.explicitDifferentOwner) {
        // Metadata proves the bytes are foreign, but it does not authorize
        // deleting them. Drop only this logical binding and leave the
        // unowned bytes for the actual owner or an explicit cleanup action.
        await _forgetIndexedBinding(id, record: record);
        return null;
      }
      final touchedUs = DateTime.now().toUtc().microsecondsSinceEpoch;
      await _index.touch(id.key, touchedUs);
      return PartialDownloadEntry(
        length: record.bytes,
        validators: resume.validators,
        totalLength: resume.totalLength,
        open: ({required int start}) => _bytes.readChunks(
          record.path,
          start: start,
          endExclusive: record.bytes,
        ),
      );
    }

    final file = File(record.path);
    if (!await file.exists()) {
      await _invalidateIndexedArtifact(id, record: record);
      return null;
    }
    final length = await file.length();
    if (length < record.bytes) {
      await _invalidateIndexedArtifact(id, record: record);
      final metadata = File('${record.path}.meta');
      if (await metadata.exists()) await metadata.delete();
      return null;
    }

    final resume = await _readIndexedPartialResumeState(record.path, id);
    if (resume.explicitDifferentOwner) {
      // Metadata proves the bytes are foreign, but it does not authorize
      // deleting them. Drop only this logical binding and leave the
      // unowned bytes for the actual owner or an explicit cleanup action.
      await _forgetIndexedBinding(id, record: record);
      return null;
    }
    final touchedUs = DateTime.now().toUtc().microsecondsSinceEpoch;
    await _index.touch(id.key, touchedUs);
    final adoptionExpected = record.copyWith(touchedUs: touchedUs);
    return PartialDownloadEntry(
      length: record.bytes,
      validators: resume.validators,
      totalLength: resume.totalLength,
      open: ({required int start}) => _readIndexedChunks(
        record.path,
        length: record.bytes,
        start: start,
      ),
      adoptInto: (session, {TaskControl? control}) => _adoptIndexedPosixPartial(
        session,
        expected: adoptionExpected,
        control: control,
      ),
    );
  }

  Future<bool> _adoptIndexedPosixPartial(
    DownloadSession target, {
    required CacheRec expected,
    TaskControl? control,
  }) => _serializeArtifactMutation(expected.id, () =>
      _serializePhysicalPartialMutation(target.physicalId, () async {
        _requireOpen();
        control?.throwIfCancelled();
        final id = expected.id;
        final physicalId = target.physicalId;
        if (target.id != id ||
            _borrowedPartialIds.contains(id) ||
            (!physicalId.isExactFallback &&
                _borrowedPhysicalPartialIds.contains(physicalId))) {
          return false;
        }
        final current = await _index.get(id.key);
        if (current == null ||
            current.state != CacheState.partial ||
            !_sameIndexedRecord(expected, current) ||
            parseSafRecordPath(current.path) != null ||
            !_recordBelongsToCurrentRoot(id, current)) {
          return false;
        }
        final file = File(current.path);
        if (!await file.exists() || await file.length() < current.bytes) {
          return false;
        }
        final resume = await _readIndexedPartialResumeState(current.path, id);
        if (resume.explicitDifferentOwner) return false;
        final adoptedArtifact = _registry.artifactForIndexedRecord(current);
        if (adoptedArtifact == null) return false;

        final donor = _registry.find(id);
        if (donor != null) {
          if (!donor.canEvict ||
              donor.demanded ||
              donor.activeRun ||
              donor.hasWriter) {
            return false;
          }
          await donor.settleCacheMutations();
          control?.throwIfCancelled();
          if (!identical(_registry.find(id), donor) ||
              !donor.canEvict ||
              donor.demanded ||
              donor.activeRun ||
              donor.hasWriter) {
            return false;
          }
          final taken = _registry.takeIdlePhysical(id);
          if (!identical(taken, donor)) return false;
          await donor.dispose();
        }

        _borrowedPartialIds.add(id);
        if (!physicalId.isExactFallback) {
          _borrowedPhysicalPartialIds.add(physicalId);
        }
        try {
          await target.adoptDurablePartialBacking(
            artifact: adoptedArtifact,
            index: _index,
            cacheMutationOwner: this,
            storageRootId: current.storageRootId,
            expectedLength: current.bytes,
            validators: resume.validators,
            totalLength: resume.totalLength,
            releaseBacking: () {
              _borrowedPartialIds.remove(id);
              if (!physicalId.isExactFallback) {
                _borrowedPhysicalPartialIds.remove(physicalId);
              }
            },
            control: control,
          );
          return true;
        } catch (_) {
          if (!target.hasBorrowedDurableSpool) {
            _borrowedPartialIds.remove(id);
            if (!physicalId.isExactFallback) {
              _borrowedPhysicalPartialIds.remove(physicalId);
            }
          }
          rethrow;
        }
      }));

  Future<_IndexedPartialResumeState> _readSafPartialResumeState(
    String path,
    DownloadId id,
  ) async {
    final parsed = parseSafRecordPath(path);
    if (parsed == null || safTreeIo == null || safTreeUri == null) {
      return const _IndexedPartialResumeState();
    }
    final metadataPath = '${parsed.relativePath}.meta';
    if (!await safTreeIo!.exists(metadataPath)) {
      return const _IndexedPartialResumeState();
    }
    final handle = await safTreeIo!.open(metadataPath, mode: SafWriteMode.read);
    if (handle == null) return const _IndexedPartialResumeState();
    try {
      final length = await safTreeIo!.length(handle) ?? 0;
      if (length <= 0) return const _IndexedPartialResumeState();
      final bytes = await safTreeIo!.read(handle, length);
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return const _IndexedPartialResumeState();
      final meta = Map<String, Object?>.from(decoded);
      final key = meta['downloadKey'];
      if (key is String && key != id.key) {
        return const _IndexedPartialResumeState(explicitDifferentOwner: true);
      }
      final rawDownload = meta['download'];
      if (rawDownload is Map) {
        try {
          if (DownloadId.fromJson(Map<String, Object?>.from(rawDownload)) !=
              id) {
            return const _IndexedPartialResumeState(
              explicitDifferentOwner: true,
            );
          }
        } on Object {
          return const _IndexedPartialResumeState();
        }
      }
      final rawValidators = meta['validators'];
      final rawLength = meta['totalLength'];
      if (rawValidators is! Map || (rawLength != null && rawLength is! int)) {
        return const _IndexedPartialResumeState();
      }
      var validators = Validators.fromJson(
        Map<String, Object?>.from(rawValidators),
      );
      final rawRequestUri = meta['validatorRequestUri'];
      final requestUri = rawRequestUri is String
          ? Uri.tryParse(rawRequestUri)
          : null;
      if (validators.canResume && requestUri != id.canonicalUri) {
        validators = const Validators();
      }
      return _IndexedPartialResumeState(
        validators: validators,
        totalLength: rawLength as int?,
      );
    } on Object {
      return const _IndexedPartialResumeState();
    } finally {
      await safTreeIo!.close(handle);
    }
  }

  Future<void> _storePartialDownloadInSaf(
    DownloadId id,
    PartialDownloadEntry entry,
  ) async {
    final io = safTreeIo!;
    final treeUri = safTreeUri!;
    final relativePath = 'partial/${layoutFor(id).tokenFor(id)}.part';
    final recordPath = encodeSafRecordPath(
      treeUri: treeUri,
      relativePath: relativePath,
    );
    final previous = await _index.get(id.key);
    if (previous != null && _isVerifiedReadyRecord(previous)) return;
    await _serializeStructuredWrite(recordPath, () async {
      final existingResume = await _readSafPartialResumeState(recordPath, id);
      if (existingResume.explicitDifferentOwner) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'SAF partial artifact metadata belongs to another download',
        );
      }
      final temporaryPath =
          '$relativePath.zic-tmp-${DateTime.now().microsecondsSinceEpoch}';
      final temporaryRecordPath = encodeSafRecordPath(
        treeUri: treeUri,
        relativePath: temporaryPath,
      );
      await _registerActiveTemporaryCleanupDebt(
        temporaryRecordPath,
        storageRootId: treeUri,
      );
      final handle = await _withStorageWriteQuantum(
        () => io.open(temporaryPath, mode: SafWriteMode.writeTruncate),
      );
      if (handle == null) {
        throw StateError('SAF tree refused create for $temporaryPath');
      }
      final crc = Crc32();
      var written = 0;
      try {
        await for (final chunk in entry.open(start: 0)) {
          if (chunk.isEmpty) continue;
          final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
          crc.add(bytes);
          await _withStorageWriteQuantum(() => io.write(handle, bytes));
          written += chunk.length;
        }
      } finally {
        await _withStorageWriteQuantum(() => io.close(handle));
      }
      try {
        if (written != entry.length) {
          throw StateError(
            'partial artifact length changed while storing ${id.key}: '
            '$written/${entry.length}',
          );
        }
        final beforeCommitResume = await _readSafPartialResumeState(
          recordPath,
          id,
        );
        if (beforeCommitResume.explicitDifferentOwner) {
          throw const Failure(
            code: ErrorCode.artifactCorruption,
            message: 'SAF partial artifact owner changed before commit',
          );
        }
        final now = DateTime.now().toUtc().microsecondsSinceEpoch;
        final record = CacheRec(
          id: id,
          state: CacheState.partial,
          path: recordPath,
          bytes: written,
          checksum: crc.hex,
          createdUs: previous?.createdUs ?? now,
          touchedUs: now,
          pinned: false,
          storageRootId: treeUri,
        );
        StorageCleanupDebtRecord? previousCleanupDebt;
        if (previous != null &&
            previous.state == CacheState.partial &&
            previous.path != recordPath &&
            parseSafRecordPath(previous.path) == null) {
          if (!await _cleanupLocatorIsAvailable(
            previous.path,
            previous.storageRootId,
          )) {
            throw const Failure(
              code: ErrorCode.policy,
              message:
                  'previous exact partial root is unavailable for safe replacement',
            );
          }
          previousCleanupDebt = await _snapshotObsoletePartialSourceCleanupDebt(
            accessLocator: previous.path,
            storageRootId: previous.storageRootId,
          );
        }
        await _commitSafBodyReplacement<void>(
          targetPath: relativePath,
          temporaryPath: temporaryPath,
          bodyBytes: written,
          bodyChecksum: crc.hex,
          verifyChecksum: false,
          expectedCacheAuthority: record,
          commitAuthority: () async {
            try {
              await _index.put(record);
            } on Object {
              if (previousCleanupDebt != null) {
                await _forgetStorageCleanupDebt(
                  previousCleanupDebt.accessLocator,
                );
              }
              rethrow;
            }
            if (previousCleanupDebt != null) {
              await _cleanupObsoleteSourceNow(previousCleanupDebt);
            }
          },
        );
      } finally {
        final temporaryExists = await _withStorageWriteQuantum(
          () => io.exists(temporaryPath),
        );
        if (temporaryExists) {
          await _withStorageWriteQuantum(() => io.delete(temporaryPath));
        }
        if (!await _withStorageWriteQuantum(() => io.exists(temporaryPath))) {
          await _forgetStorageCleanupDebt(temporaryRecordPath);
        }
      }
      // Metadata is an optimization for validator-bound resume. A provider
      // failure here must not discard the newly committed media prefix.
      try {
        await _withStorageWriteQuantum(
          () => _writeBytesToSafTracked(
            io,
            '$relativePath.meta',
            Uint8List.fromList(
              utf8.encode(
                jsonEncode(<String, Object?>{
                  'downloadKey': id.key,
                  'download': id.toJson(),
                  'validators': entry.validators.toJson(),
                  'totalLength': entry.totalLength,
                  'validatorRequestUri': id.canonicalUri.toString(),
                }),
              ),
            ),
            replaceNonAuthoritative: true,
          ),
        );
      } on Object {
        // The indexed partial remains resumable without validators.
      }
    });
  }

  @override
  Future<void> storePartialDownload({
    required DownloadId id,
    required PartialDownloadEntry entry,
  }) => _notifyManagementAfter(
    _serializeArtifactMutation(
      id,
      () => _storePartialDownload(
        id: id,
        entry: entry,
        preferDirectStaging: false,
      ),
    ),
  );

  @override
  Future<void> storeTransferPartialDownload({
    required DownloadId id,
    required PartialDownloadEntry entry,
  }) => _notifyManagementAfter(
    _serializeArtifactMutation(
      id,
      () => _storePartialDownload(
        id: id,
        entry: entry,
        preferDirectStaging: true,
      ),
    ),
  );

  Future<void> _storePartialDownload({
    required DownloadId id,
    required PartialDownloadEntry entry,
    required bool preferDirectStaging,
  }) async {
    _requireOpen();
    if (_borrowedPartialIds.contains(id)) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'durable partial is borrowed by the active transfer owner',
      );
    }
    if (entry.length <= 0) return;
    if (preferDirectStaging) {
      await _storeExactPartialDirectStaging(id: id, entry: entry);
      return;
    }
    if (safTreeIo != null && safTreeUri != null) {
      await _storePartialDownloadInSaf(id, entry);
      return;
    }
    final session = _registry.get(id);
    if (session.activeRun || session.hasWriter) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'partial download store destination is busy',
      );
    }
    await session.restore(verifyPromotedChecksum: false);
    if (session.state == DownloadState.promoted ||
        session.artifact.committedLength >= entry.length) {
      return;
    }
    await session.bindResponse(
      validators: entry.validators,
      totalLength: entry.totalLength,
    );
    final writer = session.acquireWriter();
    var offset = session.artifact.committedLength;
    try {
      await for (final chunk in entry.open(start: offset)) {
        if (chunk.isEmpty) continue;
        await session.append(writer, offset, chunk);
        offset += chunk.length;
      }
      if (offset != entry.length) {
        throw StateError(
          'partial artifact length changed while storing ${id.key}: '
          '$offset/${entry.length}',
        );
      }
    } on Object catch (error) {
      await session.fail(writer, error);
      rethrow;
    }
    await session.pause(writer);
  }

  Future<void> _storeExactPartialDirectStaging({
    required DownloadId id,
    required PartialDownloadEntry entry,
  }) async {
    final previous = await _index.get(id.key);
    if (previous != null && previous.id != id) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'exact partial index belongs to another download',
      );
    }
    if (previous != null && _isVerifiedReadyRecord(previous)) return;
    if (previous != null &&
        previous.state == CacheState.partial &&
        previous.bytes > entry.length) {
      return;
    }

    final active = _registry.find(id);
    if (active != null && active.state != DownloadState.disposed) {
      if (!active.canEvict ||
          active.demanded ||
          active.activeRun ||
          active.hasWriter) {
        throw const Failure(
          code: ErrorCode.sessionBusy,
          message: 'exact transfer staging destination has a live store session',
        );
      }
      // Generic Direct exact-partial persistence historically materializes a
      // store-owned DownloadSession. Automatic staging must remain compatible
      // with that same-process state: settle its index tail, recheck the idle
      // boundary, then mechanically retire only the session handle. Durable
      // bytes/index authority remain untouched for the staging migration below.
      await active.settleCacheMutations();
      final current = _registry.find(id);
      if (!identical(current, active) ||
          !active.canEvict ||
          active.demanded ||
          active.activeRun ||
          active.hasWriter) {
        throw const Failure(
          code: ErrorCode.sessionBusy,
          message: 'exact transfer staging destination became busy',
        );
      }
      final retired = _registry.takeIdlePhysical(id);
      if (!identical(retired, active)) {
        throw const Failure(
          code: ErrorCode.sessionBusy,
          message: 'exact transfer staging could not retire idle store session',
        );
      }
      await active.dispose();
    }

    final targetLayout = layout;
    final artifact = targetLayout.artifactForPhysical(PhysicalMediaId.exact(id));
    final targetPath = File(artifact.partialPath).absolute.path;
    final previousRoot = previous?.storageRootId.trim() ?? '';
    final previousIsTarget = previous != null &&
        previous.state == CacheState.partial &&
        parseSafRecordPath(previous.path) == null &&
        File(previous.path).absolute.path == targetPath &&
        (previousRoot.isEmpty ||
            previousRoot == 'default' ||
            previousRoot == targetLayout.root);
    if (previousIsTarget && previous.bytes == entry.length) return;

    CacheRec? obsoleteSource;
    String? obsoleteSourceChecksum;
    if (previous != null &&
        previous.state == CacheState.partial &&
        !previousIsTarget) {
      if (!await _cleanupLocatorIsAvailable(
        previous.path,
        previous.storageRootId,
      )) {
        throw const Failure(
          code: ErrorCode.policy,
          message: 'previous exact partial root is unavailable for staging',
        );
      }
      obsoleteSourceChecksum = await _migrationRangeChecksum(
        _bytes.readChunks(
          previous.path,
          start: 0,
          endExclusive: previous.bytes,
        ),
        expectedBytes: previous.bytes,
      );
      obsoleteSource = previous;
    }

    if (!previousIsTarget && await artifact.hasRestorableBody()) {
      if (obsoleteSource == null) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'unindexed body already occupies exact staging path',
        );
      }
      // A failed earlier external -> App-private migration can leave a
      // non-authoritative deterministic target behind. The indexed old
      // locator remains authority, so clear only that failed target first.
      await artifact.reset(deleteFinal: true);
    }

    Future<void> commitCurrentPartialAuthority() async {
      if (artifact.committedLength <= 0) return;
      await artifact.writeMeta(<String, Object?>{
        'version': 3,
        'physicalMedia': PhysicalMediaId.exact(id).toJson(),
        'downloadKey': id.key,
        'download': id.toJson(),
        'uri': id.canonicalUri.toString(),
        'sourceRevision': id.sourceRevision,
        'validators': entry.validators.toJson(),
        if (!entry.validators.isEmpty)
          'validatorRequestUri': id.canonicalUri.toString(),
        if (entry.totalLength != null) 'totalLength': entry.totalLength,
      });

      StorageCleanupDebtRecord? cleanupDebt;
      if (obsoleteSource != null) {
        cleanupDebt = await _registerObsoletePartialSourceCleanupDebt(
          accessLocator: obsoleteSource.path,
          storageRootId: obsoleteSource.storageRootId,
          expectedBytes: obsoleteSource.bytes,
          checksum: obsoleteSourceChecksum!,
        );
      }
      final now = DateTime.now().toUtc().microsecondsSinceEpoch;
      final record = CacheRec(
        id: id,
        state: CacheState.partial,
        path: artifact.partialPath,
        bytes: artifact.committedLength,
        checksum: artifact.checksum,
        createdUs: previous?.createdUs ?? now,
        touchedUs: now,
        pinned: previous?.pinned ?? false,
        checksumAlgorithm: previous?.checksumAlgorithm ?? 'crc32',
        artifactId: previous?.path == artifact.partialPath
            ? previous?.artifactId ?? ''
            : '',
        storageRootId: targetLayout.root,
      );
      try {
        await _index.put(record);
      } on Object {
        if (cleanupDebt != null) {
          await _forgetStorageCleanupDebt(cleanupDebt.accessLocator);
        }
        rethrow;
      }
      if (cleanupDebt != null) {
        await _cleanupObsoleteSourceNow(cleanupDebt);
      }
    }

    try {
      if (previousIsTarget) {
        final file = File(previous.path);
        if (!await file.exists() || await file.length() != previous.bytes) {
          throw const Failure(
            code: ErrorCode.artifactCorruption,
            message: 'exact staging partial changed before durable update',
          );
        }
        await artifact.adoptExistingPartial(expectedLength: previous.bytes);
      } else {
        await artifact.restore();
      }
      var offset = artifact.committedLength;
      try {
        await for (final chunk in entry.open(start: offset)) {
          if (chunk.isEmpty) continue;
          await artifact.append(offset, chunk);
          offset += chunk.length;
          if (offset >= entry.length) break;
        }
        if (offset != entry.length) {
          throw StateError(
            'exact partial source changed while storing ${id.key}: '
            '$offset/${entry.length}',
          );
        }
      } catch (error, stackTrace) {
        if (artifact.committedLength > 0) {
          try {
            if (obsoleteSource == null ||
                artifact.committedLength >= obsoleteSource.bytes) {
              await artifact.pause();
              await commitCurrentPartialAuthority();
            } else {
              await artifact.reset(deleteFinal: true);
            }
          } on Object {
            // Preserve the source/store error. Unless the replacement reached
            // a safe prefix boundary the old indexed locator stays authority.
          }
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      await artifact.pause();
      await commitCurrentPartialAuthority();
    } finally {
      await artifact.dispose();
    }
  }

  @override
  Future<void> invalidatePartialDownload(DownloadId id) =>
      _notifyManagementAfter(
        _serializeArtifactMutation(id, () => _invalidatePartialDownload(id)),
      );

  Future<void> _invalidatePartialDownload(DownloadId id) async {
    _requireOpen();
    if (_borrowedPartialIds.contains(id)) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'durable partial is borrowed by the active transfer owner',
      );
    }
    var session = _registry.find(id);
    if (session != null && (session.activeRun || session.hasWriter)) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'partial download store destination is busy',
      );
    }
    if (session != null && session.state != DownloadState.promoted) {
      // Reset through the session lifecycle, not directly through Artifact:
      // the session must advance its epoch and clear Reader ingress
      // projections before the physical partial is invalidated. A direct
      // Artifact.reset() leaves those projections advertising bytes that no
      // longer exist and permits a stale append/replay completion to publish
      // into the cleared generation.
      await session.reset(removeCacheRecord: false);
    }
    session = _registry.find(id);
    if (session != null && (session.activeRun || session.hasWriter)) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'partial download store destination is busy',
      );
    }
    final record = await _index.get(id.key);
    if (record?.state == CacheState.partial) {
      await _invalidateIndexedArtifact(id, record: record);
    }
  }

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) {
    _requireOpen();
    if (bytes.isEmpty) {
      throw StateError('cannot cache an empty Reader artifact');
    }
    final ownedBytes = Uint8List.fromList(bytes);
    final checksum = Crc32()..add(ownedBytes);
    final checksumHex = checksum.hex;
    final active = _artifactWrites[id];
    if (active != null) {
      final proof = _artifactWriteProofs[id];
      if (proof == null ||
          proof.length != ownedBytes.lengthInBytes ||
          proof.checksum != checksumHex) {
        return Future<void>.error(
          const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'concurrent artifact writes contain different content',
          ),
        );
      }
      return active;
    }
    final run = _serializeArtifactMutation(
      id,
      () => _storePromotedArtifact(id, ownedBytes, checksumHex: checksumHex),
    );
    _artifactWrites[id] = run;
    _artifactWriteProofs[id] = (
      length: ownedBytes.lengthInBytes,
      checksum: checksumHex,
    );
    return _notifyManagementAfter(
      run.whenComplete(() {
        if (identical(_artifactWrites[id], run)) {
          _artifactWrites.remove(id);
          _artifactWriteProofs.remove(id);
        }
      }),
    );
  }

  Future<void> _storePromotedArtifact(
    DownloadId id,
    Uint8List bytes, {
    String? checksumHex,
  }) async {
    final effectiveChecksum = checksumHex ?? (Crc32()..add(bytes)).hex;
    final existing = await _index.get(id.key);
    if (existing != null &&
        existing.id == id &&
        _isVerifiedReadyRecord(existing) &&
        existing.bytes == bytes.lengthInBytes &&
        existing.checksum.trim().toLowerCase() ==
            effectiveChecksum.toLowerCase()) {
      try {
        final durable = await _openArtifactStreamExact(id);
        if (durable != null && durable.length == bytes.lengthInBytes) {
          // A sealed artifact is owned by artifact_object/artifact_replica.
          // Do not recreate a DownloadSession merely to re-prove the same
          // immutable body from a final sidecar.
          return;
        }
      } on ArtifactReadFailure catch (error) {
        if (!_isStructuralReplicaFailure(error.kind) ||
            (await _index.listArtifactReplicas(
              existing.effectiveArtifactId,
            )).isNotEmpty) {
          rethrow;
        }
        // All structural replicas were retired by the ordinary read path. The
        // caller already owns complete bytes, so fall through to a fresh
        // materialization rather than treating compatibility metadata as body.
      }
    }

    final session = _registry.get(id);
    if (session.activeRun || session.hasWriter) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'artifact cache destination is busy',
      );
    }
    await session.restore();
    if (session.state == DownloadState.promoted) {
      if (session.committedLength != bytes.lengthInBytes ||
          session.artifact.checksum != effectiveChecksum) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'promoted artifact already contains different content',
        );
      }
      return;
    }
    if (session.committedLength > 0) {
      await session.reset(removeCacheRecord: false);
    }
    // This is a NEW mutable session generation, so keep its transfer metadata
    // self-describing for collision detection and any pre-commit session
    // recovery. Once seal + SQLite artifact/replica commit succeeds, this
    // sidecar is no longer durable READY authority. Empty validators are
    // intentional: complete immutable bytes are being materialized, not an
    // HTTP response state synthesized.
    await session.bindResponse(
      validators: const Validators(),
      totalLength: bytes.lengthInBytes,
    );
    final runLease = session.beginRun();
    try {
      final writer = session.acquireWriter(expectedRun: runLease);
      try {
        await session.append(writer, 0, bytes);
        await session.seal(
          writer,
          expectedLength: bytes.lengthInBytes,
          expectedChecksum: effectiveChecksum,
        );
      } catch (error) {
        if (session.hasWriter) {
          try {
            await session.fail(writer, error);
          } catch (_) {}
        }
        rethrow;
      }
      await session.promote(expectedRun: runLease);
    } finally {
      session.endRun(runLease);
    }
  }

  @override
  Future<void> invalidateArtifact(DownloadId id) => _notifyManagementAfter(
    _serializeArtifactMutation(
      id,
      () async {
          _requireOpen();
          if (_borrowedPartialIds.contains(id)) {
            throw const Failure(
              code: ErrorCode.sessionBusy,
              message: 'durable artifact is borrowed by the active transfer owner',
            );
          }
          final record = await _index.get(id.key);
          final deletedPhysical = await _invalidateIndexedArtifact(
            id,
            record: record,
            // A maintenance touch cannot rescue an explicitly invalidated body.
            compareRecency: false,
          );
          if (deletedPhysical && _registry.find(id) != null) {
            await _registry.evict(id);
          }
        },
    ),
  );

  Future<int> _evictCacheRecord(DownloadId id, {CacheRec? expected}) =>
      _serializeArtifactMutation(id, () async {
          if (_borrowedPartialIds.contains(id)) {
            throw const Failure(
              code: ErrorCode.sessionBusy,
            message:
                'durable artifact is borrowed by the active transfer owner',
            );
          }
          final record = await _index.get(id.key);
          if (record == null ||
              (expected != null && !_sameIndexedRecord(expected, record))) {
            return 0;
          }
          final deletedPhysical = await _invalidateIndexedArtifact(
            id,
            record: record,
          );
          if (deletedPhysical && _registry.find(id) != null) {
            // The physical reference check has already completed successfully;
            // now clear the session's Artifact state as well. Never do this
            // for a shared path because registry.evict deletes blindly.
            await _registry.evict(id);
          }
          return deletedPhysical ? record.bytes : 0;
      });

  Future<bool> _invalidateIndexedArtifact(
    DownloadId id, {
    CacheRec? record,
    String? physicalPath,
    String? physicalArtifactId,
    String? physicalStorageRootId,
    bool compareRecency = true,
  }) async {
    // The persistent registry deliberately does not retain a second mutable
    // DownloadSession while composition owns this durable spool. Centralize
    // the borrowed guard here so stale-read cleanup cannot delete the backing
    // behind the active physical owner even when it bypasses public clear/evict.
    if (_borrowedPartialIds.contains(id)) return false;
    final snapshot = await _index.get(id.key);
    if (snapshot == null) return false;
    if (record != null && !_sameIndexedRecord(
      record,
      snapshot,
      compareRecency: compareRecency,
    )) {
      // Cache trim and invalidation callers may be acting on a snapshot. Never
      // remove a newer binding that reused the same logical key.
      return false;
    }
    final physicalAccess = _ArtifactAccessRecord(
      artifactId: physicalArtifactId ?? snapshot.effectiveArtifactId,
      replicaId: physicalArtifactId ?? snapshot.effectiveArtifactId,
      accessLocator: physicalPath ?? snapshot.path,
      bytes: snapshot.bytes,
      checksum: snapshot.checksum,
      checksumAlgorithm: snapshot.checksumAlgorithm,
      storageRootId: physicalStorageRootId ?? snapshot.storageRootId,
    );
    if (!_artifactAccessBelongsToCurrentRoot(id, physicalAccess)) {
      // A store opened after a root change may still contain historical
      // bindings. The current owner must not remove bytes belonging to that
      // other root; reconciliation occurs only when that root is selected.
      return false;
    }
    // Physical locators can be shared by multiple logical records. Coordinate
    // invalidation with adoption, structured materialization, and mirroring on
    // the actual artifact-object locator; the compatibility binding path may
    // already be stale after an immutable object rebind.
    return _serializeArtifactReplicaMutation(
      snapshot.effectiveArtifactId,
      () => _serializeStructuredWrite(
        physicalAccess.accessLocator,
        () => _invalidateIndexedArtifactLocked(
          id,
          record: snapshot,
          physicalAccess: physicalAccess,
          compareRecency: compareRecency,
        ),
      ),
    );
  }

  Future<bool> _invalidateIndexedArtifactLocked(
    DownloadId id, {
    required CacheRec record,
    required _ArtifactAccessRecord physicalAccess,
    required bool compareRecency,
  }) async {
    final initial = await _index.get(id.key);
    if (initial == null) return false;
    if (!_sameIndexedRecord(
      record,
      initial,
      compareRecency: compareRecency,
    )) {
      // Cache trim and invalidation callers may be acting on a snapshot. Never
      // remove a newer binding that reused the same logical key.
      return false;
    }
    final active = _registry.find(id);
    if (active != null && (active.activeRun || active.hasWriter)) return false;
    final replicas = initial.state == CacheState.ready
        ? await _index.listArtifactReplicas(initial.effectiveArtifactId)
        : const <ArtifactReplicaRecord>[];
    final migrations = initial.state == CacheState.ready
        ? await _index.listArtifactReplicaMigrationsForArtifact(
            initial.effectiveArtifactId,
          )
        : const <ArtifactReplicaMigrationRecord>[];
    Future<bool> removeBindingAndPhysical({
      required bool sessionWasReset,
    }) async {
      final current = initial;
      final partialCleanupDebt = current.state == CacheState.partial
          ? await _snapshotObsoletePartialSourceCleanupDebt(
              accessLocator: physicalAccess.accessLocator,
              storageRootId: physicalAccess.storageRootId,
            )
          : null;
      final sealedCleanupDebts = <StorageCleanupDebtRecord>[];
      if (current.state == CacheState.ready && replicas.isNotEmpty) {
        for (final replica in replicas) {
          final prepared = await _prepareObsoleteSealedReplicaCleanupDebt(
            replica: replica,
            expectedBytes: current.bytes,
            expectedChecksum: current.checksum,
            expectedChecksumAlgorithm: current.checksumAlgorithm,
          );
          if (!prepared.safeToRetire) {
            await _forgetStorageCleanupDebts(sealedCleanupDebts);
            return false;
          }
          final debt = prepared.debt;
          if (debt != null) sealedCleanupDebts.add(debt);
        }
      }
      final migrationCleanupDebts = <StorageCleanupDebtRecord>[];
      if (current.state == CacheState.ready) {
        for (final migration in migrations) {
          if (migration.phase == ArtifactReplicaMigrationPhase.cleanupPending &&
              migration.sourceAccessLocator !=
                  migration.destinationAccessLocator) {
            migrationCleanupDebts.add(
              await _registerObsoleteSealedSourceCleanupDebt(
                migration.sourceAccessLocator,
                storageRootId: migration.sourceStorageRootId,
                expectedBytes: current.bytes,
                expectedChecksum: current.checksum,
                expectedChecksumAlgorithm: current.checksumAlgorithm,
              ),
            );
          }
          final temporaryDebt =
              await _registerMigrationTemporaryCleanupDebt(migration);
          if (temporaryDebt != null) {
            migrationCleanupDebts.add(temporaryDebt);
          }
        }
      }


      Future<void> cancelCleanupIntent() async {
        if (partialCleanupDebt != null) {
          await _forgetStorageCleanupDebt(partialCleanupDebt.accessLocator);
        }
        await _forgetStorageCleanupDebts(sealedCleanupDebts);
        await _forgetStorageCleanupDebts(migrationCleanupDebts);
      }

      await _index.remove(id.key);
      if (await _index.get(id.key) != null) {
        await cancelCleanupIntent();
        return false;
      }
      final isReferencedByOther = await _index.isPathOrArtifactReferenced(
        path: physicalAccess.accessLocator,
        artifactId: physicalAccess.artifactId,
        excludingKey: id.key,
      );
      if (await _index.get(id.key) != null) {
        await cancelCleanupIntent();
        return false;
      }
      final activeAfterRemoval = _registry.find(id);
      if (activeAfterRemoval != null &&
          (activeAfterRemoval.activeRun ||
              activeAfterRemoval.hasWriter ||
              activeAfterRemoval.demanded)) {
        // A session may have become active after the initial guard while the
        // index mutation was awaiting storage. Do not delete its bytes merely
        // because the row disappeared during that race. Active-session body
        // authority is not represented in the durable cleanup query, so also
        // retire any provisional exact-locator cleanup intent.
        await cancelCleanupIntent();
        return false;
      }
      if (!sessionWasReset &&
          activeAfterRemoval != null &&
          activeAfterRemoval.state != DownloadState.disposed &&
          _recordPathMatchesSession(current, activeAfterRemoval)) {
        // A new session appeared for the same binding after the initial
        // snapshot. It owns the current lifecycle now; leave the physical
        // bytes untouched rather than resetting it after its row was removed.
        await cancelCleanupIntent();
        return false;
      }
      if (isReferencedByOther) {
        await cancelCleanupIntent();
        return false;
      }
      if (replicas.isNotEmpty) {
        for (final debt in sealedCleanupDebts) {
          await _cleanupObsoleteSourceNow(debt);
        }
        for (final debt in migrationCleanupDebts) {
          if (debt.kind == StorageCleanupDebtKind.temporary) {
            await _cleanupTemporaryDebtAcrossAliases(debt);
          } else {
            await _cleanupObsoleteSourceNow(debt);
          }
        }
        return true;
      }
      if (partialCleanupDebt != null) {
        await _cleanupObsoleteSourceNow(partialCleanupDebt);
        return true;
      }
      await _bytes.delete(physicalAccess.accessLocator);
      await _deleteArtifactSidecar(physicalAccess.accessLocator);
      return true;
    }

    if (active != null &&
        active.state != DownloadState.disposed &&
        !active.demanded &&
        _recordPathMatchesSession(initial, active)) {
      // Hold _resetting through the logical-row removal, reference check, and
      // physical delete. A plain resetIfIdle() releases that boundary before
      // the next await and permits a new demand to race this deletion.
      final removed = await active.resetIfIdleAndRun<bool>(
        removeCacheRecord: false,
        operation: () => removeBindingAndPhysical(sessionWasReset: true),
      );
      return removed ?? false;
    }
    return removeBindingAndPhysical(sessionWasReset: false);
  }

  bool _recordPathMatchesSession(CacheRec record, DownloadSession session) =>
      record.path == session.artifact.partialPath ||
      record.path == session.artifact.finalPath;

  Future<void> _forgetIndexedBinding(
    DownloadId id, {
    required CacheRec record,
  }) async {
    final current = await _index.get(id.key);
    if (current == null || !_sameIndexedRecord(record, current)) return;
    await _index.remove(id.key);
  }

  Future<void> _deleteArtifactSidecar(String path) async {
    await _deleteCompanionData(path);
    final parsed = parseSafRecordPath(path);
    if (parsed != null) {
      if (safTreeIo == null || safTreeUri != parsed.treeUri) return;
      await safTreeIo!.delete('${parsed.relativePath}.meta');
      return;
    }
    final metadata = File('$path.meta');
    if (await metadata.exists()) await metadata.delete();
  }

  Future<bool> _artifactSidecarExists(String path) async {
    for (final suffix in ['', '.zic-old']) {
      if (await _bytes.exists(_companionLocator(path, suffix))) return true;
    }
    final parsed = parseSafRecordPath(path);
    if (parsed != null) {
      if (safTreeIo == null || safTreeUri != parsed.treeUri) return true;
      return safTreeIo!.exists('${parsed.relativePath}.meta');
    }
    return File('$path.meta').exists();
  }

  bool _sameIndexedRecord(
    CacheRec first,
    CacheRec second, {
    bool compareRecency = true,
  }) =>
      first.id == second.id &&
      first.state == second.state &&
      first.path == second.path &&
      first.bytes == second.bytes &&
      first.checksum.trim().toLowerCase() ==
          second.checksum.trim().toLowerCase() &&
      first.createdUs == second.createdUs &&
      (!compareRecency || first.touchedUs == second.touchedUs) &&
      first.pinned == second.pinned &&
      first.checksumAlgorithm.trim().toLowerCase() ==
          second.checksumAlgorithm.trim().toLowerCase() &&
      first.effectiveArtifactId == second.effectiveArtifactId &&
      first.storageRootId == second.storageRootId;

  Future<ArtifactCacheUsage> _inspectPersistentArtifactUsage() async {
    final records = await _index.list();
    final physicalPartials = await _index.listPhysicalPartials();
    final physicalArtifacts = await _index.listPhysicalMediaArtifacts();
    final exactReadyArtifactIds = <String>{
      for (final record in records)
        if (record.state == CacheState.ready) record.effectiveArtifactId,
    };
    final additionalArtifacts = <String, int>{};
    for (final physical in physicalArtifacts) {
      if (exactReadyArtifactIds.contains(physical.artifactId)) continue;
      final previous = additionalArtifacts[physical.artifactId] ?? 0;
      if (physical.bytes > previous) {
        additionalArtifacts[physical.artifactId] = physical.bytes;
      }
    }
    final physicalArtifactIds = <PhysicalMediaId>{
      for (final physical in physicalArtifacts) physical.id,
    };
    final activePhysicalPartials = physicalPartials.where(
      (record) => !physicalArtifactIds.contains(record.id),
    );
    final physicalPartialBytes = activePhysicalPartials.fold<int>(
      0,
      (sum, record) => sum + record.bytes,
    );
    final physicalOnlyArtifactBytes = additionalArtifacts.values.fold<int>(
      0,
      (sum, bytes) => sum + bytes,
    );
    return ArtifactCacheUsage(
      bytes:
          physicalCacheBytes(records) +
          physicalPartialBytes +
          physicalOnlyArtifactBytes,
      entries:
          records.length +
          activePhysicalPartials.length +
          physicalArtifacts.length,
    );
  }

  @override
  Future<ArtifactCacheUsage> inspectArtifacts() async {
    _requireOpen();
    return _inspectPersistentArtifactUsage();
  }

  Future<({bool removed, bool dominated})>
      _evictPhysicalPartialForMaintenance(
    PhysicalPartialRecord expected, {
    bool removeIfDominated = false,
  }) => _serializePhysicalArtifactMutation(
        expected.id,
        () => _serializePhysicalPartialMutation(expected.id, () async {
          _requireOpen();
          if (_borrowedPhysicalPartialIds.contains(expected.id)) {
            throw const Failure(
              code: ErrorCode.sessionBusy,
              message: 'physical durable partial is borrowed by the transfer owner',
            );
          }
          final ready = await _index.getPhysicalMediaArtifact(expected.id);
          if (ready != null && !removeIfDominated) {
            return (removed: false, dominated: true);
          }
          final current = await _index.getPhysicalPartial(expected.id);
          if (current == null || current != expected) {
            return (removed: false, dominated: ready != null);
          }
          await _removePhysicalPartialRecord(current, deleteBody: true);
          return (removed: true, dominated: ready != null);
        }),
      );

  Future<({bool changed, bool released})>
      _evictPhysicalArtifactForMaintenance(
    PhysicalMediaArtifactRecord expected,
  ) => _serializePhysicalArtifactMutation(expected.id, () async {
        _requireOpen();
        final current = await _index.getPhysicalMediaArtifact(expected.id);
        if (current == null || current != expected) {
          return (changed: false, released: false);
        }
        // A surviving exact READY binding (pinned, busy, or created after the
        // maintenance snapshot) must retain canonical routing metadata. The
        // SQLite owner rechecks both exact references and the physical LRU
        // generation in one IMMEDIATE transaction, closing the final
        // check/delete race without rescanning the whole cache index.
        final replicas = await _index.listArtifactReplicas(current.artifactId);
        final debts = <StorageCleanupDebtRecord>[];
        for (final replica in replicas) {
          final prepared = await _prepareObsoleteSealedReplicaCleanupDebt(
            replica: replica,
            expectedBytes: current.bytes,
            expectedChecksum: current.checksum,
            expectedChecksumAlgorithm: current.checksumAlgorithm,
          );
          if (!prepared.safeToRetire) {
            await _forgetStorageCleanupDebts(debts);
            return (changed: false, released: false);
          }
          final debt = prepared.debt;
          if (debt != null) debts.add(debt);
        }
        late final bool removed;
        try {
          removed = await _index.removePhysicalMediaArtifactBindingForMaintenance(
            id: current.id,
            expectedArtifactId: current.artifactId,
            expectedTouchedUs: current.touchedUs,
          );
        } on Object {
          await _forgetStorageCleanupDebts(debts);
          rethrow;
        }
        if (!removed) {
          await _forgetStorageCleanupDebts(debts);
          return (changed: false, released: false);
        }
        for (final debt in debts) {
          await _cleanupObsoleteSourceNow(debt);
        }
        if (await _index.getArtifactObject(current.artifactId) != null) {
          return (changed: true, released: false);
        }
        return (changed: true, released: true);
      });

  Future<({int evicted, int skippedBusy, int remainingBytes})>
      _trimPhysicalPartialsTo(
    int targetBytes, {
    required int initialBytes,
  }) async {
    final values = await _index.listPhysicalPartials()
      ..sort((left, right) => left.touchedUs.compareTo(right.touchedUs));
    var evicted = 0;
    var skippedBusy = 0;
    var remainingBytes = initialBytes;
    for (final record in values) {
      if (remainingBytes <= targetBytes) break;
      if (_borrowedPhysicalPartialIds.contains(record.id)) {
        skippedBusy++;
        continue;
      }
      try {
        final result = await _evictPhysicalPartialForMaintenance(record);
        if (!result.removed || result.dominated) continue;
        evicted++;
        remainingBytes = (remainingBytes - record.bytes).clamp(0, 1 << 62);
      } on Failure catch (error) {
        if (error.code == ErrorCode.sessionBusy ||
            error.code == ErrorCode.writerBusy) {
          skippedBusy++;
          continue;
        }
        rethrow;
      }
    }
    if (evicted > 0) _notifyManagementProjectionChanged();
    return (
      evicted: evicted,
      skippedBusy: skippedBusy,
      remainingBytes: remainingBytes,
    );
  }

  Future<int> _physicalOnlyArtifactBytes() async {
    final records = await _index.list();
    final exactReadyArtifactIds = <String>{
      for (final record in records)
        if (record.state == CacheState.ready) record.effectiveArtifactId,
    };
    final bytes = <String, int>{};
    for (final physical in await _index.listPhysicalMediaArtifacts()) {
      if (exactReadyArtifactIds.contains(physical.artifactId)) continue;
      final previous = bytes[physical.artifactId] ?? 0;
      if (physical.bytes > previous) {
        bytes[physical.artifactId] = physical.bytes;
      }
    }
    return bytes.values.fold<int>(0, (sum, value) => sum + value);
  }

  Future<int> _physicalPartialBytes() async {
    final partials = await _index.listPhysicalPartials();
    final readyIds = <PhysicalMediaId>{
      for (final artifact in await _index.listPhysicalMediaArtifacts()) artifact.id,
    };
    return partials.fold<int>(
      0,
      (sum, record) =>
          readyIds.contains(record.id) ? sum : sum + record.bytes,
    );
  }

  Future<({int evicted, int remainingBytes})> _trimPhysicalArtifactsTo(
    int targetBytes, {
    required int initialBytes,
  }) async {
    final values = await _index.listPhysicalMediaArtifacts()
      ..sort((left, right) => left.touchedUs.compareTo(right.touchedUs));
    var evicted = 0;
    var remainingBytes = initialBytes;
    var changed = false;
    for (final record in values) {
      if (remainingBytes <= targetBytes) break;
      final result = await _evictPhysicalArtifactForMaintenance(record);
      changed = changed || result.changed;
      if (!result.released) continue;
      evicted++;
      remainingBytes = (remainingBytes - record.bytes).clamp(0, 1 << 62);
    }
    if (changed) _notifyManagementProjectionChanged();
    return (evicted: evicted, remainingBytes: remainingBytes);
  }

  @override
  Future<ArtifactCacheReport> trimArtifacts({
    required int maxBytes,
    required int targetBytes,
  }) async {
    _requireOpen();
    if (maxBytes < 0 || targetBytes < 0 || targetBytes > maxBytes) {
      throw ArgumentError('invalid artifact cache limits');
    }
    final before = await _inspectPersistentArtifactUsage();
    if (before.bytes <= maxBytes) {
      return ArtifactCacheReport(
        beforeBytes: before.bytes,
        releasedBytes: 0,
        remainingBytes: before.bytes,
        evictedEntries: 0,
        skippedBusy: 0,
      );
    }

    final partial = await _trimPhysicalPartialsTo(
      targetBytes,
      initialBytes: before.bytes,
    );
    var exactReport = const CacheReport(
      requestedBytes: 0,
      releasedBytes: 0,
      evicted: 0,
      skippedBusy: 0,
      skippedProtected: 0,
      remainingBytes: 0,
    );
    if (partial.remainingBytes > targetBytes) {
      final reserved =
          await _physicalOnlyArtifactBytes() + await _physicalPartialBytes();
      final exactMax = maxBytes > reserved ? maxBytes - reserved : 0;
      final exactTarget = targetBytes > reserved ? targetBytes - reserved : 0;
      exactReport = await _cacheOps.trim(
        CacheLimits(maxBytes: exactMax, targetBytes: exactTarget),
        busy: _borrowedPartialIds,
      );
    }
    // CacheOps reports only exact-index bytes. Reconcile once between phases,
    // then keep a running physical-byte total instead of rescanning all three
    // persistent indexes once for every physical artifact candidate.
    final afterExact = await _inspectPersistentArtifactUsage();
    final physicalArtifacts = await _trimPhysicalArtifactsTo(
      targetBytes,
      initialBytes: afterExact.bytes,
    );
    final after = await _inspectPersistentArtifactUsage();
    return ArtifactCacheReport(
      beforeBytes: before.bytes,
      releasedBytes: before.bytes - after.bytes,
      remainingBytes: after.bytes,
      evictedEntries:
          partial.evicted + exactReport.evicted + physicalArtifacts.evicted,
      skippedBusy: partial.skippedBusy + exactReport.skippedBusy,
    );
  }

  @override
  Future<ArtifactCacheReport> clearArtifacts() async {
    _requireOpen();
    final before = await _inspectPersistentArtifactUsage();
    final exactReport = await _cacheOps.clear(busy: _borrowedPartialIds);
    var physicalPartialEvicted = 0;
    var skippedPhysicalBusy = 0;
    var changed = false;
    for (final record in await _index.listPhysicalPartials()) {
      if (_borrowedPhysicalPartialIds.contains(record.id)) {
        skippedPhysicalBusy++;
        continue;
      }
      try {
        final result = await _evictPhysicalPartialForMaintenance(
          record,
          removeIfDominated: true,
        );
        if (!result.removed) continue;
        if (!result.dominated) physicalPartialEvicted++;
        changed = true;
      } on Failure catch (error) {
        if (error.code == ErrorCode.sessionBusy ||
            error.code == ErrorCode.writerBusy) {
          skippedPhysicalBusy++;
          continue;
        }
        rethrow;
      }
    }
    var physicalArtifactEvicted = 0;
    for (final record in await _index.listPhysicalMediaArtifacts()) {
      final result = await _evictPhysicalArtifactForMaintenance(record);
      changed = changed || result.changed;
      if (result.released) physicalArtifactEvicted++;
    }
    if (changed) _notifyManagementProjectionChanged();
    final after = await _inspectPersistentArtifactUsage();
    return ArtifactCacheReport(
      beforeBytes: before.bytes,
      releasedBytes: before.bytes - after.bytes,
      remainingBytes: after.bytes,
      evictedEntries:
          exactReport.evicted +
          physicalPartialEvicted +
          physicalArtifactEvicted,
      skippedBusy: exactReport.skippedBusy + skippedPhysicalBusy,
    );
  }

  Future<void> close() async {
    if (_closed) return;
    if (_borrowedPartialIds.isNotEmpty ||
        _borrowedPhysicalPartialIds.isNotEmpty) {
      throw StateError(
        'cannot close persistent artifact store with borrowed durable partials',
      );
    }
    _deferredRecencyTouchControl.cancel();
    _closed = true;
    try {
    // Public methods reject new work after _closed, but operations that were
    // already admitted can still enqueue a per-id/path tail while their
    // current callback is awaiting I/O. Drain every tail before disposing the
    // registry/index; otherwise a late cache mutation can touch a closed
    // SQLite handle or close an artifact while its body reader is still open.
    while (true) {
      final redundantSweep = _redundantPhysicalPartialSweep;
      final pending = <Future<void>>{
        if (redundantSweep != null) redundantSweep,
        ..._artifactWrites.values,
        ..._artifactMutationTails.values,
        ..._physicalPartialMutationTails.values,
        ..._physicalArtifactMutationTails.values,
        ..._exactArtifactTouchDrains.values,
        ..._structuredWriteTails.values,
        ..._placementWrites.values,
      };
      if (pending.isEmpty) break;
      for (final operation in pending) {
        try {
          await operation;
        } on Object {
          // The caller that initiated the operation already owns its failure;
          // close still has to establish the lifecycle barrier.
        }
      }
    }
    while (true) {
      final cleanupDebtDrain = _cleanupDebtDrain;
      if (cleanupDebtDrain == null) break;
      try {
        await cleanupDebtDrain;
      } on Object {
        // The drainer records per-item failures and must not weaken close.
      }
    }
    try {
      await _managementProjectionChanges.close();
    } finally {
      try {
        await _registry.dispose();
      } finally {
        // The metadata process owner MUST outlive the SQLite handle even when
        // an earlier close stage fails; otherwise another process could enter
        // recovery while this process still owns an open database connection.
        await _index.close();
      }
    }
    try {
      if (await _recoveryMarker.exists()) {
        await _recoveryMarker.delete();
      }
    } on Object catch (error, stackTrace) {
      // A stale marker is safe: the next process performs recovery. Keep this
      // observable because it explains a one-off slower startup after an
      // otherwise clean shutdown.
      try {
        _traceSink.record(
          traceEvent(
            clock: _clock,
            sessionId: 'persistent-artifact-store',
            kind: TraceEventKind.taskFailed,
            payload: <String, Object?>{
              'stage': 'recovery-marker-cleanup',
              'error': '$error',
              'stackTrace': '$stackTrace',
            },
          ),
        );
      } on Object {
        // Diagnostics must not turn a clean store close into a failure.
      }
    }
    } finally {
      try {
        await _metadataOwnerLock.unlock();
      } finally {
        try {
          await _metadataOwnerLock.close();
        } finally {
          _processMetadataOwners.remove(_metadataOwnerKey);
        }
      }
    }
  }

  void _requireOpen() {
    if (_closed)
      throw StateError('persistent download artifact store is closed');
  }
}

final class _StoreLifetimeTaskControl implements TaskControl {
  final Completer<void> _cancelled = Completer<void>();

  @override
  bool get cancelled => _cancelled.isCompleted;

  @override
  Future<void> get whenCancelled => _cancelled.future;

  @override
  int get priority => 0;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}
