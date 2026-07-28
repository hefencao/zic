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
    this.onTap,
    super.key,
  });

  final ReaderController controller;
  final MonoClock clock;
  final TraceSink traceSink;
  final ReaderPageBuilder? pageBuilder;
  final VoidCallback? onTap;

  @override
  State<ReaderView> createState() => _ReaderViewState();
}

final class _ReaderViewState extends State<ReaderView> {
  late PageController _pageController;
  double _lastLogicalPosition = 0;
  int _lastMicros = 0;
  Interaction _interaction = Interaction.idle;
  int _handledNavigationRevision = 0;
  int? _zoomedPage;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.controller.currentIndex);
    _lastLogicalPosition = widget.controller.currentIndex.toDouble();
    _lastMicros = widget.clock.nowMicros();
    _handledNavigationRevision = widget.controller.navigationRevision;
    widget.controller.addListener(_handleControllerCommand);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _emitObservation(_lastLogicalPosition, 0);
      }
    });
  }

  @override
  void didUpdateWidget(covariant ReaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerCommand);
      widget.controller.addListener(_handleControllerCommand);
      _pageController.dispose();
      _pageController = PageController(
        initialPage: widget.controller.currentIndex,
      );
      _lastLogicalPosition = widget.controller.currentIndex.toDouble();
      _lastMicros = widget.clock.nowMicros();
      _interaction = Interaction.idle;
      _handledNavigationRevision = widget.controller.navigationRevision;
      _zoomedPage = null;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerCommand);
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chapter = widget.controller.chapter;

    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final direction = widget.controller.direction;
        final isVertical = direction == ReadingDirection.vertical;
        return NotificationListener<ScrollNotification>(
          onNotification: _handleScrollNotification,
          child: PageView.builder(
            controller: _pageController,
            itemCount: chapter.pages.length,
            reverse: direction == ReadingDirection.rtl,
            scrollDirection: isVertical ? Axis.vertical : Axis.horizontal,
            physics: _zoomedPage == null
                ? const PageScrollPhysics()
                : const NeverScrollableScrollPhysics(),
            onPageChanged: _handlePageChanged,
            itemBuilder: (context, index) => RotatedBox(
              key: ValueKey<String>('reader-page-rotation:$index'),
              quarterTurns: widget.controller.rotationQuarterTurns,
              child: _ZoomableReaderPage(
                key: ValueKey<String>(
                  'zoom:${chapter.pages[index].assetKey}:'
                  '${index == widget.controller.currentIndex}',
                ),
                onTap: widget.onTap,
                onZoomChanged: (zoomed) {
                  final next = zoomed ? index : null;
                  if (_zoomedPage == next) {
                    return;
                  }
                  setState(() => _zoomedPage = next);
                },
                child: _ReaderPageHost(
                  asset: chapter.pages[index],
                  sessionId: widget.controller.sessionId,
                  clock: widget.clock,
                  traceSink: widget.traceSink,
                  pageBuilder: widget.pageBuilder,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _handleControllerCommand() {
    final controller = widget.controller;
    final revision = controller.navigationRevision;
    if (revision == _handledNavigationRevision) {
      return;
    }
    final requested = controller.requestedIndex;
    if (requested == null) {
      _handledNavigationRevision = revision;
      return;
    }
    if (!_pageController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _handleControllerCommand();
        }
      });
      return;
    }
    _handledNavigationRevision = revision;
    _interaction = Interaction.jumping;
    _zoomedPage = null;
    _pageController.jumpToPage(requested);
    controller.acknowledgePageRequest(revision);
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      _interaction = notification.dragDetails == null
          ? Interaction.scrolling
          : Interaction.dragging;
      _emitFromMetrics(notification.metrics);
    } else if (notification is ScrollUpdateNotification) {
      _interaction = Interaction.scrolling;
      _emitFromMetrics(notification.metrics);
    } else if (notification is ScrollEndNotification) {
      _interaction = Interaction.idle;
      _emitFromMetrics(notification.metrics);
    }
    return false;
  }

  void _emitFromMetrics(ScrollMetrics metrics) {
    if (metrics is! PageMetrics) {
      return;
    }
    final logicalPosition =
        metrics.page ?? widget.controller.currentIndex.toDouble();
    final now = widget.clock.nowMicros();
    final elapsedSeconds = math.max(1, now - _lastMicros) / 1000000.0;
    final velocity = (logicalPosition - _lastLogicalPosition) / elapsedSeconds;
    _lastLogicalPosition = logicalPosition;
    _lastMicros = now;
    _emitObservation(logicalPosition, velocity);
  }

  void _handlePageChanged(int index) {
    _zoomedPage = null;
    _lastLogicalPosition = index.toDouble();
    _interaction = Interaction.settling;
    _emitObservation(index.toDouble(), 0, stableIndex: index);
    widget.traceSink.record(
      traceEvent(
        clock: widget.clock,
        sessionId: widget.controller.sessionId,
        kind: TraceEventKind.pageCurrent,
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
      if (targetIndex == boundedStable) {
        targetIndex = null;
      }
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
  }
}

final class _ZoomableReaderPage extends StatefulWidget {
  const _ZoomableReaderPage({
    required this.child,
    required this.onZoomChanged,
    this.onTap,
    super.key,
  });

  final Widget child;
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
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      child: InteractiveViewer(
        transformationController: _transformation,
        minScale: 1,
        maxScale: 5,
        panEnabled: true,
        scaleEnabled: true,
        clipBehavior: Clip.hardEdge,
        onInteractionUpdate: (_) => _publishZoom(),
        onInteractionEnd: (_) => _publishZoom(),
        child: SizedBox.expand(child: widget.child),
      ),
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
  });

  final PageAsset asset;
  final String sessionId;
  final MonoClock clock;
  final TraceSink traceSink;
  final ReaderPageBuilder? pageBuilder;

  @override
  State<_ReaderPageHost> createState() => _ReaderPageHostState();
}

final class _ReaderPageHostState extends State<_ReaderPageHost> {
  bool _reportedFirstFrame = false;

  @override
  void didUpdateWidget(covariant _ReaderPageHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.assetKey != widget.asset.assetKey) {
      _reportedFirstFrame = false;
    }
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
          payload: <String, Object?>{'pageIndex': asset.index},
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
