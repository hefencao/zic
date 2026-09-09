import 'dart:io';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:test/test.dart';

void main() {
  test('E-Hentai version URLs reuse only matching unique image keys', () async {
    final oldChapter = _chapter(
      comicId: 'https://e-hentai.org/g/1/old/',
      revision: 'old',
      urls: const <String>[
        'https://e-hentai.org/s/aaaaaaaaaaaaaaaa/1-1',
        'https://e-hentai.org/s/bbbbbbbbbbbbbbbb/1-2',
      ],
    );
    final newChapter = _chapter(
      comicId: 'https://e-hentai.org/g/2/new/',
      revision: 'new',
      urls: const <String>[
        'https://e-hentai.org/s/aaaaaaaaaaaaaaaa/2-1',
        'https://e-hentai.org/s/cccccccccccccccc/2-2',
      ],
    );
    final oldId = readerPageDownloadId(oldChapter, oldChapter.pages.first);
    final newId = readerPageDownloadId(newChapter, newChapter.pages.first);
    final backend = _Backend(<DownloadId, Uint8List>{
      oldId: Uint8List.fromList(<int>[1, 2, 3]),
    });
    final cache = ArtifactCacheManager(backend: backend);

    final plan = VerifiedArtifactReusePlan.match(
      oldChapter: oldChapter,
      newChapter: newChapter,
    );

    expect(plan.mappings, <DownloadId, DownloadId>{newId: oldId});
    expect(plan.registerEquivalences(cache), 1);
    expect((await cache.readForeground(newId))?.bytes, <int>[1, 2, 3]);
  });

  test('equivalence registration is independent of current artifact existence',
      () async {
    final oldChapter = _chapter(
      comicId: 'old',
      revision: 'old',
      urls: const <String>[
        'https://e-hentai.org/s/aaaaaaaaaaaaaaaa/1-1',
        'https://e-hentai.org/s/bbbbbbbbbbbbbbbb/1-2',
      ],
    );
    final newChapter = _chapter(
      comicId: 'new',
      revision: 'new',
      urls: const <String>[
        'https://e-hentai.org/s/aaaaaaaaaaaaaaaa/2-1',
        'https://e-hentai.org/s/bbbbbbbbbbbbbbbb/2-2',
      ],
    );
    final oldFirst = readerPageDownloadId(oldChapter, oldChapter.pages.first);
    final newFirst = readerPageDownloadId(newChapter, newChapter.pages.first);
    final newSecond = readerPageDownloadId(newChapter, newChapter.pages.last);
    final cache = ArtifactCacheManager(
      backend: _Backend(<DownloadId, Uint8List>{
        oldFirst: Uint8List.fromList(<int>[7, 7, 7]),
      }),
    );
    final plan = VerifiedArtifactReusePlan.match(
      oldChapter: oldChapter,
      newChapter: newChapter,
    );

    expect(plan.registerEquivalences(cache), 2);
    expect((await cache.readForeground(newFirst))?.bytes, <int>[7, 7, 7]);
    expect(await cache.readForeground(newSecond), isNull);
  });

  test('version migration materializes verified artifacts under target keys',
      () async {
    final oldChapter = _chapter(
      comicId: 'old',
      revision: 'old',
      urls: const <String>[
        'https://e-hentai.org/s/aaaaaaaaaaaaaaaa/1-1',
      ],
    );
    final newChapter = _chapter(
      comicId: 'new',
      revision: 'new',
      urls: const <String>[
        'https://e-hentai.org/s/aaaaaaaaaaaaaaaa/2-1',
      ],
    );
    final oldId = readerPageDownloadId(oldChapter, oldChapter.pages.single);
    final newId = readerPageDownloadId(newChapter, newChapter.pages.single);
    final backend = _Backend(<DownloadId, Uint8List>{
      oldId: Uint8List.fromList(<int>[4, 5, 6]),
    });
    final plan = VerifiedArtifactReusePlan.match(
      oldChapter: oldChapter,
      newChapter: newChapter,
    );

    expect(
      await plan.materializeTargetArtifacts(
        ArtifactCacheManager(backend: backend),
      ),
      1,
    );

    final reopened = ArtifactCacheManager(backend: backend);
    expect((await reopened.readForeground(newId))?.bytes, <int>[4, 5, 6]);
    expect(await reopened.lookupAuthoritative(oldId), isNotNull);
  });

  test('persistent migration binds verified artifact without body copy and survives reopen',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-zero-copy-version-migration-',
    );
    addTearDown(() => root.delete(recursive: true));
    final recordingBytes = _RecordingArtifactBytes();
    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      bytes: recordingBytes,
    );
    addTearDown(store.close);
    final cache = ArtifactCacheManager(backend: store);
    final oldChapter = _chapter(
      comicId: 'persistent-old',
      revision: 'old',
      urls: const <String>[
        'https://e-hentai.org/s/aaaaaaaaaaaaaaaa/1-1',
      ],
    );
    final newChapter = _chapter(
      comicId: 'persistent-new',
      revision: 'new',
      urls: const <String>[
        'https://e-hentai.org/s/aaaaaaaaaaaaaaaa/2-1',
      ],
    );
    final oldId = readerPageDownloadId(oldChapter, oldChapter.pages.single);
    final newId = readerPageDownloadId(newChapter, newChapter.pages.single);
    final bytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x18, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
    ]);
    await cache.storePromotedArtifact(id: oldId, bytes: bytes);
    var source = await store.index.get(oldId.key);
    expect(source, isNotNull);
    await store.index.put(source!.copyWith(pinned: true));
    source = await store.index.get(oldId.key);
    recordingBytes.resetReadCounters();

    final plan = VerifiedArtifactReusePlan.match(
      oldChapter: oldChapter,
      newChapter: newChapter,
    );
    expect(await plan.materializeTargetArtifacts(cache), 1);

    final target = await store.index.get(newId.key);
    expect(target, isNotNull);
    expect(source!.pinned, isTrue);
    expect(target!.pinned, isFalse,
        reason: 'target cache reuse must not inherit source offline retention');
    expect(target.effectiveArtifactId, source.effectiveArtifactId);
    expect(target.path, source.path);
    expect(
      await store.artifactReplicasFor(newId),
      hasLength(1),
      reason: 'target exact identity must not create a second body replica',
    );
    expect(recordingBytes.existsCalls, greaterThan(0));
    expect(recordingBytes.lengthCalls, greaterThan(0));
    expect(recordingBytes.readChunkCalls, 0,
        reason: 'migration preflight may stat but must not read the body');
    expect(recordingBytes.readBytes, 0);

    await store.close();
    final reopened = await PersistentDownloadArtifactStore.open(root.path);
    addTearDown(reopened.close);
    final reopenedCache = ArtifactCacheManager(backend: reopened);
    final lookup = await reopenedCache.lookupAuthoritative(newId);
    expect(lookup, isNotNull);
    expect(lookup!.storageId, newId,
        reason: 'the target is now its own exact durable logical authority');
    expect((await reopenedCache.readForeground(newId))?.bytes, bytes);

    final replacement = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x18, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x4c,
    ]);
    await reopenedCache.storePromotedArtifact(id: newId, bytes: replacement);
    final reboundSource = await reopened.index.get(oldId.key);
    final reboundTarget = await reopened.index.get(newId.key);
    expect(reboundSource, isNotNull);
    expect(reboundTarget, isNotNull);
    expect(reboundTarget!.effectiveArtifactId,
        isNot(reboundSource!.effectiveArtifactId),
        reason: 'a later exact target write must detach from shared authority');
    expect((await reopenedCache.readForeground(oldId))?.bytes, bytes);
    expect((await reopenedCache.readForeground(newId))?.bytes, replacement);
  });

  test('checksum reuse includes algorithm and normalizes digest case', () {
    final oldChapter = _chapter(
      comicId: 'old-checksum',
      revision: 'old',
      urls: const <String>['https://cdn.invalid/old-page'],
      checksums: const <String?>['AaBbCcDd'],
      checksumAlgorithms: const <String?>['MD5'],
    );
    final sameAlgorithm = _chapter(
      comicId: 'new-checksum',
      revision: 'new',
      urls: const <String>['https://cdn.invalid/new-page'],
      checksums: const <String?>['aabbccdd'],
      checksumAlgorithms: const <String?>['md5'],
    );
    final differentAlgorithm = _chapter(
      comicId: 'new-checksum-sha',
      revision: 'new',
      urls: const <String>['https://cdn.invalid/new-page'],
      checksums: const <String?>['aabbccdd'],
      checksumAlgorithms: const <String?>['sha1'],
    );

    expect(
      VerifiedArtifactReusePlan.match(
        oldChapter: oldChapter,
        newChapter: sameAlgorithm,
      ).mappings,
      hasLength(1),
    );
    expect(
      VerifiedArtifactReusePlan.match(
        oldChapter: oldChapter,
        newChapter: differentAlgorithm,
      ).mappings,
      isEmpty,
    );
    expect(
      verifiedPageIdentity(oldChapter.pages.single),
      'checksum:md5:aabbccdd',
    );
  });

  test('untyped checksums never create reuse aliases', () {
    final oldChapter = _chapter(
      comicId: 'old-untyped-checksum',
      revision: 'old',
      urls: const <String>['https://cdn.invalid/old-page'],
      checksums: const <String?>['same-token'],
    );
    final newChapter = _chapter(
      comicId: 'new-untyped-checksum',
      revision: 'new',
      urls: const <String>['https://cdn.invalid/new-page'],
      checksums: const <String?>['same-token'],
    );

    expect(
      VerifiedArtifactReusePlan.match(
        oldChapter: oldChapter,
        newChapter: newChapter,
      ).mappings,
      isEmpty,
    );
  });

  test('page index or title similarity alone never creates reuse aliases', () {
    final oldChapter = _chapter(
      comicId: 'old',
      revision: 'old',
      urls: const <String>['https://cdn.invalid/version-old/page-1.jpg'],
    );
    final newChapter = _chapter(
      comicId: 'new',
      revision: 'new',
      urls: const <String>['https://cdn.invalid/version-new/page-1.jpg'],
    );

    final plan = VerifiedArtifactReusePlan.match(
      oldChapter: oldChapter,
      newChapter: newChapter,
    );

    expect(plan.mappings, isEmpty);
  });

  test('resolved anchor identities prepare temporary offset aliases', () async {
    final oldChapter = _chapter(
      comicId: 'old',
      revision: 'old',
      urls: const <String>[
        'venera-resource:old-0',
        'venera-resource:old-1',
        'venera-resource:old-2',
      ],
    );
    final newChapter = _chapter(
      comicId: 'new',
      revision: 'new',
      urls: const <String>[
        'venera-resource:new-cover',
        'venera-resource:new-0',
        'venera-resource:new-1',
        'venera-resource:new-2',
      ],
    );
    final identities = <String, String>{
      'venera-resource:old-0': 'eh:a',
      'venera-resource:old-1': 'eh:b',
      'venera-resource:old-2': 'eh:c',
      'venera-resource:new-0': 'eh:a',
      'venera-resource:new-1': 'eh:b',
      'venera-resource:new-2': 'eh:c',
    };

    final plan = await VerifiedArtifactReusePlan.matchResolvedOffset(
      oldChapter: oldChapter,
      newChapter: newChapter,
      resolveIdentity: (page) async => identities[page.uri.toString()],
    );

    expect(plan.mappings, hasLength(3));
    expect(
      plan.mappings[readerPageDownloadId(newChapter, newChapter.pages[1])],
      readerPageDownloadId(oldChapter, oldChapter.pages[0]),
    );
    expect(
      plan.mappings[readerPageDownloadId(newChapter, newChapter.pages[2])],
      readerPageDownloadId(oldChapter, oldChapter.pages[1]),
      reason: 'accepted affine offset aliases the whole VibeVenera overlap',
    );
    expect(
      plan.mappings[readerPageDownloadId(newChapter, newChapter.pages[3])],
      readerPageDownloadId(oldChapter, oldChapter.pages[2]),
    );
  });

  test('resolved related reuse is bidirectional across an inserted page',
      () async {
    final older = _chapter(
      comicId: 'older',
      revision: 'older',
      urls: const <String>[
        'venera-resource:older-0',
        'venera-resource:older-1',
        'venera-resource:older-2',
      ],
    );
    final newer = _chapter(
      comicId: 'newer',
      revision: 'newer',
      urls: const <String>[
        'venera-resource:newer-cover',
        'venera-resource:newer-0',
        'venera-resource:newer-1',
        'venera-resource:newer-2',
      ],
    );
    final identities = <String, String>{
      'venera-resource:older-0': 'eh:a',
      'venera-resource:older-1': 'eh:b',
      'venera-resource:older-2': 'eh:c',
      'venera-resource:newer-0': 'eh:a',
      'venera-resource:newer-1': 'eh:b',
      'venera-resource:newer-2': 'eh:c',
    };

    final plan = await VerifiedArtifactReusePlan.matchResolvedRelated(
      sourceChapter: newer,
      targetChapter: older,
      resolveIdentity: (page) async => identities[page.uri.toString()],
    );

    expect(plan.mappings, hasLength(3));
    expect(
      plan.mappings[readerPageDownloadId(older, older.pages.first)],
      readerPageDownloadId(newer, newer.pages[1]),
    );
    expect(
      plan.mappings[readerPageDownloadId(older, older.pages[1])],
      readerPageDownloadId(newer, newer.pages[2]),
      reason: 'accepted affine offset aliases the whole reverse overlap',
    );
    expect(
      plan.mappings[readerPageDownloadId(older, older.pages.last)],
      readerPageDownloadId(newer, newer.pages[3]),
    );
  });

  test('reverse proof registration reuses one symmetric equivalence edge',
      () async {
    final older = _chapter(
      comicId: 'older',
      revision: 'older',
      urls: const <String>[
        'https://e-hentai.org/s/aaaaaaaaaaaaaaaa/1-1',
      ],
    );
    final newer = _chapter(
      comicId: 'newer',
      revision: 'newer',
      urls: const <String>[
        'https://e-hentai.org/s/aaaaaaaaaaaaaaaa/2-1',
      ],
    );
    final olderId = readerPageDownloadId(older, older.pages.single);
    final newerId = readerPageDownloadId(newer, newer.pages.single);
    final cache = ArtifactCacheManager(
      backend: _Backend(<DownloadId, Uint8List>{
        olderId: Uint8List.fromList(<int>[9, 9, 9]),
      }),
    );
    final forward = VerifiedArtifactReusePlan.match(
      oldChapter: older,
      newChapter: newer,
    );
    final reverse = VerifiedArtifactReusePlan.match(
      oldChapter: newer,
      newChapter: older,
    );

    expect(forward.registerEquivalences(cache), 1);
    expect(reverse.registerEquivalences(cache), 1);
    expect(cache.equivalenceCount, 1);
    expect((await cache.readForeground(newerId))?.bytes, <int>[9, 9, 9]);
  });

  test('persisted verified offset restores aliases without a resolver', () {
    final older = _chapter(
      comicId: 'older',
      revision: 'older',
      urls: const <String>[
        'venera-resource:older-0',
        'venera-resource:older-1',
      ],
    );
    final newer = _chapter(
      comicId: 'newer',
      revision: 'newer',
      urls: const <String>[
        'venera-resource:new-cover',
        'venera-resource:newer-0',
        'venera-resource:newer-1',
      ],
    );

    final forward = VerifiedArtifactReusePlan.fromVerifiedOffset(
      sourceChapter: older,
      targetChapter: newer,
      targetOffsetFromSource: 1,
      verifiedSourceIndexes: const <int>[0, 1],
    );
    final reverse = VerifiedArtifactReusePlan.fromVerifiedOffset(
      sourceChapter: newer,
      targetChapter: older,
      targetOffsetFromSource: -1,
      verifiedSourceIndexes: const <int>[1, 2],
    );

    expect(forward.mappings, hasLength(2));
    expect(reverse.mappings, hasLength(2));
    expect(
      forward.mappings[readerPageDownloadId(newer, newer.pages[1])],
      readerPageDownloadId(older, older.pages[0]),
    );
    expect(
      reverse.mappings[readerPageDownloadId(older, older.pages[0])],
      readerPageDownloadId(newer, newer.pages[1]),
    );
  });

  test('compact persisted offset resolves only queried target pages', () async {
    final older = _chapter(
      comicId: 'older-compact',
      revision: 'older',
      urls: const <String>[
        'venera-resource:older-0',
        'venera-resource:older-1',
        'venera-resource:older-2',
      ],
    );
    final newer = _chapter(
      comicId: 'newer-compact',
      revision: 'newer',
      urls: const <String>[
        'venera-resource:new-cover',
        'venera-resource:newer-0',
        'venera-resource:newer-1',
        'venera-resource:newer-2',
      ],
    );
    final oldSecond = readerPageDownloadId(older, older.pages[1]);
    final newSecond = readerPageDownloadId(newer, newer.pages[2]);
    final backend = _Backend(<DownloadId, Uint8List>{
      oldSecond: Uint8List.fromList(<int>[4, 2]),
    });
    final cache = ArtifactCacheManager(backend: backend);
    final resolver = VerifiedArtifactReuseResolver(targetChapter: newer);

    expect(
      resolver.addVerifiedOffset(
        sourceChapter: older,
        targetOffsetFromSource: 1,
        verifiedSourceIndexes: const <int>[0, 1, 2],
      ),
      3,
    );
    cache.registerEquivalentResolver(
      key: 'newer-compact',
      resolver: resolver.resolve,
    );

    expect(resolver.relationCount, 1);
    expect(resolver.eligiblePageCount, 3);
    expect(cache.equivalenceCount, 0,
        reason: 'compact relations must not materialize page-pair edges');
    expect(cache.directEquivalents(newSecond), <DownloadId>[oldSecond]);
    expect((await cache.readForeground(newSecond))?.bytes, <int>[4, 2]);
    expect(
      cache.directEquivalents(
        DownloadId(
          content: newSecond.content,
          sourceRevision: newSecond.sourceRevision,
          canonicalUri: Uri.parse('venera-resource:changed'),
        ),
      ),
      isEmpty,
      reason: 'the current target identity must still match exactly',
    );
  });

  test('compact related proof returns an affine offset without page pairs',
      () async {
    final older = _chapter(
      comicId: 'older-proof',
      revision: 'older',
      urls: const <String>[
        'venera-resource:older-0',
        'venera-resource:older-1',
        'venera-resource:older-2',
      ],
    );
    final newer = _chapter(
      comicId: 'newer-proof',
      revision: 'newer',
      urls: const <String>[
        'venera-resource:new-cover',
        'venera-resource:newer-0',
        'venera-resource:newer-1',
        'venera-resource:newer-2',
      ],
    );
    final identities = <String, String>{
      'venera-resource:older-0': 'eh:a',
      'venera-resource:older-1': 'eh:b',
      'venera-resource:older-2': 'eh:c',
      'venera-resource:newer-0': 'eh:a',
      'venera-resource:newer-1': 'eh:b',
      'venera-resource:newer-2': 'eh:c',
    };

    final proof = await VerifiedArtifactReusePlan.matchResolvedRelatedOffset(
      sourceChapter: older,
      targetChapter: newer,
      resolveIdentity: (page) async => identities[page.uri.toString()],
    );

    expect(proof?.targetOffsetFromSource, 1);
    expect(proof?.verifiedSourceIndexes, <int>[0, 1, 2]);
  });

  test('persisted offset registers symmetric future-artifact equivalence',
      () async {
    final older = _chapter(
      comicId: 'older',
      revision: 'older',
      urls: const <String>[
        'venera-resource:older-0',
        'venera-resource:older-1',
      ],
    );
    final newer = _chapter(
      comicId: 'newer',
      revision: 'newer',
      urls: const <String>[
        'venera-resource:new-cover',
        'venera-resource:newer-0',
        'venera-resource:newer-1',
      ],
    );
    final oldFirst = readerPageDownloadId(older, older.pages.first);
    final newFirst = readerPageDownloadId(newer, newer.pages[1]);
    final cache = ArtifactCacheManager(
      backend: _Backend(<DownloadId, Uint8List>{}),
    );
    final plan = VerifiedArtifactReusePlan.fromVerifiedOffset(
      sourceChapter: older,
      targetChapter: newer,
      targetOffsetFromSource: 1,
      verifiedSourceIndexes: const <int>[0, 1],
    );

    expect(plan.registerEquivalences(cache), 2);
    expect(cache.equivalenceCount, 2);
    expect(await cache.lookup(oldFirst), isNull);

    await cache.storePromotedArtifact(
      id: newFirst,
      bytes: Uint8List.fromList(<int>[6, 6, 6]),
    );
    expect((await cache.readForeground(oldFirst))?.bytes, <int>[6, 6, 6]);
  });

  test('VibeVenera 2-of-3 anchors authorize the affine overlap', () async {
    final source = _chapter(
      comicId: 'source-middle-proof',
      revision: 'source',
      urls: const <String>[
        'venera-resource:source-a',
        'venera-resource:source-b',
        'venera-resource:source-c',
      ],
    );
    final target = _chapter(
      comicId: 'target-middle-proof',
      revision: 'target',
      urls: const <String>[
        'venera-resource:target-a',
        'venera-resource:target-x',
        'venera-resource:target-c',
      ],
    );
    final identities = <String, String>{
      'venera-resource:source-a': 'media:a',
      'venera-resource:source-b': 'media:b',
      'venera-resource:source-c': 'media:c',
      'venera-resource:target-a': 'media:a',
      'venera-resource:target-x': 'media:x',
      'venera-resource:target-c': 'media:c',
    };

    final proof = await VerifiedArtifactReusePlan.matchResolvedRelatedOffset(
      sourceChapter: source,
      targetChapter: target,
      resolveIdentity: (page) async => identities[page.uri.toString()],
    );
    expect(proof?.targetOffsetFromSource, 0);
    expect(proof?.verifiedSourceIndexes, <int>[0, 2]);

    final resolver = VerifiedArtifactReuseResolver(targetChapter: target);
    resolver.addVerifiedOffset(
      sourceChapter: source,
      targetOffsetFromSource: proof!.targetOffsetFromSource,
      verifiedSourceIndexes: proof.verifiedSourceIndexes,
    );
    expect(
      resolver.resolve(readerPageDownloadId(target, target.pages.first)),
      <DownloadId>[readerPageDownloadId(source, source.pages.first)],
    );
    expect(
      resolver.resolve(readerPageDownloadId(target, target.pages[1])),
      <DownloadId>[readerPageDownloadId(source, source.pages[1])],
      reason: 'two matching anchors authorize the whole affine overlap',
    );
    expect(
      resolver.resolve(readerPageDownloadId(target, target.pages.last)),
      <DownloadId>[readerPageDownloadId(source, source.pages.last)],
    );
  });

  test('resolved offset requires verified anchor agreement', () async {
    final oldChapter = _chapter(
      comicId: 'old',
      revision: 'old',
      urls: const <String>[
        'venera-resource:old-0',
        'venera-resource:old-1',
        'venera-resource:old-2',
      ],
    );
    final newChapter = _chapter(
      comicId: 'new',
      revision: 'new',
      urls: const <String>[
        'venera-resource:new-0',
        'venera-resource:new-1',
        'venera-resource:new-2',
      ],
    );

    final plan = await VerifiedArtifactReusePlan.matchResolvedOffset(
      oldChapter: oldChapter,
      newChapter: newChapter,
      resolveIdentity: (page) async => page.uri.toString(),
    );

    expect(plan.mappings, isEmpty);
  });

  test('resource reuse identity accepts only strong media keys', () {
    expect(
      verifiedComicResourceIdentity(
        Uri.parse('https://e-hentai.org/s/AaBbCc/1-1'),
      ),
      'eh:aabbcc',
    );
    expect(
      verifiedComicResourceIdentity(
        Uri.parse(
          'https://cdn.invalid/0123456789abcdef0123456789abcdef.jpg',
        ),
      ),
      'hash:0123456789abcdef0123456789abcdef',
    );
    expect(
      verifiedComicResourceIdentity(
        Uri.parse('https://cdn.invalid/page-1.jpg'),
      ),
      isNull,
    );
  });
}

ChapterManifest _chapter({
  required String comicId,
  required String revision,
  required List<String> urls,
  List<String?>? checksums,
  List<String?>? checksumAlgorithms,
}) {
  final chapterId = 'chapter-$revision';
  return ChapterManifest(
    sourceId: 'venera:ehentai',
    comicId: comicId,
    chapter: Chapter(
      chapterId: chapterId,
      comicId: comicId,
      title: 'Gallery',
      sequence: 0,
      pageCount: urls.length,
      sourceRevision: revision,
    ),
    pages: <PageAsset>[
      for (var index = 0; index < urls.length; index++)
        PageAsset(
          pageId: 'page-$index-$revision',
          chapterId: chapterId,
          index: index,
          uri: Uri.parse(urls[index]),
          checksum: checksums?[index],
          checksumAlgorithm: checksumAlgorithms?[index],
        ),
    ],
    readingDirection: ReadingDirection.vertical,
  );
}

final class _RecordingArtifactBytes implements ArtifactBytes {
  final ArtifactBytes _delegate = const LocalArtifactBytes();
  int existsCalls = 0;
  int lengthCalls = 0;
  int readChunkCalls = 0;
  int readBytes = 0;

  void resetReadCounters() {
    existsCalls = 0;
    lengthCalls = 0;
    readChunkCalls = 0;
    readBytes = 0;
  }

  @override
  Future<bool> exists(String path) {
    existsCalls++;
    return _delegate.exists(path);
  }

  @override
  Future<int> length(String path) {
    lengthCalls++;
    return _delegate.length(path);
  }

  @override
  Stream<Uint8List> readChunks(
    String path, {
    required int start,
    int? endExclusive,
  }) async* {
    readChunkCalls++;
    await for (final chunk in _delegate.readChunks(
      path,
      start: start,
      endExclusive: endExclusive,
    )) {
      readBytes += chunk.lengthInBytes;
      yield chunk;
    }
  }

  @override
  Future<void> delete(String path) => _delegate.delete(path);
}

final class _Backend implements ArtifactCacheBackend {
  _Backend(this.values);

  final Map<DownloadId, Uint8List> values;

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async {
    final bytes = values[id];
    if (bytes == null) return null;
    return ArtifactCacheStreamEntry(
      length: bytes.lengthInBytes,
      open: ({required int start, int? endExclusive}) async* {
        yield Uint8List.sublistView(
          bytes,
          start,
          endExclusive ?? bytes.lengthInBytes,
        );
      },
      readAll: () async => bytes,
    );
  }

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {
    values[id] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> invalidateArtifact(DownloadId id) async {
    values.remove(id);
  }
}
