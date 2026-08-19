import 'dart:async';
import 'dart:math' as math;

import 'package:domain/domain.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:telemetry/telemetry.dart';

import 'reader_controller.dart';
import 'reader_frame_timing.dart';
import 'vertical_reader_geometry.dart';

typedef ReaderPageBuilder = Widget? Function(
  BuildContext context,
  PageAsset asset,
  VoidCallback reportFirstFrame,
);


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
    if (!isScrolling && target != null) {
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
    this.demandRevision,
    this.onTap,
    this.verticalStitch = false,
    this.pageAspectRatios = const <String, double>{},
    super.key,
  });

  final ReaderController controller;
  final MonoClock clock;
  final TraceSink traceSink;
  final ReaderFrameTimingSource? frameTimingSource;
  final ReaderPageBuilder? pageBuilder;
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

  @override
  State<ReaderView> createState() => _ReaderViewState();
}

final class _ReaderViewState extends State<ReaderView> {
  late PageController _pageController;
  late ScrollController _verticalController;
  late final _ReaderVerticalScrollPhysics _verticalScrollPhysics;
  double _lastLogicalPosition = 0;
  int _lastMicros = 0;
  Interaction _interaction = Interaction.idle;
  int _handledNavigationRevision = 0;
  int? _zoomedPage;
  int? _lastReportedVerticalPage;
  int _lastVerticalTravelDirection = 0;
  int? _lastVerticalVisibleMaxIndex;
  late List<GlobalKey> _verticalPageLayoutKeys;
  int _lastVerticalLayoutSnapshotMicros = -1000000;
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
  late Map<String, double> _verticalLayoutRatios;
  Map<String, double>? _pendingVerticalLayoutRatios;
  bool _verticalRatioCommitScheduled = false;
  double? _pendingVerticalGeometryCorrection;
  bool _verticalGeometryCorrectionClearScheduled = false;
  double? _lastVerticalScrollPixels;
  double? _lastVerticalLogicalPosition;
  double? _lastVerticalVelocity;
  int? _lastVerticalMetricsMicros;
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
    _lastVerticalVisibleMaxIndex = widget.controller.currentIndex;
    _verticalPageLayoutKeys = _createVerticalPageLayoutKeys();
    _pageSlots = _createPageSlots();
    _verticalLayoutRatios = widget.pageAspectRatios;
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
      _lastReportedVerticalPage = null;
      _lastVerticalVisibleMaxIndex = widget.controller.currentIndex;
      _verticalPageLayoutKeys = _createVerticalPageLayoutKeys();
      _lastVerticalLayoutSnapshotMicros = -1000000;
      _lastDirection = widget.controller.direction;
      _lastRotationQuarterTurns = widget.controller.rotationQuarterTurns;
      _pageSlots = _createPageSlots();
      _verticalLayoutRatios = widget.pageAspectRatios;
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
    }
    final stitchChanged = oldWidget.verticalStitch != widget.verticalStitch;
    final ratiosChanged =
        !identical(oldWidget.pageAspectRatios, widget.pageAspectRatios);
    if (oldWidget.verticalStitch != widget.verticalStitch) {
      _preserveVerticalAnchor(
        oldRatios: _verticalLayoutRatios,
        oldStitch: oldWidget.verticalStitch,
      );
    }
    if (ratiosChanged) {
      if (widget.controller.direction != ReadingDirection.vertical) {
        _verticalLayoutRatios = widget.pageAspectRatios;
        _pendingVerticalLayoutRatios = null;
        _invalidateVerticalGeometryCache();
      } else if (_verticalScrollActive) {
        // Ratios for pages strictly beyond the current viewport cannot change
        // the prefix or extents of anything being painted now. Adopt those
        // decode-ahead facts immediately so they are stable before the page
        // enters the viewport. Changes at/before the visible tail remain
        // pending until idle, preserving the dev.280 scroll-stable prefix.
        _adoptFutureVerticalRatios(widget.pageAspectRatios);
        _pendingVerticalLayoutRatios =
            _sameVerticalRatios(_verticalLayoutRatios, widget.pageAspectRatios)
                ? null
                : widget.pageAspectRatios;
      } else {
        if (!stitchChanged) {
          _preserveVerticalAnchor(
            oldRatios: _verticalLayoutRatios,
            oldStitch: widget.verticalStitch,
            nextRatios: widget.pageAspectRatios,
          );
        }
        _verticalLayoutRatios = widget.pageAspectRatios;
        _pendingVerticalLayoutRatios = null;
        _invalidateVerticalGeometryCache();
      }
    }
  }

  @override
  void dispose() {
    _detachFrameTimingSource();
    widget.controller.removeListener(_handleControllerCommand);
    _pageController.dispose();
    _verticalController.dispose();
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
            final physics = _zoomedPage == null
                ? _verticalScrollPhysics
                : const NeverScrollableScrollPhysics();
            _scheduleVerticalInitialCompositionWarmup();
            final cacheExtent = _viewport.height > 0
                ? _viewport.height * _verticalCacheScreens
                : null;
            final list = ListView.builder(
              key: const ValueKey<String>('reader-vertical-list'),
              controller: _verticalController,
              itemCount: itemCount,
              cacheExtent: cacheExtent,
              physics: physics,
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
                    // zoom still clips to its page so it cannot cover siblings.
                    child: stitched && _zoomedPage == null
                        ? page
                        : ClipRect(child: page),
                  ),
                );
              },
            );
            return NotificationListener<ScrollNotification>(
              onNotification: _handleVerticalScrollNotification,
              child: list,
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

  List<GlobalKey> _createVerticalPageLayoutKeys() => List<GlobalKey>.generate(
        widget.controller.chapter.pages.length,
        (index) => GlobalKey(debugLabel: 'reader-vertical-layout:$index'),
        growable: false,
      );

  List<Widget> _createPageSlots() {
    final chapter = widget.controller.chapter;
    return List<Widget>.generate(chapter.pages.length, (index) {
      final asset = chapter.pages[index];
      return _ReaderPageShell(
        key: ValueKey<String>('reader-page-shell:${asset.assetKey}'),
        controller: widget.controller,
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
      );
    }, growable: false);
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

  void _adoptFutureVerticalRatios(Map<String, double> latest) {
    final pages = widget.controller.chapter.pages;
    final visibleMax = (_lastVerticalVisibleMaxIndex ??
            widget.controller.currentIndex)
        .clamp(0, pages.length - 1)
        .toInt();
    Map<String, double>? merged;
    final adopted = <int>[];
    for (var index = visibleMax + 1; index < pages.length; index++) {
      final key = pages[index].assetKey;
      final ratio = latest[key];
      if (ratio == null || _verticalLayoutRatios[key] == ratio) continue;
      merged ??= <String, double>{..._verticalLayoutRatios};
      merged[key] = ratio;
      adopted.add(index);
    }
    if (merged == null) return;
    _verticalLayoutRatios = Map<String, double>.unmodifiable(merged);
    _invalidateVerticalGeometryCache();
    widget.traceSink.record(
      traceEvent(
        clock: widget.clock,
        sessionId: widget.controller.sessionId,
        kind: TraceEventKind.pageGeometryPrepared,
        revision: widget.demandRevision?.call(),
        payload: <String, Object?>{
          'pageIndexes': adopted,
          'visibleMaxIndex': visibleMax,
          'interaction': _interaction.name,
          'source': 'decode-ahead-ratio',
        },
      ),
    );
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
      if (_verticalScrollActive) {
        // ScrollEnd and isScrollingNotifier can settle on adjacent frames.
        // Once the interaction is otherwise idle, retry the commit on the
        // next frame instead of leaving the latest measured ratios pending.
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
      if (_lastDirection == ReadingDirection.vertical) {
        _flushFrameTimingSummary();
      }
      _lastDirection = controller.direction;
      _zoomedPage = null;
      _resetVerticalCompositionCache();
      rebuildLayout = true;
      if (controller.direction == ReadingDirection.vertical) {
        _verticalLayoutRatios = widget.pageAspectRatios;
        _pendingVerticalLayoutRatios = null;
        _verticalInitialOffsetApplied = false;
        _prepareVerticalControllerForCurrentPage();
      } else {
        _verticalLayoutRatios = widget.pageAspectRatios;
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
    if (!mounted ||
        timings.isEmpty ||
        widget.controller.direction != ReadingDirection.vertical) {
      return;
    }
    // Flutter delivers FrameTiming in batches. Reader state sampled here is
    // the callback-time state, not the historical state of every frame in the
    // batch, so attaching scroll/current/interaction to each sample invents a
    // false per-frame correlation. Preserve engine timing plus enough batch
    // anchors for offline monotonic alignment instead.
    final callbackMonotonicMicros = widget.clock.nowMicros();
    final context = _ReaderFrameTimingTraceContext(
      callbackMonotonicMicros: callbackMonotonicMicros,
      batchLastVsyncStartMicros: timings.last.vsyncStartMicros,
      scrollPixels: _lastVerticalScrollPixels,
      logicalPosition: _lastVerticalLogicalPosition,
      velocity: _lastVerticalVelocity,
      metricsMicros: _lastVerticalMetricsMicros,
      layoutPageIndex: _lastVerticalLayoutPageIndex,
      layoutGlobalTop: _lastVerticalLayoutGlobalTop,
      layoutGlobalBottom: _lastVerticalLayoutGlobalBottom,
      layoutMicros: _lastVerticalLayoutMicros,
      interaction: _interaction,
      geometryCorrectionTarget: _pendingVerticalGeometryCorrection,
      stitched: widget.verticalStitch,
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
          : Interaction.scrolling;
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
      _interaction = widget.controller.pageScrubbing
          ? Interaction.scrubbing
          : notification.dragDetails == null
              ? Interaction.scrolling
              : Interaction.dragging;
      _emitFromVerticalMetrics(notification.metrics, forceLayoutSnapshot: true);
    } else if (notification is ScrollUpdateNotification) {
      _pendingVerticalAnchor = null;
      _interaction = widget.controller.pageScrubbing
          ? Interaction.scrubbing
          : Interaction.scrolling;
      _emitFromVerticalMetrics(notification.metrics);
    } else if (notification is ScrollEndNotification) {
      _interaction = widget.controller.pageScrubbing
          ? Interaction.scrubbing
          : Interaction.idle;
      _emitFromVerticalMetrics(notification.metrics, forceLayoutSnapshot: true);
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

  void _emitFromPageMetrics(ScrollMetrics metrics) {
    if (metrics is! PageMetrics) return;
    final logicalPosition =
        metrics.page ?? widget.controller.currentIndex.toDouble();
    final velocity = _velocityFor(logicalPosition);
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
    if (velocity.abs() > 0.001) {
      _lastVerticalTravelDirection = velocity > 0 ? 1 : -1;
    }
    final visible = geometry.visibleCoverages(
      pixels: metrics.pixels,
      viewportDimension: metrics.viewportDimension,
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
    if (!force && now - _lastVerticalLayoutSnapshotMicros < 100000) {
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
    }
  }
}

final class _ReaderFrameTimingTraceContext {
  const _ReaderFrameTimingTraceContext({
    required this.callbackMonotonicMicros,
    required this.batchLastVsyncStartMicros,
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


final class _ReaderPageShell extends StatefulWidget {
  const _ReaderPageShell({
    required this.controller,
    required this.asset,
    required this.index,
    required this.clock,
    required this.traceSink,
    required this.pageBuilder,
    required this.demandRevision,
    required this.onZoomChanged,
    this.onTap,
    super.key,
  });

  final ReaderController controller;
  final PageAsset asset;
  final int index;
  final MonoClock clock;
  final TraceSink traceSink;
  final ReaderPageBuilder? pageBuilder;
  final int Function()? demandRevision;
  final ValueChanged<bool> onZoomChanged;
  final VoidCallback? onTap;

  @override
  State<_ReaderPageShell> createState() => _ReaderPageShellState();
}

final class _ReaderPageShellState extends State<_ReaderPageShell> {
  late bool _active;
  late bool _keepAlive;
  late int _rotationQuarterTurns;
  late final ValueNotifier<bool> _activeNotifier;
  late final ValueNotifier<bool> _keepAliveNotifier;

  @override
  void initState() {
    super.initState();
    _readControllerState();
    _activeNotifier = ValueNotifier<bool>(_active);
    _keepAliveNotifier = ValueNotifier<bool>(_keepAlive);
    widget.controller.addListener(_handleControllerChanged);
  }

  @override
  void didUpdateWidget(covariant _ReaderPageShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      widget.controller.addListener(_handleControllerChanged);
    }
    final nextActive = widget.index == widget.controller.currentIndex;
    final nextKeepAlive = _keepAliveFor(widget.controller);
    final nextRotation = widget.controller.rotationQuarterTurns;
    _active = nextActive;
    _keepAlive = nextKeepAlive;
    _activeNotifier.value = nextActive;
    _keepAliveNotifier.value = nextKeepAlive;
    if (_rotationQuarterTurns != nextRotation) {
      _rotationQuarterTurns = nextRotation;
      setState(() {});
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    _activeNotifier.dispose();
    _keepAliveNotifier.dispose();
    super.dispose();
  }

  bool _keepAliveFor(ReaderController controller) {
    return controller.direction == ReadingDirection.vertical &&
        (widget.index - controller.currentIndex).abs() <= 7;
  }

  void _readControllerState() {
    _active = widget.index == widget.controller.currentIndex;
    _keepAlive = _keepAliveFor(widget.controller);
    _rotationQuarterTurns = widget.controller.rotationQuarterTurns;
  }

  void _handleControllerChanged() {
    final nextActive = widget.index == widget.controller.currentIndex;
    final nextKeepAlive = _keepAliveFor(widget.controller);
    final nextRotation = widget.controller.rotationQuarterTurns;
    if (_active != nextActive) {
      _active = nextActive;
      _activeNotifier.value = nextActive;
    }
    if (_keepAlive != nextKeepAlive) {
      _keepAlive = nextKeepAlive;
      _keepAliveNotifier.value = nextKeepAlive;
    }
    if (_rotationQuarterTurns != nextRotation) {
      setState(() => _rotationQuarterTurns = nextRotation);
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = _ZoomableReaderPage(
      key: ValueKey<String>('zoom:${widget.asset.assetKey}'),
      active: _activeNotifier,
      clock: widget.clock,
      onTap: widget.onTap,
      onZoomChanged: widget.onZoomChanged,
      child: _ReaderPageHost(
        key: ValueKey<String>(
          'reader-page-host:${widget.asset.assetKey}',
        ),
        asset: widget.asset,
        keepAlive: _keepAliveNotifier,
        sessionId: widget.controller.sessionId,
        clock: widget.clock,
        traceSink: widget.traceSink,
        pageBuilder: widget.pageBuilder,
        demandRevision: widget.demandRevision,
      ),
    );
    return RotatedBox(
      key: ValueKey<String>('reader-page-rotation:${widget.index}'),
      quarterTurns: _rotationQuarterTurns,
      child: page,
    );
  }
}

final class _ZoomableReaderPage extends StatefulWidget {
  const _ZoomableReaderPage({
    required this.child,
    required this.active,
    required this.clock,
    required this.onZoomChanged,
    this.onTap,
    super.key,
  });

  final Widget child;
  final ValueListenable<bool> active;
  final MonoClock clock;
  final ValueChanged<bool> onZoomChanged;
  final VoidCallback? onTap;

  @override
  State<_ZoomableReaderPage> createState() => _ZoomableReaderPageState();
}

final class _ZoomableReaderPageState extends State<_ZoomableReaderPage> {
  late final TransformationController _transformation;
  bool _zoomed = false;
  int? _pointer;
  Offset? _pointerDown;
  bool _tapCandidate = false;
  Timer? _singleTapTimer;
  int? _lastTapAtMicros;
  Offset? _lastTapPosition;

  @override
  void initState() {
    super.initState();
    _transformation = TransformationController();
    widget.active.addListener(_handleActiveChanged);
  }

  @override
  void didUpdateWidget(covariant _ZoomableReaderPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      oldWidget.active.removeListener(_handleActiveChanged);
      widget.active.addListener(_handleActiveChanged);
      _handleActiveChanged();
    }
  }

  @override
  void dispose() {
    widget.active.removeListener(_handleActiveChanged);
    _singleTapTimer?.cancel();
    _transformation.dispose();
    super.dispose();
  }

  void _handleActiveChanged() {
    if (widget.active.value || !_zoomed) return;
    _singleTapTimer?.cancel();
    _singleTapTimer = null;
    _lastTapAtMicros = null;
    _lastTapPosition = null;
    _transformation.value = Matrix4.identity();
    setState(() => _zoomed = false);
  }

  double get _scale => _transformation.value.getMaxScaleOnAxis();

  void _publishZoom() {
    final zoomed = _scale > 1.01;
    if (_zoomed == zoomed) {
      return;
    }
    setState(() => _zoomed = zoomed);
    widget.onZoomChanged(zoomed);
  }

  void _toggleZoom(Offset position) {
    if (_zoomed) {
      _transformation.value = Matrix4.identity();
    } else {
      const scale = 2.25;
      _transformation.value = Matrix4.identity()
        ..translate(
          -position.dx * (scale - 1),
          -position.dy * (scale - 1),
        )
        ..scale(scale);
    }
    _publishZoom();
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_pointer != null) {
      _tapCandidate = false;
      return;
    }
    _pointer = event.pointer;
    _pointerDown = event.localPosition;
    _tapCandidate = true;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer || !_tapCandidate) {
      return;
    }
    final origin = _pointerDown;
    if (origin == null || (event.localPosition - origin).distance > 12) {
      _tapCandidate = false;
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer == _pointer) {
      _clearPointer();
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) {
      return;
    }
    final candidate = _tapCandidate;
    final position = event.localPosition;
    _clearPointer();
    if (!candidate) {
      return;
    }
    final nowMicros = widget.clock.nowMicros();
    final lastAtMicros = _lastTapAtMicros;
    final lastPosition = _lastTapPosition;
    final isDoubleTap = lastAtMicros != null &&
        nowMicros - lastAtMicros <= 280000 &&
        lastPosition != null &&
        (position - lastPosition).distance <= 48;
    if (isDoubleTap) {
      _singleTapTimer?.cancel();
      _singleTapTimer = null;
      _lastTapAtMicros = null;
      _lastTapPosition = null;
      _toggleZoom(position);
      return;
    }
    _lastTapAtMicros = nowMicros;
    _lastTapPosition = position;
    _singleTapTimer?.cancel();
    _singleTapTimer = Timer(const Duration(milliseconds: 280), () {
      _singleTapTimer = null;
      _lastTapAtMicros = null;
      _lastTapPosition = null;
      widget.onTap?.call();
    });
  }

  void _clearPointer() {
    _pointer = null;
    _pointerDown = null;
    _tapCandidate = false;
  }

  @override
  Widget build(BuildContext context) {
    final child = SizedBox.expand(child: widget.child);
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      // At scale 1 the page content must not install a scale recognizer in the
      // horizontal gesture arena. Remote image widgets otherwise win the drag
      // before PageView can turn it into navigation. Double tap enters the
      // explicit zoom state; only then does InteractiveViewer own pan/scale.
      child: _zoomed
          ? InteractiveViewer(
              transformationController: _transformation,
              minScale: 1,
              maxScale: 5,
              panEnabled: true,
              scaleEnabled: true,
              clipBehavior: Clip.hardEdge,
              onInteractionUpdate: (_) => _publishZoom(),
              onInteractionEnd: (_) => _publishZoom(),
              child: child,
            )
          : child,
    );
  }
}

final class _ReaderPageHost extends StatefulWidget {
  const _ReaderPageHost({
    required this.asset,
    required this.keepAlive,
    required this.sessionId,
    required this.clock,
    required this.traceSink,
    required this.pageBuilder,
    required this.demandRevision,
    super.key,
  });

  final PageAsset asset;
  final ValueListenable<bool> keepAlive;
  final String sessionId;
  final MonoClock clock;
  final TraceSink traceSink;
  final ReaderPageBuilder? pageBuilder;
  final int Function()? demandRevision;

  @override
  State<_ReaderPageHost> createState() => _ReaderPageHostState();
}

final class _ReaderPageHostState extends State<_ReaderPageHost>
    with AutomaticKeepAliveClientMixin<_ReaderPageHost> {
  bool _reportedFirstFrame = false;
  late int _mountedAtMicros;
  int? _mountedRevision;

  @override
  void initState() {
    super.initState();
    widget.keepAlive.addListener(_handleKeepAliveChanged);
    _mountedAtMicros = widget.clock.nowMicros();
    _mountedRevision = widget.demandRevision?.call();
    _recordLifecycle(
      TraceEventKind.pageHostMounted,
      revision: _mountedRevision,
    );
  }

  @override
  bool get wantKeepAlive => widget.keepAlive.value;

  @override
  void didUpdateWidget(covariant _ReaderPageHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keepAlive != widget.keepAlive) {
      oldWidget.keepAlive.removeListener(_handleKeepAliveChanged);
      widget.keepAlive.addListener(_handleKeepAliveChanged);
      updateKeepAlive();
    }
    if (oldWidget.asset.assetKey != widget.asset.assetKey) {
      _reportedFirstFrame = false;
      _mountedAtMicros = widget.clock.nowMicros();
      _mountedRevision = widget.demandRevision?.call();
      _recordLifecycle(
        TraceEventKind.pageHostMounted,
        revision: _mountedRevision,
      );
    }
  }

  @override
  void dispose() {
    widget.keepAlive.removeListener(_handleKeepAliveChanged);
    _recordLifecycle(
      TraceEventKind.pageHostDisposed,
      revision: widget.demandRevision?.call(),
      payload: <String, Object?>{
        'mountedRevision': _mountedRevision,
        'firstFrameReady': _reportedFirstFrame,
        'lifetimeMicros': widget.clock.nowMicros() - _mountedAtMicros,
      },
    );
    super.dispose();
  }

  void _handleKeepAliveChanged() => updateKeepAlive();

  void _recordLifecycle(
    TraceEventKind kind, {
    int? revision,
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    widget.traceSink.record(
      traceEvent(
        clock: widget.clock,
        sessionId: widget.sessionId,
        kind: kind,
        identityHash: widget.asset.assetKey,
        revision: revision,
        payload: <String, Object?>{
          'pageIndex': widget.asset.index,
          'keepAlive': widget.keepAlive.value,
          ...payload,
        },
      ),
    );
  }

  void _reportFirstFrame() {
    if (_reportedFirstFrame) {
      return;
    }
    _reportedFirstFrame = true;
    final asset = widget.asset;
    final clock = widget.clock;
    final sessionId = widget.sessionId;
    final traceSink = widget.traceSink;
    final mountedAtMicros = _mountedAtMicros;
    final firstFrameRevision = widget.demandRevision?.call();
    final mountedRevision = _mountedRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.asset.assetKey != asset.assetKey) {
        return;
      }
      traceSink.record(
        traceEvent(
          clock: clock,
          sessionId: sessionId,
          kind: TraceEventKind.firstFrameReady,
          identityHash: asset.assetKey,
          revision: firstFrameRevision,
          payload: <String, Object?>{
            'pageIndex': asset.index,
            'mountedRevision': mountedRevision,
            'mountToFirstFrameMicros': clock.nowMicros() - mountedAtMicros,
          },
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final custom = widget.pageBuilder?.call(
      context,
      widget.asset,
      _reportFirstFrame,
    );
    return custom ??
        _StaticReaderPage(
          asset: widget.asset,
          onFirstFrame: _reportFirstFrame,
        );
  }
}

final class _StaticReaderPage extends StatelessWidget {
  const _StaticReaderPage({
    required this.asset,
    required this.onFirstFrame,
  });

  final PageAsset asset;
  final VoidCallback onFirstFrame;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Image.asset(
          asset.uri.toString(),
          fit: BoxFit.contain,
          filterQuality: FilterQuality.low,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (frame != null || wasSynchronouslyLoaded) {
              onFirstFrame();
            }
            return child;
          },
          errorBuilder: (context, error, stackTrace) => Center(
            child: Text(
              'Page ${asset.index + 1} failed to load',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}
