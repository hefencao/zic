part of 'chapter_downloads.dart';

enum _SafBodyAuthorityKind { cacheBinding, physicalPartial }

final class _SafBodyReplaceIntent {
  const _SafBodyReplaceIntent({
    required this.treeUri,
    required this.targetPath,
    required this.temporaryPath,
    required this.backupPath,
    required this.hadTarget,
    required this.authorityKind,
    required this.authority,
    required this.bodyBytes,
    required this.bodyChecksum,
    required this.verifyChecksum,
  });

  factory _SafBodyReplaceIntent.decode(String source) {
    final value = jsonDecode(source);
    if (value is! Map<String, dynamic> || value['version'] != 1) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'SAF body transaction intent is invalid',
      );
    }
    final rawKind = value['authorityKind'];
    final kinds = _SafBodyAuthorityKind.values.where(
      (candidate) => candidate.name == rawKind,
    );
    final treeUri = value['treeUri'];
    final targetPath = value['targetPath'];
    final temporaryPath = value['temporaryPath'];
    final backupPath = value['backupPath'];
    final hadTarget = value['hadTarget'];
    final authority = value['authority'];
    final bodyBytes = value['bodyBytes'];
    final bodyChecksum = value['bodyChecksum'];
    final verifyChecksum = value['verifyChecksum'];
    if (kinds.length != 1 ||
        treeUri is! String ||
        treeUri.isEmpty ||
        targetPath is! String ||
        targetPath.isEmpty ||
        temporaryPath is! String ||
        temporaryPath.isEmpty ||
        backupPath is! String ||
        backupPath.isEmpty ||
        hadTarget is! bool ||
        authority is! Map ||
        bodyBytes is! int ||
        bodyBytes <= 0 ||
        bodyChecksum is! String ||
        bodyChecksum.isEmpty ||
        verifyChecksum is! bool) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'SAF body transaction intent has invalid fields',
      );
    }
    return _SafBodyReplaceIntent(
      treeUri: treeUri,
      targetPath: targetPath,
      temporaryPath: temporaryPath,
      backupPath: backupPath,
      hadTarget: hadTarget,
      authorityKind: kinds.single,
      authority: Map<String, Object?>.from(authority),
      bodyBytes: bodyBytes,
      bodyChecksum: bodyChecksum,
      verifyChecksum: verifyChecksum,
    );
  }

  final String treeUri;
  final String targetPath;
  final String temporaryPath;
  final String backupPath;
  final bool hadTarget;
  final _SafBodyAuthorityKind authorityKind;
  final Map<String, Object?> authority;
  final int bodyBytes;
  final String bodyChecksum;
  final bool verifyChecksum;

  String encode() => jsonEncode(<String, Object?>{
        'version': 1,
        'treeUri': treeUri,
        'targetPath': targetPath,
        'temporaryPath': temporaryPath,
        'backupPath': backupPath,
        'hadTarget': hadTarget,
        'authorityKind': authorityKind.name,
        'authority': authority,
        'bodyBytes': bodyBytes,
        'bodyChecksum': bodyChecksum,
        'verifyChecksum': verifyChecksum,
      });
}

Map<String, Object?> _physicalPartialAuthorityJson(
  PhysicalPartialRecord record,
) =>
    <String, Object?>{
      'physicalMedia': record.id.toJson(),
      'path': record.path,
      'bytes': record.bytes,
      'checksum': record.checksum,
      'createdUs': record.createdUs,
      'touchedUs': record.touchedUs,
      'checksumAlgorithm': record.checksumAlgorithm,
      'storageRootId': record.storageRootId,
    };

PhysicalPartialRecord _physicalPartialAuthorityFromJson(
  Map<String, Object?> json,
) {
  final rawId = json['physicalMedia'];
  if (rawId is! Map) {
    throw const FormatException('physicalMedia must be an object');
  }
  return PhysicalPartialRecord(
    id: PhysicalMediaId.fromJson(Map<String, Object?>.from(rawId)),
    path: json['path']! as String,
    bytes: json['bytes']! as int,
    checksum: json['checksum']! as String,
    createdUs: json['createdUs']! as int,
    touchedUs: json['touchedUs']! as int,
    checksumAlgorithm: (json['checksumAlgorithm'] as String?) ?? 'crc32',
    storageRootId: (json['storageRootId'] as String?) ?? 'default',
  );
}

extension _PersistentSafBodyTransactionExtension
    on _PersistentDownloadStructuredPlacementMixin {
  Directory get _safBodyTransactionDirectory =>
      Directory('$_metadataOwnerKey.saf-body-transactions');

  Future<File> _writeSafBodyTransactionIntent(
    _SafBodyReplaceIntent intent,
  ) async {
    final directory = _safBodyTransactionDirectory;
    await directory.create(recursive: true);
    final serial = _safBodyIntentSerial++;
    final stem =
        'txn-$pid-${DateTime.now().toUtc().microsecondsSinceEpoch}-$serial';
    final temporary = File('${directory.path}/.$stem.tmp');
    final target = File('${directory.path}/$stem.json');
    await temporary.writeAsString(intent.encode(), flush: true);
    await temporary.rename(target.path);
    return target;
  }

  Future<List<(File, _SafBodyReplaceIntent)>>
      _loadSafBodyTransactionIntents() async {
    final directory = _safBodyTransactionDirectory;
    if (!await directory.exists()) {
      return const <(File, _SafBodyReplaceIntent)>[];
    }
    final result = <(File, _SafBodyReplaceIntent)>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.startsWith('.') && name.endsWith('.tmp')) {
        // Runtime readers must never retire another concurrent writer's local
        // journal staging file. Store-open recovery removes orphan temps before
        // any body transaction can start.
        continue;
      }
      if (!name.endsWith('.json')) continue;
      final String encoded;
      try {
        encoded = await entity.readAsString();
      } on PathNotFoundException {
        // Another target may finish and retire its intent after enumeration.
        continue;
      }
      result.add((
        entity,
        _SafBodyReplaceIntent.decode(encoded),
      ));
    }
    return result;
  }

  Future<void> _retireOrphanSafBodyIntentTemps() async {
    final directory = _safBodyTransactionDirectory;
    if (!await directory.exists()) return;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.startsWith('.') || !name.endsWith('.tmp')) continue;
      try {
        await entity.delete();
      } on Object {
        // A later clean open can retry harmless local staging cleanup.
      }
    }
  }

  Future<void> _retireSafBodyTransactionIntent(File file) async {
    if (await file.exists()) await file.delete();
    // Keep the directory until the store drains: another page may have just
    // created it and be about to open its own durable intent staging file.
  }

  Future<bool> _safBodyAuthorityCommitted(
    _SafBodyReplaceIntent intent,
  ) async {
    if (intent.authorityKind == _SafBodyAuthorityKind.cacheBinding) {
      final expected = CacheRec.fromJson(intent.authority);
      final current = await _index.get(expected.key);
      return current != null &&
          current.id == expected.id &&
          current.state == expected.state &&
          current.path == expected.path &&
          current.bytes == expected.bytes &&
          current.checksum == expected.checksum &&
          current.checksumAlgorithm == expected.checksumAlgorithm &&
          current.effectiveArtifactId == expected.effectiveArtifactId &&
          current.storageRootId == expected.storageRootId;
    }
    final expected = _physicalPartialAuthorityFromJson(intent.authority);
    final current = await _index.getPhysicalPartial(expected.id);
    return current != null &&
        current.id == expected.id &&
        current.path == expected.path &&
        current.bytes == expected.bytes &&
        current.checksum == expected.checksum &&
        current.checksumAlgorithm == expected.checksumAlgorithm &&
        current.storageRootId == expected.storageRootId;
  }

  Future<bool> _safBodyMatchesIntent(
    SafTreeIo io,
    _SafBodyReplaceIntent intent, {
    String? relativePath,
    bool requireChecksum = false,
  }) async {
    final path = relativePath ?? intent.targetPath;
    if (!await io.exists(path)) return false;
    if (!intent.verifyChecksum && !requireChecksum) {
      final handle = await io.open(path, mode: SafWriteMode.read);
      if (handle == null) return false;
      try {
        return await io.length(handle) == intent.bodyBytes;
      } finally {
        await io.close(handle);
      }
    }
    final recordPath = encodeSafRecordPath(
      treeUri: intent.treeUri,
      relativePath: path,
    );
    final proof = await _artifactProof(recordPath);
    return proof.bytes == intent.bodyBytes &&
        proof.checksum == intent.bodyChecksum;
  }

  Future<void> _cleanupSafBodyTemporary(
    SafTreeIo io,
    _SafBodyReplaceIntent intent,
  ) async {
    if (await io.exists(intent.temporaryPath)) {
      await io.delete(intent.temporaryPath);
    }
    if (!await io.exists(intent.temporaryPath)) {
      await _forgetStorageCleanupDebt(
        encodeSafRecordPath(
          treeUri: intent.treeUri,
          relativePath: intent.temporaryPath,
        ),
      );
    }
  }

  Future<void> _recoverSafBodyIntent(
    File intentFile,
    _SafBodyReplaceIntent intent, {
    bool requireWritable = false,
    bool useStagedProof = false,
  }) async {
    final io = safTreeIo;
    final treeUri = safTreeUri;
    if (io == null || treeUri == null || intent.treeUri != treeUri) return;
    final committed = await _safBodyAuthorityCommitted(intent);
    if (committed) {
      if (!await _safBodyMatchesIntent(
        io,
        intent,
        requireChecksum: !useStagedProof,
      )) {
        // Identical partial checkpoints already match the stable index before
        // commit. A crash after backup rename can therefore leave that current
        // authority in the backup; only its full content proof permits restore.
        if (await io.exists(intent.targetPath) ||
            !intent.hadTarget ||
            !await _safBodyMatchesIntent(
              io,
              intent,
              relativePath: intent.backupPath,
              requireChecksum: true,
            )) {
          throw const Failure(
            code: ErrorCode.artifactCorruption,
            message: 'committed SAF body target disagrees with transaction',
          );
        }
        if (!await io.rename(intent.backupPath, intent.targetPath)) {
          throw const Failure(
            code: ErrorCode.policy,
            message: 'SAF current body backup could not be restored',
          );
        }
      }
      try {
        await _deleteSafPathExactly(
          io,
          intent.backupPath,
          failureMessage: 'committed SAF body backup could not be retired',
        );
        await _cleanupSafBodyTemporary(io, intent);
        await _retireSafBodyTransactionIntent(intentFile);
      } on Object {
        if (requireWritable) rethrow;
      }
      return;
    }

    if (intent.hadTarget && await io.exists(intent.backupPath)) {
      if (await io.exists(intent.targetPath)) {
        if (!await _safBodyMatchesIntent(io, intent, requireChecksum: true)) {
          throw const Failure(
            code: ErrorCode.artifactCorruption,
            message: 'uncommitted SAF body target changed externally',
          );
        }
        await _deleteSafPathExactly(
          io,
          intent.targetPath,
          failureMessage: 'uncommitted SAF body target could not be retired',
        );
      }
      if (!await io.rename(intent.backupPath, intent.targetPath)) {
        throw const Failure(
          code: ErrorCode.policy,
          message: 'SAF body rollback backup could not be restored',
        );
      }
    } else if (!intent.hadTarget && await io.exists(intent.targetPath)) {
      if (!await _safBodyMatchesIntent(io, intent, requireChecksum: true)) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'uncommitted first SAF body changed externally',
        );
      }
      await _deleteSafPathExactly(
        io,
        intent.targetPath,
        failureMessage: 'uncommitted first SAF body could not be retired',
      );
    } else if (intent.hadTarget && !await io.exists(intent.targetPath)) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'SAF body rollback lost both target and backup',
      );
    }
    try {
      await _cleanupSafBodyTemporary(io, intent);
      await _retireSafBodyTransactionIntent(intentFile);
    } on Object {
      if (requireWritable) rethrow;
    }
  }

  Future<void> _recoverSafBodyTarget(
    String targetPath, {
    bool requireWritable = false,
  }) async {
    final treeUri = safTreeUri;
    if (treeUri == null) return;
    File? matchedFile;
    _SafBodyReplaceIntent? matchedIntent;
    for (final entry in await _loadSafBodyTransactionIntents()) {
      final (file, intent) = entry;
      if (intent.treeUri != treeUri || intent.targetPath != targetPath) continue;
      if (matchedFile != null) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'multiple SAF body intents exist for one target',
        );
      }
      matchedFile = file;
      matchedIntent = intent;
    }
    if (matchedFile != null && matchedIntent != null) {
      await _recoverSafBodyIntent(
        matchedFile,
        matchedIntent,
        requireWritable: requireWritable,
      );
    }
  }

  Future<void> _recoverSafBodyTransactions() async {
    final treeUri = safTreeUri;
    if (safTreeIo == null || treeUri == null) return;
    await _retireOrphanSafBodyIntentTemps();
    for (final entry in await _loadSafBodyTransactionIntents()) {
      final (file, intent) = entry;
      if (intent.treeUri != treeUri) continue;
      await _serializeStructuredWrite(
        encodeSafRecordPath(treeUri: treeUri, relativePath: intent.targetPath),
        () => _recoverSafBodyIntent(file, intent),
      );
    }
  }

  Future<T> _commitSafBodyReplacement<T>({
    required String targetPath,
    required String temporaryPath,
    required int bodyBytes,
    required String bodyChecksum,
    required bool verifyChecksum,
    CacheRec? expectedCacheAuthority,
    PhysicalPartialRecord? expectedPhysicalAuthority,
    required Future<T> Function() commitAuthority,
  }) async {
    final io = safTreeIo;
    final treeUri = safTreeUri;
    if (io == null || treeUri == null) {
      throw StateError('SAF body replace requires a configured tree');
    }
    if ((expectedCacheAuthority == null) ==
        (expectedPhysicalAuthority == null)) {
      throw ArgumentError(
        'exactly one SAF body authority projection must be supplied',
      );
    }
    await _recoverSafBodyTarget(targetPath, requireWritable: true);
    final hadTarget = await io.exists(targetPath);
    final backupPath = '$targetPath.zic-old';
    if (await io.exists(backupPath)) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'SAF body replace found an unowned rollback backup',
      );
    }
    final intent = _SafBodyReplaceIntent(
      treeUri: treeUri,
      targetPath: targetPath,
      temporaryPath: temporaryPath,
      backupPath: backupPath,
      hadTarget: hadTarget,
      authorityKind: expectedCacheAuthority != null
          ? _SafBodyAuthorityKind.cacheBinding
          : _SafBodyAuthorityKind.physicalPartial,
      authority: expectedCacheAuthority?.toJson() ??
          _physicalPartialAuthorityJson(expectedPhysicalAuthority!),
      bodyBytes: bodyBytes,
      bodyChecksum: bodyChecksum,
      verifyChecksum: verifyChecksum,
    );
    final intentFile = await _writeSafBodyTransactionIntent(intent);
    late final T result;
    try {
      if (hadTarget) {
        final backedUp = await _withStorageWriteQuantum(
          () => io.rename(targetPath, backupPath),
        );
        if (!backedUp) {
          throw const Failure(
            code: ErrorCode.policy,
            message: 'SAF provider refused body backup rename',
          );
        }
      }
      final installed = await _withStorageWriteQuantum(
        () => io.rename(temporaryPath, targetPath),
      );
      if (!installed) {
        throw const Failure(
          code: ErrorCode.policy,
          message: 'SAF provider refused staged body commit rename',
        );
      }
      if (!await _safBodyMatchesIntent(io, intent)) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'SAF body changed before authority commit',
        );
      }
      result = await commitAuthority();
    } catch (_) {
      try {
        await _recoverSafBodyIntent(
          intentFile,
          intent,
          requireWritable: true,
        );
      } on Object {
        // Keep the durable intent for the next-open recovery pass.
      }
      rethrow;
    }
    try {
      await _recoverSafBodyIntent(
        intentFile,
        intent,
        requireWritable: true,
        // Only this still-live, verified staging/commit owns the copy proof.
        // Reopened intents and exception recovery must independently read CRC.
        useStagedProof: true,
      );
    } on Object {
      // Index authority is already committed. The durable intent makes backup
      // and temp cleanup replayable without rolling the body back.
    }
    return result;
  }
}
