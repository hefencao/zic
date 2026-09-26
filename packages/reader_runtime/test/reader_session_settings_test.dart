import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_runtime/reader_runtime.dart';

void main() {
  test('source webtoon confidence participates in settings identity and copy',
      () {
    const baseline = ReaderSessionSettings(sourceWebtoonConfidence: 0.25);
    final changed = baseline.copyWith(sourceWebtoonConfidence: 0.75);

    expect(baseline.sourceWebtoonConfidence, 0.25);
    expect(changed.sourceWebtoonConfidence, 0.75);
    expect(changed, isNot(baseline));
  });

  test('paged direction defaults LTR and can explicitly follow source', () {
    const defaults = ReaderSessionSettings();
    expect(
      defaults.resolvePagedDirection(ReadingDirection.rtl),
      ReadingDirection.ltr,
    );

    final source = defaults.copyWith(
      pagedDirectionPreference: ReaderPagedDirectionPreference.source,
    );
    expect(
      source.resolvePagedDirection(ReadingDirection.rtl),
      ReadingDirection.rtl,
    );

    final rtl = defaults.copyWith(
      pagedDirectionPreference: ReaderPagedDirectionPreference.rtl,
    );
    expect(
      rtl.resolvePagedDirection(ReadingDirection.ltr),
      ReadingDirection.rtl,
    );
  });

  test('long-press scale and status-bar mode participate in settings identity',
      () {
    const defaults = ReaderSessionSettings();
    expect(defaults.paged.effectiveLongPressZoomScale, 2.0);
    expect(defaults.systemStatusBarMode, ReaderSystemStatusBarMode.show);

    final changed = defaults.copyWith(
      paged: defaults.paged.copyWith(longPressZoomScale: 2.75),
      systemStatusBarMode: ReaderSystemStatusBarMode.followControls,
    );
    expect(changed.paged.effectiveLongPressZoomScale, 2.75);
    expect(
      changed.systemStatusBarMode,
      ReaderSystemStatusBarMode.followControls,
    );
    expect(changed.resolveSystemStatusBarVisible(false), isFalse);
    expect(changed.resolveSystemStatusBarVisible(true), isTrue);
    expect(
      defaults
          .copyWith(systemStatusBarMode: ReaderSystemStatusBarMode.hide)
          .resolveSystemStatusBarVisible(true),
      isFalse,
    );
    expect(defaults.resolveSystemStatusBarVisible(false), isTrue);
    expect(changed, isNot(defaults));
  });

  test('paged and continuous mode settings stay independent', () {
    const defaults = ReaderSessionSettings();
    final changed = defaults.copyWith(
      paged: defaults.paged.copyWith(
        crossChapterReading: true,
        zoomStages: const <double>[2.0, 3.0],
      ),
    );

    expect(changed.paged.crossChapterReading, isTrue);
    expect(changed.paged.zoomStageFirst, 2.0);
    expect(changed.continuous.crossChapterReading, isFalse);
    expect(changed.continuous.zoomStageFirst, 1.5);
    expect(
      changed.modeSettingsFor(ReaderMode.paged),
      isNot(changed.modeSettingsFor(ReaderMode.continuous)),
    );
  });

  test('page inversion is only effective for enabled per-comic settings', () {
    const disabled = ReaderSessionSettings(
      invertPageOrderOverride: true,
    );
    expect(disabled.effectiveInvertPageOrder, isFalse);

    const enabled = ReaderSessionSettings(
      comicSpecificEnabled: true,
      invertPageOrderOverride: true,
    );
    expect(enabled.effectiveInvertPageOrder, isTrue);

    expect(
      enabled.copyWith(comicSpecificEnabled: false).effectiveInvertPageOrder,
      isFalse,
    );
  });

  test('per-comic adaptive policy is independent from manual override master',
      () {
    const adaptive = ReaderSessionSettings(
      globalAdaptiveEnabled: true,
    );
    expect(adaptive.effectiveAdaptiveEnabled, isTrue);

    const disabled = ReaderSessionSettings(
      globalAdaptiveEnabled: true,
      comicAdaptiveEnabled: false,
    );
    expect(disabled.effectiveAdaptiveEnabled, isFalse);

    const disabledWithManualOverrides = ReaderSessionSettings(
      comicSpecificEnabled: true,
      globalAdaptiveEnabled: true,
      comicAdaptiveEnabled: false,
    );
    expect(disabledWithManualOverrides.effectiveAdaptiveEnabled, isFalse);
  });

  test('adaptive profile drives long-press zoom unless comic overrides it', () {
    const vertical = ReaderSessionSettings(
      globalAdaptiveEnabled: true,
      adaptiveProfile: AdaptiveReaderProfile(
        direction: ReadingDirection.vertical,
        confidence: 0.9,
        basis: 'test',
      ),
    );
    expect(
      vertical.effectiveLongPressZoomFor(ReadingDirection.vertical),
      isFalse,
    );
    final fixedPagedDirection = vertical.copyWith(
      comicSpecificEnabled: true,
      directionOverride: ReadingDirection.rtl,
    );
    expect(
      fixedPagedDirection.effectiveLongPressZoomFor(ReadingDirection.rtl),
      isFalse,
      reason: 'manual direction must not erase adaptive gesture semantics',
    );

    const paged = ReaderSessionSettings(
      globalAdaptiveEnabled: true,
      paged: ReaderModeSettings(longPressZoomEnabled: false),
      adaptiveProfile: AdaptiveReaderProfile(
        direction: ReadingDirection.rtl,
        confidence: 0.9,
        basis: 'test',
      ),
    );
    expect(paged.effectiveLongPressZoomFor(ReadingDirection.rtl), isTrue);

    final explicit = vertical.copyWith(
      comicSpecificEnabled: true,
      longPressZoomOverride: true,
    );
    expect(
      explicit.effectiveLongPressZoomFor(ReadingDirection.vertical),
      isTrue,
    );
  });
}
