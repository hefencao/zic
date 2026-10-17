import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:comic_translation/comic_translation.dart';
import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry/telemetry.dart';
import 'package:zic/translation_chapter_jobs.dart';

void main() {
  test('chapter cancellation drains initialization and cannot start a late download', () async {
    final initialized = Completer<void>();
    final jobs = AppTranslationChapterJobs(initialize: () => initialized.future);
    final entry = _entry('first');
    var prepared = 0;
    Future<PreparedTranslationChapter> prepare() async {
      prepared++;
      return (entry: entry, composition: null);
    }

    final completion = jobs.start(entry, prepare: prepare, trace: const NoopTraceSink());
    expect(jobs.hasActive, isTrue);
    expect(identical(jobs.start(entry, prepare: prepare, trace: const NoopTraceSink()),
      completion), isTrue);
    expect(() => jobs.start(_entry('second'), prepare: prepare,
      trace: const NoopTraceSink()), throwsStateError);

    final cancelled = jobs.cancel(AppTranslationChapterJobs.keyFor(entry.chapter));
    final drained = jobs.cancelAll();
    expect(jobs.stateFor(AppTranslationChapterJobs.keyFor(entry.chapter))?.phase,
      ComicTranslationChapterPhase.cancelling);
    expect(prepared, 0);

    initialized.complete();
    await Future.wait([completion, cancelled, drained]);
    expect(jobs.hasActive, isFalse);
    expect(jobs.stateFor(AppTranslationChapterJobs.keyFor(entry.chapter))?.phase,
      ComicTranslationChapterPhase.cancelled);
    expect(prepared, 0);
    jobs.dispose();
  });
}

ImportedLibraryEntry _entry(String chapterId) => ImportedLibraryEntry(
  chapter: ImportedChapterRecord(
    directoryId: 'fixture:$chapterId', displayName: chapterId,
    sourceId: 'fixture-source', comicId: 'fixture-comic', chapterId: chapterId,
    sourceRevision: 'fixture-v1', pages: const [ImportedPageRecord(
      displayName: 'page', sourceId: 'file:///fixture/page.png',
      contentKindHint: ContentKindHint.png,
    )],
  ),
);
