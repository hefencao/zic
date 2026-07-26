import 'dart:math' as math;

import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:telemetry/telemetry.dart';

import 'reader_controller.dart';

final class ReaderView extends StatefulWidget {
  const ReaderView({
    required this.controller,
    required this.clock,
    this.traceSink = const NoopTraceSink(),
    super.key,
  });

  final ReaderController controller;
  final MonoClock clock;
  final TraceSink traceSink;

  @override
  State<ReaderView> createState() => _ReaderViewState();
}

final class _ReaderViewState extends State<ReaderView> {
  late PageController _pageController;
  double _lastLogicalPosition = 0;
  int _lastMicros = 0;
  Interaction _interaction = Interaction.idle;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.controller.currentIndex);
    _lastLogicalPosition = widget.controller.currentIndex.toDouble();
    _lastMicros = widget.clock.nowMicros();
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
      _pageController.dispose();
      _pageController = PageController(initialPage: widget.controller.currentIndex);
      _lastLogicalPosition = widget.controller.currentIndex.toDouble();
    }
  }

  @override
  void dispose() {
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
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            NotificationListener<ScrollNotification>(
              onNotification: _handleScrollNotification,
              child: PageView.builder(
                controller: _pageController,
                itemCount: chapter.pages.length,
                reverse: direction == ReadingDirection.rtl,
                scrollDirection: isVertical ? Axis.vertical : Axis.horizontal,
                onPageChanged: _handlePageChanged,
                itemBuilder: (context, index) => _StaticReaderPage(
                  asset: chapter.pages[index],
                  sessionId: widget.controller.sessionId,
                  clock: widget.clock,
                  traceSink: widget.traceSink,
                ),
              ),
            ),
            Positioned(
              right: 12,
              bottom: 12,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Text(
                    '${widget.controller.currentIndex + 1} / ${chapter.pages.length}',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
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
    final logicalPosition = metrics.page ?? widget.controller.currentIndex.toDouble();
    final now = widget.clock.nowMicros();
    final elapsedSeconds = math.max(1, now - _lastMicros) / 1000000.0;
    final velocity = (logicalPosition - _lastLogicalPosition) / elapsedSeconds;
    _lastLogicalPosition = logicalPosition;
    _lastMicros = now;
    _emitObservation(logicalPosition, velocity);
  }

  void _handlePageChanged(int index) {
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

final class _StaticReaderPage extends StatefulWidget {
  const _StaticReaderPage({
    required this.asset,
    required this.sessionId,
    required this.clock,
    required this.traceSink,
  });

  final PageAsset asset;
  final String sessionId;
  final MonoClock clock;
  final TraceSink traceSink;

  @override
  State<_StaticReaderPage> createState() => _StaticReaderPageState();
}

final class _StaticReaderPageState extends State<_StaticReaderPage> {
  bool _reportedFirstFrame = false;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Image.asset(
          widget.asset.uri.toString(),
          fit: BoxFit.contain,
          filterQuality: FilterQuality.low,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (!_reportedFirstFrame && (frame != null || wasSynchronouslyLoaded)) {
              _reportedFirstFrame = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                widget.traceSink.record(
                  traceEvent(
                    clock: widget.clock,
                    sessionId: widget.sessionId,
                    kind: TraceEventKind.firstFrameReady,
                    identityHash: widget.asset.assetKey,
                    payload: <String, Object?>{'pageIndex': widget.asset.index},
                  ),
                );
              });
            }
            return child;
          },
          errorBuilder: (context, error, stackTrace) => Center(
            child: Text(
              'Page ${widget.asset.index + 1} failed to load',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}
