import 'dart:async';

import 'package:domain/domain.dart';
import 'package:flutter/material.dart';

import 'reader_session_settings.dart';

const readerTapRegionOverlayKey =
    ValueKey<String>('reader-tap-region-overlay');
const readerTapRegionSaveKey =
    ValueKey<String>('reader-tap-region-save');
const readerTapRegionCancelKey =
    ValueKey<String>('reader-tap-region-cancel');
const readerTapRegionResetLayoutKey =
    ValueKey<String>('reader-tap-region-reset-layout');
const readerTapRegionAnimationKey =
    ValueKey<String>('reader-tap-region-animation');

final class ReaderTapRegionOverlay extends StatefulWidget {
  const ReaderTapRegionOverlay({
    required this.mode,
    required this.initialSettings,
    required this.onCancel,
    required this.onSave,
    super.key,
  });

  final ReaderMode mode;
  final ReaderModeSettings initialSettings;
  final VoidCallback onCancel;
  final ValueChanged<ReaderModeSettings> onSave;

  @override
  State<ReaderTapRegionOverlay> createState() =>
      _ReaderTapRegionOverlayState();
}

final class _ReaderTapRegionOverlayState
    extends State<ReaderTapRegionOverlay> {
  late ReaderModeSettings _draft;

  @override
  void initState() {
    super.initState();
    _draft = widget.initialSettings;
  }

  void _moveColumn(int divider, double deltaFraction) {
    setState(() {
      final layout = _draft.singleTapGridLayout;
      final current = divider == 0
          ? layout.firstColumnEnd
          : layout.secondColumnEnd;
      _draft = _draft.copyWith(
        singleTapGridLayout:
            layout.moveColumn(divider, current + deltaFraction),
      );
    });
  }

  void _moveRow(int divider, double deltaFraction) {
    setState(() {
      final layout = _draft.singleTapGridLayout;
      final current =
          divider == 0 ? layout.firstRowEnd : layout.secondRowEnd;
      _draft = _draft.copyWith(
        singleTapGridLayout:
            layout.moveRow(divider, current + deltaFraction),
      );
    });
  }

  Future<void> _chooseAction(int index) async {
    final selected = await showModalBottomSheet<ReaderGestureAction>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final action in ReaderGestureAction.values)
              ListTile(
                leading: Icon(readerGestureActionIcon(action)),
                title: Text(readerGestureActionLabel(action)),
                trailing: _draft.singleTapActionAt(index) == action
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(context, action),
              ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    final zones = List<ReaderGestureAction>.from(
      _draft.singleTapZones.length == 9
          ? _draft.singleTapZones
          : readerDefaultGestureZones,
    );
    zones[index] = selected;
    setState(() {
      _draft = _draft.copyWith(
        singleTapZones: List<ReaderGestureAction>.unmodifiable(zones),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final layout = _draft.singleTapGridLayout;
    return Material(
      key: readerTapRegionOverlayKey,
      color: Colors.transparent,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final height = constraints.maxHeight;
          if (!width.isFinite ||
              !height.isFinite ||
              width <= 0 ||
              height <= 0) {
            return const SizedBox.shrink();
          }
          final xs = <double>[
            0,
            width * layout.firstColumnEnd,
            width * layout.secondColumnEnd,
            width,
          ];
          final ys = <double>[
            0,
            height * layout.firstRowEnd,
            height * layout.secondRowEnd,
            height,
          ];
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              const ColoredBox(color: Color(0x22000000)),
              for (var row = 0; row < 3; row++)
                for (var column = 0; column < 3; column++)
                  _TapRegionCell(
                    index: row * 3 + column,
                    left: xs[column],
                    top: ys[row],
                    width: xs[column + 1] - xs[column],
                    height: ys[row + 1] - ys[row],
                    action: _draft.singleTapActionAt(row * 3 + column),
                    onPressed: (index) => unawaited(_chooseAction(index)),
                  ),
              _VerticalDividerHandle(
                divider: 0,
                x: xs[1],
                height: height,
                onDeltaFraction: (delta) => _moveColumn(0, delta / width),
              ),
              _VerticalDividerHandle(
                divider: 1,
                x: xs[2],
                height: height,
                onDeltaFraction: (delta) => _moveColumn(1, delta / width),
              ),
              _HorizontalDividerHandle(
                divider: 0,
                y: ys[1],
                width: width,
                onDeltaFraction: (delta) => _moveRow(0, delta / height),
              ),
              _HorizontalDividerHandle(
                divider: 1,
                y: ys[2],
                width: width,
                onDeltaFraction: (delta) => _moveRow(1, delta / height),
              ),
              Align(
                alignment: Alignment.topCenter,
                child: SafeArea(
                  bottom: false,
                  child: _EditorToolbar(
                    mode: widget.mode,
                    onCancel: widget.onCancel,
                    onResetLayout: () => setState(
                      () => _draft = _draft.copyWith(
                        singleTapGridLayout:
                            readerDefaultGestureGridLayout,
                      ),
                    ),
                    onSave: () => widget.onSave(_draft),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  top: false,
                  child: _EditorFooter(
                    pageAnimation: _draft.singleTapPageAnimation,
                    onAnimationChanged: (value) => setState(
                      () => _draft = _draft.copyWith(
                        singleTapPageAnimation: value,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

final class _TapRegionCell extends StatelessWidget {
  const _TapRegionCell({
    required this.index,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.action,
    required this.onPressed,
  });

  final int index;
  final double left;
  final double top;
  final double width;
  final double height;
  final ReaderGestureAction action;
  final ValueChanged<int> onPressed;

  @override
  Widget build(BuildContext context) => Positioned(
        left: left,
        top: top,
        width: width,
        height: height,
        child: GestureDetector(
          key: ValueKey<String>('reader-tap-region-cell-$index'),
          behavior: HitTestBehavior.opaque,
          onTap: () => onPressed(index),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.22),
              ),
            ),
            alignment: Alignment.center,
            padding: const EdgeInsets.all(8),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.48),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      readerGestureActionIcon(action),
                      color: Colors.white,
                      size: 20,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        readerGestureActionLabel(action),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

final class _VerticalDividerHandle extends StatelessWidget {
  const _VerticalDividerHandle({
    required this.divider,
    required this.x,
    required this.height,
    required this.onDeltaFraction,
  });

  final int divider;
  final double x;
  final double height;
  final ValueChanged<double> onDeltaFraction;

  @override
  Widget build(BuildContext context) => Positioned(
        key: ValueKey<String>('reader-tap-region-column-$divider'),
        left: x - 18,
        top: 0,
        width: 36,
        height: height,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: (details) =>
              onDeltaFraction(details.delta.dx),
          child: Center(
            child: Container(
              width: 3,
              height: double.infinity,
              color: Colors.white.withValues(alpha: 0.88),
            ),
          ),
        ),
      );
}

final class _HorizontalDividerHandle extends StatelessWidget {
  const _HorizontalDividerHandle({
    required this.divider,
    required this.y,
    required this.width,
    required this.onDeltaFraction,
  });

  final int divider;
  final double y;
  final double width;
  final ValueChanged<double> onDeltaFraction;

  @override
  Widget build(BuildContext context) => Positioned(
        key: ValueKey<String>('reader-tap-region-row-$divider'),
        left: 0,
        top: y - 18,
        width: width,
        height: 36,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onVerticalDragUpdate: (details) =>
              onDeltaFraction(details.delta.dy),
          child: Center(
            child: Container(
              width: double.infinity,
              height: 3,
              color: Colors.white.withValues(alpha: 0.88),
            ),
          ),
        ),
      );
}

final class _EditorToolbar extends StatelessWidget {
  const _EditorToolbar({
    required this.mode,
    required this.onCancel,
    required this.onResetLayout,
    required this.onSave,
  });

  final ReaderMode mode;
  final VoidCallback onCancel;
  final VoidCallback onResetLayout;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.all(10),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: <Widget>[
            IconButton(
              key: readerTapRegionCancelKey,
              tooltip: '取消',
              onPressed: onCancel,
              icon: const Icon(Icons.close, color: Colors.white),
            ),
            Expanded(
              child: Text(
                '${mode == ReaderMode.continuous ? '连续模式' : '分页模式'} · 单击区域',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton(
              key: readerTapRegionResetLayoutKey,
              onPressed: onResetLayout,
              child: const Text('重置布局'),
            ),
            IconButton(
              key: readerTapRegionSaveKey,
              tooltip: '保存',
              onPressed: onSave,
              icon: const Icon(Icons.check, color: Colors.white),
            ),
          ],
        ),
      );
}

final class _EditorFooter extends StatelessWidget {
  const _EditorFooter({
    required this.pageAnimation,
    required this.onAnimationChanged,
  });

  final bool pageAnimation;
  final ValueChanged<bool> onAnimationChanged;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.all(10),
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: <Widget>[
            const Expanded(
              child: Text(
                '点区域修改动作；拖动白线调整实际命中范围',
                maxLines: 2,
                style: TextStyle(color: Colors.white),
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              '切页动画',
              style: TextStyle(color: Colors.white),
            ),
            Switch(
              key: readerTapRegionAnimationKey,
              value: pageAnimation,
              onChanged: onAnimationChanged,
            ),
          ],
        ),
      );
}

String readerGestureActionLabel(ReaderGestureAction action) => switch (action) {
      ReaderGestureAction.defaultBehavior => '默认行为',
      ReaderGestureAction.previousPage => '上一页',
      ReaderGestureAction.nextPage => '下一页',
      ReaderGestureAction.previousChapter => '上一章',
      ReaderGestureAction.nextChapter => '下一章',
    };

IconData readerGestureActionIcon(ReaderGestureAction action) => switch (action) {
      ReaderGestureAction.defaultBehavior => Icons.touch_app_outlined,
      ReaderGestureAction.previousPage => Icons.navigate_before,
      ReaderGestureAction.nextPage => Icons.navigate_next,
      ReaderGestureAction.previousChapter => Icons.skip_previous_outlined,
      ReaderGestureAction.nextChapter => Icons.skip_next_outlined,
    };
