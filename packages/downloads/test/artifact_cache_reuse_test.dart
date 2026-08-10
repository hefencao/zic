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

    expect(plan.aliases, <DownloadId, DownloadId>{newId: oldId});
    expect(plan.apply(cache), 1);
    expect((await cache.readForeground(newId))?.bytes, <int>[1, 2, 3]);
  });

  test('applyExisting aliases only pages with an existing old artifact', () async {
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

    expect(await plan.applyExisting(cache), 1);
    expect(cache.resolveAlias(newFirst), oldFirst);
    expect(cache.resolveAlias(newSecond), newSecond);
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

    expect(plan.aliases, isEmpty);
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

    expect(plan.aliases, hasLength(3));
    expect(
      plan.aliases[readerPageDownloadId(newChapter, newChapter.pages[1])],
      readerPageDownloadId(oldChapter, oldChapter.pages[0]),
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

    expect(plan.aliases, isEmpty);
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
        ),
    ],
    readingDirection: ReadingDirection.vertical,
  );
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
