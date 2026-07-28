import 'dart:convert';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:test/test.dart';
import 'package:transport/transport.dart';

void main() {
  test('MangaDex browse maps source summaries and cover identities', () async {
    final source = MangaDexSource(transport: _MangaDexFixtureTransport());

    final page = await source.browse(limit: 20);

    expect(page.items, hasLength(1));
    expect(page.hasMore, isFalse);
    expect(page.items.single.comicId, 'manga-1');
    expect(page.items.single.title, 'Fixture Manga');
    expect(page.items.single.authors, <String>['Fixture Author']);
    expect(
      page.items.single.coverUri,
      Uri.parse(
        'https://uploads.mangadex.org/covers/manga-1/cover.jpg.256.jpg',
      ),
    );
  });

  test('MangaDex source resolves chapters into Reader page manifests', () async {
    final source = MangaDexSource(transport: _MangaDexFixtureTransport());

    final comic = await source.loadComic('manga-1');
    final chapter = await source.loadChapter('chapter-1');

    expect(comic.comic.readingDirection, ReadingDirection.rtl);
    expect(comic.chapters, hasLength(1));
    expect(chapter.sourceId, 'mangadex');
    expect(chapter.comicId, 'manga-1');
    expect(chapter.chapter.title, 'Ch. 1 · Opening');
    expect(chapter.chapter.sourceRevision, 'fixture-hash');
    expect(chapter.pages, hasLength(2));
    expect(
      chapter.pages.first.uri,
      Uri.parse(
        'https://uploads.example/data/fixture-hash/001.jpg',
      ),
    );
    expect(chapter.pages.first.contentKindHint, ContentKindHint.jpeg);
  });

  test('remote imported chapter preserves cover and source ownership', () async {
    final source = MangaDexSource(transport: _MangaDexFixtureTransport());
    final comic = (await source.loadComic('manga-1')).comic;
    final manifest = await source.loadChapter('chapter-1');

    final record = ImportedChapterRecord.remote(
      comic: comic,
      manifest: manifest,
      importedAt: DateTime.utc(2026, 7, 28),
    );

    expect(record.sourceId, 'mangadex');
    expect(record.comicTitle, 'Fixture Manga');
    expect(
      record.coverSourceId,
      'https://uploads.mangadex.org/covers/manga-1/cover.jpg.256.jpg',
    );
    expect(record.pages.first.stablePageId, 'page-1');
    final restored = ImportedChapterRecord.fromJson(record.toJson());
    expect(restored.pages.first.stablePageId, 'page-1');
    expect(restored.toManifest().pages.first.uri, manifest.pages.first.uri);
  });

  test('MangaDex metadata rejects an oversized response before decoding',
      () async {
    final source = MangaDexSource(transport: const _OversizedTransport());

    await expectLater(
      source.browse(),
      throwsA(
        isA<Failure>()
            .having((failure) => failure.code, 'code', ErrorCode.source),
      ),
    );
  });
}

final class _OversizedTransport implements Transport {
  const _OversizedTransport();

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    return ByteResponse(
      bytes: const Stream<List<int>>.empty(),
      statusCode: 200,
      rangeStart: 0,
      totalLength: 5 * 1024 * 1024,
    );
  }
}

final class _MangaDexFixtureTransport implements Transport {
  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    final payload = switch (uri.path) {
      '/manga' => _browse,
      '/manga/manga-1' => _manga,
      '/manga/manga-1/feed' => _feed,
      '/chapter/chapter-1' => _chapter,
      '/at-home/server/chapter-1' => _atHome,
      _ => throw StateError('unexpected fixture URI: $uri'),
    };
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    return ByteResponse(
      bytes: Stream<List<int>>.value(bytes),
      statusCode: 200,
      rangeStart: 0,
      totalLength: bytes.length,
    );
  }
}

const Map<String, Object?> _browse = <String, Object?>{
  'total': 1,
  'data': <Object?>[_mangaData],
};

const Map<String, Object?> _manga = <String, Object?>{
  'data': _mangaData,
};

const Map<String, Object?> _mangaData = <String, Object?>{
  'id': 'manga-1',
  'attributes': <String, Object?>{
    'title': <String, Object?>{'en': 'Fixture Manga'},
    'description': <String, Object?>{'en': 'Fixture description'},
    'originalLanguage': 'ja',
    'contentRating': 'safe',
    'createdAt': '2025-01-01T00:00:00+00:00',
    'updatedAt': '2026-01-01T00:00:00+00:00',
  },
  'relationships': <Object?>[
    <String, Object?>{
      'type': 'cover_art',
      'id': 'cover-1',
      'attributes': <String, Object?>{'fileName': 'cover.jpg'},
    },
    <String, Object?>{
      'type': 'author',
      'id': 'author-1',
      'attributes': <String, Object?>{'name': 'Fixture Author'},
    },
  ],
};

const Map<String, Object?> _feed = <String, Object?>{
  'total': 1,
  'data': <Object?>[
    <String, Object?>{
      'id': 'chapter-1',
      'attributes': <String, Object?>{
        'chapter': '1',
        'title': 'Opening',
        'pages': 2,
        'publishAt': '2026-01-02T00:00:00+00:00',
        'updatedAt': '2026-01-03T00:00:00+00:00',
      },
      'relationships': <Object?>[],
    },
  ],
};

const Map<String, Object?> _chapter = <String, Object?>{
  'data': <String, Object?>{
    'id': 'chapter-1',
    'attributes': <String, Object?>{
      'chapter': '1',
      'title': 'Opening',
      'pages': 2,
      'publishAt': '2026-01-02T00:00:00+00:00',
    },
    'relationships': <Object?>[
      <String, Object?>{'type': 'manga', 'id': 'manga-1'},
    ],
  },
};

const Map<String, Object?> _atHome = <String, Object?>{
  'baseUrl': 'https://uploads.example',
  'chapter': <String, Object?>{
    'hash': 'fixture-hash',
    'data': <Object?>['001.jpg', '002.png'],
    'dataSaver': <Object?>['001.jpg', '002.png'],
  },
};
