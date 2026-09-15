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

  ImportedChapterRecord chapter(String host, {List<String>? pageIds}) {
    final ids = pageIds ?? const <String>['page-0', 'page-1'];
    return ImportedChapterRecord(
      directoryId: 'fixture',
      displayName: 'chapter',
      sourceId: 'venera:fixture',
      comicId: 'comic',
      chapterId: 'chapter',
      sourceRevision: 'r1',
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

}
