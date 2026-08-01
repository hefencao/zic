import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_runtime/reader_runtime.dart';

void main() {
  ChapterManifest manifest({
    required List<({int? width, int? height, bool animated})> pages,
    ReadingDirection sourceDirection = ReadingDirection.ltr,
  }) =>
      ChapterManifest(
        sourceId: 'source',
        comicId: 'comic',
        chapter: Chapter(
          chapterId: 'chapter',
          comicId: 'comic',
          title: 'chapter',
          sequence: 0,
          pageCount: pages.length,
          sourceRevision: 'r1',
        ),
        pages: List<PageAsset>.generate(
          pages.length,
          (index) => PageAsset(
            pageId: 'page-$index',
            chapterId: 'chapter',
            index: index,
            uri: Uri.parse('https://example.test/$index.webp'),
            width: pages[index].width,
            height: pages[index].height,
            animatedHint: pages[index].animated,
          ),
        ),
        readingDirection: sourceDirection,
      );


  test('portable VibeVenera metadata identifies animated title before decode', () {
    final chapter = manifest(
      sourceDirection: ReadingDirection.vertical,
      pages: const [
        (width: null, height: null, animated: false),
        (width: null, height: null, animated: false),
        (width: null, height: null, animated: false),
      ],
    );
    final metadata = AdaptiveReaderMetadata(
      sourceKey: 'local-folder',
      comicId: 'comic',
      title: '[Animated WEBP] sample',
    );
    final profile = classifyAdaptiveReaderLayout(
      chapter,
      metadata: metadata,
    );

    expect(profile?.animated, isTrue);
    expect(profile?.direction, ReadingDirection.ltr);
    expect(profile?.basis, 'title:animated webp');
    expect(profile?.metadataFingerprint, metadata.fingerprint);
  });

  test('source vertical direction alone is not adaptive evidence', () {
    final chapter = manifest(
      sourceDirection: ReadingDirection.vertical,
      pages: const [
        (width: null, height: null, animated: false),
        (width: null, height: null, animated: false),
        (width: null, height: null, animated: false),
      ],
    );

    expect(classifyAdaptiveReaderLayout(chapter), isNull);
  });

  test('cover is excluded and two content-page geometry samples decide', () {
    final chapter = manifest(
      pages: const [
        (width: 600, height: 3000, animated: false),
        (width: 1600, height: 1000, animated: false),
        (width: 1600, height: 1000, animated: false),
      ],
      sourceDirection: ReadingDirection.rtl,
    );

    final profile = classifyAdaptiveReaderLayout(chapter);
    expect(profile?.direction, ReadingDirection.rtl);
    expect(profile?.basis, 'page-geometry');
    expect(profile?.samples, 2);
  });

  test('decoded animation requires two non-cover pages', () {
    final chapter = manifest(
      sourceDirection: ReadingDirection.vertical,
      pages: const [
        (width: null, height: null, animated: false),
        (width: null, height: null, animated: false),
        (width: null, height: null, animated: false),
      ],
    );
    final classifier = AdaptiveReaderClassifier(chapter);

    expect(classifier.observeAnimated(chapter.pages[1]), isNull);
    final profile = classifier.observeAnimated(chapter.pages[2]);
    expect(profile?.animated, isTrue);
    expect(profile?.direction, ReadingDirection.ltr);
    expect(profile?.basis, 'decoded-animation');
    expect(profile?.samples, 2);
  });


  test('manifest animated hints do not replace decoded animation evidence', () {
    final chapter = manifest(
      sourceDirection: ReadingDirection.vertical,
      pages: const [
        (width: null, height: null, animated: true),
        (width: null, height: null, animated: true),
        (width: null, height: null, animated: true),
      ],
    );

    expect(classifyAdaptiveReaderLayout(chapter), isNull);
  });

  test('portable category and language metadata follow the VibeVenera model', () {
    final chapter = manifest(
      pages: const [
        (width: null, height: null, animated: false),
        (width: null, height: null, animated: false),
        (width: null, height: null, animated: false),
      ],
    );
    final category = AdaptiveReaderMetadata(
      sourceKey: 'source',
      comicId: 'comic',
      title: 'sample',
      tags: const <String>['category:comic'],
    );
    final korean = AdaptiveReaderMetadata(
      sourceKey: 'source',
      comicId: 'comic',
      title: 'sample',
      tags: const <String>['language:korean'],
    );

    expect(
      classifyAdaptiveReaderLayout(chapter, metadata: category)?.direction,
      ReadingDirection.ltr,
    );
    expect(
      classifyAdaptiveReaderLayout(chapter, metadata: korean)?.direction,
      ReadingDirection.vertical,
    );
  });

  test('persisted profile round-trips at the current model version', () {
    const profile = AdaptiveReaderProfile(
      direction: ReadingDirection.vertical,
      confidence: 0.92,
      basis: 'page-geometry',
      samples: 3,
    );

    final restored = AdaptiveReaderProfile.fromJson(profile.toJson());
    expect(restored, profile);
    expect(restored.modelVersion, AdaptiveReaderProfile.currentModelVersion);
  });
}
