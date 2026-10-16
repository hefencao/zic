import 'package:comic_translation/comic_translation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('initialization, disable and backend replacement retain the media child', (tester) async {
    const identity = ComicTranslationPageIdentity(
      imageKey: 'image', sourceKey: 'test', comicId: 'comic', chapterId: 'chapter',
      pageIndex: 0, mediaKind: ComicTranslationMediaKind.staticImage,
    );
    final first = ComicTranslationSession(enabled: true, sourceLanguage: 'ja', targetLanguage: 'zh-CN');
    final second = ComicTranslationSession(enabled: true, sourceLanguage: 'ja', targetLanguage: 'en');
    Future<void> paint(ComicTranslationSession? session) => tester.pumpWidget(
      MaterialApp(home: SizedBox(width: 200, height: 300, child: ComicTranslationOverlay(
        session: session, identity: identity, child: const _MediaChild(),
      ))),
    );
    await paint(null);
    final media = tester.state(find.byType(_MediaChild));
    for (final session in [first, null, second, first]) {
      await paint(session);
      expect(tester.state(find.byType(_MediaChild)), same(media));
    }
    first.setEnabled(false);
    await paint(first);
    expect(tester.state(find.byType(_MediaChild)), same(media));
    await tester.pumpWidget(const SizedBox.shrink());
    await first.close();
    await second.close();
  });
}

class _MediaChild extends StatefulWidget {
  const _MediaChild();
  @override
  State<_MediaChild> createState() => _MediaChildState();
}

class _MediaChildState extends State<_MediaChild> {
  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.white);
}
