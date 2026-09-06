import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:storage_bridge/storage_bridge.dart';

import 'saf_store.dart';
import 'startup_platform.dart';


final Map<String, StorageRootAccessAliasProof> _successfulAliasProofs =
    <String, StorageRootAccessAliasProof>{};
final Map<String, Future<StorageRootAccessAliasProof?>> _aliasProofsInFlight =
    <String, Future<StorageRootAccessAliasProof?>>{};

/// Computes an ephemeral SAF↔Direct alias proof for one Android tree.
///
/// Returning null means the tree remains SAF-only. This function never changes
/// the selected download directory or migrates bytes.
Future<StorageRootAccessAliasProof?> probeAndroidStorageRootAccessAlias(
  String treeUri, {
  String Function()? nonceFactory,
}) async {
  final normalized = treeUri.trim();
  if (normalized.isEmpty ||
      kIsWeb ||
      defaultTargetPlatform != TargetPlatform.android) {
    return null;
  }
  final proven = _successfulAliasProofs[normalized];
  if (proven != null) return proven;
  final inFlight = _aliasProofsInFlight[normalized];
  if (inFlight != null) return inFlight;

  late final Future<StorageRootAccessAliasProof?> probe;
  probe = Future<StorageRootAccessAliasProof?>(() async {
    if (!await allFilesAccessGranted()) return null;
    final directPath = await directPathForSafTree(normalized);
    if (directPath == null || directPath.isEmpty) return null;
    try {
      final proof = await proveStorageRootAccessAlias(
        direct: DirectStorageAccessLocator(directPath),
        saf: SafStorageAccessLocator(normalized),
        io: _AndroidStorageRootAliasProbeIo(SafStore(treeUri: normalized)),
        nonceFactory: nonceFactory,
      );
      if (proof != null) _successfulAliasProofs[normalized] = proof;
      return proof;
    } on Object catch (error) {
      debugPrint('storage-root SAF/Direct proof failed: $error');
      return null;
    } finally {
      if (identical(_aliasProofsInFlight[normalized], probe)) {
        _aliasProofsInFlight.remove(normalized);
      }
    }
  });
  _aliasProofsInFlight[normalized] = probe;
  return probe;
}

final class _AndroidStorageRootAliasProbeIo implements StorageRootAliasProbeIo {
  _AndroidStorageRootAliasProbeIo(this._saf);

  final SafStore _saf;

  @override
  Future<void> createDirectExclusive(
    DirectStorageAccessLocator direct,
    String relativeName,
    Uint8List bytes,
  ) async {
    final created = await createDirectProbeFileExclusive(
      directPath: direct.path,
      relativeName: relativeName,
      bytes: bytes,
    );
    if (!created) {
      throw StateError('Direct canary could not be created exclusively');
    }
  }

  @override
  Future<void> deleteDirect(
    DirectStorageAccessLocator direct,
    String relativeName,
  ) async {
    final deleted = await deleteDirectProbeFile(
      directPath: direct.path,
      relativeName: relativeName,
    );
    if (!deleted) throw StateError('Direct canary could not be deleted');
  }

  @override
  Future<Uint8List> readDirect(
    DirectStorageAccessLocator direct,
    String relativeName,
  ) async {
    final bytes = await readDirectProbeFile(
      directPath: direct.path,
      relativeName: relativeName,
    );
    if (bytes == null) throw StateError('Direct canary could not be read');
    return bytes;
  }

  @override
  Future<bool> safExists(
    SafStorageAccessLocator saf,
    String relativeName,
  ) =>
      _saf.exists(relativeName);

  @override
  Future<Uint8List> readSaf(
    SafStorageAccessLocator saf,
    String relativeName,
  ) async {
    final handle = await _saf.open(relativeName);
    if (handle == null) throw StateError('SAF canary could not be opened');
    try {
      final length = await _saf.length(handle);
      if (length == null || length < 0) {
        throw StateError('SAF canary length unavailable');
      }
      final out = BytesBuilder(copy: false);
      var remaining = length;
      while (remaining > 0) {
        final chunk = await _saf.read(handle, remaining);
        if (chunk.isEmpty) break;
        out.add(chunk);
        remaining -= chunk.lengthInBytes;
      }
      return out.takeBytes();
    } finally {
      await _saf.close(handle);
    }
  }

  @override
  Future<void> writeSafTruncate(
    SafStorageAccessLocator saf,
    String relativeName,
    Uint8List bytes,
  ) async {
    final handle = await _saf.open(
      relativeName,
      mode: SafMode.writeTruncate,
    );
    if (handle == null) throw StateError('SAF canary could not be reopened');
    try {
      await _saf.write(handle, bytes);
    } finally {
      await _saf.close(handle);
    }
  }
}
