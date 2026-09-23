part of 'reader_view.dart';

final class _ReaderPageShell extends StatefulWidget {
  const _ReaderPageShell({
    required this.controller,
    required this.keepAliveCenter,
    required this.asset,
    required this.index,
    required this.clock,
    required this.traceSink,
    required this.pageBuilder,
    required this.demandRevision,
    required this.onZoomChanged,
    required this.zoomStageFirst,
    required this.zoomStageSecond,
    required this.longPressZoomEnabled,
    required this.longPressZoomScale,
    required this.longPressZoomRestoreOnRelease,
    required this.longPressZoomMoveMode,
    required this.longPressZoomPanRatio,
    required this.longPressZoomLimitToViewport,
    required this.doubleTapZoomOrigin,
    required this.pageAspectRatio,
    this.onTap,
    this.onScaleChanged,
    this.onStripLensStart,
    this.onStripPanHoldStart,
    this.onStripLensMove,
    this.onStripLensEnd,
    this.onStripDoubleTap,
    super.key,
  });

  final ReaderController controller;
  final ValueListenable<int> keepAliveCenter;
  final PageAsset asset;
  final int index;
  final MonoClock clock;
  final TraceSink traceSink;
  final ReaderPageBuilder? pageBuilder;
  final int Function()? demandRevision;
  final ValueChanged<bool> onZoomChanged;
  final double zoomStageFirst;
  final double zoomStageSecond;
  final bool longPressZoomEnabled;
  final double longPressZoomScale;
  final bool longPressZoomRestoreOnRelease;
  final ReaderLongPressMoveMode longPressZoomMoveMode;
  final double longPressZoomPanRatio;
  final bool longPressZoomLimitToViewport;

  /// Where double-tap zoom anchors the magnified result.
  final ReaderDoubleTapZoomOrigin doubleTapZoomOrigin;

  /// Resolves this page's current display ratio (height/width) for the
  /// image-rect based boundary constraints.
  final double? Function() pageAspectRatio;
  final VoidCallback? onTap;
  final ValueChanged<double>? onScaleChanged;
  final VoidCallback? onStripLensStart;
  final VoidCallback? onStripPanHoldStart;

  /// Receives the raw global pointer position while the strip lens is active.
  final void Function(Offset globalPosition)? onStripLensMove;
  final VoidCallback? onStripLensEnd;
  final void Function(Offset globalPosition)? onStripDoubleTap;

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
    widget.controller.currentIndexListenable.addListener(_handleCurrentIndexChanged);
    widget.keepAliveCenter.addListener(_handleKeepAliveCenterChanged);
  }

  @override
  void didUpdateWidget(covariant _ReaderPageShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      oldWidget.controller.currentIndexListenable
          .removeListener(_handleCurrentIndexChanged);
      widget.controller.addListener(_handleControllerChanged);
      widget.controller.currentIndexListenable
          .addListener(_handleCurrentIndexChanged);
    }
    if (oldWidget.keepAliveCenter != widget.keepAliveCenter) {
      oldWidget.keepAliveCenter.removeListener(_handleKeepAliveCenterChanged);
      widget.keepAliveCenter.addListener(_handleKeepAliveCenterChanged);
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
    widget.controller.currentIndexListenable
        .removeListener(_handleCurrentIndexChanged);
    widget.keepAliveCenter.removeListener(_handleKeepAliveCenterChanged);
    _activeNotifier.dispose();
    _keepAliveNotifier.dispose();
    super.dispose();
  }

  bool _keepAliveFor(ReaderController controller) {
    return controller.direction == ReadingDirection.vertical &&
        (widget.index - widget.keepAliveCenter.value).abs() <= 7;
  }

  void _readControllerState() {
    _active = widget.index == widget.controller.currentIndex;
    _keepAlive = _keepAliveFor(widget.controller);
    _rotationQuarterTurns = widget.controller.rotationQuarterTurns;
  }

  void _handleCurrentIndexChanged() {
    final nextActive = widget.index == widget.controller.currentIndex;
    if (_active == nextActive) return;
    _active = nextActive;
    _activeNotifier.value = nextActive;
  }

  void _handleKeepAliveCenterChanged() {
    final nextKeepAlive = _keepAliveFor(widget.controller);
    if (_keepAlive == nextKeepAlive) return;
    _keepAlive = nextKeepAlive;
    _keepAliveNotifier.value = nextKeepAlive;
  }

  void _handleControllerChanged() {
    // Broad controller notifications are commands (direction/rotation/request),
    // never current-page projection. Direction can still change keepAlive.
    _handleKeepAliveCenterChanged();
    final nextRotation = widget.controller.rotationQuarterTurns;
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
      interactive:
          widget.controller.direction != ReadingDirection.vertical,
      zoomStageFirst: widget.zoomStageFirst,
      zoomStageSecond: widget.zoomStageSecond,
      longPressZoomEnabled: widget.longPressZoomEnabled,
      longPressZoomScale: widget.longPressZoomScale,
      longPressZoomRestoreOnRelease: widget.longPressZoomRestoreOnRelease,
      longPressZoomMoveMode: widget.longPressZoomMoveMode,
      longPressZoomPanRatio: widget.longPressZoomPanRatio,
      longPressZoomLimitToViewport: widget.longPressZoomLimitToViewport,
      doubleTapZoomOrigin: widget.doubleTapZoomOrigin,
      pageAspectRatio: widget.pageAspectRatio,
      onScaleChanged: widget.onScaleChanged,
      onStripLensStart: widget.onStripLensStart,
      onStripPanHoldStart: widget.onStripPanHoldStart,
      onStripLensMove: widget.onStripLensMove,
      onStripLensEnd: widget.onStripLensEnd,
      onStripDoubleTap: widget.onStripDoubleTap,
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
    this.interactive = true,
    this.zoomStageFirst = 1.5,
    this.zoomStageSecond = 2.0,
    this.longPressZoomEnabled = false,
    this.longPressZoomScale = 2.0,
    this.longPressZoomRestoreOnRelease = true,
    this.longPressZoomMoveMode = ReaderLongPressMoveMode.drag,
    this.longPressZoomPanRatio = 1.0,
    this.longPressZoomLimitToViewport = true,
    this.doubleTapZoomOrigin = ReaderDoubleTapZoomOrigin.center,
    this.pageAspectRatio,
    this.onScaleChanged,
    this.onStripLensStart,
    this.onStripPanHoldStart,
    this.onStripLensMove,
    this.onStripLensEnd,
    this.onStripDoubleTap,
    super.key,
  });

  final Widget child;
  final ValueListenable<bool> active;
  final MonoClock clock;
  final ValueChanged<bool> onZoomChanged;
  final VoidCallback? onTap;

  /// False inside continuous strips where the whole-strip zoom owns all
  /// magnification gestures; the page only keeps tap-to-toggle-controls.
  final bool interactive;
  final double zoomStageFirst;
  final double zoomStageSecond;
  final bool longPressZoomEnabled;
  final double longPressZoomScale;

  /// True (default) restores 1x when the long press ends; false keeps the
  /// zoom until a double-tap, page change or reset.
  final bool longPressZoomRestoreOnRelease;

  /// Long-press zoom movement: drag follows the finger, focus keeps the
  /// magnified region centered on the finger.
  final ReaderLongPressMoveMode longPressZoomMoveMode;

  /// Finger-to-content travel multiplier for [ReaderLongPressMoveMode.drag].
  final double longPressZoomPanRatio;

  /// When true, dragging keeps the scaled content covering the viewport.
  final bool longPressZoomLimitToViewport;

  /// Where double-tap zoom anchors the magnified result.
  final ReaderDoubleTapZoomOrigin doubleTapZoomOrigin;

  /// Resolves this page's current display ratio (height/width) for the
  /// image-rect based boundary constraints.
  final double? Function()? pageAspectRatio;
  final ValueChanged<double>? onScaleChanged;

  /// Strip-mode lens hooks (continuous reading). The page drives them from
  /// its own raw-pointer timer so no LongPress recognizer can compete with
  /// list scrolling. The move hook receives the raw global pointer position.
  final VoidCallback? onStripLensStart;

  /// The second press of a double-tap held past the threshold: keeps the
  /// current zoom stage and enters fixed horizontal-offset mode until release.
  final VoidCallback? onStripPanHoldStart;
  final void Function(Offset globalPosition)? onStripLensMove;
  final VoidCallback? onStripLensEnd;
  final void Function(Offset globalPosition)? onStripDoubleTap;

  @override
  State<_ZoomableReaderPage> createState() => _ZoomableReaderPageState();
}

final class _ZoomableReaderPageState extends State<_ZoomableReaderPage>
    with TickerProviderStateMixin {
  late final TransformationController _transformation;
  bool _zoomed = false;
  bool _lensActive = false;
  Offset? _lensBaseTranslation;
  bool _stripLensCandidate = false;
  bool _stripHoldFromDoubleTap = false;
  Timer? _stripLensTimer;
  AnimationController? _transition;
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
    _transformation.addListener(_handleTransformationChanged);
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
    if (!widget.interactive && oldWidget.interactive) {
      _resetZoom();
    }
  }

  @override
  void dispose() {
    widget.active.removeListener(_handleActiveChanged);
    _transformation.removeListener(_handleTransformationChanged);
    _transition?.dispose();
    _singleTapTimer?.cancel();
    _stripLensTimer?.cancel();
    _transformation.dispose();
    super.dispose();
  }

  void _handleTransformationChanged() {
    // InteractiveViewer applies its own page-box clamp during the gesture,
    // but its inertial pan/scale animations update the controller without
    // invoking onInteractionUpdate. Keep the actual image-rect constraint in
    // force for those frames as well.
    _clampInteractiveTranslation();
  }

  void _handleActiveChanged() {
    if (widget.active.value || !_zoomed) return;
    _resetZoom();
  }

  void _resetZoom() {
    _transition?.stop();
    _lensActive = false;
    _lensBaseTranslation = null;
    _singleTapTimer?.cancel();
    _singleTapTimer = null;
    _lastTapAtMicros = null;
    _lastTapPosition = null;
    _transformation.value = Matrix4.identity();
    if (_zoomed) {
      setState(() => _zoomed = false);
    } else {
      _reportScale(1);
    }
  }

  double get _scale => _transformation.value.getMaxScaleOnAxis();

  void _reportScale(double value) {
    widget.onScaleChanged?.call(value);
  }

  void _publishZoom() {
    final zoomed = _scale > 1.01;
    if (_zoomed == zoomed) {
      return;
    }
    setState(() => _zoomed = zoomed);
    widget.onZoomChanged(zoomed);
  }

  void _clampInteractiveTranslation() {
    final scale = _scale;
    if (!scale.isFinite || scale <= 0) return;
    final matrix = _transformation.value;
    final translation = Offset(matrix.storage[12], matrix.storage[13]);
    final clamped = _limitTranslation(scale, translation);
    if ((clamped - translation).distance <= precisionErrorTolerance) {
      return;
    }
    final corrected = matrix.clone();
    corrected.storage[12] = clamped.dx;
    corrected.storage[13] = clamped.dy;
    _transformation.value = corrected;
  }

  int _stageIndexForScale(double scale) {
    final first = math.max(1.1, widget.zoomStageFirst);
    final second = math.max(first, widget.zoomStageSecond);
    if (!scale.isFinite || scale <= 1.01) return -1;
    if (scale >= second - 0.01) return 1;
    if (scale >= first - 0.01) return 0;
    return -1;
  }

  Size get _boxSize =>
      context.size ?? MediaQuery.of(context).size;

  /// Actual displayed image rect within the page box under contain fit, or
  /// null when the ratio is unknown (page assumed filled). Boundary
  /// constraints follow this rect so letterboxed pages behave correctly.
  Rect? _imageRect(Size box) {
    final ratio = widget.pageAspectRatio?.call();
    if (ratio == null || !ratio.isFinite || ratio <= 0 || box.isEmpty) {
      return null;
    }
    var width = box.width;
    var height = width * ratio;
    if (height > box.height && height > 0) {
      height = box.height;
      width = height / ratio;
    }
    return Rect.fromLTWH(
      (box.width - width) / 2,
      (box.height - height) / 2,
      width,
      height,
    );
  }

  void _cycleStages(Offset position) {
    if (!widget.interactive) return;
    final currentIndex = _stageIndexForScale(_scale);
    final nextIndex = currentIndex >= 1 ? -1 : currentIndex + 1;
    final target = nextIndex < 0
        ? Matrix4.identity()
        : _stageMatrix(nextIndex, position);
    final settledScale =
        nextIndex < 0 ? 1.0 : target.getMaxScaleOnAxis();
    _transition?.stop();
    _transformation.value = target;
    _publishZoom();
    _reportScale(settledScale);
  }

  Matrix4 _stageMatrix(int index, Offset tapLocal) {
    final scale = switch (index) {
      0 => widget.zoomStageFirst,
      1 => math.max(widget.zoomStageFirst, widget.zoomStageSecond),
      _ => 1.0,
    };
    if (scale <= 1.001) {
      return Matrix4.identity();
    }
    final size = _boxSize;
    final pivot = switch (widget.doubleTapZoomOrigin) {
      ReaderDoubleTapZoomOrigin.center =>
        Offset(size.width / 2, size.height / 2),
      _ => tapLocal,
    };
    final currentScale = _scale.isFinite && _scale > 0 ? _scale : 1.0;
    final currentMatrix = _transformation.value;
    final currentOffset = Offset(
      currentMatrix.storage[12],
      currentMatrix.storage[13],
    );
    // Keep the content currently under the pivot fixed while changing
    // stages. At 1x this reduces to pivot * (1 - scale); at the second stage
    // the division by the current scale prevents a first-stage offset from
    // being interpreted as a 1x offset and clamped to the wrong edge.
    var translation = Offset(
      pivot.dx - scale * ((pivot.dx - currentOffset.dx) / currentScale),
      pivot.dy - scale * ((pivot.dy - currentOffset.dy) / currentScale),
    );
    if (widget.doubleTapZoomOrigin == ReaderDoubleTapZoomOrigin.snap) {
      final rect = _imageRect(size);
      if (rect != null) {
        double snapAxis({
          required double contentStart,
          required double contentEnd,
          required double viewSize,
          required double tapPosition,
        }) {
          if (contentEnd - contentStart <=
              viewSize + precisionErrorTolerance) {
            // The scaled image cannot cover this axis; center it instead.
            return (viewSize - (contentStart + contentEnd)) / 2;
          }
          return tapPosition >= viewSize / 2
              ? viewSize - contentEnd
              : -contentStart;
        }
        translation = Offset(
          snapAxis(
            contentStart: scale * rect.left,
            contentEnd: scale * rect.right,
            viewSize: size.width,
            tapPosition: tapLocal.dx,
          ),
          snapAxis(
            contentStart: scale * rect.top,
            contentEnd: scale * rect.bottom,
            viewSize: size.height,
            tapPosition: tapLocal.dy,
          ),
        );
      }
    }
    translation = _limitTranslation(scale, translation);
    return Matrix4.identity()
      ..translate(translation.dx, translation.dy)
      ..scale(scale);
  }

  void _animateTo(Matrix4 target, {required VoidCallback? onCompleted}) {
    _transition?.stop();
    _transition?.dispose();
    final start = _transformation.value.clone();
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _transition = controller;
    controller.addListener(() {
      final eased = Curves.easeOutCubic.transform(controller.value);
      final from = start.storage;
      final to = target.storage;
      final mixed = Float64List(16);
      for (var index = 0; index < 16; index++) {
        mixed[index] = from[index] + (to[index] - from[index]) * eased;
      }
      _transformation.value = Matrix4.fromFloat64List(mixed);
    });
    controller.addStatusListener((status) {
      if (status != AnimationStatus.completed) return;
      // Re-evaluate the zoom state against the settled matrix so the
      // InteractiveViewer unmounts and page scrolling resumes after a
      // restore-on-release magnifier.
      _publishZoom();
      onCompleted?.call();
    });
    controller.forward();
  }

  Offset _clampTranslation(double scale, Offset translation) {
    final size = _boxSize;
    final maxX = size.width * (scale - 1);
    final maxY = size.height * (scale - 1);
    return Offset(
      translation.dx.clamp(-maxX, 0.0).toDouble(),
      translation.dy.clamp(-maxY, 0.0).toDouble(),
    );
  }

  void _handleLensStart(LongPressStartDetails details) {
    if (!widget.interactive || !widget.longPressZoomEnabled || _zoomed) {
      return;
    }
    _cancelPendingTap();
    final scale = widget.longPressZoomScale.isFinite
        ? widget.longPressZoomScale.clamp(1.1, 8.0).toDouble()
        : 2.0;
    _lensActive = true;
    final entry = Offset(
      details.localPosition.dx * (1 - scale),
      details.localPosition.dy * (1 - scale),
    );
    final clamped = _limitTranslation(scale, entry);
    _transformation.value = Matrix4.identity()
      ..translate(clamped.dx, clamped.dy)
      ..scale(scale);
    _lensBaseTranslation = Offset(
      _transformation.value.storage[12],
      _transformation.value.storage[13],
    );
    _publishZoom();
    _reportScale(_scale);
  }

  double get _effectiveLensPanRatio =>
      widget.longPressZoomPanRatio.isFinite &&
              widget.longPressZoomPanRatio > 0
          ? widget.longPressZoomPanRatio.clamp(0.25, 4.0).toDouble()
          : 1.0;

  /// Boundary constraint against the actual displayed image rect (contain
  /// fit), not just the page widget: a scaled edge leaving through one side
  /// keeps the opposite side inside; an axis the scaled image cannot cover
  /// stays centered.
  Offset _limitTranslation(double scale, Offset translation) {
    if (!widget.longPressZoomLimitToViewport) return translation;
    final size = _boxSize;
    final rect = _imageRect(size);
    if (rect == null) return _clampTranslation(scale, translation);
    return Offset(
      _clampAxisForImage(
        translation.dx,
        scale: scale,
        viewSize: size.width,
        imageStart: () => rect.left,
        imageEnd: () => rect.right,
      ),
      _clampAxisForImage(
        translation.dy,
        scale: scale,
        viewSize: size.height,
        imageStart: () => rect.top,
        imageEnd: () => rect.bottom,
      ),
    );
  }

  void _handleLensMove(LongPressMoveUpdateDetails details) {
    if (!_lensActive) return;
    final scale = math.max(math.max(
      widget.zoomStageSecond,
      widget.zoomStageFirst,
    ), 1.01);
    final base = _lensBaseTranslation ?? Offset.zero;
    final Offset translation;
    switch (widget.longPressZoomMoveMode) {
      case ReaderLongPressMoveMode.drag:
        // offsetFromOrigin is cumulative from the long-press origin. Applying
        // it to the entry translation exactly once makes content follow the
        // finger at the zoomed resolution; re-adding it per update was the
        // source of the runaway drag.
        translation = base + details.offsetFromOrigin * _effectiveLensPanRatio;
      case ReaderLongPressMoveMode.focus:
        // The content point under the finger stays under it: t = p * (1 - s).
        final position = details.localPosition;
        translation = Offset(
          position.dx * (1 - scale),
          position.dy * (1 - scale),
        );
    }
    final clamped = _limitTranslation(scale, translation);
    _transformation.value = Matrix4.identity()
      ..translate(clamped.dx, clamped.dy)
      ..scale(scale);
  }

  void _handleLensEnd(LongPressEndDetails details) {
    if (!widget.interactive) return;
    _finishPagedLens();
  }

  /// Settles the paged magnifier. Owned by the long-press recognizer (end or
  /// cancel); the outer raw-pointer handlers must not clear [_lensActive]
  /// first, or restore/persist would never run.
  void _finishPagedLens() {
    if (!_lensActive) return;
    _lensActive = false;
    _lensBaseTranslation = null;
    if (!widget.longPressZoomRestoreOnRelease) {
      // Persistent magnifier: keep the zoom after release. The next double-tap
      // cycles back to 1x and page changes reset via _resetZoom.
      _reportScale(_scale);
      _publishZoom();
      return;
    }
    _animateTo(Matrix4.identity(), onCompleted: () {
      _reportScale(1);
    });
    _publishZoom();
  }

  void _cancelPendingTap() {
    _singleTapTimer?.cancel();
    _singleTapTimer = null;
    _lastTapAtMicros = null;
    _lastTapPosition = null;
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_pointer != null) {
      _tapCandidate = false;
      return;
    }
    // A press inside the double-tap window may become a held double-tap.
    // Cancel the pending single-tap timer so the first tap can never toggle
    // controls mid-hold; double-tap detection itself uses timestamps.
    if (_singleTapTimer != null) {
      _singleTapTimer?.cancel();
      _singleTapTimer = null;
    }
    _pointer = event.pointer;
    _pointerDown = event.localPosition;
    _tapCandidate = true;
    final canStartStripHold = !widget.interactive &&
        (widget.onStripPanHoldStart != null ||
            (widget.longPressZoomEnabled && widget.onStripLensStart != null));
    if (canStartStripHold) {
      final lastAt = _lastTapAtMicros;
      if (lastAt != null) {
        // Only a press that still qualifies as the second half of a
        // double-tap promotes the hold into fixed-offset mode.
        _stripHoldFromDoubleTap =
            widget.clock.nowMicros() - lastAt <= 280000 &&
                (_lastTapPosition == null ||
                    (event.position - _lastTapPosition!).distance <= 48);
      } else {
        _stripHoldFromDoubleTap = false;
      }
      _stripLensCandidate = true;
      _stripLensTimer?.cancel();
      _stripLensTimer = Timer(const Duration(milliseconds: 420), () {
        _stripLensTimer = null;
        if (!_stripLensCandidate ||
            _pointer != event.pointer ||
            _tapCandidate == false) {
          return;
        }
        _lensActive = true;
        if (_stripHoldFromDoubleTap) {
          // The second press of a double-tap held past the threshold: apply
          // the double-tap zoom immediately and enter fixed horizontal-offset
          // mode (release keeps scale and offset).
          _lastTapAtMicros = null;
          _lastTapPosition = null;
          widget.onStripPanHoldStart?.call();
          return;
        }
        if (!widget.longPressZoomEnabled || widget.onStripLensStart == null) {
          return;
        }
        widget.onStripLensStart?.call();
      });
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer) {
      return;
    }
    if (_lensActive) {
      // Strip lens follows raw pointer positions for the whole gesture; the
      // paged lens is owned by the long-press recognizer's move updates.
      if (!widget.interactive) {
        widget.onStripLensMove?.call(event.position);
      }
      return;
    }
    final origin = _pointerDown;
    if (origin == null || (event.localPosition - origin).distance > 12) {
      _tapCandidate = false;
    }
    if (!_tapCandidate) {
      return;
    }
    if (_stripLensCandidate &&
        (event.localPosition - (origin ?? event.localPosition)).distance >
            kTouchSlop) {
      _stripLensCandidate = false;
      _stripLensTimer?.cancel();
      _stripLensTimer = null;
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer == _pointer) {
      if (_lensActive && !widget.interactive) {
        _lensActive = false;
        _lensBaseTranslation = null;
        widget.onStripLensEnd?.call();
      }
      _stripLensCandidate = false;
      _stripLensTimer?.cancel();
      _stripLensTimer = null;
      _clearPointer();
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) {
      return;
    }
    final candidate = _tapCandidate;
    final position = event.localPosition;
    if (_lensActive) {
      // Strip mode ends the lens here; interactive mode lets the long-press
      // recognizer's onLongPressEnd/onLongPressCancel own the settle.
      if (!widget.interactive) {
        _lensActive = false;
        _lensBaseTranslation = null;
        _stripLensCandidate = false;
        _stripLensTimer?.cancel();
        _stripLensTimer = null;
        widget.onStripLensEnd?.call();
      }
      _clearPointer();
      return;
    }
    _stripLensCandidate = false;
    _stripLensTimer?.cancel();
    _stripLensTimer = null;
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
        (event.position - lastPosition).distance <= 48;
    if (isDoubleTap) {
      _singleTapTimer?.cancel();
      _singleTapTimer = null;
      _lastTapAtMicros = null;
      _lastTapPosition = null;
      if (!widget.interactive && widget.onStripDoubleTap != null) {
        final box = context.findRenderObject();
        final global = box is RenderBox
            ? box.localToGlobal(position)
            : position;
        widget.onStripDoubleTap?.call(global);
        return;
      }
      _cycleStages(position);
      return;
    }
    _lastTapAtMicros = nowMicros;
    _lastTapPosition = event.position;
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
    _stripHoldFromDoubleTap = false;
  }

  @override
  Widget build(BuildContext context) {
    final child = SizedBox.expand(child: widget.child);
    if (!widget.interactive) {
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _handlePointerDown,
        onPointerMove: _handlePointerMove,
        onPointerUp: _handlePointerUp,
        onPointerCancel: _handlePointerCancel,
        child: child,
      );
    }
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPressStart: widget.longPressZoomEnabled
            ? _handleLensStart
            : null,
        onLongPressMoveUpdate:
            widget.longPressZoomEnabled ? _handleLensMove : null,
        onLongPressEnd: widget.longPressZoomEnabled ? _handleLensEnd : null,
        onLongPressCancel:
            widget.longPressZoomEnabled ? _finishPagedLens : null,
        // At scale 1 the page content must not install a scale recognizer in
        // the horizontal gesture arena. Remote image widgets otherwise win the
        // drag before PageView can turn it into navigation. Double tap cycles
        // the configured zoom stages; only when zoomed does InteractiveViewer
        // own pan/scale.
        child: _zoomed
            ? InteractiveViewer(
                transformationController: _transformation,
                minScale: 1,
                maxScale: math.max(
                  math.max(widget.zoomStageSecond, widget.zoomStageFirst),
                  widget.longPressZoomScale.isFinite
                      ? widget.longPressZoomScale.clamp(1.1, 8.0).toDouble()
                      : 2.0,
                ),
                panEnabled: true,
                scaleEnabled: true,
                clipBehavior: Clip.hardEdge,
                onInteractionUpdate: (_) {
                  _clampInteractiveTranslation();
                  _publishZoom();
                },
                onInteractionEnd: (_) {
                  _clampInteractiveTranslation();
                  _publishZoom();
                  _reportScale(_scale);
                },
                child: child,
              )
            : child,
      ),
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
    final pageBuilderStartedAtMicros = widget.clock.nowMicros();
    final custom = widget.pageBuilder?.call(
      context,
      widget.asset,
      _reportFirstFrame,
    );
    final pageBuilderMicros =
        widget.clock.nowMicros() - pageBuilderStartedAtMicros;
    if (pageBuilderMicros >= 20000) {
      final asset = widget.asset;
      final revision = widget.demandRevision?.call();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || widget.asset.assetKey != asset.assetKey) return;
        widget.traceSink.record(
          traceEvent(
            clock: widget.clock,
            sessionId: widget.sessionId,
            kind: TraceEventKind.readerObservation,
            identityHash: asset.assetKey,
            revision: revision,
            payload: <String, Object?>{
              'stage': 'page-host-page-builder',
              'pageIndex': asset.index,
              'durationMicros': pageBuilderMicros,
            },
          ),
        );
      });
    }
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
