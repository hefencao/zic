import 'dart:convert';

import 'package:test/test.dart';
import 'package:domain/domain.dart';
import 'package:zic_library/library.dart';

void main() {
  test('parses and validates a chapter manifest', () {
    final manifest = parseChapterManifest(
      jsonEncode(<String, Object>{
        'sourceId': 'local',
        'comicId': 'comic',
        'readingDirection': 'rtl',
        'chapter': <String, Object>{
          'chapterId': 'chapter',
          'title': 'Chapter',
          'sequence': 1,
          'pageCount': 2,
          'sourceRevision': 'r1',
        },
        'pages': <Object>[
          <String, Object>{
            'pageId': 'p0',
            'index': 0,
            'uri': 'assets/p0.png',
            'contentKindHint': 'png',
          },
          <String, Object>{
            'pageId': 'p1',
            'index': 1,
            'uri': 'assets/p1.png',
            'contentKindHint': 'png',
          },
        ],
      }),
    );

    expect(manifest.pages, hasLength(2));
    expect(manifest.readingDirection, ReadingDirection.rtl);
  });

  test('rejects non-contiguous page indexes', () {
    expect(
      () => parseChapterManifest(
        jsonEncode(<String, Object>{
          'sourceId': 'local',
          'comicId': 'comic',
          'chapter': <String, Object>{
            'chapterId': 'chapter',
            'title': 'Chapter',
            'sequence': 1,
            'pageCount': 1,
            'sourceRevision': 'r1',
          },
          'pages': <Object>[
            <String, Object>{
              'pageId': 'p1',
              'index': 1,
              'uri': 'assets/p1.png',
            },
          ],
        }),
      ),
      throwsArgumentError,
    );
  });
}
