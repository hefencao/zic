import 'dart:async';
import 'dart:math' as math;

import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:telemetry/telemetry.dart';

import 'reader_controller.dart';

typedef ReaderPageBuilder = Widget? Function(
  BuildContext context,
  PageAsset asset,
  VoidCallback reportFirstFrame,
);

final class ReaderView extends StatefulWidget {
  const ReaderView({
    required this.controller,
    required this.clock,
    this.traceSink = const NoopTraceSink(),
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
  static const double _verticalPageGap = 8;

  late PageController _pageController;
  late ScrollController _verticalController;
  double _lastLogicalPosition = 0;
  int _lastMicros = 0;
  Interaction _interaction = Interaction.idle;
  int _handledNavigationRevision = 0;
  int? _zoomedPage;
  int? _lastReportedVerticalPage;
  Size _viewport = Size.zero;
  late ReadingDirection _lastDirection;
  bool _syncScheduled = false;
  bool _anchorRestoreScheduled = false;
  ({int index, double fraction})? _pendingVerticalAnchor;
  bool _commandScheduled = false;
  bool _verticalInitialOffsetApplied = false;
  final Set<String> _readyPageKeys = <String>{};

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.controller.currentIndex);
    _verticalController = ScrollController();
    _lastLogicalPosition = widget.controller.currentIndex.toDouble();
    _lastMicros = widget.clock.nowMicros();
    _handledNavigationRevision = widget.controller.navigationRevision;
    _lastDirection = widget.controller.direction;
    widget.controller.addListener(_handleControllerCommand);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncToCurrentPage();
      _emitObservation(_lastLogicalPosition, 0);
    });
  }

  @override
  void didUpdateWidget(covariant ReaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerCommand);
      widget.controller.addListener(_handleControllerCommand);
      _pageController.dispose();
      _verticalController.dispose();
      _pageController = PageController(
        initialPage: widget.controller.currentIndex,
      );
      _verticalController = ScrollController();
      _verticalInitialOffsetApplied = false;
      _lastLogicalPosition = widget.controller.currentIndex.toDouble();
      _lastMicros = widget.clock.nowMicros();
      _interaction = Interaction.idle;
      _handledNavigationRevision = widget.controller.navigationRevision;
      _zoomedPage = null;
      _lastReportedVerticalPage = null;
      _lastDirection = widget.controller.direction;
      _readyPageKeys.clear();
      _scheduleSyncToCurrentPage();
    } else if (oldWidget.verticalStitch != widget.verticalStitch ||
        oldWidget.pageAspectRatios != widget.pageAspectRatios) {
      _preserveVerticalAnchor(
        oldRatios: oldWidget.pageAspectRatios,
        oldStitch: oldWidget.verticalStitch,
      );
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerCommand);
    _pageController.dispose();
    _verticalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chapter = widget.controller.chapter;

    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
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
                oldRatios: widget.pageAspectRatios,
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
            final pageCount = chapter.pages.length;
            final itemCount = stitched
                ? pageCount
                : (pageCount == 0 ? 0 : pageCount * 2 - 1);
            final physics = _zoomedPage == null
                ? const ClampingScrollPhysics()
                : const NeverScrollableScrollPhysics();
            final cacheExtent =
                _viewport.height > 0 ? _viewport.height * 2 : null;
            final list = ListView.builder(
              key: const ValueKey<String>('reader-vertical-list'),
              controller: _verticalController,
              itemCount: itemCount,
              cacheExtent: cacheExtent,
              physics: physics,
              itemExtentBuilder: (itemIndex, _) {
                if (!stitched && itemIndex.isOdd) {
                  return _verticalPageGap;
                }
                final pageIndex = stitched ? itemIndex : itemIndex ~/ 2;
                return _verticalExtent(chapter.pages[pageIndex], pageIndex);
              },
              itemBuilder: (context, itemIndex) {
                if (!stitched && itemIndex.isOdd) {
                  final gapIndex = itemIndex ~/ 2;
                  return SizedBox(
                    key: ValueKey<String>('reader-vertical-gap:$gapIndex'),
                    height: _verticalPageGap,
                  );
                }
                final pageIndex = stitched ? itemIndex : itemIndex ~/ 2;
                return SizedBox(
                  key: ValueKey<String>('reader-vertical-page:$pageIndex'),
                  height: _verticalExtent(
                    chapter.pages[pageIndex],
                    pageIndex,
                  ),
                  child: ClipRect(
                    child: _buildPage(chapter, pageIndex),
                  ),
                );
              },
            );
            return _withLoadingOverlay(
              chapter,
              NotificationListener<ScrollNotification>(
                onNotification: _handleVerticalScrollNotification,
                child: list,
              ),
            );
          }
          return _withLoadingOverlay(
            chapter,
            NotificationListener<ScrollNotification>(
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
                itemBuilder: (context, index) => _buildPage(chapter, index),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _withLoadingOverlay(ChapterManifest chapter, Widget content) {
    final current = chapter.pages[widget.controller.currentIndex].assetKey;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        content,
        if (!_readyPageKeys.contains(current))
          const IgnorePointer(
            child: Center(
              child: CircularProgressIndicator(
                key: ValueKey<String>('reader-loading-indicator'),
              ),
            ),
          ),
      ],
    );
  }

  void _markFirstFrameReady(String assetKey) {
    if (_readyPageKeys.contains(assetKey)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_readyPageKeys.add(assetKey)) return;
      setState(() {});
    });
  }

  Widget _buildPage(ChapterManifest chapter, int index) => RotatedBox(
        key: ValueKey<String>('reader-page-rotation:$index'),
        quarterTurns: widget.controller.rotationQuarterTurns,
        child: _ZoomableReaderPage(
          key: ValueKey<String>('zoom:${chapter.pages[index].assetKey}'),
          active: index == widget.controller.currentIndex,
          onTap: widget.onTap,
          onZoomChanged: (zoomed) {
            final next = zoomed ? index : null;
            if (_zoomedPage == next) return;
            setState(() => _zoomedPage = next);
          },
          child: _ReaderPageHost(
            key: ValueKey<String>(
              'reader-page-host:${chapter.pages[index].assetKey}',
            ),
            asset: chapter.pages[index],
            sessionId: widget.controller.sessionId,
            clock: widget.clock,
            traceSink: widget.traceSink,
            pageBuilder: widget.pageBuilder,
            demandRevision: widget.demandRevision,
            onFirstFrameReady: () =>
                _markFirstFrameReady(chapter.pages[index].assetKey),
          ),
        ),
      );

  double _verticalExtent(
    PageAsset asset,
    int index, {
    Map<String, double>? ratios,
    Size? viewport,
  }) {
    final effectiveViewport = viewport ?? _viewport;
    if (effectiveViewport.width <= 0 || effectiveViewport.height <= 0) return 1;
    var ratio = (ratios ?? widget.pageAspectRatios)[asset.assetKey];
    var hasMeasuredRatio = ratio != null;
    final width = asset.width?.toDouble();
    final height = asset.height?.toDouble();
    if (ratio == null &&
        width != null &&
        height != null &&
        width > 0 &&
        height > 0) {
      ratio = height / width;
      hasMeasuredRatio = true;
    }
    ratio ??= 1.5;
    if (widget.controller.rotationQuarterTurns.isOdd) {
      ratio = 1 / math.max(0.001, ratio);
    }
    var scaled = effectiveViewport.width * ratio;
    if (!hasMeasuredRatio && index == widget.controller.currentIndex) {
      scaled = math.max(scaled, effectiveViewport.height);
    }
    final upper = math.max(
      effectiveViewport.height,
      effectiveViewport.width * 64,
    );
    return scaled.clamp(64.0, upper).toDouble();
  }

  double _verticalGapFor(bool stitch) => stitch ? 0 : _verticalPageGap;

  double get _effectiveGap => _verticalGapFor(widget.verticalStitch);

  ({double start, double end}) _verticalBoundsFor(
    int index, {
    Map<String, double>? ratios,
    bool? stitch,
    Size? viewport,
  }) {
    var start = 0.0;
    final pages = widget.controller.chapter.pages;
    for (var i = 0; i < index; i++) {
      start += _verticalExtent(
        pages[i],
        i,
        ratios: ratios,
        viewport: viewport,
      );
      start += _verticalGapFor(stitch ?? widget.verticalStitch);
    }
    return (
      start: start,
      end: start +
          _verticalExtent(
            pages[index],
            index,
            ratios: ratios,
            viewport: viewport,
          ),
    );
  }

  void _preserveVerticalAnchor({
    required Map<String, double> oldRatios,
    required bool oldStitch,
    Size? oldViewport,
  }) {
    if (widget.controller.direction != ReadingDirection.vertical ||
        !_verticalController.hasClients ||
        !_verticalController.position.hasContentDimensions ||
        _verticalController.position.isScrollingNotifier.value ||
        _interaction != Interaction.idle ||
        _viewport == Size.zero) {
      return;
    }
    final metrics = _verticalController.position;
    final center = metrics.pixels + metrics.viewportDimension / 2;
    final pages = widget.controller.chapter.pages;
    var offset = 0.0;
    for (var index = 0; index < pages.length; index++) {
      final extent = _verticalExtent(
        pages[index],
        index,
        ratios: oldRatios,
        viewport: oldViewport,
      );
      final end = offset + extent;
      if (center <= end || index == pages.length - 1) {
        _pendingVerticalAnchor = (
          index: index,
          fraction: ((center - offset) / math.max(1.0, extent))
              .clamp(0.0, 1.0)
              .toDouble(),
        );
        _scheduleVerticalAnchorRestore();
        return;
      }
      offset = end + _verticalGapFor(oldStitch);
    }
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
      final bounds = _verticalBoundsFor(anchor.index);
      final targetCenter = bounds.start +
          (bounds.end - bounds.start) * anchor.fraction;
      final position = _verticalController.position;
      final target = targetCenter - position.viewportDimension / 2;
      _verticalController.jumpTo(
        target.clamp(0.0, position.maxScrollExtent).toDouble(),
      );
    });
  }

  double _verticalOffsetFor(int index) {
    final bounds = _verticalBoundsFor(index);
    return (bounds.start + bounds.end) / 2 - _viewport.height / 2;
  }

  ({int index, double logicalPosition}) _verticalPosition(
    ScrollMetrics metrics,
  ) {
    final pages = widget.controller.chapter.pages;
    final center = metrics.pixels + metrics.viewportDimension / 2;
    var offset = 0.0;
    for (var i = 0; i < pages.length; i++) {
      final extent = _verticalExtent(pages[i], i);
      final end = offset + extent;
      if (center <= end || i == pages.length - 1) {
        final fraction = ((center - offset) / math.max(1.0, extent))
            .clamp(0.0, 0.999)
            .toDouble();
        return (index: i, logicalPosition: i + fraction);
      }
      offset = end + _effectiveGap;
    }
    return (
      index: pages.length - 1,
      logicalPosition: (pages.length - 1).toDouble(),
    );
  }

  void _prepareVerticalControllerForCurrentPage() {
    if (_verticalController.hasClients || _viewport == Size.zero) return;
    final initialOffset = math.max(
      0.0,
      _verticalOffsetFor(widget.controller.currentIndex),
    );
    _verticalController.dispose();
    _verticalController = ScrollController(initialScrollOffset: initialOffset);
    _verticalInitialOffsetApplied = true;
  }

  void _handleControllerCommand() {
    final controller = widget.controller;
    if (_lastDirection != controller.direction) {
      _lastDirection = controller.direction;
      _zoomedPage = null;
      if (controller.direction == ReadingDirection.vertical) {
        _verticalInitialOffsetApplied = false;
        _prepareVerticalControllerForCurrentPage();
      }
      _scheduleSyncToCurrentPage();
    }
    final revision = controller.navigationRevision;
    if (revision == _handledNavigationRevision) return;
    final requested = controller.requestedIndex;
    if (requested == null) {
      _handledNavigationRevision = revision;
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
      _interaction = Interaction.jumping;
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
    _interaction = Interaction.jumping;
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
      _interaction = Interaction.jumping;
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

  bool _handlePagedScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) {
      _interaction = notification.dragDetails == null
          ? Interaction.scrolling
          : Interaction.dragging;
      _emitFromPageMetrics(notification.metrics);
    } else if (notification is ScrollUpdateNotification) {
      _interaction = Interaction.scrolling;
      _emitFromPageMetrics(notification.metrics);
    } else if (notification is ScrollEndNotification) {
      _interaction = Interaction.idle;
      _emitFromPageMetrics(notification.metrics);
    }
    return false;
  }

  bool _handleVerticalScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) {
      _interaction = notification.dragDetails == null
          ? Interaction.scrolling
          : Interaction.dragging;
      _emitFromVerticalMetrics(notification.metrics);
    } else if (notification is ScrollUpdateNotification) {
      _interaction = Interaction.scrolling;
      _emitFromVerticalMetrics(notification.metrics);
    } else if (notification is ScrollEndNotification) {
      _interaction = Interaction.idle;
      _emitFromVerticalMetrics(notification.metrics);
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

  void _emitFromVerticalMetrics(ScrollMetrics metrics) {
    final position = _verticalPosition(metrics);
    final velocity = _velocityFor(position.logicalPosition);
    _emitObservation(
      position.logicalPosition,
      velocity,
      stableIndex: position.index,
    );
    if (_lastReportedVerticalPage != position.index) {
      _lastReportedVerticalPage = position.index;
      _recordPageCurrent(position.index);
    }
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
    _lastLogicalPosition = index.toDouble();
    _interaction = Interaction.settling;
    _emitObservation(index.toDouble(), 0, stableIndex: index);
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
  }) {
    final pages = widget.controller.chapter.pages;
    final stable = stableIndex ?? widget.controller.stableIndex;
    final boundedStable = stable.clamp(0, pages.length - 1).toInt();
    final distance = (logicalPosition - boundedStable)
        .abs()
        .clamp(0.0, 1.0)
        .toDouble();
    final currentFraction = (1.0 - distance).clamp(0.0, 1.0).toDouble();

    int? targetIndex;
    if (distance > 0.001) {
      targetIndex = logicalPosition > boundedStable
          ? logicalPosition.ceil()
          : logicalPosition.floor();
      targetIndex = targetIndex.clamp(0, pages.length - 1).toInt();
      if (targetIndex == boundedStable) targetIndex = null;
    }

    final observation = ReaderObs(
      sessionId: widget.controller.sessionId,
      currentIndex: boundedStable,
      stableIndex: boundedStable,
      interaction: _interaction,
      logicalPosition: logicalPosition,
      velocity: velocity,
      currentCoverage: Coverage(
        pageIndex: boundedStable,
        assetKey: pages[boundedStable].assetKey,
        fraction: currentFraction,
      ),
      targetCoverage: targetIndex == null
          ? null
          : Coverage(
              pageIndex: targetIndex,
              assetKey: pages[targetIndex].assetKey,
              fraction: distance,
            ),
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
            'targetCoverage': distance,
          },
        ),
      );
    }
  }
}

final class _ZoomableReaderPage extends StatefulWidget {
  const _ZoomableReaderPage({
    required this.child,
    required this.active,
    required this.onZoomChanged,
    this.onTap,
    super.key,
  });

  final Widget child;
  final bool active;
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
  DateTime? _lastTapAt;
  Offset? _lastTapPosition;

  @override
  void initState() {
    super.initState();
    _transformation = TransformationController();
  }

  @override
  void didUpdateWidget(covariant _ZoomableReaderPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active && _zoomed) {
      _singleTapTimer?.cancel();
      _singleTapTimer = null;
      _lastTapAt = null;
      _lastTapPosition = null;
      _transformation.value = Matrix4.identity();
      _zoomed = false;
    }
  }

  @override
  void dispose() {
    _singleTapTimer?.cancel();
    _transformation.dispose();
    super.dispose();
  }

  double get _scale => _transformation.value.getMaxScaleOnAxis();

  void _publishZoom() {
    final zoomed = _scale > 1.01;
    if (_zoomed == zoomed) {
      return;
    }
    _zoomed = zoomed;
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
    final now = DateTime.now();
    final lastAt = _lastTapAt;
    final lastPosition = _lastTapPosition;
    final isDoubleTap = lastAt != null &&
        now.difference(lastAt) <= const Duration(milliseconds: 280) &&
        lastPosition != null &&
        (position - lastPosition).distance <= 48;
    if (isDoubleTap) {
      _singleTapTimer?.cancel();
      _singleTapTimer = null;
      _lastTapAt = null;
      _lastTapPosition = null;
      _toggleZoom(position);
      return;
    }
    _lastTapAt = now;
    _lastTapPosition = position;
    _singleTapTimer?.cancel();
    _singleTapTimer = Timer(const Duration(milliseconds: 280), () {
      _singleTapTimer = null;
      _lastTapAt = null;
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
    required this.sessionId,
    required this.clock,
    required this.traceSink,
    required this.pageBuilder,
    required this.demandRevision,
    required this.onFirstFrameReady,
    super.key,
  });

  final PageAsset asset;
  final String sessionId;
  final MonoClock clock;
  final TraceSink traceSink;
  final ReaderPageBuilder? pageBuilder;
  final int Function()? demandRevision;
  final VoidCallback onFirstFrameReady;

  @override
  State<_ReaderPageHost> createState() => _ReaderPageHostState();
}

final class _ReaderPageHostState extends State<_ReaderPageHost> {
  bool _reportedFirstFrame = false;
  late int _mountedAtMicros;
  int? _mountedRevision;

  @override
  void initState() {
    super.initState();
    _mountedAtMicros = widget.clock.nowMicros();
    _mountedRevision = widget.demandRevision?.call();
    _recordLifecycle(
      TraceEventKind.pageHostMounted,
      revision: _mountedRevision,
    );
  }

  @override
  void didUpdateWidget(covariant _ReaderPageHost oldWidget) {
    super.didUpdateWidget(oldWidget);
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
    widget.onFirstFrameReady();
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
