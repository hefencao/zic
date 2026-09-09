import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:test/test.dart';

DownloadId _id(String version) => DownloadId(
      content: ContentId(
        sourceId: 'source',
        comicId: version,
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: version,
      canonicalUri: Uri.parse('https://example.test/$version'),
    );

void main() {
  test('version authority exposes direct candidates without changing ownership', () {
    final a = _id('a');
    final b = _id('b');
    final c = _id('c');
    final authority = VersionPageAuthority()
      ..replaceScope('a-b', <String, VersionPageReuseResolver>{
        'page': (id) sync* {
          if (id == a) yield b;
        },
      })
      ..replaceScope('b-c', <String, VersionPageReuseResolver>{
        'page': (id) sync* {
          if (id == b) yield c;
        },
      });

    expect(authority.directCandidates(a), orderedEquals(<DownloadId>[b]));
    expect(authority.directCandidates(b), orderedEquals(<DownloadId>[c]));
    expect(authority.directCandidates(c), isEmpty);
  });

  test('relation scope replacement revokes stale reuse candidates', () {
    final a = _id('a');
    final b = _id('b');
    final authority = VersionPageAuthority()
      ..replaceScope('relation', <String, VersionPageReuseResolver>{
        'old': (id) sync* {
          if (id == a) yield b;
        },
      });

    expect(authority.directCandidates(a), orderedEquals(<DownloadId>[b]));
    authority.replaceScope('relation', const <String, VersionPageReuseResolver>{});
    expect(authority.directCandidates(a), isEmpty);
  });

  test('multiple verified candidates remain candidates instead of choosing a head', () {
    final a = _id('a');
    final b = _id('b');
    final c = _id('c');
    final authority = VersionPageAuthority()
      ..replaceScope('a-b', <String, VersionPageReuseResolver>{
        'one': (id) sync* {
          if (id == a) yield b;
        },
      })
      ..replaceScope('a-c', <String, VersionPageReuseResolver>{
        'two': (id) sync* {
          if (id == a) yield c;
        },
      });

    expect(authority.directCandidates(a).toSet(), <DownloadId>{b, c});
  });
}
