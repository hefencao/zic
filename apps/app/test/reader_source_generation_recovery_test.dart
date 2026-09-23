import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/home_shell.dart';

void main() {
  Failure failure(Map<String, Object?> details) => Failure(
        code: ErrorCode.source,
        message: 'fixture source failure',
        details: details,
      );

  ImportedChapterRecord chapter(
    String host, {
    List<String>? pageIds,
    String sourceId = 'venera:fixture',
    String sourceRevision = 'r1',
  }) {
    final ids = pageIds ?? const <String>['page-0', 'page-1'];
    return ImportedChapterRecord(
      directoryId: 'fixture',
      displayName: 'chapter',
      sourceId: sourceId,
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

  test('legacy and payload-mismatched Mihon carriers require source refresh', () {
    final v1 = chapter(
      'cdn.example',
      sourceId: 'mihon:fixture',
      sourceRevision: '/chapter:0:mihon-runtime-transform-v1',
    );
    final v2 = chapter(
      'cdn.example',
      sourceId: 'mihon:fixture',
      sourceRevision: '/chapter:0:mihon-runtime-transform-v2',
    );
    const currentAuthority =
        'mihon-runtime-transform-v3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final current = chapter(
      'cdn.example',
      sourceId: 'mihon:fixture',
      sourceRevision: '/chapter:0:$currentAuthority',
    );
    final previousPayload = chapter(
      'cdn.example',
      sourceId: 'mihon:fixture',
      sourceRevision:
          '/chapter:0:mihon-runtime-transform-v3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    );

    expect(chapterRequiresSourceLocatorRefresh(v1), isTrue);
    expect(chapterRequiresSourceLocatorRefresh(v2), isTrue);
    expect(
      chapterRequiresSourceLocatorRefresh(
        current,
        currentMihonResourceAuthorityRevision: currentAuthority,
      ),
      isFalse,
    );
    expect(
      chapterRequiresSourceLocatorRefresh(
        previousPayload,
        currentMihonResourceAuthorityRevision: currentAuthority,
      ),
      isTrue,
      reason: 'plugin payload replacement invalidates persisted runtime carriers',
    );
  });

  test('route refresh only owns terminal unavailable source generations', () {
    final terminal = failure(const <String, Object?>{
      'sourceMediaSemanticRejected': true,
      'sourceSemanticRetryExhausted': true,
      'sourceSemanticAcceptedPlans': 0,
      'sourceSemanticRecoveryUnavailable': true,
    });
    expect(sourceResourceGenerationRefreshEligible(terminal), isTrue);
    expect(
      sourceResourceGenerationRefreshEligible(
        failure(const <String, Object?>{
          'sourceResourcePlanReplayEligible': true,
          'sourceResourcePlanReplayAttempted': true,
          'sourceResourcePlanReplayUnavailable': true,
        }),
      ),
      isTrue,
      reason: 'terminal resource-plan replay hands off to generation refresh',
    );
    expect(
      sourceResourceGenerationRefreshEligible(
        failure(const <String, Object?>{
          'sourceResourcePlanReplayEligible': true,
        }),
      ),
      isFalse,
      reason: 'replay eligibility alone stays below the Reader route',
    );

    expect(
      sourceResourceGenerationRefreshEligible(
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
      sourceResourceGenerationRefreshEligible(
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
      sourceResourceGenerationRefreshEligible(
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

  test('fresh recovery atomically replaces all matched page carriers', () {
    final previous = chapter('old.example');
    final refreshed = chapter('new.example');

    final replacement = readerChapterWithFreshPageAuthorities(
      previous,
      refreshed,
      1,
    );

    expect(replacement, isNotNull);
    expect(replacement!.pages[0].sourceId, refreshed.pages[0].sourceId);
    expect(replacement.pages[1].sourceId, refreshed.pages[1].sourceId);
    expect(
      replacement.pages.map((page) => page.pageId),
      previous.pages.map((page) => page.pageId),
      reason: 'carrier refresh must preserve the old logical page structure',
    );
  });

  test('fresh carrier batch follows stable identities without adopting inserts', () {
    final previous = chapter('old.example');
    final refreshed = chapter(
      'new.example',
      pageIds: const <String>['inserted', 'page-0', 'page-1'],
    );

    final replacement = readerChapterWithFreshPageAuthorities(
      previous,
      refreshed,
      1,
    );

    expect(replacement, isNotNull);
    expect(
      replacement!.pages.map((page) => page.pageId).toList(),
      const <String?>['page-0', 'page-1'],
    );
    expect(replacement.pages[0].sourceId, refreshed.pages[1].sourceId);
    expect(replacement.pages[1].sourceId, refreshed.pages[2].sourceId);
  });

  test('fresh carrier batch fails closed when any old identity disappears', () {
    final previous = chapter('old.example');
    final refreshed = chapter(
      'new.example',
      pageIds: const <String>['page-0', 'replacement'],
    );

    expect(
      readerChapterWithFreshPageAuthorities(previous, refreshed, 0),
      isNull,
    );
  });

  test('fresh recovery does not turn a revision change into carrier migration', () {
    final previous = chapter('old.example');
    final refreshed = chapter('new.example', sourceRevision: 'r2');

    expect(
      readerChapterWithFreshPageAuthorities(previous, refreshed, 1),
      isNull,
    );
  });

}
