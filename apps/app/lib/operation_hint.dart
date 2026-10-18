import 'dart:math' as math;

import 'package:flutter/material.dart';

const operationHintDismissKey = ValueKey<String>('operation-hint-dismiss');
const operationHintArrowKey = ValueKey<String>('operation-hint-arrow');

enum OperationHintResult { dismissed, performed }

enum OperationHintGesture {
  swipeUp, swipeDown, swipeLeft, swipeRight;

  Offset get direction => switch (this) {
    swipeUp => const Offset(0, -1), swipeDown => const Offset(0, 1),
    swipeLeft => const Offset(-1, 0), swipeRight => const Offset(1, 0),
  };

  int get quarterTurns => switch (this) {
    swipeUp => 0, swipeDown => 2, swipeLeft => 3, swipeRight => 1,
  };

  String get actionLabel => switch (this) {
    swipeUp => '向上滑动', swipeDown => '向下滑动',
    swipeLeft => '向左滑动', swipeRight => '向右滑动',
  };
}

/// Presentation only: the caller owns when to show and persist acknowledgement.
Future<OperationHintResult?> showOperationHint({
  required BuildContext context,
  required GlobalKey target,
  required String title,
  required String message,
  required OperationHintGesture gesture,
}) async {
  final box = target.currentContext?.findRenderObject();
  final overlay = Navigator.of(context, rootNavigator: true).overlay?.context.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize ||
      overlay is! RenderBox || !overlay.hasSize || box.size.isEmpty) {
    return null;
  }
  final rect = overlay.globalToLocal(box.localToGlobal(Offset.zero)) & box.size;
  return await showGeneralDialog<OperationHintResult>(
    context: context,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (context, _, _) => _OperationHint(
      target: rect, title: title, message: message, gesture: gesture),
  ) ?? OperationHintResult.dismissed;
}

final class _OperationHint extends StatefulWidget {
  const _OperationHint({required this.target, required this.title,
    required this.message, required this.gesture});

  final Rect target;
  final String title;
  final String message;
  final OperationHintGesture gesture;

  @override
  State<_OperationHint> createState() => _OperationHintState();
}

final class _OperationHintState extends State<_OperationHint> with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this, duration: const Duration(milliseconds: 1200));
  Offset _drag = Offset.zero;
  bool _startedAtTarget = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _motion.stop();
      _motion.value = .5;
    } else if (!_motion.isAnimating) {
      _motion.repeat();
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final direction = widget.gesture.direction;
    final padding = MediaQuery.paddingOf(context);
    return Material(type: MaterialType.transparency, child: LayoutBuilder(
      builder: (context, constraints) {
        final intersection = widget.target.intersect(Offset.zero & constraints.biggest);
        final target = intersection.isEmpty ? Rect.zero : intersection;
        final availableHeight = math.max(0.0, constraints.maxHeight - padding.vertical - 32);
        final cardHeight = math.min(availableHeight,
          target.isEmpty ? availableHeight : math.max(100.0, target.top - padding.top - 64));
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) {
            _drag = Offset.zero;
            _startedAtTarget = !target.isEmpty && target.inflate(16).contains(details.localPosition);
          },
          onPanUpdate: (details) => _drag += details.delta,
          onPanEnd: (_) {
            final distance = _drag.dx * direction.dx + _drag.dy * direction.dy;
            final cross = (_drag.dx * direction.dy - _drag.dy * direction.dx).abs();
            if (_startedAtTarget && distance >= 32 && distance > cross) {
              Navigator.of(context).pop(OperationHintResult.performed);
            }
          },
          child: Stack(fit: StackFit.expand, children: [
            Positioned.fill(child: CustomPaint(painter: _HintScrim(target))),
            if (!target.isEmpty)
              Positioned.fromRect(rect: target, child: Semantics(
                label: widget.gesture.actionLabel, button: true,
                onTap: () => Navigator.of(context).pop(OperationHintResult.performed),
                child: const SizedBox.expand())),
            Positioned(left: 24, right: 24, top: padding.top + 16,
              height: cardHeight,
              child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 360),
                child: Material(color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(20), clipBehavior: Clip.antiAlias,
                  child: Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Flexible(child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 12),
                        Text(widget.message, textAlign: TextAlign.center),
                      ]))),
                      const SizedBox(height: 8),
                      TextButton(key: operationHintDismissKey,
                        onPressed: () => Navigator.of(context).pop(OperationHintResult.dismissed),
                        child: const Text('知道了')),
                    ])),
                )))),
            if (!target.isEmpty)
              Positioned(left: target.center.dx - 24, top: target.center.dy - 24,
              child: IgnorePointer(child: ExcludeSemantics(child: AnimatedBuilder(
                animation: _motion,
                builder: (context, _) => Transform.translate(
                  key: operationHintArrowKey,
                  offset: direction * (32 * Curves.easeInOut.transform(_motion.value)),
                  child: Opacity(opacity: 1 - .5 * _motion.value,
                    child: RotatedBox(quarterTurns: widget.gesture.quarterTurns,
                      child: const Icon(Icons.arrow_upward_rounded, size: 48, color: Colors.white))),
                ),
              )))),
          ]),
        );
      },
    ));
  }
}

final class _HintScrim extends CustomPainter {
  const _HintScrim(this.target);
  final Rect target;

  @override
  void paint(Canvas canvas, Size size) {
    final highlight = RRect.fromRectAndRadius(target.isEmpty ? Rect.zero : target.deflate(2),
      const Radius.circular(12));
    final path = Path()..fillType = PathFillType.evenOdd..addRect(Offset.zero & size);
    if (!target.isEmpty) {
      path.addRRect(highlight);
    }
    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: .72));
    if (!target.isEmpty) {
      canvas.drawRRect(highlight, Paint()..color = Colors.white.withValues(alpha: .9)
        ..style = PaintingStyle.stroke..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(_HintScrim oldDelegate) => oldDelegate.target != target;
}
