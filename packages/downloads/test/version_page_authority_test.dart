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
  test('canonical authority follows a unique directional version chain', () {
    final a = _id('a');
    final b = _id('b');
    final c = _id('c');
    final authority = VersionPageAuthority()
      ..replaceScope('a-b', <String, VersionPageCanonicalResolver>{
        'page': (id) sync* {
          if (id == a) yield b;
        },
      })
      ..replaceScope('b-c', <String, VersionPageCanonicalResolver>{
        'page': (id) sync* {
          if (id == b) yield c;
        },
      });

    expect(authority.resolve(a), c);
    expect(authority.resolve(b), c);
    expect(authority.resolve(c), c);
  });

  test('relation scope replacement revokes stale canonical projections', () {
    final a = _id('a');
    final b = _id('b');
    final authority = VersionPageAuthority()
      ..replaceScope('relation', <String, VersionPageCanonicalResolver>{
        'old': (id) sync* {
          if (id == a) yield b;
        },
      });

    expect(authority.resolve(a), b);
    authority.replaceScope('relation', const <String, VersionPageCanonicalResolver>{});
    expect(authority.resolve(a), a);
  });

  test('branched or cyclic ownership fails closed to exact identity', () {
    final a = _id('a');
    final b = _id('b');
    final c = _id('c');
    final branch = VersionPageAuthority()
      ..replaceScope('a-b', <String, VersionPageCanonicalResolver>{
        'one': (id) sync* {
          if (id == a) yield b;
        },
      })
      ..replaceScope('a-c', <String, VersionPageCanonicalResolver>{
        'two': (id) sync* {
          if (id == a) yield c;
        },
      });
    expect(branch.resolve(a), a);

    final cycle = VersionPageAuthority()
      ..replaceScope('a-b', <String, VersionPageCanonicalResolver>{
        'one': (id) sync* {
          if (id == a) yield b;
        },
      })
      ..replaceScope('b-a', <String, VersionPageCanonicalResolver>{
        'two': (id) sync* {
          if (id == b) yield a;
        },
      });
    expect(cycle.resolve(a), a);
  });
}
