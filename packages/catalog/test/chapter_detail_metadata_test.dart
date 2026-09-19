import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:test/test.dart';

void main() {
  test('chapter update metadata survives saved and imported round trips', () {
    final updatedAt = DateTime.utc(2026, 9, 17, 8, 30);
    final chapter = Chapter(
      chapterId: 'chapter-1',
      comicId: 'comic-1',
      title: 'Chapter 1',
      sequence: 1,
      pageCount: 1,
      sourceRevision: 'revision-1',
      publishedAt: DateTime.utc(2026, 9, 16),
      updatedAt: updatedAt,
    );

    final saved = SavedChapterRecord.fromChapter(chapter);
    final restoredSaved = SavedChapterRecord.fromJson(saved.toJson());
    expect(restoredSaved.updatedAt, updatedAt);
    expect(restoredSaved.toChapter('comic-1').updatedAt, updatedAt);

    final imported = ImportedChapterRecord(
      directoryId: 'remote:comic-1',
      displayName: 'Chapter 1',
      sourceId: 'remote',
      comicId: 'comic-1',
      chapterId: 'chapter-1',
      sourceRevision: 'revision-1',
      sourceUpdatedAt: updatedAt,
      importedAt: DateTime.utc(2026, 9, 18),
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '1.png',
          sourceId: 'memory://chapter-1/1',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );
    final restoredImported =
        ImportedChapterRecord.fromJson(imported.toJson());
    expect(restoredImported.sourceUpdatedAt, updatedAt);
    expect(restoredImported.toManifest().chapter.updatedAt, updatedAt);
  });

  test('saved comic preserves unseen chapter ids', () {
    final comic = SavedComicRecord(
      sourceId: 'remote',
      comicId: 'comic-1',
      title: 'Comic',
      unseenChapterIds: const <String>['chapter-2', 'chapter-3'],
    );

    final restored = SavedComicRecord.fromJson(comic.toJson());
    expect(
      restored.unseenChapterIds,
      unorderedEquals(const <String>['chapter-2', 'chapter-3']),
    );
    expect(
      restored.copyWith(
        unseenChapterIds: const <String>['chapter-3'],
      ).unseenChapterIds,
      const <String>{'chapter-3'},
    );
  });

  test('chapter read state preserves manual override provenance', () {
    final state = ChapterReadState(
      sourceId: 'remote',
      comicId: 'comic-1',
      chapterId: 'chapter-1',
      isRead: true,
      updatedAt: DateTime.utc(2026, 9, 19),
      manualOverride: true,
    );

    final restored = ChapterReadState.fromJson(state.toJson());
    expect(restored.isRead, isTrue);
    expect(restored.manualOverride, isTrue);
    expect(
      ChapterReadState.fromJson(<String, Object?>{
        'sourceId': 'remote',
        'comicId': 'comic-1',
        'chapterId': 'legacy',
        'isRead': true,
        'updatedAt': DateTime.utc(2026, 9, 18).toIso8601String(),
      }).manualOverride,
      isFalse,
      reason: 'legacy auto-read rows must not become manual overrides',
    );
  });
}
