part of 'chapter_downloads.dart';

/// Optional opaque application data travels with a sealed physical image.
/// Its consumer validates the format and image digest; it is never image proof.
extension PersistentDownloadCompanionData on PersistentDownloadArtifactStore {
  static const _companionByteLimit = 64 * 1024 * 1024;

  Future<Uint8List?> readArtifactCompanion(DownloadId id) =>
      _serializeArtifactMutation(id, () async {
        _requireOpen();
        final record = await _index.get(id.key);
        if (record == null || record.id != id || !_isVerifiedReadyRecord(record)) return null;
        return _serializeArtifactReplicaMutation(record.effectiveArtifactId, () async {
          for (final replica in await _resolveArtifactReplicas(record)) {
            for (final candidate in await _artifactAccessCandidates(replica)) {
              try {
                if (!await _artifactRecordExists(candidate.access)) continue;
                final bytes = await _readCompanionAt(candidate.access.accessLocator);
                if (bytes != null) return bytes;
              } on Object {
                // Another proven access path may still carry the companion.
              }
            }
          }
          return null;
        });
      });

  Future<void> writeArtifactCompanion(DownloadId id, Uint8List bytes) =>
      _serializeArtifactMutation(id, () async {
        _requireOpen();
        if (bytes.isEmpty || bytes.length > _companionByteLimit) {
          throw ArgumentError.value(bytes.length, 'bytes.length', 'invalid companion size');
        }
        final record = await _index.get(id.key);
        if (record == null || record.id != id || !_isVerifiedReadyRecord(record)) return;
        await _serializeArtifactReplicaMutation(record.effectiveArtifactId, () async {
          for (final replica in await _resolveArtifactReplicas(record)) {
            for (final candidate in await _artifactAccessCandidates(replica)) {
              if (!await _artifactRecordExists(candidate.access)) continue;
              await _serializeStructuredWrite(candidate.access.accessLocator,
                () => _writeCompanionAt(candidate.access.accessLocator, bytes,
                  storageRootId: candidate.access.storageRootId));
              break;
            }
          }
        });
      });

  String _companionLocator(String imageLocator, [String suffix = '']) {
    final saf = parseSafRecordPath(imageLocator);
    return saf == null ? '$imageLocator.zic-data$suffix' : encodeSafRecordPath(
      treeUri: saf.treeUri, relativePath: '${saf.relativePath}.zic-data$suffix');
  }

  Future<Uint8List?> _readCompanionAt(String imageLocator) async {
    for (final suffix in ['', '.zic-old']) {
      final locator = _companionLocator(imageLocator, suffix);
      if (!await _bytes.exists(locator)) continue;
      final length = await _bytes.length(locator);
      if (length <= 0 || length > _companionByteLimit) continue;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in _bytes.readChunks(locator, start: 0, endExclusive: length)) {
        builder.add(chunk);
        if (builder.length > length) throw StateError('companion length changed');
      }
      if (builder.length != length) throw StateError('companion read was incomplete');
      return builder.takeBytes();
    }
    return null;
  }

  Future<void> _writeCompanionAt(String imageLocator, Uint8List bytes,
      {required String storageRootId}) async {
    final target = _companionLocator(imageLocator);
    final backup = _companionLocator(imageLocator, '.zic-old');
    final temporary = _companionLocator(imageLocator,
      '.zic-tmp-${DateTime.now().microsecondsSinceEpoch}');
    final saf = parseSafRecordPath(target);
    if (saf == null) {
      _rejectLocalPathLinks(target);
      _rejectLocalPathLinks(temporary);
    } else if (safTreeIo == null || saf.treeUri != safTreeUri) {
      throw StateError('companion SAF tree is unavailable');
    }
    await _registerActiveTemporaryCleanupDebt(temporary, storageRootId: storageRootId);
    try {
      final existing = await _readCompanionAt(imageLocator);
      if (existing != null && await _sameCompanionBytes(existing, bytes)) return;
      if (saf == null) {
        final file = await _withStorageWriteQuantum(() => File(temporary).open(mode: FileMode.write));
        try {
          for (var offset = 0; offset < bytes.length; offset += 256 * 1024) {
            final end = (offset + 256 * 1024).clamp(0, bytes.length);
            await _withStorageWriteQuantum(() => file.writeFrom(bytes, offset, end));
          }
          await _withStorageWriteQuantum(file.flush);
        } finally {
          await file.close();
        }
        await _withStorageWriteQuantum(() => File(temporary).rename(target));
      } else {
        final io = safTreeIo!;
        final temp = parseSafRecordPath(temporary)!.relativePath;
        final old = parseSafRecordPath(backup)!.relativePath;
        final handle = await _withStorageWriteQuantum(() => io.open(temp,
          mode: SafWriteMode.writeTruncate));
        if (handle == null) throw StateError('companion staging file is unavailable');
        try {
          for (var offset = 0; offset < bytes.length; offset += 256 * 1024) {
            final end = (offset + 256 * 1024).clamp(0, bytes.length);
            await _withStorageWriteQuantum(() => io.write(handle, Uint8List.sublistView(bytes, offset, end)));
          }
        } finally {
          await io.close(handle);
        }
        if (await io.exists(saf.relativePath)) {
          if (await io.exists(old) && !await io.delete(old)) {
            throw StateError('companion backup could not be retired');
          }
          if (!await io.rename(saf.relativePath, old)) throw StateError('companion backup failed');
        }
        try {
          if (!await io.rename(temp, saf.relativePath)) throw StateError('companion commit failed');
        } on Object {
          if (!await io.exists(saf.relativePath) && await io.exists(old)) {
            await io.rename(old, saf.relativePath);
          }
          rethrow;
        }
        if (await io.exists(old)) await io.delete(old);
      }
    } finally {
      if (await _bytes.exists(temporary)) {
        await _withStorageWriteQuantum(() => _bytes.delete(temporary));
      }
      if (!await _bytes.exists(temporary)) await _forgetStorageCleanupDebt(temporary);
    }
  }

  Future<bool> _sameCompanionBytes(Uint8List first, Uint8List second) async {
    if (first.length != second.length) return false;
    for (var offset = 0; offset < first.length; offset += 256 * 1024) {
      final end = (offset + 256 * 1024).clamp(0, first.length);
      for (var index = offset; index < end; index++) {
        if (first[index] != second[index]) return false;
      }
      await Future<void>.delayed(Duration.zero);
    }
    return true;
  }

  Future<void> _copyCompanionData(List<_ArtifactAccessCandidate> sources,
      String destination, {required String storageRootId, TaskControl? control}) =>
      _copyCompanionLocators(sources.map((source) => source.access.accessLocator),
        destination, storageRootId: storageRootId, control: control);

  Future<void> _copyCompanionLocators(Iterable<String> sources,
      String destination, {required String storageRootId, TaskControl? control}) async {
    for (final source in sources) {
      control?.throwIfCancelled();
      final bytes = await _readCompanionAt(source);
      if (bytes == null) continue;
      final existing = await _readCompanionAt(destination);
      if (existing != null && !await _sameCompanionBytes(existing, bytes)) {
        throw StateError('replica destination contains different companion data');
      }
      if (existing == null) await _writeCompanionAt(destination, bytes, storageRootId: storageRootId);
      return;
    }
  }

  Future<void> _deleteCompanionData(String imageLocator) async {
    for (final suffix in ['', '.zic-old']) {
      final locator = _companionLocator(imageLocator, suffix);
      if (await _bytes.exists(locator)) await _bytes.delete(locator);
    }
  }
}
