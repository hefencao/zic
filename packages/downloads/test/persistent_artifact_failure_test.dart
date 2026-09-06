import 'dart:io';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:test/test.dart';

void main() {
  test('persistent preflight reports lengthChanged with replica identity', () async {
    final root = await Directory.systemTemp.createTemp('zic-replica-length-');
    final store = await PersistentDownloadArtifactStore.open(root.path);
    addTearDown(() async {
      await store.close();
      await root.delete(recursive: true);
    });
    final id = _id('length-changed');
    final bytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6]);
    await store.storePromotedArtifact(id: id, bytes: bytes);
    final record = (await store.indexedRecords()).values.single;
    await File(record.path).writeAsBytes(<int>[1, 2, 3], flush: true);

    await expectLater(
      store.openArtifactStream(id),
      throwsA(
        isA<ArtifactReadFailure>()
            .having(
              (failure) => failure.kind,
              'kind',
              ArtifactReadFailureKind.lengthChanged,
            )
            .having(
              (failure) => failure.replicaId,
              'replicaId',
              record.effectiveArtifactId,
            )
            .having(
              (failure) => failure.expectedLength,
              'expectedLength',
              bytes.lengthInBytes,
            )
            .having(
              (failure) => failure.observedLength,
              'observedLength',
              3,
            ),
      ),
    );
    expect((await store.indexedRecords()).containsKey(id.key), isFalse);
  });

  test('accessDenied preserves the replica binding for later permission recovery', () async {
    final root = await Directory.systemTemp.createTemp('zic-replica-denied-');
    final id = _id('access-denied');
    final first = await PersistentDownloadArtifactStore.open(root.path);
    await first.storePromotedArtifact(
      id: id,
      bytes: Uint8List.fromList(<int>[7, 8, 9, 10]),
    );
    final record = (await first.indexedRecords()).values.single;
    await first.close();

    final denied = await PersistentDownloadArtifactStore.open(
      root.path,
      bytes: const _AccessDeniedArtifactBytes(),
    );
    addTearDown(() async {
      await denied.close();
      await root.delete(recursive: true);
    });

    await expectLater(
      denied.openArtifactStream(id),
      throwsA(
        isA<ArtifactReadFailure>()
            .having(
              (failure) => failure.kind,
              'kind',
              ArtifactReadFailureKind.accessDenied,
            )
            .having(
              (failure) => failure.replicaId,
              'replicaId',
              record.effectiveArtifactId,
            ),
      ),
    );
    expect((await denied.indexedRecords()).containsKey(id.key), isTrue);
    expect(await File(record.path).exists(), isTrue);
  });

  test('mid-stream failure keeps emitted offset and replica identity', () async {
    final root = await Directory.systemTemp.createTemp('zic-replica-stream-');
    final store = await PersistentDownloadArtifactStore.open(root.path);
    addTearDown(() async {
      await store.close();
      await root.delete(recursive: true);
    });
    final id = _id('mid-stream');
    final bytes = Uint8List(700 * 1024);
    for (var index = 0; index < bytes.length; index++) {
      bytes[index] = index & 0xff;
    }
    await store.storePromotedArtifact(id: id, bytes: bytes);
    final record = (await store.indexedRecords()).values.single;
    final entry = await store.openArtifactStream(id);
    expect(entry, isNotNull);
    await File(record.path).writeAsBytes(
      bytes.sublist(0, 256 * 1024),
      flush: true,
    );

    var emitted = 0;
    Object? failure;
    try {
      await for (final chunk
          in entry!.open(start: 0, endExclusive: entry.length)) {
        emitted += chunk.length;
      }
    } catch (error) {
      failure = error;
    }

    expect(emitted, 256 * 1024);
    expect(
      failure,
      isA<ArtifactReadFailure>()
          .having(
            (value) => value.kind,
            'kind',
            ArtifactReadFailureKind.shortRead,
          )
          .having(
            (value) => value.replicaId,
            'replicaId',
            record.effectiveArtifactId,
          )
          .having(
            (value) => value.failedOffset,
            'failedOffset',
            256 * 1024,
          )
          .having(
            (value) => value.bytesEmitted,
            'bytesEmitted',
            256 * 1024,
          ),
    );
  });
}

DownloadId _id(String pageId) => DownloadId(
      content: ContentId(
        sourceId: 'typed-read-source',
        comicId: 'typed-read-comic',
        chapterId: 'typed-read-chapter',
        pageId: pageId,
      ),
      sourceRevision: 'typed-read-r1',
      canonicalUri: Uri.parse('https://example.invalid/$pageId.bin'),
    );

final class _AccessDeniedArtifactBytes implements ArtifactBytes {
  const _AccessDeniedArtifactBytes();

  @override
  Future<bool> exists(String path) async {
    throw ArtifactReadFailure(
      kind: ArtifactReadFailureKind.accessDenied,
      accessLocator: path,
      failedOffset: 0,
      bytesEmitted: 0,
    );
  }

  @override
  Future<int> length(String path) => const LocalArtifactBytes().length(path);

  @override
  Stream<Uint8List> readChunks(
    String path, {
    required int start,
    int? endExclusive,
  }) =>
      const LocalArtifactBytes().readChunks(
        path,
        start: start,
        endExclusive: endExclusive,
      );

  @override
  Future<void> delete(String path) => const LocalArtifactBytes().delete(path);
}
