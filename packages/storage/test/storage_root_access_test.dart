import 'dart:typed_data';

import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  const direct = DirectStorageAccessLocator('/storage/emulated/current/Books');
  const saf = SafStorageAccessLocator(
    'content://com.android.externalstorage.documents/tree/primary%3ABooks',
  );

  test('newest proven Direct alias wins after a removable-volume remount', () {
    const oldDirect = StorageAccessLocatorRecord(
      rootId: 'tree',
      kind: StorageAccessLocatorKind.direct,
      locator: '/mnt/media-old/Books',
      health: StorageAccessHealth.healthy,
      verifiedUs: 10,
      touchedUs: 10,
    );
    const newDirect = StorageAccessLocatorRecord(
      rootId: 'tree',
      kind: StorageAccessLocatorKind.direct,
      locator: '/mnt/media-new/Books',
      health: StorageAccessHealth.healthy,
      verifiedUs: 20,
      touchedUs: 20,
    );
    const safAccess = StorageAccessLocatorRecord(
      rootId: 'tree',
      kind: StorageAccessLocatorKind.saf,
      locator: 'content://tree/CAFE-BEEF%3ABooks',
      health: StorageAccessHealth.healthy,
      verifiedUs: 20,
      touchedUs: 20,
    );
    final ordered = <StorageAccessLocatorRecord>[oldDirect, safAccess, newDirect]
      ..sort(compareStorageAccessPreference);

    expect(ordered, <StorageAccessLocatorRecord>[newDirect, oldDirect, safAccess]);
  });

  test('denied Direct alias stays behind a healthy SAF fallback', () {
    const deniedDirect = StorageAccessLocatorRecord(
      rootId: 'tree',
      kind: StorageAccessLocatorKind.direct,
      locator: '/mnt/denied/Books',
      health: StorageAccessHealth.accessDenied,
      verifiedUs: 30,
      touchedUs: 30,
    );
    const safAccess = StorageAccessLocatorRecord(
      rootId: 'tree',
      kind: StorageAccessLocatorKind.saf,
      locator: 'content://tree/CAFE-BEEF%3ABooks',
      health: StorageAccessHealth.healthy,
      verifiedUs: 20,
      touchedUs: 20,
    );
    final ordered = <StorageAccessLocatorRecord>[deniedDirect, safAccess]
      ..sort(compareStorageAccessPreference);

    expect(ordered.first, safAccess);
  });

  test('proves one root only after Direct→SAF and SAF→Direct visibility',
      () async {
    final io = _AliasProbeIo(shared: true);

    final proof = await proveStorageRootAccessAlias(
      direct: direct,
      saf: saf,
      io: io,
      nonceFactory: () => '0123456789abcdef',
    );

    expect(proof, isNotNull);
    expect(proof!.direct, same(direct));
    expect(proof.saf, same(saf));
    expect(io.safWrites, 1);
    expect(io.directFiles, isEmpty, reason: 'probe canary must be removed');
    expect(io.safFiles, isEmpty, reason: 'same-root cleanup is visible via SAF');
  });

  test('different roots fail before SAF is allowed to write', () async {
    final io = _AliasProbeIo(shared: false);

    final proof = await proveStorageRootAccessAlias(
      direct: direct,
      saf: saf,
      io: io,
      nonceFactory: () => 'fedcba9876543210',
    );

    expect(proof, isNull);
    expect(io.safWrites, 0);
    expect(io.directFiles, isEmpty);
    expect(io.safFiles, isEmpty);
  });

  test('pre-existing SAF name is never overwritten', () async {
    final io = _AliasProbeIo(shared: false);
    const nonce = 'aaaaaaaa11111111';
    final name = '.zic-root-proof-$nonce.tmp';
    final userBytes = Uint8List.fromList(<int>[9, 8, 7]);
    io.safFiles[name] = userBytes;

    final proof = await proveStorageRootAccessAlias(
      direct: direct,
      saf: saf,
      io: io,
      nonceFactory: () => nonce,
    );

    expect(proof, isNull);
    expect(io.directCreates, 0);
    expect(io.safWrites, 0);
    expect(io.safFiles[name], userBytes);
  });

  test('SAF cannot mutate a canary whose Direct token does not match', () async {
    final io = _AliasProbeIo(shared: true, corruptSafRead: true);

    final proof = await proveStorageRootAccessAlias(
      direct: direct,
      saf: saf,
      io: io,
      nonceFactory: () => 'bbbbbbbb22222222',
    );

    expect(proof, isNull);
    expect(io.safWrites, 0);
    expect(io.directFiles, isEmpty);
  });


  test('SAF rewrite still requires Direct readback before proof succeeds',
      () async {
    final io = _AliasProbeIo(shared: true, corruptDirectRead: true);

    final proof = await proveStorageRootAccessAlias(
      direct: direct,
      saf: saf,
      io: io,
      nonceFactory: () => 'cccccccc33333333',
    );

    expect(proof, isNull);
    expect(io.safWrites, 1);
    expect(io.directFiles, isEmpty, reason: 'failed proof still cleans canary');
  });
}

final class _AliasProbeIo implements StorageRootAliasProbeIo {
  _AliasProbeIo({
    required this.shared,
    this.corruptSafRead = false,
    this.corruptDirectRead = false,
  });

  final bool shared;
  final bool corruptSafRead;
  final bool corruptDirectRead;
  final Map<String, Uint8List> directFiles = <String, Uint8List>{};
  final Map<String, Uint8List> safFiles = <String, Uint8List>{};
  int directCreates = 0;
  int safWrites = 0;

  Map<String, Uint8List> get _safView => shared ? directFiles : safFiles;

  @override
  Future<void> createDirectExclusive(
    DirectStorageAccessLocator direct,
    String relativeName,
    Uint8List bytes,
  ) async {
    directCreates++;
    if (directFiles.containsKey(relativeName)) {
      throw StateError('direct canary already exists');
    }
    directFiles[relativeName] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> deleteDirect(
    DirectStorageAccessLocator direct,
    String relativeName,
  ) async {
    directFiles.remove(relativeName);
  }

  @override
  Future<Uint8List> readDirect(
    DirectStorageAccessLocator direct,
    String relativeName,
  ) async =>
      corruptDirectRead
          ? Uint8List.fromList(<int>[4, 5, 6])
          : Uint8List.fromList(directFiles[relativeName] ?? const <int>[]);

  @override
  Future<Uint8List> readSaf(
    SafStorageAccessLocator saf,
    String relativeName,
  ) async {
    if (corruptSafRead) return Uint8List.fromList(<int>[1, 2, 3]);
    return Uint8List.fromList(_safView[relativeName] ?? const <int>[]);
  }

  @override
  Future<bool> safExists(
    SafStorageAccessLocator saf,
    String relativeName,
  ) async =>
      _safView.containsKey(relativeName);

  @override
  Future<void> writeSafTruncate(
    SafStorageAccessLocator saf,
    String relativeName,
    Uint8List bytes,
  ) async {
    safWrites++;
    if (!_safView.containsKey(relativeName)) {
      throw StateError('SAF canary was not proven before write');
    }
    _safView[relativeName] = Uint8List.fromList(bytes);
  }
}
