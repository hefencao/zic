import 'dart:async';
import 'dart:math' as math;

import 'package:domain/domain.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:telemetry/telemetry.dart';

import 'reader_controller.dart';
import 'reader_frame_timing.dart';
import 'vertical_reader_geometry.dart';

part 'reader_page_host.dart';

typedef ReaderPageBuilder = Widget? Function(
  BuildContext context,
  PageAsset asset,
  VoidCallback reportFirstFrame,
);

/// How the zoomed content follows the finger during a long-press zoom.
enum ReaderLongPressMoveMode {
  /// Drag: content moves with the finger, scaled by the pan ratio.
  drag,

  /// Focus: the finger acts as a magnifier position; the content point under
  /// the finger stays under it while the rest of the page slides past.
  focus,
}

/// Where double-tap zoom anchors the magnified result.
enum ReaderDoubleTapZoomOrigin {
  /// Center: zoom around the viewport center regardless of the tap point.
  center,

  /// Snap: zoom around the tap point, then snap the image edge nearest the
  /// tap flush with that side of the viewport (right half snaps right edge).
  /// Axes whose scaled image cannot cover the viewport stay centered.
  snap,

  /// Focus: keep the tapped content point under the tap position.
  focus,
}

/// Clamps one translation axis against the actual scaled image rect instead
/// of the page widget: while the scaled image can cover the view it must
/// (one edge out means the opposite edge stays in); otherwise the image is
/// kept centered because panning cannot reveal more of it.
double _clampAxisForImage(
  double value, {
  required double scale,
  required double viewSize,
  required double? Function() imageStart,
  required double? Function() imageEnd,
}) {
  final start = imageStart();
  final end = imageEnd();
  if (start == null || end == null || !(end > start)) {
    return value.clamp(viewSize * (1 - scale), 0.0).toDouble();
  }
  final scaledStart = scale * start;
  final scaledEnd = scale * end;
  if (scaledEnd - scaledStart <= viewSize + precisionErrorTolerance) {
    return (viewSize - (scaledStart + scaledEnd)) / 2;
  }
  return value.clamp(viewSize - scaledEnd, -scaledStart).toDouble();
}


final class _ReaderVerticalScrollPhysics extends ClampingScrollPhysics {
  const _ReaderVerticalScrollPhysics({
    required this.geometryCorrectionTarget,
    super.parent,
  });

  final double? Function() geometryCorrectionTarget;

  @override
  _ReaderVerticalScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _ReaderVerticalScrollPhysics(
      geometryCorrectionTarget: geometryCorrectionTarget,
      parent: buildParent(ancestor),
    );
  }

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final target = geometryCorrectionTarget();
    if (target != null) {
      return target
          .clamp(newPosition.minScrollExtent, newPosition.maxScrollExtent)
          .toDouble();
    }
    return super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
  }
}

final class ReaderView extends StatefulWidget {
  const ReaderView({
    required this.controller,
    required this.clock,
    this.traceSink = const NoopTraceSink(),
    this.frameTimingSource,
    this.pageBuilder,
    this.pagePresentationRevisions = const <String, int>{},
    this.demandRevision,
    this.onTap,
    this.verticalStitch = false,
    this.pageAspectRatios = const <String, double>{},
    this.pageAspectRatiosListenable,
    this.zoomStageFirst = 1.5,
    this.zoomStageSecond = 2.0,
    this.longPressZoomEnabled = false,
    this.longPressZoomRestoreOnRelease = true,
    this.longPressZoomMoveMode = ReaderLongPressMoveMode.drag,
    this.longPressZoomPanRatio = 1.0,
    this.longPressZoomLimitToViewport = true,
    this.doubleTapZoomOrigin = ReaderDoubleTapZoomOrigin.center,
    this.onZoomScaleChanged,
    super.key,
  });

  final ReaderController controller;
  final MonoClock clock;
  final TraceSink traceSink;
  final ReaderFrameTimingSource? frameTimingSource;
  final ReaderPageBuilder? pageBuilder;

  /// Presentation-only rebuild revisions keyed by stable page asset identity.
  ///
  /// A force reload can replace one page's presentation subtree without
  /// recreating ReaderController, navigation state, or unrelated page slots.
  final Map<String, int> pagePresentationRevisions;
  final int Function()? demandRevision;
  final VoidCallback? onTap;

  /// Removes the visual gap between pages in continuous vertical mode.
  ///
  /// This is a presentation choice only. It does not merge page identities or
  /// alter pipeline demand, cache ownership, or source artifacts.
  final bool verticalStitch;

  /// Runtime-observed page height/width ratios keyed by stable asset identity.
  ///
  /// Source metadata remains the first choice. This projection fills missing
  /// or inaccurate dimensions after the media header is parsed, without
  /// changing page, download, decode or cache identity.
  final Map<String, double> pageAspectRatios;

  /// Live runtime ratio updates. Paged presentation consumes these lazily for
  /// zoom bounds and must not rebuild the whole PageView for one page header.
  /// Continuous vertical presentation still rebuilds when extents can change.
  final ValueListenable<Map<String, double>>? pageAspectRatiosListenable;

  /// Double-tap zoom stages, ascending and > 1. The cycle is
  /// 1x → [zoomStageFirst] → [zoomStageSecond] → 1x.
  final double zoomStageFirst;
  final double zoomStageSecond;

  /// Where double-tap zoom anchors the magnified result.
  final ReaderDoubleTapZoomOrigin doubleTapZoomOrigin;

  /// Enables the long-press magnifier lens that follows the finger.
  final bool longPressZoomEnabled;

  /// True (default) animates back to 1x when the long press ends. False keeps
  /// the zoom after release; double-tap or page change then returns to 1x.
  final bool longPressZoomRestoreOnRelease;

  /// Long-press zoom movement: drag follows the finger, focus keeps the
  /// magnified region centered on the finger position.
  final ReaderLongPressMoveMode longPressZoomMoveMode;

  /// Multiplier between finger travel and zoomed-content travel while dragging
  /// in [ReaderLongPressMoveMode.drag]. 1.0 follows the zoomed resolution
  /// exactly; values below 1 dampen small adjustments.
  final double longPressZoomPanRatio;

  /// When true (default), dragging cannot pull a scaled edge past the opposite
  /// viewport boundary: if the top goes out above, the bottom stays inside.
  /// When false, dragging is unconstrained.
  final bool longPressZoomLimitToViewport;

  /// Reports the settled zoom scale (1x when fully zoomed out) whenever a
  /// gesture completes or a stage transition finishes. Consumers use it to
  /// raise decode resolution for the visible region only.
  final ValueChanged<double>? onZoomScaleChanged;

  @override
  State<ReaderView> createState() => _ReaderViewState();
}

final class _ReaderViewState extends State<ReaderView>
    with TickerProviderStateMixin {
  late PageController _pageController;
  late ScrollController _verticalController;
  late final _ReaderVerticalScrollPhysics _verticalScrollPhysics;
  double _lastLogicalPosition = 0;
  int _lastMicros = 0;
  double? _lastPagedVelocity;
  int? _lastPagedMetricsMicros;
  Interaction _interaction = Interaction.idle;
  int _handledNavigationRevision = 0;
  int? _zoomedPage;
  int? _lastReportedVerticalPage;
  int _lastVerticalTravelDirection = 0;
  int? _lastVerticalVisibleMinIndex;
  int? _lastVerticalVisibleMaxIndex;
  late List<GlobalKey> _verticalPageLayoutKeys;
  int _lastVerticalLayoutSnapshotMicros = -1000000;
  int _lastTransitionTraceMicros = -1000000;
  int? _lastTransitionCurrentIndex;
  int? _lastTransitionTargetIndex;
  Interaction? _lastTransitionInteraction;
  ReaderFrameTimingSubscription? _frameTimingSubscription;
  _ReaderFrameTimingSummary? _frameTimingSummary;
  Size _viewport = Size.zero;
  double _devicePixelRatio = 1;
  late ReadingDirection _lastDirection;
  late int _lastRotationQuarterTurns;
  bool _syncScheduled = false;
  bool _anchorRestoreScheduled = false;
  ({int index, double offset})? _pendingVerticalAnchor;
  bool _commandScheduled = false;
  bool _verticalInitialOffsetApplied = false;
  late List<Widget> _pageSlots;
  late Map<String, double> _runtimePageAspectRatios;
  late Map<String, double> _verticalLayoutRatios;
  Map<String, double>? _pendingVerticalLayoutRatios;
  bool _verticalRatioCommitScheduled = false;
  bool _verticalFutureRatioAdoptionScheduled = false;
  bool _verticalObservationRefreshScheduled = false;
  double? _pendingVerticalGeometryCorrection;
  bool _verticalGeometryCorrectionClearScheduled = false;
  double? _lastVerticalScrollPixels;
  double? _lastVerticalLogicalPosition;
  double? _lastVerticalVelocity;
  int? _lastVerticalMetricsMicros;
  int? _lastVerticalScrollUpdateMicros;
  double? _lastVerticalScrollUpdatePixels;
  int _verticalCadenceWindowStartMicros = 0;
  int _verticalCadenceIntervalCount = 0;
  int _verticalCadenceGapSumMicros = 0;
  int _verticalCadenceMinGapMicros = 0;
  int _verticalCadenceMaxGapMicros = 0;
  int _verticalCadenceLt10ms = 0;
  int _verticalCadence10To14ms = 0;
  int _verticalCadence14To18ms = 0;
  int _verticalCadence18To20ms = 0;
  int _verticalCadence20To25ms = 0;
  int _verticalCadence25To35ms = 0;
  int _verticalCadenceGe35ms = 0;
  int _verticalCadenceDragDriven = 0;
  bool _verticalSceneMotionProbeActive = false;
  bool _verticalSceneMotionStopPending = false;
  int _verticalSceneMotionWindowStartMicros = 0;
  int _verticalSceneMotionSampleCount = 0;
  int _verticalSceneMotionValidSampleCount = 0;
  int _verticalSceneMotionMissingRenderBoxCount = 0;
  int _verticalSceneMotionMovingSampleCount = 0;
  int _verticalSceneMotionDragSampleCount = 0;
  int _verticalSceneMotionBallisticSampleCount = 0;
  int _verticalSceneMotionStationaryBallisticCount = 0;
  int _verticalSceneMotionResidualOutlierCount = 0;
  int _verticalSceneMotionFrameGapSumMicros = 0;
  int _verticalSceneMotionMinFrameGapMicros = 0;
  int _verticalSceneMotionMaxFrameGapMicros = 0;
  int _verticalSceneMotionGapLt10ms = 0;
  int _verticalSceneMotionGap10To14ms = 0;
  int _verticalSceneMotionGap14To18ms = 0;
  int _verticalSceneMotionGap18To20ms = 0;
  int _verticalSceneMotionGap20To25ms = 0;
  int _verticalSceneMotionGap25To35ms = 0;
  int _verticalSceneMotionGapGe35ms = 0;
  double _verticalSceneMotionMaxAbsResidualDeltaPx = 0;
  int? _verticalSceneMotionLastFrameStampMicros;
  int? _verticalSceneMotionLastCallbackMicros;
  double? _verticalSceneMotionLastPixels;
  double? _verticalSceneMotionLastResidualPx;
  late final ValueNotifier<int> _verticalKeepAliveCenter;
  int? _lastVerticalLayoutPageIndex;
  double? _lastVerticalLayoutGlobalTop;
  double? _lastVerticalLayoutGlobalBottom;
  int? _lastVerticalLayoutMicros;
  ReaderVerticalGeometry? _cachedVerticalGeometry;
  Map<String, double>? _cachedVerticalRatios;
  Size? _cachedVerticalViewport;
  bool? _cachedVerticalStitch;
  int? _cachedVerticalRotation;
  double? _cachedVerticalDevicePixelRatio;
  // Keep the steady-state composition window small while scrolling. The first
  // layout gets one bounded six-screen pass so initial adjacent hosts can
  // resolve before the reader is interactive; it is collapsed after the first
  // scroll ends and never grows incrementally during idle or scrolling.
  int _verticalCacheScreens = 2;
  bool _verticalInitialCompositionWarmupScheduled = false;
  bool _verticalInitialCompositionPrimed = false;
  // Strip-level zoom for continuous vertical reading. One uniform matrix
  // transforms every page together, so stitched seams cannot split under
  // zoom; page extents and ScrollPosition stay untouched.
  double _stripScale = 1;
  Offset _stripOffset = Offset.zero;
  late final ValueNotifier<Matrix4> _stripTransform =
      ValueNotifier<Matrix4>(Matrix4.identity());
  bool _stripPinchActive = false;
  double? _stripPinchBaseScale;
  Offset? _stripPinchBaseOffset;
  double? _stripPinchInitialDistance;
  Offset? _stripPinchInitialFocal;
  final Map<int, Offset> _stripPointerPositions = <int, Offset>{};
  bool _stripLensActive = false;
  Offset? _stripLensStartViewport;
  Offset? _stripLensBaseOffset;
  // A held second tap can freeze the strip's horizontal crop while the
  // reader continues to keep one uniform transform for every page.
  bool _stripHorizontalOffsetLocked = false;
  bool _stripHorizontalPanActive = false;
  Offset? _stripPanStartViewport;
  Offset? _stripPanBaseOffset;
  /// Discrete double-tap stage: -1 unzoomed, 0 first stage, 1 second stage.
  int _stripStageIndex = -1;
  /// Target of the running zoom animation, used to complete it instantly if
  /// a second pointer lands mid-flight.
  double? _stripAnimationTargetScale;
  AnimationController? _stripZoomAnimation;
  static const int _verticalInitialCacheScreens = 6;
  static const int _frameTimingBudgetMicros = 16667;
  static const int _frameTimingMissedVsyncMicros = 20000;
  static const int _frameTimingSummaryWindowMicros = 1000000;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.controller.currentIndex);
    _verticalController = _createVerticalController();
    _verticalScrollPhysics = _ReaderVerticalScrollPhysics(
      geometryCorrectionTarget: () => _pendingVerticalGeometryCorrection,
    );
    _lastLogicalPosition = widget.controller.currentIndex.toDouble();
    _lastMicros = widget.clock.nowMicros();
    _handledNavigationRevision = widget.controller.navigationRevision;
    _lastDirection = widget.controller.direction;
    _lastRotationQuarterTurns = widget.controller.rotationQuarterTurns;
    _lastVerticalVisibleMinIndex = widget.controller.currentIndex;
    _lastVerticalVisibleMaxIndex = widget.controller.currentIndex;
    _verticalKeepAliveCenter = ValueNotifier<int>(widget.controller.currentIndex);
    _verticalPageLayoutKeys = _createVerticalPageLayoutKeys();
    _runtimePageAspectRatios =
        widget.pageAspectRatiosListenable?.value ?? widget.pageAspectRatios;
    widget.pageAspectRatiosListenable?.addListener(_handlePageAspectRatiosChanged);
    _pageSlots = _createPageSlots();
    _verticalLayoutRatios = _runtimePageAspectRatios;
    widget.controller.addListener(_handleControllerCommand);
    _attachFrameTimingSource();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncToCurrentPage();
      _emitObservation(_lastLogicalPosition, 0);
    });
  }

  @override
  void didUpdateWidget(covariant ReaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageAspectRatiosListenable !=
        widget.pageAspectRatiosListenable) {
      oldWidget.pageAspectRatiosListenable
          ?.removeListener(_handlePageAspectRatiosChanged);
      widget.pageAspectRatiosListenable
          ?.addListener(_handlePageAspectRatiosChanged);
    }
    final frameSourceChanged =
        oldWidget.frameTimingSource != widget.frameTimingSource;
    final traceOwnerChanged = oldWidget.traceSink != widget.traceSink ||
        oldWidget.controller != widget.controller ||
        oldWidget.clock != widget.clock;
    if (frameSourceChanged) {
      _flushFrameTimingSummary(
        traceSink: oldWidget.traceSink,
        controller: oldWidget.controller,
        clock: oldWidget.clock,
        demandRevision: oldWidget.demandRevision,
      );
      _frameTimingSubscription?.cancel();
      _frameTimingSubscription = null;
      _attachFrameTimingSource();
    } else if (traceOwnerChanged) {
      _flushFrameTimingSummary(
        traceSink: oldWidget.traceSink,
        controller: oldWidget.controller,
        clock: oldWidget.clock,
        demandRevision: oldWidget.demandRevision,
      );
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerCommand);
      widget.controller.addListener(_handleControllerCommand);
      _pageController.dispose();
      _verticalController.dispose();
      _pageController = PageController(
        initialPage: widget.controller.currentIndex,
      );
      _verticalController = _createVerticalController();
      _verticalInitialOffsetApplied = false;
      _lastLogicalPosition = widget.controller.currentIndex.toDouble();
      _lastMicros = widget.clock.nowMicros();
      _interaction = Interaction.idle;
      _handledNavigationRevision = widget.controller.navigationRevision;
      _zoomedPage = null;
      _resetStripZoom();
      _lastReportedVerticalPage = null;
      _lastVerticalVisibleMinIndex = widget.controller.currentIndex;
      _lastVerticalVisibleMaxIndex = widget.controller.currentIndex;
      _verticalKeepAliveCenter.value = widget.controller.currentIndex;
      _verticalPageLayoutKeys = _createVerticalPageLayoutKeys();
      _lastVerticalLayoutSnapshotMicros = -1000000;
      _lastDirection = widget.controller.direction;
      _lastRotationQuarterTurns = widget.controller.rotationQuarterTurns;
      _pageSlots = _createPageSlots();
      _runtimePageAspectRatios =
          widget.pageAspectRatiosListenable?.value ?? widget.pageAspectRatios;
      _verticalLayoutRatios = _runtimePageAspectRatios;
      _pendingVerticalLayoutRatios = null;
      _verticalRatioCommitScheduled = false;
      _pendingVerticalGeometryCorrection = null;
      _resetVerticalCompositionCache();
      _scheduleSyncToCurrentPage();
    } else if ((oldWidget.pageBuilder == null) !=
            (widget.pageBuilder == null) ||
        oldWidget.traceSink != widget.traceSink ||
        oldWidget.clock != widget.clock) {
      _pageSlots = _createPageSlots();
    } else if (!mapEquals(
      oldWidget.pagePresentationRevisions,
      widget.pagePresentationRevisions,
    )) {
      final nextSlots = List<Widget>.of(_pageSlots);
      final pages = widget.controller.chapter.pages;
      for (var index = 0; index < pages.length; index++) {
        final assetKey = pages[index].assetKey;
        if ((oldWidget.pagePresentationRevisions[assetKey] ?? 0) ==
            (widget.pagePresentationRevisions[assetKey] ?? 0)) {
          continue;
        }
        nextSlots[index] = _createPageSlot(index);
      }
      _pageSlots = nextSlots;
    }
    final stitchChanged = oldWidget.verticalStitch != widget.verticalStitch;
    final nextRatios =
        widget.pageAspectRatiosListenable?.value ?? widget.pageAspectRatios;
    final ratiosChanged = !identical(_runtimePageAspectRatios, nextRatios);
    if (oldWidget.verticalStitch != widget.verticalStitch) {
      _preserveVerticalAnchor(
        oldRatios: _verticalLayoutRatios,
        oldStitch: oldWidget.verticalStitch,
      );
    }
    if (ratiosChanged) {
      _adoptPageAspectRatios(
        nextRatios,
        stitchChanged: stitchChanged,
        rebuild: false,
      );
    }
  }

  @override
  void dispose() {
    _detachFrameTimingSource();
    widget.pageAspectRatiosListenable
        ?.removeListener(_handlePageAspectRatiosChanged);
    widget.controller.removeListener(_handleControllerCommand);
    _stripZoomAnimation?.dispose();
    _stripTransform.dispose();
    _pageController.dispose();
    _verticalController.dispose();
    _verticalKeepAliveCenter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chapter = widget.controller.chapter;

    return LayoutBuilder(
      builder: (context, constraints) {
          final nextDevicePixelRatio = MediaQuery.devicePixelRatioOf(context);
          if (nextDevicePixelRatio.isFinite &&
              nextDevicePixelRatio > 0 &&
              nextDevicePixelRatio != _devicePixelRatio) {
            final previous = _devicePixelRatio;
            if (widget.controller.direction == ReadingDirection.vertical &&
                _viewport != Size.zero) {
              _preserveVerticalAnchor(
                oldRatios: _verticalLayoutRatios,
                oldStitch: widget.verticalStitch,
                oldDevicePixelRatio: previous,
              );
            }
            _devicePixelRatio = nextDevicePixelRatio;
          }
          final nextViewport = constraints.biggest;
          if (nextViewport.width.isFinite &&
              nextViewport.height.isFinite &&
              nextViewport.width > 0 &&
              nextViewport.height > 0 &&
              nextViewport != _viewport) {
            final previousViewport = _viewport;
            if (widget.controller.direction == ReadingDirection.vertical &&
                previousViewport != Size.zero) {
              _preserveVerticalAnchor(
                oldRatios: _verticalLayoutRatios,
                oldStitch: widget.verticalStitch,
                oldViewport: previousViewport,
              );
            }
            _viewport = nextViewport;
            if (widget.controller.direction == ReadingDirection.vertical &&
                previousViewport == Size.zero &&
                !_verticalInitialOffsetApplied) {
              _prepareVerticalControllerForCurrentPage();
            }
          }
          final direction = widget.controller.direction;
          if (direction == ReadingDirection.vertical) {
            final stitched = widget.verticalStitch;
            final geometry = _verticalGeometry();
            final pageCount = chapter.pages.length;
            final itemCount = stitched
                ? pageCount
                : (pageCount == 0 ? 0 : pageCount * 2 - 1);
            // Strip zoom is a viewport-space visual layer: scrolling stays
            // enabled while zoomed so the reader can keep flipping pages
            // under the magnifier. Pinch/double-tap/lens own zoom changes.
            _scheduleVerticalInitialCompositionWarmup();
            final cacheExtent = _viewport.height > 0
                ? _viewport.height * _verticalCacheScreens
                : null;
            final list = ListView.builder(
              key: const ValueKey<String>('reader-vertical-list'),
              controller: _verticalController,
              itemCount: itemCount,
              cacheExtent: cacheExtent,
              // While a held-double-tap / long-press pans horizontally it
              // must own the pointer exclusively: vertical page flipping is
              // suspended for the duration and resumes on release.
              physics: _stripLensActive
                  ? const NeverScrollableScrollPhysics()
                  : _verticalScrollPhysics,
              // In stitched mode adjacent pages share one paint layer. A
              // RepaintBoundary per page lets external texture edges round
              // independently while scrolling and can expose a transient
              // one-pixel background line.
              addRepaintBoundaries: !stitched,
              addSemanticIndexes: false,
              itemExtentBuilder: (itemIndex, _) {
                if (!stitched && itemIndex.isOdd) {
                  return readerVerticalPageGap;
                }
                final pageIndex = stitched ? itemIndex : itemIndex ~/ 2;
                return geometry.extentAt(pageIndex);
              },
              itemBuilder: (context, itemIndex) {
                if (!stitched && itemIndex.isOdd) {
                  final gapIndex = itemIndex ~/ 2;
                  return SizedBox(
                    key: ValueKey<String>('reader-vertical-gap:$gapIndex'),
                    height: readerVerticalPageGap,
                  );
                }
                final pageIndex = stitched ? itemIndex : itemIndex ~/ 2;
                final page = _buildPage(pageIndex);
                return SizedBox(
                  key: ValueKey<String>('reader-vertical-page:$pageIndex'),
                  height: geometry.extentAt(pageIndex),
                  child: SizedBox.expand(
                    key: _verticalPageLayoutKeys[pageIndex],
                    // Exact stitched extents already constrain the page. Avoid
                    // independent hard-clip edges during ordinary scrolling;
                    // strip zoom clips at the viewport, per-page zoom clips to
                    // its page so it cannot cover siblings.
                    child: (stitched || !_stripZoomed) && _zoomedPage == null
                        ? page
                        : ClipRect(child: page),
                  ),
                );
              },
            );
            final transformed = ClipRect(
              child: AnimatedBuilder(
                animation: _stripTransform,
                builder: (context, _) => Transform(
                  transform: _stripTransform.value,
                  alignment: Alignment.topLeft,
                  child: list,
                ),
              ),
            );
            // Pinch is tracked with raw pointers instead of a
            // ScaleGestureRecognizer so single-finger drags always stay with
            // the list's scroll recognizer.
            return NotificationListener<ScrollNotification>(
              onNotification: _handleVerticalScrollNotification,
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: _handleStripPointerDown,
                onPointerMove: _handleStripPointerMove,
                onPointerUp: _handleStripPointerUp,
                onPointerCancel: _handleStripPointerCancel,
                child: transformed,
              ),
            );
          }
          return NotificationListener<ScrollNotification>(
            onNotification: _handlePagedScrollNotification,
            child: PageView.builder(
              controller: _pageController,
              itemCount: chapter.pages.length,
              reverse: direction == ReadingDirection.rtl,
              scrollDirection: Axis.horizontal,
              physics: _zoomedPage == null
                  ? const PageScrollPhysics()
                  : const NeverScrollableScrollPhysics(),
              onPageChanged: _handlePageChanged,
              itemBuilder: (context, index) => _buildPage(index),
            ),
          );
      },
    );
  }

  Widget _buildPage(int index) => _pageSlots[index];

  /// Current display ratio (height/width) of a page, from runtime-observed
  /// ratios first and manifest dimensions as fallback. Used for image-rect
  /// based boundary constraints; null means the page box is assumed filled.
  double? _pageAspectRatioFor(int index) {
    final pages = widget.controller.chapter.pages;
    if (index < 0 || index >= pages.length) return null;
    final asset = pages[index];
    var ratio = _runtimePageAspectRatios[asset.assetKey];
    if (ratio == null) {
      final width = asset.width?.toDouble();
      final height = asset.height?.toDouble();
      if (width != null && height != null && width > 0 && height > 0) {
        ratio = height / width;
      }
    }
    if (ratio == null || !ratio.isFinite || ratio <= 0) return null;
    return ratio;
  }

  List<GlobalKey> _createVerticalPageLayoutKeys() => List<GlobalKey>.generate(
        widget.controller.chapter.pages.length,
        (index) => GlobalKey(debugLabel: 'reader-vertical-layout:$index'),
        growable: false,
      );

  List<Widget> _createPageSlots() => List<Widget>.generate(
        widget.controller.chapter.pages.length,
        _createPageSlot,
        growable: false,
      );

  Widget _createPageSlot(int index) {
    final asset = widget.controller.chapter.pages[index];
    return _ReaderPageShell(
      key: ValueKey<String>('reader-page-shell:${asset.assetKey}'),
      controller: widget.controller,
      keepAliveCenter: _verticalKeepAliveCenter,
      asset: asset,
      index: index,
      clock: widget.clock,
      traceSink: widget.traceSink,
      pageBuilder: widget.pageBuilder,
      demandRevision: widget.demandRevision,
      onTap: widget.onTap,
      onZoomChanged: (zoomed) {
        final next = zoomed ? index : null;
        if (_zoomedPage == next) return;
        setState(() => _zoomedPage = next);
      },
      zoomStageFirst: widget.zoomStageFirst,
      zoomStageSecond: widget.zoomStageSecond,
      longPressZoomEnabled: widget.longPressZoomEnabled,
      longPressZoomRestoreOnRelease: widget.longPressZoomRestoreOnRelease,
      longPressZoomMoveMode: widget.longPressZoomMoveMode,
      longPressZoomPanRatio: widget.longPressZoomPanRatio,
      longPressZoomLimitToViewport: widget.longPressZoomLimitToViewport,
      doubleTapZoomOrigin: widget.doubleTapZoomOrigin,
      pageAspectRatio: () => _pageAspectRatioFor(index),
      onScaleChanged: widget.onZoomScaleChanged,
      onStripLensStart: _handleStripLensStartedAt,
      onStripPanHoldStart: _handleStripPanHoldStartedAt,
      onStripLensMove: _handleStripLensMovedTo,
      onStripLensEnd: _handleStripLensFinished,
      onStripDoubleTap: _handleStripDoubleTappedAt,
    );
  }

  bool get _verticalScrollActive {
    if (_verticalController.hasClients &&
        _verticalController.position.isScrollingNotifier.value) {
      return true;
    }
    return _interaction == Interaction.dragging ||
        _interaction == Interaction.scrolling ||
        _interaction == Interaction.settling ||
        _interaction == Interaction.scrubbing;
  }

  void _handlePageAspectRatiosChanged() {
    final latest = widget.pageAspectRatiosListenable?.value;
    if (latest == null || identical(_runtimePageAspectRatios, latest)) {
      return;
    }
    _adoptPageAspectRatios(
      latest,
      stitchChanged: false,
      rebuild: true,
    );
  }

  void _adoptPageAspectRatios(
    Map<String, double> latest, {
    required bool stitchChanged,
    required bool rebuild,
  }) {
    _runtimePageAspectRatios = latest;
    if (widget.controller.direction != ReadingDirection.vertical) {
      // Horizontal presentation uses the ratio only when a page enters a zoom
      // boundary calculation. Updating the live projection is sufficient; a
      // full PageView rebuild would amplify one media-header observation into
      // a whole-reader frame stall.
      _verticalLayoutRatios = latest;
      _pendingVerticalLayoutRatios = null;
      _invalidateVerticalGeometryCache();
      return;
    }
    if (_verticalScrollActive || _stripZoomed || _stripLensActive) {
      // Ratios for pages strictly beyond the current viewport cannot change
      // the prefix or extents of anything being painted now. Adopt those
      // decode-ahead facts immediately so they are stable before the page
      // enters the viewport. Changes at/before the visible tail remain
      // pending until idle, preserving the dev.280 scroll-stable prefix.
      _adoptFutureVerticalRatios(latest);
      _pendingVerticalLayoutRatios =
          _sameVerticalRatios(_verticalLayoutRatios, latest) ? null : latest;
    } else {
      if (!stitchChanged) {
        _preserveVerticalAnchor(
          oldRatios: _verticalLayoutRatios,
          oldStitch: widget.verticalStitch,
          nextRatios: latest,
        );
      }
      _verticalLayoutRatios = latest;
      _pendingVerticalLayoutRatios = null;
      _invalidateVerticalGeometryCache();
      _scheduleVerticalObservationRefreshAfterLayout();
    }
    if (rebuild && mounted) {
      setState(() {});
    }
  }

  void _adoptFutureVerticalRatios(Map<String, double> latest) {
    final pages = widget.controller.chapter.pages;
    if (pages.isEmpty || _lastVerticalTravelDirection == 0) return;
    final visibleMin = (_lastVerticalVisibleMinIndex ??
            widget.controller.currentIndex)
        .clamp(0, pages.length - 1)
        .toInt();
    final visibleMax = (_lastVerticalVisibleMaxIndex ??
            widget.controller.currentIndex)
        .clamp(0, pages.length - 1)
        .toInt();
    final oldGeometry = _verticalGeometry();
    final oldPixels = _verticalController.hasClients
        ? _verticalController.position.pixels
        : null;
    final oldAnchor = oldPixels == null
        ? null
        : oldGeometry.anchorForTop(oldPixels);
    Map<String, double>? merged;
    final adopted = <int>[];

    void adopt(int index) {
      final key = pages[index].assetKey;
      final ratio = latest[key];
      if (ratio == null || _verticalLayoutRatios[key] == ratio) return;
      merged ??= <String, double>{..._verticalLayoutRatios};
      merged![key] = ratio;
      adopted.add(index);
    }

    if (_lastVerticalTravelDirection > 0) {
      // Higher-index future pages are after the painted prefix, so their
      // measured extents can be installed immediately without moving anything
      // already visible.
      for (var index = visibleMax + 1; index < pages.length; index++) {
        adopt(index);
      }
    } else {
      // When scrolling toward lower indexes, the incoming pages are part of
      // the prefix of the current viewport. Their measured extents still need
      // to be installed before they become visible, but doing so must atomically
      // shift ScrollPosition by the same prefix delta. Otherwise fast reverse
      // scrolling keeps one-screen provisional extents and visibly reflows when
      // the reader later becomes idle.
      for (var index = 0; index < visibleMin; index++) {
        adopt(index);
      }
    }
    if (merged == null) return;
    final nextRatios = Map<String, double>.unmodifiable(merged!);
    double? correction;
    if (_lastVerticalTravelDirection < 0 &&
        oldAnchor != null &&
        oldPixels != null) {
      correction = _verticalGeometry(ratios: nextRatios)
          .restoreTop(oldAnchor);
      if ((correction - oldPixels).abs() > 0.01) {
        _pendingVerticalGeometryCorrection = correction;
        _scheduleVerticalGeometryCorrectionClear();
      }
    }
    _verticalLayoutRatios = nextRatios;
    _invalidateVerticalGeometryCache();
    widget.traceSink.record(
      traceEvent(
        clock: widget.clock,
        sessionId: widget.controller.sessionId,
        kind: TraceEventKind.pageGeometryPrepared,
        revision: widget.demandRevision?.call(),
        payload: <String, Object?>{
          'pageIndexes': adopted,
          'visibleMinIndex': visibleMin,
          'visibleMaxIndex': visibleMax,
          'travelDirection': _lastVerticalTravelDirection,
          if (correction != null) 'geometryCorrectionTarget': correction,
          'interaction': _interaction.name,
          'source': 'decode-ahead-ratio',
        },
      ),
    );
  }

  void _scheduleFutureVerticalRatioAdoption() {
    if (_verticalFutureRatioAdoptionScheduled ||
        _pendingVerticalLayoutRatios == null ||
        _lastVerticalTravelDirection == 0 ||
        widget.controller.direction != ReadingDirection.vertical) {
      return;
    }
    _verticalFutureRatioAdoptionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _verticalFutureRatioAdoptionScheduled = false;
      if (!mounted ||
          widget.controller.direction != ReadingDirection.vertical ||
          !_verticalScrollActive) {
        return;
      }
      final pending = _pendingVerticalLayoutRatios;
      if (pending == null) return;
      final prior = _verticalLayoutRatios;
      _adoptFutureVerticalRatios(pending);
      _pendingVerticalLayoutRatios =
          _sameVerticalRatios(_verticalLayoutRatios, pending) ? null : pending;
      if (identical(prior, _verticalLayoutRatios)) return;
      setState(() {});
      _scheduleVerticalObservationRefreshAfterLayout();
    });
  }

  bool _sameVerticalRatios(
    Map<String, double> left,
    Map<String, double> right,
  ) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (right[entry.key] != entry.value) return false;
    }
    return true;
  }

  void _invalidateVerticalGeometryCache() {
    _cachedVerticalGeometry = null;
    _cachedVerticalRatios = null;
    _cachedVerticalViewport = null;
    _cachedVerticalStitch = null;
    _cachedVerticalRotation = null;
    _cachedVerticalDevicePixelRatio = null;
  }

  void _schedulePendingVerticalRatioCommit() {
    if (_verticalRatioCommitScheduled ||
        _pendingVerticalLayoutRatios == null ||
        widget.controller.direction != ReadingDirection.vertical) {
      return;
    }
    _verticalRatioCommitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _verticalRatioCommitScheduled = false;
      if (!mounted ||
          widget.controller.direction != ReadingDirection.vertical) {
        return;
      }
      if (_verticalScrollActive || _stripZoomed || _stripLensActive) {
        // ScrollEnd and isScrollingNotifier can settle on adjacent frames.
        // A zoomed strip must not resize its content underneath the
        // magnifier (that reads as a spontaneous zoom-out). Once the strip
        // returns to 1x and the interaction is idle, retry the commit on the
        // next frame instead of leaving measured ratios pending forever.
        if (_interaction == Interaction.idle &&
            _pendingVerticalLayoutRatios != null) {
          _schedulePendingVerticalRatioCommit();
        }
        return;
      }
      final pending = _pendingVerticalLayoutRatios;
      if (pending == null ||
          identical(pending, _verticalLayoutRatios) ||
          _sameVerticalRatios(_verticalLayoutRatios, pending)) {
        _pendingVerticalLayoutRatios = null;
        return;
      }
      _preserveVerticalAnchor(
        oldRatios: _verticalLayoutRatios,
        oldStitch: widget.verticalStitch,
        nextRatios: pending,
      );
      setState(() {
        _verticalLayoutRatios = pending;
        _pendingVerticalLayoutRatios = null;
        _invalidateVerticalGeometryCache();
      });
      _scheduleVerticalObservationRefreshAfterLayout();
    });
  }

  void _scheduleVerticalObservationRefreshAfterLayout() {
    if (_verticalObservationRefreshScheduled ||
        widget.controller.direction != ReadingDirection.vertical) {
      return;
    }
    _verticalObservationRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _verticalObservationRefreshScheduled = false;
      if (!mounted ||
          widget.controller.direction != ReadingDirection.vertical ||
          !_verticalController.hasClients ||
          !_verticalController.position.hasContentDimensions) {
        return;
      }
      _emitFromVerticalMetrics(
        _verticalController.position,
        forceLayoutSnapshot: true,
      );
    });
  }

  void _scheduleVerticalGeometryCorrectionClear() {
    if (_verticalGeometryCorrectionClearScheduled) return;
    _verticalGeometryCorrectionClearScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _verticalGeometryCorrectionClearScheduled = false;
      if (!mounted) return;
      // Keep the target alive through every layout pass of the geometry-change
      // frame. ScrollPosition may rerun layout after correctPixels().
      _pendingVerticalGeometryCorrection = null;
    });
  }

  void _resetVerticalCompositionCache() {
    _invalidateVerticalGeometryCache();
    _verticalCacheScreens = 2;
    _verticalInitialCompositionWarmupScheduled = false;
    _verticalInitialCompositionPrimed = false;
  }

  void _scheduleVerticalInitialCompositionWarmup() {
    if (_verticalInitialCompositionWarmupScheduled ||
        _verticalInitialCompositionPrimed ||
        _verticalCacheScreens >= 7 ||
        widget.controller.direction != ReadingDirection.vertical ||
        _viewport == Size.zero) {
      return;
    }
    _verticalInitialCompositionWarmupScheduled = true;
    _verticalCacheScreens = _verticalInitialCacheScreens;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          widget.controller.direction != ReadingDirection.vertical ||
          _verticalInitialCompositionPrimed) {
        return;
      }
      _verticalInitialCompositionPrimed = true;
    });
  }

  ScrollController _createVerticalController({
    double initialScrollOffset = 0,
  }) =>
      ScrollController(initialScrollOffset: initialScrollOffset);

  // ---------------------------------------------------------------------------
  // Continuous strip zoom. One uniform matrix scales every page together so
  // stitched seams cannot split; page extents, ScrollPosition and pipeline
  // demand stay untouched while zoomed.
  // ---------------------------------------------------------------------------

  bool get _stripZoomed {
    return _stripScale != 1;
  }

  Matrix4 get _currentStripMatrix => Matrix4.identity()
    ..translate(_stripOffset.dx, _stripOffset.dy)
    ..scale(_stripScale);

  void _applyStripMatrix() {
    _stripTransform.value = _currentStripMatrix;
    setState(() {});
  }

  void _cancelStripAnimation() {
    _stripZoomAnimation?.stop();
    _stripZoomAnimation?.dispose();
    _stripZoomAnimation = null;
    _stripAnimationTargetScale = null;
  }

  /// Completes an in-flight zoom animation instantly. Rapid tapping can put
  /// a second pointer on screen while the zoom is still animating; letting
  /// the pinch branch freeze that animation mid-scale looked like "zoom grew
  /// then shrank back".
  void _completeStripZoomAnimationInstantly() {
    final target = _stripAnimationTargetScale;
    if (_stripZoomAnimation == null || target == null) return;
    _cancelStripAnimation();
    _applyStripStageTarget(target);
    _stripScale = target;
    _stripOffset = _clampStripTranslation(_stripOffset, target);
    _stripTransform.value = _currentStripMatrix;
  }

  Offset _clampStripPivot(Offset globalPivot) {
    final size = _viewport;
    if (size == Size.zero) return Offset.zero;
    return Offset(
      globalPivot.dx.clamp(0.0, size.width).toDouble(),
      globalPivot.dy.clamp(0.0, size.height).toDouble(),
    );
  }

  /// Resolves a requested zoom into its settled scale/offset without touching
  /// live state, so animations can interpolate straight onto the final frame.
  ({double scale, Offset offset}) _resolvedStripZoom(
    double requestedScale,
    Offset pivotGlobal,
  ) {
    final clampedScale = requestedScale
        .clamp(1.0, math.max(widget.zoomStageSecond, 1.1))
        .toDouble();
    final size = _viewport == Size.zero
        ? const Size(1, 1)
        : _viewport;
    if (clampedScale <= 1.001) {
      return (scale: 1.0, offset: Offset.zero);
    }
    final focal = _clampStripPivot(pivotGlobal);
    // Keep the content point under the pivot fixed:
    // x_content = (f - o) / s  =>  offset' = f - s' * x_content.
    // Dividing by the CURRENT scale matters when re-zooming from a non-1x
    // state (second stage): otherwise the stage-1 offset is reused as if the
    // view were still at 1x and the offset lands out of bounds.
    final currentScale =
        _stripScale.isFinite && _stripScale > 0 ? _stripScale : 1.0;
    final dx =
        focal.dx - clampedScale * ((focal.dx - _stripOffset.dx) / currentScale);
    final dy =
        focal.dy - clampedScale * ((focal.dy - _stripOffset.dy) / currentScale);
    var offsetX = dx.clamp(size.width * (1 - clampedScale), 0.0).toDouble();
    var offsetY = dy.clamp(size.height * (1 - clampedScale), 0.0).toDouble();
    if ((size.width * clampedScale) < size.width + precisionErrorTolerance) {
      offsetX = (size.width - size.width * clampedScale) / 2;
    }
    if ((size.height * clampedScale) <
        size.height + precisionErrorTolerance) {
      offsetY = (size.height - size.height * clampedScale) / 2;
    }
    final offset = _clampStripTranslation(
      Offset(offsetX, offsetY),
      clampedScale,
    );
    return (scale: clampedScale, offset: offset);
  }

  void _setStripZoom(double scale, Offset pivotGlobal) {
    final resolved = _resolvedStripZoom(scale, pivotGlobal);
    _stripScale = resolved.scale;
    _stripOffset = resolved.offset;
    _applyStripMatrix();
  }

  void _animateStripZoom(double targetScale, Offset pivotGlobal) {
    _cancelStripAnimation();
    final startScale = _stripScale;
    final startOffset = _stripOffset;
    if (targetScale <= 1.001 && startScale <= 1.001) {
      return;
    }
    // Resolve the settled frame up front so the interpolation lands exactly
    // on it: interpolating the offset toward zero and correcting afterwards
    // made every double-tap visibly jump back after the zoom.
    final resolved = _resolvedStripZoom(targetScale, pivotGlobal);
    _stripAnimationTargetScale = resolved.scale;
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _stripZoomAnimation = controller;
    controller.addListener(() {
      final eased = Curves.easeOutCubic.transform(controller.value);
      _stripScale = startScale + (resolved.scale - startScale) * eased;
      _stripOffset = _clampStripTranslation(
        Offset.lerp(startOffset, resolved.offset, eased)!,
        _stripScale,
      );
      _applyStripMatrix();
    });
    controller.addStatusListener((status) {
      if (status != AnimationStatus.completed) return;
      _stripScale = resolved.scale;
      _stripOffset = resolved.offset;
      _applyStripMatrix();
      _stripAnimationTargetScale = null;
      _notifyZoomSettled();
    });
    controller.forward();
  }

  /// Stage the next double-tap advances to. While a zoom animation is still
  /// running, the TARGET scale (not the in-flight value) is the reference so
  /// rapid double-tap sequences step monotonically 1x → 一级 → 二级 → 1x and
  /// can never read an intermediate scale as "already at second stage" and
  /// fall back to the smaller stage.
  double _nextStripZoomTarget() {
    // Discrete stage tracking: independent of in-flight animation state so
    // rapid double-tap sequences always step 1x → 一级 → 二级 → 1x and can
    // never fall back to a smaller stage mid-animation.
    switch (_stripStageIndex) {
      case 0:
        return math.max(math.max(1.1, widget.zoomStageFirst),
            widget.zoomStageSecond);
      case 1:
        return 1.0;
      default:
        return math.max(1.1, widget.zoomStageFirst);
    }
  }

  void _applyStripStageTarget(double target) {
    final first = math.max(1.1, widget.zoomStageFirst);
    final second = math.max(first, widget.zoomStageSecond);
    if (target <= 1.001) {
      _stripStageIndex = -1;
    } else if (target >= second - 0.01) {
      _stripStageIndex = 1;
    } else {
      _stripStageIndex = 0;
    }
  }

  Offset _stripPivotForOrigin(Offset viewportLocal) {
    final size = _viewport == Size.zero ? const Size(1, 1) : _viewport;
    switch (widget.doubleTapZoomOrigin) {
      case ReaderDoubleTapZoomOrigin.center:
        return _clampStripPivot(size.center(Offset.zero));
      case ReaderDoubleTapZoomOrigin.snap:
        // Pivot from the horizontal edge nearest the tap so that edge snaps
        // flush with that side of the viewport; the vertical anchor keeps
        // the tap position.
        final pivotX = viewportLocal.dx >= size.width / 2 ? size.width : 0.0;
        return _clampStripPivot(Offset(pivotX, viewportLocal.dy));
      case ReaderDoubleTapZoomOrigin.focus:
        return _clampStripPivot(viewportLocal);
    }
  }

  void _cycleStripZoom(Offset globalPivot) {
    final next = _nextStripZoomTarget();
    _applyStripStageTarget(next);
    final local = _viewportLocalFromGlobal(globalPivot);
    _animateStripZoom(next, _stripPivotForOrigin(local));
  }

  void _notifyZoomSettled() {
    widget.onZoomScaleChanged?.call(_stripScale);
    // Leaving the magnifier unblocks deferred ratio commits; without this a
    // zoom session that spanned a measurement would pin stale extents until
    // the next scroll.
    if (_stripScale <= 1.001 && !_stripLensActive) {
      _schedulePendingVerticalRatioCommit();
    }
  }

  void _beginStripHorizontalPanTracking(Offset globalPosition) {
    _stripHorizontalPanActive = false;
    _stripPanStartViewport = _viewportLocalFromGlobal(globalPosition);
    _stripPanBaseOffset = _stripOffset;
  }

  void _resetStripHorizontalPanTracking() {
    _stripHorizontalPanActive = false;
    _stripPanStartViewport = null;
    _stripPanBaseOffset = null;
  }

  void _handleStripPointerDown(PointerDownEvent event) {
    _stripPointerPositions[event.pointer] = event.position;
    if (_stripPointerPositions.length == 1) {
      _beginStripHorizontalPanTracking(event.position);
    }
    if (_stripPointerPositions.length == 2) {
      _resetStripHorizontalPanTracking();
      _completeStripZoomAnimationInstantly();
      final positions =
          _stripPointerPositions.values.toList(growable: false);
      _stripPinchActive = true;
      _stripPinchBaseScale = _stripScale;
      _stripPinchBaseOffset = _stripOffset;
      _stripPinchInitialDistance = (positions[0] - positions[1]).distance;
      _stripPinchInitialFocal = Offset(
        (positions[0].dx + positions[1].dx) / 2,
        (positions[0].dy + positions[1].dy) / 2,
      );
      setState(() {});
    }
  }

  void _handleStripPointerMove(PointerMoveEvent event) {
    if (!_stripPointerPositions.containsKey(event.pointer)) return;
    _stripPointerPositions[event.pointer] = event.position;
    if (_stripPinchActive &&
        _stripPointerPositions.length >= 2 &&
        _stripPinchInitialDistance != null &&
        _stripPinchInitialDistance! > 0) {
      final positions =
          _stripPointerPositions.values.toList(growable: false);
      final distance = (positions[0] - positions[1]).distance;
      final focal = Offset(
        (positions[0].dx + positions[1].dx) / 2,
        (positions[0].dy + positions[1].dy) / 2,
      );
      _applyStripPinch(
        newDistance: distance,
        newFocal: focal,
      );
      return;
    }
    if (_stripPointerPositions.length != 1 ||
        !_stripZoomed ||
        _stripHorizontalOffsetLocked ||
        _stripLensActive) {
      return;
    }
    final start = _stripPanStartViewport;
    final base = _stripPanBaseOffset;
    if (start == null || base == null) return;
    final local = _viewportLocalFromGlobal(event.position);
    final delta = local - start;
    if (!_stripHorizontalPanActive) {
      if (delta.distance <= kTouchSlop || delta.dx.abs() <= delta.dy.abs()) {
        return;
      }
      _stripHorizontalPanActive = true;
    }
    _stripOffset = _clampStripTranslation(
      Offset(base.dx + delta.dx, base.dy),
      _stripScale,
    );
    _applyStripMatrix();
  }

  void _handleStripPointerUp(PointerUpEvent event) {
    _stripPointerPositions.remove(event.pointer);
    if (_stripPinchActive && _stripPointerPositions.length < 2) {
      _finishStripPinch();
    }
    if (_stripPointerPositions.isEmpty) {
      _resetStripHorizontalPanTracking();
    } else if (!_stripPinchActive && _stripPointerPositions.length == 1) {
      _beginStripHorizontalPanTracking(
        _stripPointerPositions.values.first,
      );
    }
  }

  void _handleStripPointerCancel(PointerCancelEvent event) {
    _stripPointerPositions.remove(event.pointer);
    if (_stripPinchActive && _stripPointerPositions.length < 2) {
      _finishStripPinch();
    }
    if (_stripPointerPositions.isEmpty) {
      _resetStripHorizontalPanTracking();
    } else if (!_stripPinchActive && _stripPointerPositions.length == 1) {
      _beginStripHorizontalPanTracking(
        _stripPointerPositions.values.first,
      );
    }
  }

  void _applyStripPinch({
    required double newDistance,
    required Offset newFocal,
  }) {
    if (!_stripPinchActive || _stripPinchBaseScale == null) return;
    final base = _stripPinchBaseScale!;
    final baseOffset = _stripPinchBaseOffset ?? Offset.zero;
    final focalStart = _stripPinchInitialFocal ?? newFocal;
    final clamped = (base * (newDistance / _stripPinchInitialDistance!))
        .clamp(1.0, math.max(widget.zoomStageSecond, widget.zoomStageFirst))
        .toDouble();
    // The content point under the starting focal stays under the moving
    // focal while the strip scales.
    final contentPointDx = (focalStart.dx - baseOffset.dx) / base;
    final contentPointDy = (focalStart.dy - baseOffset.dy) / base;
    final dx = newFocal.dx - contentPointDx * clamped;
    final dy = newFocal.dy - contentPointDy * clamped;
    _stripScale = clamped;
    if (clamped <= 1.001) {
      _stripOffset = Offset.zero;
      _stripTransform.value = Matrix4.identity();
      return;
    }
    _stripOffset = _clampStripTranslation(Offset(dx, dy), clamped);
    _stripTransform.value = _currentStripMatrix;
  }

  void _finishStripPinch() {
    if (!_stripPinchActive) return;
    _stripPinchActive = false;
    _stripPinchBaseScale = null;
    _stripPinchBaseOffset = null;
    _stripPinchInitialDistance = null;
    _stripPinchInitialFocal = null;
    // The pinch result persists: no snap-back on release. A pinch that ends
    // at/below 1x collapses to identity; anything above keeps its scale and
    // offset so accidental light two-finger contact cannot discard a zoom.
    if (!_stripZoomed) {
      _stripScale = 1;
      _stripOffset = Offset.zero;
      _stripStageIndex = -1;
      _applyStripMatrix();
      _notifyZoomSettled();
      return;
    }
    _applyStripStageTarget(_stripScale);
    _setStripZoom(_stripScale, _viewport.center(Offset.zero));
    _notifyZoomSettled();
  }

  void _handleStripDoubleTappedAt(Offset global) {
    // A subsequent double-tap is the explicit way out of the fixed-crop
    // state. Unlocking itself must not unexpectedly advance to another zoom
    // stage; ordinary double-taps only cycle while the strip is unlocked.
    if (_stripHorizontalOffsetLocked) {
      _stripHorizontalOffsetLocked = false;
      setState(() {});
      return;
    }
    _cycleStripZoom(global);
  }

  Offset _viewportLocalFromGlobal(Offset global) {
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      return box.globalToLocal(global);
    }
    return global;
  }

  void _handleStripLensStartedAt() {
    final pointer = _stripPointerPositions.values.isEmpty
        ? null
        : _stripPointerPositions.values.first;
    if (pointer == null) return;
    _handleStripLensStartAt(_viewportLocalFromGlobal(pointer));
  }

  double get _effectiveStripPanRatio =>
      widget.longPressZoomPanRatio.isFinite &&
              widget.longPressZoomPanRatio > 0
          ? widget.longPressZoomPanRatio.clamp(0.25, 4.0).toDouble()
          : 1.0;

  /// Horizontal image edges (in viewport coordinates) of the current page,
  /// or null when the page is assumed to fill the width. Pages are laid out
  /// full-width; a contain-fit image narrower than the box leaves side bars
  /// that the boundary constraint must not treat as draggable content.
  ({double left, double right})? _stripCurrentImageEdges() {
    final size = _viewport;
    if (size == Size.zero) return null;
    final index = widget.controller.currentIndex;
    final ratio = _pageAspectRatioFor(index);
    if (ratio == null) return null;
    final boxHeight = _verticalGeometry().extentAt(index);
    var imageWidth = size.width;
    var imageHeight = imageWidth * ratio;
    if (imageHeight > boxHeight && imageHeight > 0) {
      imageHeight = boxHeight;
      imageWidth = imageHeight / ratio;
    }
    final left = (size.width - imageWidth) / 2;
    return (left: left, right: left + imageWidth);
  }

  /// Keeps a scaled edge from passing the opposite viewport boundary while
  /// [ReaderView.longPressZoomLimitToViewport] is enabled: if the top leaves
  /// through the top, the bottom stays inside the bottom. The horizontal axis
  /// follows the actual current-page image rect, not just the page widget, so
  /// letterboxed pages stay centered instead of sliding off screen. The
  /// vertical range scales with the live [_stripScale], so second-stage zoom
  /// gets the full second-stage travel instead of a smaller-stage bound.
  Offset _clampStripTranslation(Offset translation, double scale) {
    if (!widget.longPressZoomLimitToViewport) return translation;
    final size = _viewport == Size.zero ? const Size(1, 1) : _viewport;
    final dx = _clampAxisForImage(
      translation.dx,
      scale: scale,
      viewSize: size.width,
      imageStart: () => _stripCurrentImageEdges()?.left,
      imageEnd: () => _stripCurrentImageEdges()?.right,
    );
    final dy = translation.dy
        .clamp(size.height * (1 - scale), 0.0)
        .toDouble();
    return Offset(dx, dy);
  }

  void _handleStripLensMovedTo(Offset globalPosition) {
    if (!_stripLensActive || !_stripZoomed) return;
    final start = _stripLensStartViewport;
    final base = _stripLensBaseOffset;
    if (start == null || base == null) return;
    if (_stripHorizontalOffsetLocked) return;
    final local = _viewportLocalFromGlobal(globalPosition);
    final scale = _stripScale;
    // Horizontal only: the lens drags left/right while the vertical axis
    // stays with native scrolling, so the two never fight mid-gesture.
    final double translationX;
    switch (widget.longPressZoomMoveMode) {
      case ReaderLongPressMoveMode.drag:
        // Content follows the finger relative to the lens-entry state,
        // scaled by the configured ratio against the zoomed resolution.
        translationX =
            base.dx + (local.dx - start.dx) * _effectiveStripPanRatio;
      case ReaderLongPressMoveMode.focus:
        // The content point under the finger stays under it: t = p * (1 - s).
        translationX = local.dx * (1 - scale);
    }
    _stripOffset = _clampStripTranslation(
      Offset(translationX, _stripOffset.dy),
      scale,
    );
    _applyStripMatrix();
  }

  void _handleStripLensFinished() {
    if (!_stripLensActive) return;
    _stripLensActive = false;
    _stripLensStartViewport = null;
    // Continuous mode keeps the strip zoom and the panned offset after
    // release: there is no auto restore. Double-tap cycles back to 1x.
    _stripLensBaseOffset = null;
    // Re-enable list scrolling suspended for the hold gesture.
    // ignore: no-op guard, setState required for physics swap below.
    setState(() {});
    _notifyZoomSettled();
  }

  void _handleStripLensStartAt(Offset viewportLocal) {
    _cancelStripAnimation();
    _stripLensActive = true;
    final pivot = _clampStripPivot(viewportLocal);
    _stripLensStartViewport = pivot;
    // Entering the lens on an already-zoomed strip must not jump the scale:
    // the long press then acts as a horizontal drag whose offset locks on
    // release. Only an unzoomed strip enters at the magnifier scale.
    if (!_stripZoomed) {
      _setStripZoom(
        math.max(widget.zoomStageFirst, 2.0),
        pivot,
      );
    }
    // Keep the discrete double-tap stages in sync with the magnifier scale
    // so a later double-tap advances/exits relative to what is on screen.
    _applyStripStageTarget(_stripScale);
    _stripLensBaseOffset = _stripOffset;
  }

  /// The second press of a double-tap held past the threshold: keep the
  /// current zoom stage and enter fixed horizontal-offset mode. A hold that
  /// starts at 1x still enters the first magnification stage.
  void _handleStripPanHoldStartedAt() {
    final pointer = _stripPointerPositions.values.isEmpty
        ? null
        : _stripPointerPositions.values.first;
    if (pointer == null) return;
    final local = _viewportLocalFromGlobal(pointer);
    _cancelStripAnimation();
    _resetStripHorizontalPanTracking();
    _stripLensActive = true;
    _stripHorizontalOffsetLocked = true;
    _stripLensStartViewport = _clampStripPivot(local);
    if (!_stripZoomed) {
      // A hold from 1x still provides the natural first magnification. Once
      // already zoomed, however, the hold is only a lock gesture and must not
      // advance to the next discrete stage.
      final target = math.max(widget.zoomStageFirst, 2.0);
      _applyStripStageTarget(target);
      _setStripZoom(target, _stripPivotForOrigin(local));
    } else {
      _applyStripStageTarget(_stripScale);
      _stripOffset = _clampStripTranslation(_stripOffset, _stripScale);
      _applyStripMatrix();
    }
    _stripLensBaseOffset = _stripOffset;
  }

  void _resetStripZoom() {
    _cancelStripAnimation();
    if (!_stripLensActive &&
        !_stripHorizontalOffsetLocked &&
        _stripScale == 1 &&
        _stripOffset == Offset.zero) {
      return;
    }
    _stripLensActive = false;
    _stripLensStartViewport = null;
    _stripLensBaseOffset = null;
    _stripHorizontalOffsetLocked = false;
    _resetStripHorizontalPanTracking();
    _stripScale = 1;
    _stripOffset = Offset.zero;
    _stripStageIndex = -1;
    _applyStripMatrix();
  }



  ReaderVerticalGeometry _verticalGeometry({
    Map<String, double>? ratios,
    bool? stitch,
    Size? viewport,
    double? devicePixelRatio,
  }) {
    final effectiveRatios = ratios ?? _verticalLayoutRatios;
    final effectiveViewport = viewport ?? _viewport;
    final effectiveStitch = stitch ?? widget.verticalStitch;
    final effectiveRotation = widget.controller.rotationQuarterTurns;
    final effectiveDevicePixelRatio = devicePixelRatio ?? _devicePixelRatio;
    final cacheable = ratios == null &&
        stitch == null &&
        viewport == null &&
        devicePixelRatio == null;
    if (cacheable &&
        _cachedVerticalGeometry != null &&
        identical(_cachedVerticalRatios, effectiveRatios) &&
        _cachedVerticalViewport == effectiveViewport &&
        _cachedVerticalStitch == effectiveStitch &&
        _cachedVerticalRotation == effectiveRotation &&
        _cachedVerticalDevicePixelRatio == effectiveDevicePixelRatio) {
      return _cachedVerticalGeometry!;
    }
    final geometry = ReaderVerticalGeometry(
      pages: widget.controller.chapter.pages,
      ratios: effectiveRatios,
      viewportWidth: effectiveViewport.width,
      viewportHeight: effectiveViewport.height,
      stitch: effectiveStitch,
      rotationQuarterTurns: effectiveRotation,
      devicePixelRatio: effectiveDevicePixelRatio,
    );
    if (cacheable) {
      _cachedVerticalGeometry = geometry;
      _cachedVerticalRatios = effectiveRatios;
      _cachedVerticalViewport = effectiveViewport;
      _cachedVerticalStitch = effectiveStitch;
      _cachedVerticalRotation = effectiveRotation;
      _cachedVerticalDevicePixelRatio = effectiveDevicePixelRatio;
    }
    return geometry;
  }

  double _verticalExtent(
    PageAsset _,
    int index, {
    Map<String, double>? ratios,
    Size? viewport,
  }) =>
      _verticalGeometry(ratios: ratios, viewport: viewport).extentAt(index);

  ({double start, double end}) _verticalBoundsFor(
    int index, {
    Map<String, double>? ratios,
    bool? stitch,
    Size? viewport,
  }) {
    final geometry = _verticalGeometry(
      ratios: ratios,
      stitch: stitch,
      viewport: viewport,
    );
    final bounds = geometry.boundsAt(index);
    assert(
      _verticalExtent(
            widget.controller.chapter.pages[index],
            index,
            ratios: ratios,
            viewport: viewport,
          ) >=
          0,
    );
    return bounds;
  }

  void _preserveVerticalAnchor({
    required Map<String, double> oldRatios,
    required bool oldStitch,
    Size? oldViewport,
    double? oldDevicePixelRatio,
    Map<String, double>? nextRatios,
  }) {
    if (widget.controller.direction != ReadingDirection.vertical ||
        !_verticalController.hasClients ||
        !_verticalController.position.hasContentDimensions ||
        _verticalController.position.isScrollingNotifier.value ||
        _interaction != Interaction.idle ||
        _viewport == Size.zero) {
      return;
    }
    final anchor = _verticalGeometry(
      ratios: oldRatios,
      stitch: oldStitch,
      viewport: oldViewport,
      devicePixelRatio: oldDevicePixelRatio,
    ).anchorForTop(_verticalController.position.pixels);
    if (nextRatios != null) {
      final nextGeometry = _verticalGeometry(ratios: nextRatios);
      _pendingVerticalGeometryCorrection = nextGeometry.restoreTop(anchor);
      _scheduleVerticalGeometryCorrectionClear();
      return;
    }
    _pendingVerticalAnchor = (index: anchor.index, offset: anchor.offset);
    _scheduleVerticalAnchorRestore();
  }

  void _scheduleVerticalAnchorRestore() {
    if (_anchorRestoreScheduled) return;
    _anchorRestoreScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _anchorRestoreScheduled = false;
      if (!mounted) return;
      final anchor = _pendingVerticalAnchor;
      _pendingVerticalAnchor = null;
      if (anchor == null ||
          widget.controller.direction != ReadingDirection.vertical ||
          !_verticalController.hasClients ||
          !_verticalController.position.hasContentDimensions ||
          _verticalController.position.isScrollingNotifier.value ||
          _interaction != Interaction.idle) {
        return;
      }
      final position = _verticalController.position;
      final target = _verticalGeometry().restoreTop(
        ReaderVerticalAnchor(index: anchor.index, offset: anchor.offset),
      );
      final bounded = target.clamp(0.0, position.maxScrollExtent).toDouble();
      if ((bounded - position.pixels).abs() > 2.0) {
        _verticalController.jumpTo(bounded);
      }
    });
  }

  double _verticalOffsetFor(int index) =>
      _verticalGeometry().centeredOffsetFor(index);

  void _prepareVerticalControllerForCurrentPage() {
    if (_verticalController.hasClients || _viewport == Size.zero) return;
    final initialOffset = math.max(
      0.0,
      _verticalOffsetFor(widget.controller.currentIndex),
    );
    _verticalController.dispose();
    _verticalController = _createVerticalController(
      initialScrollOffset: initialOffset,
    );
    _verticalInitialOffsetApplied = true;
  }

  void _handleControllerCommand() {
    final controller = widget.controller;
    var rebuildLayout = false;
    if (_lastDirection != controller.direction) {
      _flushFrameTimingSummary();
      _lastDirection = controller.direction;
      _zoomedPage = null;
      _resetStripZoom();
      _verticalKeepAliveCenter.value = controller.currentIndex;
      _resetVerticalCompositionCache();
      rebuildLayout = true;
      if (controller.direction == ReadingDirection.vertical) {
        _verticalLayoutRatios = _runtimePageAspectRatios;
        _pendingVerticalLayoutRatios = null;
        _verticalInitialOffsetApplied = false;
        _prepareVerticalControllerForCurrentPage();
      } else {
        _verticalLayoutRatios = _runtimePageAspectRatios;
        _pendingVerticalLayoutRatios = null;
      }
      _scheduleSyncToCurrentPage();
    }
    if (_lastRotationQuarterTurns != controller.rotationQuarterTurns) {
      _lastRotationQuarterTurns = controller.rotationQuarterTurns;
      _cachedVerticalGeometry = null;
      rebuildLayout = true;
    }
    if (rebuildLayout && mounted) {
      setState(() {});
    }
    final revision = controller.navigationRevision;
    if (revision == _handledNavigationRevision) return;
    final requested = controller.requestedIndex;
    if (requested == null) {
      _handledNavigationRevision = revision;
      if (_interaction == Interaction.scrubbing && !controller.pageScrubbing) {
        _interaction = Interaction.idle;
        if (controller.direction == ReadingDirection.vertical &&
            _verticalController.hasClients &&
            _verticalController.position.hasContentDimensions) {
          _emitFromVerticalMetrics(_verticalController.position);
          _schedulePendingVerticalRatioCommit();
        } else {
          _emitObservation(
            controller.currentIndex.toDouble(),
            0,
            stableIndex: controller.currentIndex,
          );
        }
      }
      return;
    }
    if (controller.direction == ReadingDirection.vertical) {
      if (!_verticalController.hasClients ||
          _viewport == Size.zero ||
          !_verticalController.position.hasContentDimensions) {
        _scheduleControllerCommand();
        return;
      }
      _handledNavigationRevision = revision;
      _interaction = controller.pageScrubbing
          ? Interaction.scrubbing
          : Interaction.jumping;
      _zoomedPage = null;
      // Strip zoom intentionally survives page jumps: scrolling stays
      // enabled while zoomed, so navigation must not reset it either.
      final maxExtent = _verticalController.position.maxScrollExtent;
      _verticalController.jumpTo(
        _verticalOffsetFor(requested).clamp(0.0, maxExtent).toDouble(),
      );
      _completeVerticalPageRequest(revision, requested);
      return;
    }
    if (!_pageController.hasClients ||
        !_pageController.position.hasViewportDimension) {
      _scheduleControllerCommand();
      return;
    }
    _handledNavigationRevision = revision;
    _interaction = controller.pageScrubbing
        ? Interaction.scrubbing
        : Interaction.jumping;
    _zoomedPage = null;
    _pageController.jumpToPage(requested);
    controller.acknowledgePageRequest(revision);
  }

  void _scheduleControllerCommand() {
    if (_commandScheduled) return;
    _commandScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _commandScheduled = false;
      if (mounted) _handleControllerCommand();
    });
  }

  void _completeVerticalPageRequest(int revision, int requested) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          widget.controller.direction != ReadingDirection.vertical ||
          widget.controller.navigationRevision != revision ||
          widget.controller.requestedIndex != requested) {
        return;
      }
      if (!_verticalController.hasClients ||
          !_verticalController.position.hasContentDimensions) {
        _completeVerticalPageRequest(revision, requested);
        return;
      }
      final position = _verticalController.position;
      final bounds = _verticalBoundsFor(requested);
      final viewportStart = position.pixels;
      final viewportEnd = viewportStart + position.viewportDimension;
      final targetVisible =
          bounds.end > viewportStart && bounds.start < viewportEnd;
      if (!targetVisible) {
        final maxExtent = position.maxScrollExtent;
        _verticalController.jumpTo(
          _verticalOffsetFor(requested).clamp(0.0, maxExtent).toDouble(),
        );
        _completeVerticalPageRequest(revision, requested);
        return;
      }
      _lastLogicalPosition = requested.toDouble();
      _verticalKeepAliveCenter.value = requested;
      _interaction = widget.controller.pageScrubbing
          ? Interaction.scrubbing
          : Interaction.jumping;
      _emitObservation(
        requested.toDouble(),
        0,
        stableIndex: requested,
      );
      if (_lastReportedVerticalPage != requested) {
        _lastReportedVerticalPage = requested;
        _recordPageCurrent(requested);
      }
      widget.controller.acknowledgePageRequest(revision);
    });
  }

  void _scheduleSyncToCurrentPage() {
    if (_syncScheduled) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (mounted) _syncToCurrentPage();
    });
  }

  void _syncToCurrentPage() {
    final controller = widget.controller;
    final index = controller.currentIndex;
    if (controller.direction == ReadingDirection.vertical) {
      if (!_verticalController.hasClients ||
          _viewport == Size.zero ||
          !_verticalController.position.hasContentDimensions) {
        _scheduleSyncToCurrentPage();
        return;
      }
      final maxExtent = _verticalController.position.maxScrollExtent;
      _verticalKeepAliveCenter.value = index;
      _verticalController.jumpTo(
        _verticalOffsetFor(index).clamp(0.0, maxExtent).toDouble(),
      );
      return;
    }
    if (_pageController.hasClients) {
      _pageController.jumpToPage(index);
    }
  }

  void _attachFrameTimingSource() {
    final source = widget.frameTimingSource;
    if (source == null || _frameTimingSubscription != null) return;
    _frameTimingSubscription = source.subscribe(_handleFrameTimings);
  }

  void _detachFrameTimingSource() {
    _flushFrameTimingSummary();
    _frameTimingSubscription?.cancel();
    _frameTimingSubscription = null;
  }

  void _handleFrameTimings(List<ReaderFrameTimingSample> timings) {
    if (!mounted || timings.isEmpty) {
      return;
    }
    final vertical = widget.controller.direction == ReadingDirection.vertical;
    final pagePosition = !vertical && _pageController.hasClients
        ? _pageController.position
        : null;
    // Flutter delivers FrameTiming in batches. Reader state sampled here is
    // the callback-time state, not the historical state of every frame in the
    // batch, so attaching scroll/current/interaction to each sample invents a
    // false per-frame correlation. Preserve engine timing plus enough batch
    // anchors for offline monotonic alignment instead.
    final callbackMonotonicMicros = widget.clock.nowMicros();
    final context = _ReaderFrameTimingTraceContext(
      callbackMonotonicMicros: callbackMonotonicMicros,
      batchLastVsyncStartMicros: timings.last.vsyncStartMicros,
      mode: vertical ? 'vertical' : 'paged',
      scrollPixels: vertical ? _lastVerticalScrollPixels : pagePosition?.pixels,
      logicalPosition:
          vertical ? _lastVerticalLogicalPosition : _lastLogicalPosition,
      velocity: vertical ? _lastVerticalVelocity : _lastPagedVelocity,
      metricsMicros:
          vertical ? _lastVerticalMetricsMicros : _lastPagedMetricsMicros,
      layoutPageIndex: vertical ? _lastVerticalLayoutPageIndex : null,
      layoutGlobalTop: vertical ? _lastVerticalLayoutGlobalTop : null,
      layoutGlobalBottom: vertical ? _lastVerticalLayoutGlobalBottom : null,
      layoutMicros: vertical ? _lastVerticalLayoutMicros : null,
      interaction: _interaction,
      geometryCorrectionTarget:
          vertical ? _pendingVerticalGeometryCorrection : null,
      stitched: vertical && widget.verticalStitch,
    );
    for (var index = 0; index < timings.length; index++) {
      final timing = timings[index];
      if (_isFrameTimingOutlier(timing)) {
        _flushFrameTimingSummary();
        widget.traceSink.record(
          traceEvent(
            clock: widget.clock,
            sessionId: widget.controller.sessionId,
            kind: TraceEventKind.readerFrameTiming,
            revision: widget.demandRevision?.call(),
            payload: <String, Object?>{
              ...context.toPayload(),
              'buildMicros': timing.buildMicros,
              'rasterMicros': timing.rasterMicros,
              'totalSpanMicros': timing.totalSpanMicros,
              'vsyncOverheadMicros': timing.vsyncOverheadMicros,
              'vsyncStartMicros': timing.vsyncStartMicros,
              if (timing.frameIntervalMicros != null)
                'frameIntervalMicros': timing.frameIntervalMicros,
              'timingBatchIndex': index,
              'timingBatchSize': timings.length,
            },
          ),
        );
      } else {
        _appendFrameTimingSummary(timing, context);
      }
    }
  }

  // Keep every anomalous cadence sample individually. Healthy frames may be
  // summarized, but an interval hole is evidence in its own right even when
  // Flutter build/raster work is small; folding it would destroy the exact
  // sequence needed to distinguish UI stalls from idle/platform cadence.
  bool _isFrameTimingOutlier(ReaderFrameTimingSample timing) =>
      timing.buildMicros >= _frameTimingBudgetMicros ||
      timing.rasterMicros >= _frameTimingBudgetMicros ||
      timing.totalSpanMicros >= _frameTimingBudgetMicros ||
      (timing.frameIntervalMicros ?? 0) >= _frameTimingMissedVsyncMicros;

  void _appendFrameTimingSummary(
    ReaderFrameTimingSample timing,
    _ReaderFrameTimingTraceContext context,
  ) {
    final summary = _frameTimingSummary;
    if (summary != null &&
        timing.vsyncStartMicros - summary.firstVsyncStartMicros >=
            _frameTimingSummaryWindowMicros) {
      _flushFrameTimingSummary();
    }
    final pending = _frameTimingSummary;
    if (pending == null) {
      _frameTimingSummary = _ReaderFrameTimingSummary(timing, context);
    } else {
      pending.add(timing, context);
    }
  }

  void _flushFrameTimingSummary({
    TraceSink? traceSink,
    ReaderController? controller,
    MonoClock? clock,
    int Function()? demandRevision,
  }) {
    final summary = _frameTimingSummary;
    if (summary == null) return;
    _frameTimingSummary = null;
    (traceSink ?? widget.traceSink).record(
      traceEvent(
        clock: clock ?? widget.clock,
        sessionId: (controller ?? widget.controller).sessionId,
        kind: TraceEventKind.readerFrameTiming,
        revision: (demandRevision ?? widget.demandRevision)?.call(),
        payload: summary.toPayload(),
      ),
    );
  }

  bool _handlePagedScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) {
      _pendingVerticalAnchor = null;
      _interaction = widget.controller.pageScrubbing
          ? Interaction.scrubbing
          : notification.dragDetails == null
              ? Interaction.scrolling
              : Interaction.dragging;
      _emitFromPageMetrics(notification.metrics);
    } else if (notification is ScrollUpdateNotification) {
      _pendingVerticalAnchor = null;
      _interaction = widget.controller.pageScrubbing
          ? Interaction.scrubbing
          : notification.dragDetails == null
              ? Interaction.scrolling
              : Interaction.dragging;
      _emitFromPageMetrics(notification.metrics);
    } else if (notification is ScrollEndNotification) {
      _interaction = widget.controller.pageScrubbing
          ? Interaction.scrubbing
          : Interaction.idle;
      _emitFromPageMetrics(notification.metrics);
    }
    return false;
  }

  bool _handleVerticalScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) {
      _pendingVerticalAnchor = null;
      _pendingVerticalGeometryCorrection = null;
      _lastVerticalScrollUpdateMicros = null;
      _lastVerticalScrollUpdatePixels = null;
      _resetVerticalScrollCadenceSummary(widget.clock.nowMicros());
      _interaction = widget.controller.pageScrubbing
          ? Interaction.scrubbing
          : notification.dragDetails == null
              ? Interaction.scrolling
              : Interaction.dragging;
      _startVerticalSceneMotionProbe();
      _emitFromVerticalMetrics(notification.metrics, forceLayoutSnapshot: true);
    } else if (notification is ScrollUpdateNotification) {
      _pendingVerticalAnchor = null;
      final dragDriven = notification.dragDetails != null;
      _interaction = widget.controller.pageScrubbing
          ? Interaction.scrubbing
          : dragDriven
              ? Interaction.dragging
              : Interaction.scrolling;
      if (!_verticalSceneMotionProbeActive) {
        _startVerticalSceneMotionProbe();
      }
      _recordVerticalScrollCadence(
        notification.metrics,
        dragDriven: dragDriven,
      );
      _emitFromVerticalMetrics(notification.metrics);
    } else if (notification is ScrollEndNotification) {
      _interaction = widget.controller.pageScrubbing
          ? Interaction.scrubbing
          : Interaction.idle;
      _verticalSceneMotionStopPending = true;
      _flushVerticalScrollCadenceSummary(widget.clock.nowMicros());
      _lastVerticalScrollUpdateMicros = null;
      _lastVerticalScrollUpdatePixels = null;
      _emitFromVerticalMetrics(notification.metrics, forceLayoutSnapshot: true);
      if (_interaction == Interaction.idle &&
          _verticalKeepAliveCenter.value != widget.controller.currentIndex) {
        _verticalKeepAliveCenter.value = widget.controller.currentIndex;
      }
      if (_verticalInitialCompositionPrimed && _verticalCacheScreens != 2) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              _verticalCacheScreens != 2 &&
              _interaction == Interaction.idle) {
            setState(() => _verticalCacheScreens = 2);
          }
        });
      }
      if (_interaction == Interaction.idle) {
        _schedulePendingVerticalRatioCommit();
      }
    }
    return false;
  }

  void _startVerticalSceneMotionProbe() {
    _verticalSceneMotionStopPending = false;
    if (_verticalSceneMotionProbeActive) return;
    _verticalSceneMotionProbeActive = true;
    _resetVerticalSceneMotionSummary(widget.clock.nowMicros());
    _verticalSceneMotionLastFrameStampMicros = null;
    _verticalSceneMotionLastCallbackMicros = null;
    _verticalSceneMotionLastPixels = null;
    _verticalSceneMotionLastResidualPx = null;
    _scheduleVerticalSceneMotionSample();
  }

  void _scheduleVerticalSceneMotionSample() {
    if (!_verticalSceneMotionProbeActive) return;
    final controller = widget.controller;
    WidgetsBinding.instance.addPostFrameCallback((frameTimeStamp) {
      if (!mounted ||
          !_verticalSceneMotionProbeActive ||
          widget.controller != controller ||
          controller.direction != ReadingDirection.vertical) {
        return;
      }
      _sampleVerticalSceneMotion(frameTimeStamp);
      if (_verticalSceneMotionStopPending &&
          _interaction == Interaction.idle) {
        _flushVerticalSceneMotionSummary(widget.clock.nowMicros());
        _verticalSceneMotionProbeActive = false;
        _verticalSceneMotionStopPending = false;
        _verticalSceneMotionLastFrameStampMicros = null;
        _verticalSceneMotionLastCallbackMicros = null;
        _verticalSceneMotionLastPixels = null;
        _verticalSceneMotionLastResidualPx = null;
        return;
      }
      _scheduleVerticalSceneMotionSample();
    });
  }

  void _resetVerticalSceneMotionSummary(int nowMicros) {
    _verticalSceneMotionWindowStartMicros = nowMicros;
    _verticalSceneMotionSampleCount = 0;
    _verticalSceneMotionValidSampleCount = 0;
    _verticalSceneMotionMissingRenderBoxCount = 0;
    _verticalSceneMotionMovingSampleCount = 0;
    _verticalSceneMotionDragSampleCount = 0;
    _verticalSceneMotionBallisticSampleCount = 0;
    _verticalSceneMotionStationaryBallisticCount = 0;
    _verticalSceneMotionResidualOutlierCount = 0;
    _verticalSceneMotionFrameGapSumMicros = 0;
    _verticalSceneMotionMinFrameGapMicros = 0;
    _verticalSceneMotionMaxFrameGapMicros = 0;
    _verticalSceneMotionGapLt10ms = 0;
    _verticalSceneMotionGap10To14ms = 0;
    _verticalSceneMotionGap14To18ms = 0;
    _verticalSceneMotionGap18To20ms = 0;
    _verticalSceneMotionGap20To25ms = 0;
    _verticalSceneMotionGap25To35ms = 0;
    _verticalSceneMotionGapGe35ms = 0;
    _verticalSceneMotionMaxAbsResidualDeltaPx = 0;
  }

  void _sampleVerticalSceneMotion(Duration frameTimeStamp) {
    final nowMicros = widget.clock.nowMicros();
    final frameStampMicros = frameTimeStamp.inMicroseconds;
    final previousFrameStampMicros = _verticalSceneMotionLastFrameStampMicros;
    final previousCallbackMicros = _verticalSceneMotionLastCallbackMicros;
    _verticalSceneMotionLastFrameStampMicros = frameStampMicros;
    _verticalSceneMotionLastCallbackMicros = nowMicros;
    _verticalSceneMotionSampleCount++;

    int? frameGapMicros;
    if (previousFrameStampMicros != null &&
        frameStampMicros > previousFrameStampMicros) {
      frameGapMicros = frameStampMicros - previousFrameStampMicros;
      _recordVerticalSceneMotionFrameGap(frameGapMicros);
    }

    final position = _verticalController.hasClients
        ? _verticalController.position
        : null;
    if (position == null || !position.hasContentDimensions) {
      _verticalSceneMotionMissingRenderBoxCount++;
      _maybeFlushVerticalSceneMotionSummary(nowMicros);
      return;
    }
    final geometry = _verticalGeometry();
    final scenePosition = geometry.positionAt(
      pixels: position.pixels,
      viewportDimension: position.viewportDimension,
    );
    final pageIndex = scenePosition.index;
    if (pageIndex < 0 || pageIndex >= _verticalPageLayoutKeys.length) {
      _verticalSceneMotionMissingRenderBoxCount++;
      _maybeFlushVerticalSceneMotionSummary(nowMicros);
      return;
    }
    final context = _verticalPageLayoutKeys[pageIndex].currentContext;
    final renderObject = context?.findRenderObject();
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      _verticalSceneMotionMissingRenderBoxCount++;
      _maybeFlushVerticalSceneMotionSummary(nowMicros);
      return;
    }

    final globalTop = renderObject.localToGlobal(Offset.zero).dy;
    final expectedStart = geometry.boundsAt(pageIndex).start;
    final residual = globalTop + position.pixels - expectedStart;
    final previousPixels = _verticalSceneMotionLastPixels;
    final previousResidual = _verticalSceneMotionLastResidualPx;
    _verticalSceneMotionLastPixels = position.pixels;
    _verticalSceneMotionLastResidualPx = residual;
    _verticalSceneMotionValidSampleCount++;
    if (_interaction == Interaction.dragging) {
      _verticalSceneMotionDragSampleCount++;
    } else if (_interaction == Interaction.scrolling) {
      _verticalSceneMotionBallisticSampleCount++;
    }

    double? pixelDelta;
    double? residualDelta;
    if (previousPixels != null) {
      pixelDelta = position.pixels - previousPixels;
      if (pixelDelta.abs() > 0.01) {
        _verticalSceneMotionMovingSampleCount++;
      } else if (_interaction == Interaction.scrolling) {
        _verticalSceneMotionStationaryBallisticCount++;
      }
    }
    if (previousResidual != null) {
      residualDelta = residual - previousResidual;
      final absolute = residualDelta.abs();
      if (absolute > _verticalSceneMotionMaxAbsResidualDeltaPx) {
        _verticalSceneMotionMaxAbsResidualDeltaPx = absolute;
      }
      if (absolute > 0.25) {
        _verticalSceneMotionResidualOutlierCount++;
      }
    }

    final callbackGapMicros = previousCallbackMicros == null
        ? null
        : nowMicros - previousCallbackMicros;
    final sceneMismatch = residualDelta != null && residualDelta.abs() > 0.25;
    final longFrame = frameGapMicros != null && frameGapMicros >= 20000;
    if (sceneMismatch || longFrame) {
      widget.traceSink.record(
        traceEvent(
          clock: widget.clock,
          sessionId: widget.controller.sessionId,
          kind: TraceEventKind.verticalSceneMotionOutlier,
          revision: widget.demandRevision?.call(),
          payload: <String, Object?>{
            'frameStampMicros': frameStampMicros,
            if (frameGapMicros != null) 'frameGapMicros': frameGapMicros,
            if (callbackGapMicros != null)
              'callbackGapMicros': callbackGapMicros,
            'pageIndex': pageIndex,
            'scrollPixels': position.pixels,
            if (pixelDelta != null) 'pixelDelta': pixelDelta,
            'globalTop': globalTop,
            'expectedStart': expectedStart,
            'layoutResidualPx': residual,
            if (residualDelta != null) 'layoutResidualDeltaPx': residualDelta,
            'interaction': _interaction.name,
            'stitched': widget.verticalStitch,
          },
        ),
      );
    }
    _maybeFlushVerticalSceneMotionSummary(nowMicros);
  }

  void _recordVerticalSceneMotionFrameGap(int gapMicros) {
    _verticalSceneMotionFrameGapSumMicros += gapMicros;
    if (_verticalSceneMotionMinFrameGapMicros == 0 ||
        gapMicros < _verticalSceneMotionMinFrameGapMicros) {
      _verticalSceneMotionMinFrameGapMicros = gapMicros;
    }
    if (gapMicros > _verticalSceneMotionMaxFrameGapMicros) {
      _verticalSceneMotionMaxFrameGapMicros = gapMicros;
    }
    if (gapMicros < 10000) {
      _verticalSceneMotionGapLt10ms++;
    } else if (gapMicros < 14000) {
      _verticalSceneMotionGap10To14ms++;
    } else if (gapMicros < 18000) {
      _verticalSceneMotionGap14To18ms++;
    } else if (gapMicros < 20000) {
      _verticalSceneMotionGap18To20ms++;
    } else if (gapMicros < 25000) {
      _verticalSceneMotionGap20To25ms++;
    } else if (gapMicros < 35000) {
      _verticalSceneMotionGap25To35ms++;
    } else {
      _verticalSceneMotionGapGe35ms++;
    }
  }

  void _maybeFlushVerticalSceneMotionSummary(int nowMicros) {
    if (nowMicros - _verticalSceneMotionWindowStartMicros < 1000000) return;
    _flushVerticalSceneMotionSummary(nowMicros);
    _resetVerticalSceneMotionSummary(nowMicros);
  }

  void _flushVerticalSceneMotionSummary(int nowMicros) {
    final samples = _verticalSceneMotionSampleCount;
    if (samples == 0) return;
    final frameIntervals = _verticalSceneMotionGapLt10ms +
        _verticalSceneMotionGap10To14ms +
        _verticalSceneMotionGap14To18ms +
        _verticalSceneMotionGap18To20ms +
        _verticalSceneMotionGap20To25ms +
        _verticalSceneMotionGap25To35ms +
        _verticalSceneMotionGapGe35ms;
    widget.traceSink.record(
      traceEvent(
        clock: widget.clock,
        sessionId: widget.controller.sessionId,
        kind: TraceEventKind.verticalSceneMotionSummary,
        revision: widget.demandRevision?.call(),
        payload: <String, Object?>{
          'windowMicros': nowMicros - _verticalSceneMotionWindowStartMicros,
          'sampleCount': samples,
          'validSampleCount': _verticalSceneMotionValidSampleCount,
          'missingRenderBoxCount': _verticalSceneMotionMissingRenderBoxCount,
          'frameIntervalCount': frameIntervals,
          if (frameIntervals > 0)
            'frameGapMeanMicros':
                _verticalSceneMotionFrameGapSumMicros ~/ frameIntervals,
          'minFrameGapMicros': _verticalSceneMotionMinFrameGapMicros,
          'maxFrameGapMicros': _verticalSceneMotionMaxFrameGapMicros,
          'gapLt10msCount': _verticalSceneMotionGapLt10ms,
          'gap10To14msCount': _verticalSceneMotionGap10To14ms,
          'gap14To18msCount': _verticalSceneMotionGap14To18ms,
          'gap18To20msCount': _verticalSceneMotionGap18To20ms,
          'gap20To25msCount': _verticalSceneMotionGap20To25ms,
          'gap25To35msCount': _verticalSceneMotionGap25To35ms,
          'gapGe35msCount': _verticalSceneMotionGapGe35ms,
          'movingSampleCount': _verticalSceneMotionMovingSampleCount,
          'dragSampleCount': _verticalSceneMotionDragSampleCount,
          'ballisticSampleCount': _verticalSceneMotionBallisticSampleCount,
          'stationaryBallisticCount':
              _verticalSceneMotionStationaryBallisticCount,
          'residualOutlierCount': _verticalSceneMotionResidualOutlierCount,
          'maxAbsLayoutResidualDeltaPx':
              _verticalSceneMotionMaxAbsResidualDeltaPx,
          'interaction': _interaction.name,
          'stitched': widget.verticalStitch,
        },
      ),
    );
  }

  void _resetVerticalScrollCadenceSummary(int nowMicros) {
    _verticalCadenceWindowStartMicros = nowMicros;
    _verticalCadenceIntervalCount = 0;
    _verticalCadenceGapSumMicros = 0;
    _verticalCadenceMinGapMicros = 0;
    _verticalCadenceMaxGapMicros = 0;
    _verticalCadenceLt10ms = 0;
    _verticalCadence10To14ms = 0;
    _verticalCadence14To18ms = 0;
    _verticalCadence18To20ms = 0;
    _verticalCadence20To25ms = 0;
    _verticalCadence25To35ms = 0;
    _verticalCadenceGe35ms = 0;
    _verticalCadenceDragDriven = 0;
  }

  void _recordVerticalScrollCadenceSummary({
    required int nowMicros,
    required int gapMicros,
    required bool dragDriven,
  }) {
    if (_verticalCadenceWindowStartMicros == 0) {
      _resetVerticalScrollCadenceSummary(nowMicros - gapMicros);
    }
    _verticalCadenceIntervalCount++;
    _verticalCadenceGapSumMicros += gapMicros;
    if (_verticalCadenceMinGapMicros == 0 ||
        gapMicros < _verticalCadenceMinGapMicros) {
      _verticalCadenceMinGapMicros = gapMicros;
    }
    if (gapMicros > _verticalCadenceMaxGapMicros) {
      _verticalCadenceMaxGapMicros = gapMicros;
    }
    if (dragDriven) _verticalCadenceDragDriven++;
    if (gapMicros < 10000) {
      _verticalCadenceLt10ms++;
    } else if (gapMicros < 14000) {
      _verticalCadence10To14ms++;
    } else if (gapMicros < 18000) {
      _verticalCadence14To18ms++;
    } else if (gapMicros < 20000) {
      _verticalCadence18To20ms++;
    } else if (gapMicros < 25000) {
      _verticalCadence20To25ms++;
    } else if (gapMicros < 35000) {
      _verticalCadence25To35ms++;
    } else {
      _verticalCadenceGe35ms++;
    }
    if (nowMicros - _verticalCadenceWindowStartMicros >= 1000000) {
      _flushVerticalScrollCadenceSummary(nowMicros);
      _resetVerticalScrollCadenceSummary(nowMicros);
    }
  }

  void _flushVerticalScrollCadenceSummary(int nowMicros) {
    final count = _verticalCadenceIntervalCount;
    if (count == 0) return;
    widget.traceSink.record(
      traceEvent(
        clock: widget.clock,
        sessionId: widget.controller.sessionId,
        kind: TraceEventKind.scrollCadenceSummary,
        revision: widget.demandRevision?.call(),
        payload: <String, Object?>{
          'windowMicros': nowMicros - _verticalCadenceWindowStartMicros,
          'intervalCount': count,
          'gapMeanMicros': _verticalCadenceGapSumMicros ~/ count,
          'minGapMicros': _verticalCadenceMinGapMicros,
          'maxGapMicros': _verticalCadenceMaxGapMicros,
          'gapLt10msCount': _verticalCadenceLt10ms,
          'gap10To14msCount': _verticalCadence10To14ms,
          'gap14To18msCount': _verticalCadence14To18ms,
          'gap18To20msCount': _verticalCadence18To20ms,
          'gap20To25msCount': _verticalCadence20To25ms,
          'gap25To35msCount': _verticalCadence25To35ms,
          'gapGe35msCount': _verticalCadenceGe35ms,
          'dragDrivenCount': _verticalCadenceDragDriven,
          'ballisticCount': count - _verticalCadenceDragDriven,
          'currentIndex': widget.controller.currentIndex,
          'interaction': _interaction.name,
        },
      ),
    );
  }

  void _recordVerticalScrollCadence(
    ScrollMetrics metrics, {
    required bool dragDriven,
  }) {
    final now = widget.clock.nowMicros();
    final previousMicros = _lastVerticalScrollUpdateMicros;
    final previousPixels = _lastVerticalScrollUpdatePixels;
    _lastVerticalScrollUpdateMicros = now;
    _lastVerticalScrollUpdatePixels = metrics.pixels;
    if (previousMicros == null || previousPixels == null) return;
    final gapMicros = now - previousMicros;
    final pixelDelta = metrics.pixels - previousPixels;
    if (pixelDelta.abs() > 0.01) {
      _recordVerticalScrollCadenceSummary(
        nowMicros: now,
        gapMicros: gapMicros,
        dragDriven: dragDriven,
      );
    }
    if (gapMicros <= 20000 || pixelDelta.abs() <= 0.01) return;
    widget.traceSink.record(
      traceEvent(
        clock: widget.clock,
        sessionId: widget.controller.sessionId,
        kind: TraceEventKind.scrollCadenceOutlier,
        revision: widget.demandRevision?.call(),
        payload: <String, Object?>{
          'gapMicros': gapMicros,
          'pixelDelta': pixelDelta,
          'scrollPixels': metrics.pixels,
          'viewportDimension': metrics.viewportDimension,
          'interaction': _interaction.name,
          'dragDriven': dragDriven,
          'currentIndex': widget.controller.currentIndex,
        },
      ),
    );
  }

  void _emitFromPageMetrics(ScrollMetrics metrics) {
    if (metrics is! PageMetrics) return;
    final logicalPosition =
        metrics.page ?? widget.controller.currentIndex.toDouble();
    final velocity = _velocityFor(logicalPosition);
    _lastPagedVelocity = velocity;
    _lastPagedMetricsMicros = _lastMicros;
    _emitObservation(logicalPosition, velocity);
  }

  void _emitFromVerticalMetrics(
    ScrollMetrics metrics, {
    bool forceLayoutSnapshot = false,
  }) {
    final geometry = _verticalGeometry();
    final position = geometry.positionAt(
      pixels: metrics.pixels,
      viewportDimension: metrics.viewportDimension,
    );
    final velocity = _velocityFor(position.logicalPosition);
    _lastVerticalScrollPixels = metrics.pixels;
    _lastVerticalLogicalPosition = position.logicalPosition;
    _lastVerticalVelocity = velocity;
    _lastVerticalMetricsMicros = widget.clock.nowMicros();
    final priorTravelDirection = _lastVerticalTravelDirection;
    if (velocity.abs() > 0.001) {
      _lastVerticalTravelDirection = velocity > 0 ? 1 : -1;
    }
    if (_lastVerticalTravelDirection != 0 &&
        _lastVerticalTravelDirection != priorTravelDirection &&
        _pendingVerticalLayoutRatios != null) {
      _scheduleFutureVerticalRatioAdoption();
    }
    final visible = geometry.visibleCoverages(
      pixels: metrics.pixels,
      viewportDimension: metrics.viewportDimension,
    );
    _lastVerticalVisibleMinIndex = visible.isEmpty
        ? position.index
        : visible.fold<int>(
            position.index,
            (minimum, entry) => entry.index < minimum ? entry.index : minimum,
          );
    _lastVerticalVisibleMaxIndex = visible.isEmpty
        ? position.index
        : visible.fold<int>(
            position.index,
            (maximum, entry) => entry.index > maximum ? entry.index : maximum,
          );
    double? currentVisible;
    for (final entry in visible) {
      if (entry.index == position.index) {
        currentVisible = entry.fraction;
        break;
      }
    }
    final target = _verticalTargetCoverage(
      visible,
      currentIndex: position.index,
      travelDirection: _lastVerticalTravelDirection,
    );
    final visibleCoverages = visible
        .map(
          (entry) => Coverage(
            pageIndex: entry.index,
            assetKey: widget.controller.chapter.pages[entry.index].assetKey,
            fraction: entry.fraction,
          ),
        )
        .toList(growable: false);
    _emitObservation(
      position.logicalPosition,
      velocity,
      stableIndex: position.index,
      inferTargetFromLogicalPosition: false,
      currentCoverageOverride: Coverage(
        pageIndex: position.index,
        assetKey: widget.controller.chapter.pages[position.index].assetKey,
        fraction: currentVisible ?? 1,
      ),
      targetCoverageOverride: target,
      visibleCoveragesOverride: visibleCoverages,
    );
    _scheduleVerticalLayoutSnapshot(
      geometry: geometry,
      metrics: metrics,
      currentIndex: position.index,
      targetIndex: target?.pageIndex,
      visible: visible,
      force: forceLayoutSnapshot,
    );
    if (_lastReportedVerticalPage != position.index) {
      _lastReportedVerticalPage = position.index;
      _recordPageCurrent(position.index);
    }
  }

  void _scheduleVerticalLayoutSnapshot({
    required ReaderVerticalGeometry geometry,
    required ScrollMetrics metrics,
    required int currentIndex,
    required int? targetIndex,
    required List<({int index, double fraction})> visible,
    bool force = false,
  }) {
    final now = widget.clock.nowMicros();
    // dev.294's active 10Hz probe has repeatedly shown stable geometry. Keep
    // start/end samples and a coarse active heartbeat without spending every
    // tenth frame on RenderBox/global-transform diagnostics.
    if (!force && now - _lastVerticalLayoutSnapshotMicros < 500000) {
      return;
    }
    _lastVerticalLayoutSnapshotMicros = now;
    final scheduledPixels = metrics.pixels;
    final scheduledViewportDimension = metrics.viewportDimension;
    final interaction = _interaction;
    final revision = widget.demandRevision?.call();
    final controller = widget.controller;
    final pages = controller.chapter.pages;
    final samples = visible.take(8).toList(growable: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          widget.controller != controller ||
          controller.direction != ReadingDirection.vertical) {
        return;
      }
      for (final sample in samples) {
        final pageIndex = sample.index;
        if (pageIndex < 0 || pageIndex >= _verticalPageLayoutKeys.length) {
          continue;
        }
        final context = _verticalPageLayoutKeys[pageIndex].currentContext;
        final renderObject = context?.findRenderObject();
        if (renderObject is! RenderBox ||
            !renderObject.attached ||
            !renderObject.hasSize) {
          continue;
        }
        final constraints = renderObject.constraints;
        final paintBounds = renderObject.paintBounds;
        final transform = renderObject.getTransformTo(null).storage;
        final globalOrigin = renderObject.localToGlobal(Offset.zero);
        final globalBottomRight = renderObject.localToGlobal(
          Offset(renderObject.size.width, renderObject.size.height),
        );
        final position = _verticalController.hasClients
            ? _verticalController.position
            : null;
        final observedPixels = position?.pixels ?? scheduledPixels;
        final observedViewportDimension =
            position?.viewportDimension ?? scheduledViewportDimension;
        final expected = geometry.boundsAt(pageIndex);
        final expectedExtent = geometry.extentAt(pageIndex);
        final role = pageIndex == currentIndex
            ? 'current'
            : pageIndex == targetIndex
                ? 'transition'
                : 'visible';
        if (pageIndex == currentIndex) {
          _lastVerticalLayoutPageIndex = pageIndex;
          _lastVerticalLayoutGlobalTop = globalOrigin.dy;
          _lastVerticalLayoutGlobalBottom = globalBottomRight.dy;
          _lastVerticalLayoutMicros = widget.clock.nowMicros();
        }
        widget.traceSink.record(
          traceEvent(
            clock: widget.clock,
            sessionId: controller.sessionId,
            kind: TraceEventKind.pageLayoutSnapshot,
            identityHash: pages[pageIndex].assetKey,
            revision: revision,
            payload: <String, Object?>{
              'pageIndex': pageIndex,
              'role': role,
              'interaction': interaction.name,
              'visibleFraction': sample.fraction,
              'currentIndex': currentIndex,
              if (targetIndex != null) 'targetIndex': targetIndex,
              'scrollPixels': observedPixels,
              'viewportDimension': observedViewportDimension,
              'scheduledScrollPixels': scheduledPixels,
              'expectedStart': expected.start,
              'expectedExtent': expectedExtent,
              'renderWidth': renderObject.size.width,
              'renderHeight': renderObject.size.height,
              'extentDeltaPx': renderObject.size.height - expectedExtent,
              // For an unchanged Sliver placement this cancels ordinary scroll
              // movement: globalTop = viewportTop + expectedStart - pixels.
              // Any wobble in the residual points at layout/transform rather
              // than the expected change in scroll position itself.
              'layoutResidualPx':
                  globalOrigin.dy + observedPixels - expected.start,
              'minWidth': constraints.minWidth,
              'maxWidth': constraints.maxWidth,
              'minHeight': constraints.minHeight,
              'maxHeight': constraints.maxHeight,
              'paintLeft': paintBounds.left,
              'paintTop': paintBounds.top,
              'paintRight': paintBounds.right,
              'paintBottom': paintBounds.bottom,
              'globalLeft': globalOrigin.dx,
              'globalTop': globalOrigin.dy,
              'globalRight': globalBottomRight.dx,
              'globalBottom': globalBottomRight.dy,
              'transformM00': transform[0],
              'transformM01': transform[1],
              'transformM10': transform[4],
              'transformM11': transform[5],
              'transformTx': transform[12],
              'transformTy': transform[13],
              'devicePixelRatio': _devicePixelRatio,
              'stitched': widget.verticalStitch,
            },
          ),
        );
      }
    });
  }

  Coverage? _verticalTargetCoverage(
    List<({int index, double fraction})> visible, {
    required int currentIndex,
    required int travelDirection,
  }) {
    final candidates = visible
        .where((entry) => entry.index != currentIndex && entry.fraction > 0)
        .toList(growable: false);
    if (candidates.isEmpty) return null;
    Iterable<({int index, double fraction})> directional = candidates;
    if (travelDirection > 0) {
      directional = candidates.where((entry) => entry.index > currentIndex);
    } else if (travelDirection < 0) {
      directional = candidates.where((entry) => entry.index < currentIndex);
    }
    final ranked = directional.isEmpty
        ? candidates.toList(growable: false)
        : directional.toList(growable: false);
    ranked.sort((a, b) {
      final distance = (a.index - currentIndex)
          .abs()
          .compareTo((b.index - currentIndex).abs());
      if (distance != 0) return distance;
      return b.fraction.compareTo(a.fraction);
    });
    final target = ranked.first;
    final page = widget.controller.chapter.pages[target.index];
    return Coverage(
      pageIndex: target.index,
      assetKey: page.assetKey,
      fraction: target.fraction,
    );
  }

  double _velocityFor(double logicalPosition) {
    final now = widget.clock.nowMicros();
    final elapsedSeconds = math.max(1, now - _lastMicros) / 1000000.0;
    final velocity = (logicalPosition - _lastLogicalPosition) / elapsedSeconds;
    _lastLogicalPosition = logicalPosition;
    _lastMicros = now;
    return velocity;
  }

  void _handlePageChanged(int index) {
    _zoomedPage = null;
    final priorPosition = _lastLogicalPosition;
    final pagePosition = _pageController.hasClients
        ? _pageController.page
        : null;
    final observedPosition = pagePosition ?? priorPosition;
    final priorStillOverlaps = (priorPosition - index).abs() < 1.0 &&
        (priorPosition - index).abs() > 0.001;
    final observedCollapsedToStable =
        (observedPosition - index).abs() <= 0.001;
    final handoffPosition = (observedCollapsedToStable && priorStillOverlaps
            ? priorPosition
            : observedPosition)
        .clamp(0.0, widget.controller.chapter.pages.length - 1.0)
        .toDouble();
    _lastLogicalPosition = handoffPosition;
    _interaction = widget.controller.pageScrubbing
        ? Interaction.scrubbing
        : Interaction.settling;
    // PageView changes its stable page when the drag crosses 50%. Preserve the
    // actual fractional position so the outgoing page remains transition-owned
    // until it leaves the viewport. Emitting the integer page here briefly
    // removed its upload demand, retired a valid texture, and produced a black
    // frame followed by a full presentation reload.
    _emitObservation(handoffPosition, 0, stableIndex: index);
    _recordPageCurrent(index);
  }

  void _recordPageCurrent(int index) {
    widget.traceSink.record(
      traceEvent(
        clock: widget.clock,
        sessionId: widget.controller.sessionId,
        kind: TraceEventKind.pageCurrent,
        identityHash: widget.controller.chapter.pages[index].assetKey,
        revision: widget.demandRevision?.call(),
        payload: <String, Object?>{'pageIndex': index},
      ),
    );
  }

  void _emitObservation(
    double logicalPosition,
    double velocity, {
    int? stableIndex,
    bool inferTargetFromLogicalPosition = true,
    Coverage? currentCoverageOverride,
    Coverage? targetCoverageOverride,
    List<Coverage>? visibleCoveragesOverride,
  }) {
    final pages = widget.controller.chapter.pages;
    final stable = stableIndex ?? widget.controller.stableIndex;
    final boundedStable = stable.clamp(0, pages.length - 1).toInt();
    final distance = (logicalPosition - boundedStable)
        .abs()
        .clamp(0.0, 1.0)
        .toDouble();
    final currentFraction = currentCoverageOverride?.fraction ??
        (1.0 - distance).clamp(0.0, 1.0).toDouble();

    var targetCoverage = targetCoverageOverride;
    int? targetIndex = targetCoverage?.pageIndex;
    if (targetCoverage == null &&
        inferTargetFromLogicalPosition &&
        distance > 0.001) {
      targetIndex = logicalPosition > boundedStable
          ? logicalPosition.ceil()
          : logicalPosition.floor();
      targetIndex = targetIndex.clamp(0, pages.length - 1).toInt();
      if (targetIndex == boundedStable) {
        targetIndex = null;
      } else {
        targetCoverage = Coverage(
          pageIndex: targetIndex,
          assetKey: pages[targetIndex].assetKey,
          fraction: distance,
        );
      }
    }

    final observation = ReaderObs(
      sessionId: widget.controller.sessionId,
      currentIndex: boundedStable,
      stableIndex: boundedStable,
      interaction: _interaction,
      logicalPosition: logicalPosition,
      velocity: velocity,
      currentCoverage: currentCoverageOverride ??
          Coverage(
            pageIndex: boundedStable,
            assetKey: pages[boundedStable].assetKey,
            fraction: currentFraction,
          ),
      targetCoverage: targetCoverage,
      visibleCoverages: visibleCoveragesOverride ??
          <Coverage>[
            currentCoverageOverride ??
                Coverage(
                  pageIndex: boundedStable,
                  assetKey: pages[boundedStable].assetKey,
                  fraction: currentFraction,
                ),
            if (targetCoverage != null) targetCoverage,
          ],
      direction: widget.controller.direction,
      timestamp: DateTime.now(),
      monotonicMicros: widget.clock.nowMicros(),
    );
    widget.controller.report(observation);
    if (targetIndex != null) {
      final now = observation.monotonicMicros;
      final transitionChanged =
          _lastTransitionCurrentIndex != boundedStable ||
          _lastTransitionTargetIndex != targetIndex ||
          _lastTransitionInteraction != _interaction;
      if (transitionChanged || now - _lastTransitionTraceMicros >= 250000) {
        widget.traceSink.record(
          traceEvent(
            clock: widget.clock,
            sessionId: widget.controller.sessionId,
            kind: TraceEventKind.pageTransition,
            identityHash: pages[targetIndex].assetKey,
            revision: widget.demandRevision?.call(),
            payload: <String, Object?>{
              'currentIndex': boundedStable,
              'targetIndex': targetIndex,
              'logicalPosition': logicalPosition,
              'velocity': velocity,
              'interaction': _interaction.name,
              'currentCoverage': currentFraction,
              'targetCoverage': targetCoverage?.fraction,
            },
          ),
        );
        _lastTransitionTraceMicros = now;
        _lastTransitionCurrentIndex = boundedStable;
        _lastTransitionTargetIndex = targetIndex;
        _lastTransitionInteraction = _interaction;
      }
    } else {
      _lastTransitionCurrentIndex = boundedStable;
      _lastTransitionTargetIndex = null;
      _lastTransitionInteraction = _interaction;
    }
  }
}

final class _ReaderFrameTimingTraceContext {
  const _ReaderFrameTimingTraceContext({
    required this.callbackMonotonicMicros,
    required this.batchLastVsyncStartMicros,
    required this.mode,
    required this.scrollPixels,
    required this.logicalPosition,
    required this.velocity,
    required this.metricsMicros,
    required this.layoutPageIndex,
    required this.layoutGlobalTop,
    required this.layoutGlobalBottom,
    required this.layoutMicros,
    required this.interaction,
    required this.geometryCorrectionTarget,
    required this.stitched,
  });

  final int callbackMonotonicMicros;
  final int batchLastVsyncStartMicros;
  final String mode;
  final double? scrollPixels;
  final double? logicalPosition;
  final double? velocity;
  final int? metricsMicros;
  final int? layoutPageIndex;
  final double? layoutGlobalTop;
  final double? layoutGlobalBottom;
  final int? layoutMicros;
  final Interaction interaction;
  final double? geometryCorrectionTarget;
  final bool stitched;

  Map<String, Object?> toPayload() => <String, Object?>{
        'timingBatchCallbackMonotonicMicros': callbackMonotonicMicros,
        'timingBatchLastVsyncStartMicros': batchLastVsyncStartMicros,
        'mode': mode,
        if (scrollPixels != null) 'scrollPixelsAtCallback': scrollPixels,
        if (logicalPosition != null)
          'logicalPositionAtCallback': logicalPosition,
        if (velocity != null) 'scrollVelocityAtCallback': velocity,
        if (metricsMicros != null)
          'scrollSampleAgeMicros': callbackMonotonicMicros - metricsMicros!,
        if (layoutPageIndex != null) 'layoutPageIndexAtCallback': layoutPageIndex,
        if (layoutGlobalTop != null)
          'layoutGlobalTopAtCallback': layoutGlobalTop,
        if (layoutGlobalBottom != null)
          'layoutGlobalBottomAtCallback': layoutGlobalBottom,
        if (layoutMicros != null)
          'layoutSampleAgeMicros': callbackMonotonicMicros - layoutMicros!,
        'interactionAtCallback': interaction.name,
        if (geometryCorrectionTarget != null)
          'geometryCorrectionTarget': geometryCorrectionTarget,
        'stitched': stitched,
      };
}

final class _ReaderFrameTimingSummary {
  _ReaderFrameTimingSummary(
    ReaderFrameTimingSample timing,
    _ReaderFrameTimingTraceContext context,
  )   : firstVsyncStartMicros = timing.vsyncStartMicros,
        _last = timing,
        _context = context,
        _minimumBuildMicros = timing.buildMicros,
        _maximumBuildMicros = timing.buildMicros,
        _minimumRasterMicros = timing.rasterMicros,
        _maximumRasterMicros = timing.rasterMicros,
        _minimumTotalSpanMicros = timing.totalSpanMicros,
        _maximumTotalSpanMicros = timing.totalSpanMicros,
        _minimumVsyncOverheadMicros = timing.vsyncOverheadMicros,
        _maximumVsyncOverheadMicros = timing.vsyncOverheadMicros,
        _minimumFrameIntervalMicros = timing.frameIntervalMicros,
        _maximumFrameIntervalMicros = timing.frameIntervalMicros;

  final int firstVsyncStartMicros;
  int _sampleCount = 1;
  ReaderFrameTimingSample _last;
  _ReaderFrameTimingTraceContext _context;
  int _minimumBuildMicros;
  int _maximumBuildMicros;
  int _minimumRasterMicros;
  int _maximumRasterMicros;
  int _minimumTotalSpanMicros;
  int _maximumTotalSpanMicros;
  int _minimumVsyncOverheadMicros;
  int _maximumVsyncOverheadMicros;
  int? _minimumFrameIntervalMicros;
  int? _maximumFrameIntervalMicros;

  void add(
    ReaderFrameTimingSample timing,
    _ReaderFrameTimingTraceContext context,
  ) {
    _sampleCount++;
    _last = timing;
    _context = context;
    _minimumBuildMicros = math.min(_minimumBuildMicros, timing.buildMicros);
    _maximumBuildMicros = math.max(_maximumBuildMicros, timing.buildMicros);
    _minimumRasterMicros = math.min(_minimumRasterMicros, timing.rasterMicros);
    _maximumRasterMicros = math.max(_maximumRasterMicros, timing.rasterMicros);
    _minimumTotalSpanMicros = math.min(
      _minimumTotalSpanMicros,
      timing.totalSpanMicros,
    );
    _maximumTotalSpanMicros = math.max(
      _maximumTotalSpanMicros,
      timing.totalSpanMicros,
    );
    _minimumVsyncOverheadMicros = math.min(
      _minimumVsyncOverheadMicros,
      timing.vsyncOverheadMicros,
    );
    _maximumVsyncOverheadMicros = math.max(
      _maximumVsyncOverheadMicros,
      timing.vsyncOverheadMicros,
    );
    final interval = timing.frameIntervalMicros;
    if (interval != null) {
      _minimumFrameIntervalMicros = _minimumFrameIntervalMicros == null
          ? interval
          : math.min(_minimumFrameIntervalMicros!, interval);
      _maximumFrameIntervalMicros = _maximumFrameIntervalMicros == null
          ? interval
          : math.max(_maximumFrameIntervalMicros!, interval);
    }
  }

  Map<String, Object?> toPayload() => <String, Object?>{
        ..._context.toPayload(),
        'timingSummary': true,
        'frameSampleCount': _sampleCount,
        'firstVsyncStartMicros': firstVsyncStartMicros,
        'lastVsyncStartMicros': _last.vsyncStartMicros,
        'buildMicros': _last.buildMicros,
        'minBuildMicros': _minimumBuildMicros,
        'maxBuildMicros': _maximumBuildMicros,
        'rasterMicros': _last.rasterMicros,
        'minRasterMicros': _minimumRasterMicros,
        'maxRasterMicros': _maximumRasterMicros,
        'totalSpanMicros': _last.totalSpanMicros,
        'minTotalSpanMicros': _minimumTotalSpanMicros,
        'maxTotalSpanMicros': _maximumTotalSpanMicros,
        'vsyncOverheadMicros': _last.vsyncOverheadMicros,
        'minVsyncOverheadMicros': _minimumVsyncOverheadMicros,
        'maxVsyncOverheadMicros': _maximumVsyncOverheadMicros,
        'vsyncStartMicros': _last.vsyncStartMicros,
        if (_last.frameIntervalMicros != null)
          'frameIntervalMicros': _last.frameIntervalMicros,
        if (_minimumFrameIntervalMicros != null)
          'minFrameIntervalMicros': _minimumFrameIntervalMicros,
        if (_maximumFrameIntervalMicros != null)
          'maxFrameIntervalMicros': _maximumFrameIntervalMicros,
      };
}
