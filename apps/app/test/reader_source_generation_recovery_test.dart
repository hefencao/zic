import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/demo_home.dart';

void main() {
  Failure failure(Map<String, Object?> details) => Failure(
        code: ErrorCode.source,
        message: 'fixture source failure',
        details: details,
      );

  ImportedChapterRecord chapter(
    String host, {
    List<String>? pageIds,
    String sourceRevision = 'r1',
  }) {
    final ids = pageIds ?? const <String>['page-0', 'page-1'];
    return ImportedChapterRecord(
      directoryId: 'fixture',
      displayName: 'chapter',
      sourceId: 'venera:fixture',
      comicId: 'comic',
      chapterId: 'chapter',
      sourceRevision: sourceRevision,
      pages: <ImportedPageRecord>[
        for (var index = 0; index < ids.length; index++)
          ImportedPageRecord(
            displayName: '$index.webp',
            sourceId: 'https://$host/media/$index.webp',
            pageId: ids[index],
            contentKindHint: ContentKindHint.webp,
            animatedHint: true,
          ),
      ],
    );
  }

  test('compact Home snapshot page requires source locator refresh', () {
    final compact = ImportedChapterRecord(
      directoryId: 'fixture',
      displayName: 'chapter',
      sourceId: 'venera:jm',
      comicId: 'comic',
      chapterId: 'chapter',
      sourceRevision: 'r1',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: 'page-1',
          sourceId: 'zic-home-snapshot-page:0',
          contentKindHint: ContentKindHint.unknown,
        ),
      ],
    );
    final usable = chapter('cdn.example');

    expect(chapterRequiresSourceLocatorRefresh(compact), isTrue);
    expect(chapterRequiresSourceLocatorRefresh(usable), isFalse);
  });

  test('route refresh only owns terminal unavailable source generations', () {
    final terminal = failure(const <String, Object?>{
      'sourceMediaSemanticRejected': true,
      'sourceSemanticRetryExhausted': true,
      'sourceSemanticAcceptedPlans': 0,
      'sourceSemanticRecoveryUnavailable': true,
    });
    expect(readerSourceGenerationRefreshEligible(terminal), isTrue);

    expect(
      readerSourceGenerationRefreshEligible(
        failure(const <String, Object?>{
          'sourceMediaSemanticRejected': true,
          'sourceSemanticRetryExhausted': true,
          'sourceSemanticAcceptedPlans': 1,
          'sourceSemanticRecoveryUnavailable': true,
        }),
      ),
      isFalse,
      reason: 'a source-owned retry plan remains inside its generation',
    );
    expect(
      readerSourceGenerationRefreshEligible(
        failure(const <String, Object?>{
          'sourceMediaSemanticRejected': true,
          'sourceSemanticRetryExhausted': true,
          'sourceSemanticAcceptedPlans': 0,
          'sourceSemanticRecoveryUnavailable': false,
        }),
      ),
      isFalse,
      reason: 'an exhausted source-owned chain is not an unavailable generation',
    );
    expect(
      readerSourceGenerationRefreshEligible(
        const Failure(
          code: ErrorCode.network,
          message: 'fixture network failure',
        ),
      ),
      isFalse,
      reason: 'ordinary network retry remains owned below the Reader route',
    );
  });
  test(
      'page authority recovery distinguishes a new carrier from metadata refresh',
      () {
    final previous = chapter('old.example');
    final same = chapter('old.example');
    final changed = chapter('new.example');

    expect(readerPageAuthorityChanged(previous, same, 1), isFalse);
    expect(readerPageAuthorityChanged(previous, changed, 1), isTrue);
    expect(readerFreshPageIndexForRecovery(previous, changed, 1), 1);
  });

  test('explicit page identity disappearance fails closed', () {
    final previous = chapter('old.example');
    final refreshed = chapter(
      'new.example',
      pageIds: const <String>['page-0', 'replacement'],
    );

    expect(readerFreshPageIndexForRecovery(previous, refreshed, 1), isNull);
    expect(readerPageAuthorityChanged(previous, refreshed, 1), isFalse);
  });

  test('page authority recovery follows stable page identity when order moves', () {
    final previous = chapter('old.example');
    final refreshed = chapter(
      'new.example',
      pageIds: const <String>['inserted', 'page-0', 'page-1'],
    );

    expect(readerFreshPageIndexForRecovery(previous, refreshed, 1), 2);
    expect(readerPageAuthorityChanged(previous, refreshed, 1), isTrue);
  });

  test('fresh recovery splices only the failed page carrier', () {
    final previous = chapter('old.example');
    final refreshed = chapter('new.example');

    final replacement = readerChapterWithFreshPageAuthority(
      previous,
      refreshed,
      1,
    );

    expect(replacement, isNotNull);
    expect(replacement!.pages[0].sourceId, previous.pages[0].sourceId);
    expect(replacement.pages[1].sourceId, refreshed.pages[1].sourceId);
    expect(replacement.pages[0].sourceId, isNot(refreshed.pages[0].sourceId));
  });

  test('fresh recovery does not turn a revision change into a page splice', () {
    final previous = chapter('old.example');
    final refreshed = chapter('new.example', sourceRevision: 'r2');

    expect(
      readerChapterWithFreshPageAuthority(previous, refreshed, 1),
      isNull,
    );
  });

}
