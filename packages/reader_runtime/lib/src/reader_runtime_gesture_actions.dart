part of 'reader_runtime_screen.dart';

extension _ReaderRuntimeGestureActions on _ReaderRuntimeScreenState {
  int _tapZoneIndex(
    Offset globalPosition,
    ReaderGestureGridLayout layout,
  ) {
    final renderObject = context.findRenderObject();
    final box = renderObject is RenderBox ? renderObject : null;
    final local =
        box == null ? globalPosition : box.globalToLocal(globalPosition);
    final size = box?.size ?? MediaQuery.sizeOf(context);
    if (size.width <= 0 || size.height <= 0) return 4;
    final x = (local.dx / size.width).clamp(0.0, 1.0).toDouble();
    final y = (local.dy / size.height).clamp(0.0, 1.0).toDouble();
    final column = layout.columnFor(x);
    final row = layout.rowFor(y);
    return row * 3 + column;
  }

  void _handleReaderSingleTap(Offset globalPosition) {
    final reader = _reader;
    if (reader == null) return;
    if (_tapRegionDraft != null) return;
    final mode = _readerMode(reader.direction);
    final settings = _settings.modeSettingsFor(mode);
    final zone = _tapZoneIndex(
      globalPosition,
      settings.singleTapGridLayout,
    );
    final action = settings.singleTapActionAt(zone);
    _pipeline.trace.record(
      traceEvent(
        clock: _pipeline.clock,
        sessionId: reader.sessionId,
        kind: TraceEventKind.readerObservation,
        revision: _pipeline.revision,
        payload: <String, Object?>{
          'stage': 'reader-single-tap-action',
          'mode': mode.name,
          'zone': zone,
          'action': action.name,
          'pageIndex': reader.currentIndex,
          if (mode == ReaderMode.continuous &&
              (action == ReaderGestureAction.previousPage ||
                  action == ReaderGestureAction.nextPage))
            'screenRetainFraction':
                settings.effectiveSingleTapScreenRetainFraction,
        },
      ),
    );
    switch (action) {
      case ReaderGestureAction.defaultBehavior:
        _toggleControls();
        return;
      case ReaderGestureAction.previousPage:
        if (mode == ReaderMode.continuous) {
          reader.requestViewportStep(
            -(1 - settings.effectiveSingleTapScreenRetainFraction),
            animated: settings.singleTapPageAnimation,
          );
        } else {
          final target = reader.currentIndex - 1;
          if (target >= 0) {
            reader.requestPage(
              target,
              animated: settings.singleTapPageAnimation,
            );
          }
        }
        return;
      case ReaderGestureAction.nextPage:
        if (mode == ReaderMode.continuous) {
          reader.requestViewportStep(
            1 - settings.effectiveSingleTapScreenRetainFraction,
            animated: settings.singleTapPageAnimation,
          );
        } else {
          final target = reader.currentIndex + 1;
          if (target < widget.chapter.pages.length) {
            reader.requestPage(
              target,
              animated: settings.singleTapPageAnimation,
            );
          }
        }
        return;
      case ReaderGestureAction.previousChapter:
        unawaited(_requestTapChapter(ReaderChapterBoundary.previous));
        return;
      case ReaderGestureAction.nextChapter:
        unawaited(_requestTapChapter(ReaderChapterBoundary.next));
        return;
    }
  }

  Future<void> _requestTapChapter(ReaderChapterBoundary boundary) async {
    if (_tapChapterRequestInFlight) return;
    final available = boundary == ReaderChapterBoundary.previous
        ? widget.canReadPreviousChapter
        : widget.canReadNextChapter;
    final callback = widget.onChapterBoundaryRequested;
    if (!available || callback == null) return;
    _tapChapterRequestInFlight = true;
    try {
      await Future<void>.sync(() => callback(boundary));
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          _copyableReaderErrorSnackBar(
            boundary == ReaderChapterBoundary.previous
                ? '加载上一章失败：$error'
                : '加载下一章失败：$error',
          ),
        );
      }
    } finally {
      _tapChapterRequestInFlight = false;
    }
  }
}
