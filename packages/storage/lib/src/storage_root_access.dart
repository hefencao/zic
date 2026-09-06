import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

sealed class StorageAccessLocator {
  const StorageAccessLocator(this.value);

  final String value;
}

final class DirectStorageAccessLocator extends StorageAccessLocator {
  const DirectStorageAccessLocator(super.path);

  String get path => value;
}

final class SafStorageAccessLocator extends StorageAccessLocator {
  const SafStorageAccessLocator(super.treeUri);

  String get treeUri => value;
}

/// Ephemeral proof that two access locators observed the same physical root.
///
/// The proof does not create storage ownership or choose a preferred access
/// path. Persisting root identity/health belongs to the later StorageRoot
/// registry boundary.
final class StorageRootAccessAliasProof {
  const StorageRootAccessAliasProof({
    required this.direct,
    required this.saf,
  });

  final DirectStorageAccessLocator direct;
  final SafStorageAccessLocator saf;
}

/// Minimal I/O needed to prove that one Direct and one SAF locator address the
/// same physical directory. Implementations must create the Direct canary
/// exclusively so an existing user file can never be overwritten.
abstract interface class StorageRootAliasProbeIo {
  Future<bool> safExists(SafStorageAccessLocator saf, String relativeName);

  Future<Uint8List> readSaf(
    SafStorageAccessLocator saf,
    String relativeName,
  );

  Future<void> writeSafTruncate(
    SafStorageAccessLocator saf,
    String relativeName,
    Uint8List bytes,
  );

  Future<void> createDirectExclusive(
    DirectStorageAccessLocator direct,
    String relativeName,
    Uint8List bytes,
  );

  Future<Uint8List> readDirect(
    DirectStorageAccessLocator direct,
    String relativeName,
  );

  Future<void> deleteDirect(
    DirectStorageAccessLocator direct,
    String relativeName,
  );
}

/// Proves SAF↔Direct aliasing without trusting URI/path similarity.
///
/// SAF is only allowed to mutate the canary after it has read the exact token
/// that this call created exclusively through Direct access. A mismatched root
/// therefore fails before any SAF write occurs. The canary is always deleted
/// through Direct access before this future completes.
Future<StorageRootAccessAliasProof?> proveStorageRootAccessAlias({
  required DirectStorageAccessLocator direct,
  required SafStorageAccessLocator saf,
  required StorageRootAliasProbeIo io,
  String Function()? nonceFactory,
}) async {
  if (direct.path.trim().isEmpty || saf.treeUri.trim().isEmpty) {
    throw ArgumentError('storage access locators must not be empty');
  }
  final nonce = (nonceFactory ?? _randomProbeNonce).call();
  if (!RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(nonce)) {
    throw ArgumentError.value(nonce, 'nonce', 'invalid storage-root probe nonce');
  }
  final relativeName = '.zic-root-proof-$nonce.tmp';
  final directToken = Uint8List.fromList(
    utf8.encode('zic-root-proof-direct:$nonce'),
  );
  final safToken = Uint8List.fromList(
    utf8.encode('zic-root-proof-saf:$nonce'),
  );

  // If SAF already exposes this cryptographically-random name, do not touch
  // either side. Direct creation below is exclusive as the second collision
  // guard.
  if (await io.safExists(saf, relativeName)) return null;

  var directCreated = false;
  try {
    await io.createDirectExclusive(direct, relativeName, directToken);
    directCreated = true;

    if (!await io.safExists(saf, relativeName)) return null;
    final viaSaf = await io.readSaf(saf, relativeName);
    if (!_sameBytes(viaSaf, directToken)) return null;

    // SAF may only write after the previous read proved that this document is
    // the exact canary just created by this call, never an unrelated user file.
    await io.writeSafTruncate(saf, relativeName, safToken);
    final viaDirect = await io.readDirect(direct, relativeName);
    if (!_sameBytes(viaDirect, safToken)) return null;

    return StorageRootAccessAliasProof(direct: direct, saf: saf);
  } finally {
    if (directCreated) {
      await io.deleteDirect(direct, relativeName);
    }
  }
}

String _randomProbeNonce() {
  final random = Random.secure();
  final out = StringBuffer();
  for (var index = 0; index < 16; index++) {
    out.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

bool _sameBytes(Uint8List left, Uint8List right) {
  if (left.lengthInBytes != right.lengthInBytes) return false;
  for (var index = 0; index < left.lengthInBytes; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
