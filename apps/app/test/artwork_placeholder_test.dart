import 'dart:convert';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:zic/artwork_placeholder.dart';
import 'package:zic/home_widgets.dart';

void main() {
  test('artwork fallback colors are soft and vary by seed', () {
    final first = softArtworkColor('comic-a');
    final second = softArtworkColor('comic-b');
    final firstHsl = HSLColor.fromColor(first);

    expect(first, isNot(second));
    expect(firstHsl.saturation, inInclusiveRange(0.18, 0.31));
    expect(firstHsl.lightness, inInclusiveRange(0.76, 0.83));
  });

  testWidgets('artwork fallback does not show a broken-image icon', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 48,
          height: 64,
          child: SoftArtworkPlaceholder(seed: 'comic-a'),
        ),
      ),
    );

    expect(find.byType(Icon), findsNothing);
  });

  testWidgets('mounted Home covers decode ready bytes during fast scrolling', (
    tester,
  ) async {
    final source = MemoryEncodedResourceSource(base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
      'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    ));
    final loaded = <int>[];
    final physics = _DeferringArtworkPhysics();
    await tester.pumpWidget(MaterialApp(home: ListView.builder(
      physics: physics,
      itemCount: 100,
      itemExtent: 180,
      itemBuilder: (context, index) => ComicCoverCard(
        comic: LibraryComic(
          sourceId: 'fixture', comicId: '$index', title: 'Comic $index',
          authors: const [], tags: const [], description: '',
          coverSourceId: null, readingDirection: ReadingDirection.ltr,
          chapters: const [], sourceChapters: const [],
          savedAt: DateTime.utc(2026), metadataUpdatedAt: DateTime.utc(2026),
        ),
        preference: ComicPreference.defaults(sourceId: 'fixture', comicId: '$index'),
        coverIdentity: 'fixture:$index',
        coverSource: () async {
          loaded.add(index);
          return source;
        },
        onTap: () {},
      ),
    )));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(loaded, isNotEmpty);
    expect(loaded, isNot(contains(99)), reason: 'Covers remain sliver-lazy.');
    expect(tester.widgetList<RawImage>(find.byType(RawImage))
        .where((image) => image.image != null), isNotEmpty,
        reason: 'Ready cover bytes must not wait for scrolling to stop.');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

final class _DeferringArtworkPhysics extends ScrollPhysics {
  const _DeferringArtworkPhysics({super.parent});

  @override
  _DeferringArtworkPhysics applyTo(ScrollPhysics? ancestor) =>
      _DeferringArtworkPhysics(parent: buildParent(ancestor));

  @override
  bool recommendDeferredLoading(double velocity, ScrollMetrics metrics, BuildContext context) => true;
}
