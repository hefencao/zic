import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'bubble_boundary.dart';
import 'grouping.dart';
import 'models.dart';
import 'session.dart';

part 'translation_layout.dart';
part 'translation_layout_geometry.dart';
part 'translation_layout_search.dart';
part 'translation_text_layout.dart';

/// Receives already-disambiguated Reader taps; the overlay never owns gestures.
final class ComicTranslationOverlayController {
  final Set<_ComicTranslationOverlayState> _layers = {};

  /// Retains only completed text layout, never image bytes or model leases.
  /// The application clears this bounded reuse tier on background/pressure.
  static void clearRetainedLayouts() => _RetainedTranslationLayouts.clear();

  bool peekSourceAt(Offset globalPosition) {
    for (final layer in _layers) {
      if (layer.peekSourceAt(globalPosition)) return true;
    }
    return false;
  }
}

abstract final class _TranslationLog {
  static void warning(String scope, String message) => debugPrint('$scope: $message');
  static void error(String scope, String message, [StackTrace? stack]) =>
      debugPrint('$scope: $message');
}

class ComicTranslationOverlay extends StatefulWidget {
  final ComicTranslationSession? session;
  final ComicTranslationPageIdentity identity;
  final ComicTranslationOverlayController? controller;
  final ValueChanged<Map<String, Object?>>? onDiagnostic;
  final BoxFit fit;
  int get pageIndex => identity.pageIndex;
  final Alignment alignment;
  final Widget child;

  const ComicTranslationOverlay({
    required this.session,
    required this.identity,
    this.controller,
    this.onDiagnostic,
    this.fit = BoxFit.contain,
    super.key,
    required this.child,
    this.alignment = Alignment.center,
  });

  @override
  State<ComicTranslationOverlay> createState() =>
      _ComicTranslationOverlayState();
}

class _ComicTranslationOverlayState extends State<ComicTranslationOverlay> {
  static const _sourcePeekDuration = Duration(milliseconds: 1500);
  Timer? _sourcePeekTimer;
  String? _hiddenBlockKey;
  _ComicTranslationPainter? _painter;
  _ComicTranslationPainter? _displayPainter;
  Uint8List? _cleanOverlayBytes;
  bool _cleanOverlayReady = false;
  bool _cleanOverlayOpaque = false;
  int _layoutGeneration = 0;
  bool _layoutScheduled = false;
  _ComicTranslationPainter? _layoutTaskPainter;
  Size? _layoutTaskSize;

  void _cancelLayoutPreparation() {
    if (!_layoutScheduled) return;
    _layoutGeneration++;
    _layoutScheduled = false;
    _layoutTaskPainter = null;
    _layoutTaskSize = null;
  }

  void _scheduleLayoutPreparation(_ComicTranslationPainter painter, Size size, {required bool retained}) {
    if (_layoutScheduled &&
        identical(_layoutTaskPainter?.layoutCache, painter.layoutCache) &&
        _layoutTaskSize == size) {
      return;
    }
    final generation = ++_layoutGeneration;
    _layoutScheduled = true;
    _layoutTaskPainter = painter;
    _layoutTaskSize = size;
    widget.onDiagnostic?.call({
      'stage': 'layout-started', 'contentDigest': painter.artifact.contentDigest,
      'width': size.width, 'height': size.height,
      'fontScale': painter.fontScale, 'bodyFontRatio': painter.bodyFontRatio,
      'retained': retained,
    });
    void scheduleNext() {
      unawaited(
        SchedulerBinding.instance.scheduleTask<void>(() {
          if (!mounted || generation != _layoutGeneration) return;
          late final bool completed;
          try {
            var done = false;
            final prepared = painter.layoutCache.prepared.length;
            final budget = Stopwatch()..start();
            // Amortize idle-task scheduling without occupying a whole frame.
            // Publish each completed balloon before continuing the next one.
            do {
              done = painter.prepareNext(size);
            } while (!done && budget.elapsedMicroseconds < 1500 &&
                painter.layoutCache.prepared.length == prepared);
            completed = done;
          } catch (error, stack) {
            if (mounted && generation == _layoutGeneration) {
              _layoutScheduled = false;
              _layoutTaskPainter = null;
              _layoutTaskSize = null;
            }
            _TranslationLog.error(
              'Translation.Overlay',
              'prepare failed page=${widget.pageIndex} '
                  'digest=${painter.artifact.contentDigest.substring(0, 10)} '
                  'prepared=${painter.layoutCache.prepared.length}: $error',
              stack,
            );
            rethrow;
          }
          if (!mounted || generation != _layoutGeneration) return;
          _layoutScheduled = !completed;
          if (completed) {
            _RetainedTranslationLayouts.remember(painter, size);
            widget.onDiagnostic?.call({'stage': 'layout-ready',
              'contentDigest': painter.artifact.contentDigest,
              'blocks': painter.describePreparedBlocks()});
            setState(() {});
          }
          if (!completed) scheduleNext();
        }, Priority.idle),
      );
    }

    scheduleNext();
  }

  void _markCleanOverlayReady(Uint8List bytes) {
    if (_cleanOverlayReady || !identical(_cleanOverlayBytes, bytes)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _cleanOverlayReady ||
          !identical(_cleanOverlayBytes, bytes)) {
        return;
      }
      setState(() => _cleanOverlayReady = true);
    });
  }

  void _peekSource(String blockKey) {
    _sourcePeekTimer?.cancel();
    setState(() => _hiddenBlockKey = blockKey);
    widget.onDiagnostic?.call({'stage': 'source-peek', 'active': true});
    _sourcePeekTimer = Timer(_sourcePeekDuration, () {
      if (mounted) {
        setState(() => _hiddenBlockKey = null);
        widget.onDiagnostic?.call({'stage': 'source-peek', 'active': false});
      }
    });
  }

  bool peekSourceAt(Offset globalPosition) {
    final painter = _displayPainter;
    final box = context.findRenderObject();
    if (painter == null || box is! RenderBox || !box.attached) return false;
    final position = box.globalToLocal(globalPosition);
    if (!(Offset.zero & box.size).contains(position)) return false;
    final blockKey = painter.blockAt(position);
    if (blockKey == null) return false;
    _peekSource(blockKey);
    return true;
  }

  @override
  void initState() {
    super.initState();
    widget.controller?._layers.add(this);
  }

  @override
  void didUpdateWidget(covariant ComicTranslationOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._layers.remove(this);
      widget.controller?._layers.add(this);
    }
    if (oldWidget.identity.key == widget.identity.key &&
        identical(oldWidget.session, widget.session)) return;
    _sourcePeekTimer?.cancel();
    _hiddenBlockKey = null;
    _painter = null;
    _displayPainter = null;
    _layoutGeneration++;
    _layoutScheduled = false;
    _layoutTaskPainter = null;
    _layoutTaskSize = null;
    _cleanOverlayBytes = null;
    _cleanOverlayReady = false;
    _cleanOverlayOpaque = false;
  }

  @override
  void dispose() {
    _sourcePeekTimer?.cancel();
    _layoutGeneration++;
    widget.controller?._layers.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    if (session == null || !session.enabled) {
      _cancelLayoutPreparation();
      _painter = null;
      _displayPainter = null;
    }
    final identity = widget.identity;
    final pageState = session != null && session.enabled ? session.listenable(identity) : null;
    final fontScaleState = session?.fontScaleListenable;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        if (pageState != null && fontScaleState != null) Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: Listenable.merge([
                  pageState,
                  fontScaleState,
                ]),
                builder: (context, _) {
                  final state = pageState.value;
                  final fontScale = fontScaleState.value;
                  final artifact = state.artifact;
                  if (state.phase != ComicTranslationPhase.ready ||
                      artifact == null) {
                    _cancelLayoutPreparation();
                    _painter = null;
                    _displayPainter = null;
                    return const SizedBox();
                  }
                  final background = Theme.of(context).colorScheme.surface.withValues(
                    alpha: 0.88,
                  );
                  final foreground = Theme.of(context).colorScheme.onSurface;
                  final cleanOverlayPng = state.cleanOverlayPng;
                  if (!identical(_cleanOverlayBytes, cleanOverlayPng)) {
                    _cleanOverlayBytes = cleanOverlayPng;
                    _cleanOverlayReady = false;
                    _cleanOverlayOpaque = false;
                  }
                  final showCleanOverlay =
                      cleanOverlayPng != null &&
                      _cleanOverlayReady &&
                      _hiddenBlockKey == null;
                  final hasCleanOverlay =
                      showCleanOverlay && _cleanOverlayOpaque;
                  final current = _painter;
                  final bodyFontRatio = current?.artifact == artifact
                      ? current!.bodyFontRatio : _pageBodyFontRatio(artifact);
                  final layoutCompatible =
                      current != null &&
                      current.pageIndex == widget.pageIndex &&
                      current.artifact == artifact &&
                      current.alignment == widget.alignment &&
                      current.fit == widget.fit &&
                      current.fontScale == fontScale &&
                      current.bodyFontRatio == bodyFontRatio;
                  var painter =
                      layoutCompatible &&
                          current.background == background &&
                          current.foreground == foreground &&
                          current.hasCleanOverlay == hasCleanOverlay &&
                          current.hiddenBlockKey == _hiddenBlockKey
                      ? current
                      : _ComicTranslationPainter(
                          pageIndex: widget.pageIndex,
                          artifact: artifact,
                          fit: widget.fit,
                          alignment: widget.alignment,
                          background: background,
                          foreground: foreground,
                          fontScale: fontScale,
                          bodyFontRatio: bodyFontRatio,
                          hasCleanOverlay: hasCleanOverlay,
                          hiddenBlockKey: _hiddenBlockKey,
                          layoutCache: layoutCompatible &&
                                  current.background == background &&
                                  current.foreground == foreground
                              ? current.layoutCache
                              : _TranslationLayoutCache(),
                        );
                  _painter = painter;
                  var checkedRetained = false;
                  return LayoutBuilder(
                    builder: (context, constraints) {
                      final size = constraints.biggest;
                      if (!layoutCompatible && !checkedRetained) {
                        checkedRetained = true;
                        final cached = _RetainedTranslationLayouts.find(painter, size);
                        if (cached != null) {
                          painter = painter.withLayoutCache(cached);
                          _painter = painter;
                          widget.onDiagnostic?.call({'stage': 'layout-ready',
                            'contentDigest': artifact.contentDigest, 'reused': true,
                            'blocks': painter.describePreparedBlocks()});
                        }
                      }
                      final prepared = painter.isPreparedFor(size);
                      final previous = _displayPainter;
                      // Already visible balloons also survive when the rest of
                      // this page is still preparing at a font/style update.
                      final displayPainter = !prepared &&
                              previous != null &&
                              previous.artifact == artifact &&
                              previous.fit == painter.fit &&
                              previous.alignment == painter.alignment &&
                              previous.hasPreparedBlocksFor(size)
                          ? previous.withVisibility(hasCleanOverlay: hasCleanOverlay,
                              hiddenBlockKey: _hiddenBlockKey)
                          : painter;
                      _displayPainter = displayPainter;
                      if (!prepared) {
                        _scheduleLayoutPreparation(painter, size,
                          retained: !identical(displayPainter, painter));
                      }
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          if (cleanOverlayPng != null &&
                              _hiddenBlockKey == null)
                            ClipPath(
                              clipper: _TranslationMaskClipper(
                                artifact: artifact,
                                alignment: widget.alignment,
                                fit: widget.fit,
                                layoutCache: displayPainter.layoutCache,
                              ),
                              child: AnimatedOpacity(
                                opacity: showCleanOverlay ? 1 : 0,
                                duration: const Duration(milliseconds: 120),
                                onEnd: () {
                                  if (mounted &&
                                      showCleanOverlay &&
                                      !_cleanOverlayOpaque) {
                                    setState(() => _cleanOverlayOpaque = true);
                                  }
                                },
                                child: Image.memory(
                                  cleanOverlayPng,
                                  fit: widget.fit,
                                  alignment: widget.alignment,
                                  filterQuality: FilterQuality.medium,
                                  frameBuilder: (context, child, frame, _) {
                                    if (frame != null) {
                                      _markCleanOverlayReady(cleanOverlayPng);
                                    }
                                    return child;
                                  },
                                ),
                              ),
                            ),
                          CustomPaint(painter: displayPainter),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TranslationMaskClipper extends CustomClipper<Path> {
  final ComicTranslationArtifact artifact;
  final Alignment alignment;
  final BoxFit fit;
  final _TranslationLayoutCache layoutCache;

  _TranslationMaskClipper({
    required this.artifact,
    required this.alignment,
    required this.layoutCache,
    required this.fit,
  }) : super(reclip: layoutCache.repaint);

  @override
  Path getClip(Size size) {
    final fitted = applyBoxFit(
      fit,
      Size(artifact.imageWidth.toDouble(), artifact.imageHeight.toDouble()),
      size,
    );
    final imageRect = alignment.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    final path = Path();
    for (final region in artifact.regions) {
      if (region.translatedText.trim().isEmpty ||
          !layoutCache.preparedRegionIds.contains(region.ocrRegionId)) {
        continue;
      }
      final masks = region.sourceMaskPolygons.isEmpty
          ? [region.polygon]
          : region.sourceMaskPolygons;
      for (final polygon in masks) {
        if (polygon.length < 3) continue;
        path.addPolygon(
          polygon
              .map(
                (point) => Offset(
                  imageRect.left + point.x * imageRect.width,
                  imageRect.top + point.y * imageRect.height,
                ),
              )
              .toList(),
          true,
        );
      }
    }
    return path;
  }

  @override
  bool shouldReclip(_TranslationMaskClipper oldClipper) =>
      oldClipper.artifact != artifact ||
      oldClipper.alignment != alignment ||
      oldClipper.fit != fit ||
      !identical(oldClipper.layoutCache, layoutCache);
}
