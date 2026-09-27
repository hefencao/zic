import 'package:domain/domain.dart';
import 'package:flutter/material.dart';

import 'reader_session_settings.dart';

const readerSingleTapAnimationKey =
    ValueKey<String>('reader-single-tap-page-animation');
const readerSingleTapGridKey =
    ValueKey<String>('reader-single-tap-zone-grid');

Future<ReaderModeSettings?> showReaderGestureSettingsSheet(
  BuildContext context, {
  required ReaderMode mode,
  required ReaderModeSettings initialSettings,
}) {
  var draft = initialSettings;
  return showModalBottomSheet<ReaderModeSettings>(
    context: context,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheetState) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              16 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  '${mode == ReaderMode.continuous ? '连续模式' : '分页模式'} · 点击设置',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  '只修改当前阅读模式。九宫格按手势分层；当前仅开放单击，双击与长按继续由现有缩放手势处理，后续可各自增加独立九宫格。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Text(
                  '单击',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 4),
                SwitchListTile(
                  key: readerSingleTapAnimationKey,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('单击切页动画'),
                  subtitle: const Text(
                    '仅作用于单击九宫格的“上一页/下一页”；滑动、拖动和进度条跳转不受影响。',
                  ),
                  value: draft.singleTapPageAnimation,
                  onChanged: (value) => setSheetState(
                    () => draft = draft.copyWith(
                      singleTapPageAnimation: value,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '单击区域',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                GridView.builder(
                  key: readerSingleTapGridKey,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: 9,
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1.25,
                  ),
                  itemBuilder: (context, index) {
                    final action = draft.singleTapActionAt(index);
                    return PopupMenuButton<ReaderGestureAction>(
                      key: ValueKey<String>('reader-tap-zone-$index'),
                      tooltip: _zoneLabel(index),
                      onSelected: (selected) => setSheetState(() {
                        final zones = List<ReaderGestureAction>.from(
                          draft.singleTapZones.length == 9
                              ? draft.singleTapZones
                              : readerDefaultGestureZones,
                        );
                        zones[index] = selected;
                        draft = draft.copyWith(
                          singleTapZones:
                              List<ReaderGestureAction>.unmodifiable(zones),
                        );
                      }),
                      itemBuilder: (_) => <PopupMenuEntry<ReaderGestureAction>>[
                        for (final candidate in ReaderGestureAction.values)
                          PopupMenuItem<ReaderGestureAction>(
                            value: candidate,
                            child: Row(
                              children: <Widget>[
                                Icon(_gestureActionIcon(candidate), size: 20),
                                const SizedBox(width: 10),
                                Text(_gestureActionLabel(candidate)),
                              ],
                            ),
                          ),
                      ],
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Theme.of(context)
                                .colorScheme
                                .outlineVariant,
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: <Widget>[
                              Icon(_gestureActionIcon(action)),
                              const SizedBox(height: 4),
                              Text(
                                _zoneLabel(index),
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _gestureActionLabel(action),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  '章节动作是显式命令，不受“连续阅读”边界手势开关影响；没有相邻章节时保持当前章节。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    TextButton(
                      onPressed: () => setSheetState(
                        () => draft = draft.copyWith(
                          singleTapPageAnimation: true,
                          singleTapZones: readerDefaultGestureZones,
                        ),
                      ),
                      child: const Text('恢复默认'),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, draft),
                      child: const Text('保存'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

String _zoneLabel(int index) => const <String>[
      '左上',
      '上',
      '右上',
      '左',
      '中',
      '右',
      '左下',
      '下',
      '右下',
    ][index];

String _gestureActionLabel(ReaderGestureAction action) => switch (action) {
      ReaderGestureAction.defaultBehavior => '默认行为',
      ReaderGestureAction.previousPage => '上一页',
      ReaderGestureAction.nextPage => '下一页',
      ReaderGestureAction.previousChapter => '上一章',
      ReaderGestureAction.nextChapter => '下一章',
    };

IconData _gestureActionIcon(ReaderGestureAction action) => switch (action) {
      ReaderGestureAction.defaultBehavior => Icons.touch_app_outlined,
      ReaderGestureAction.previousPage => Icons.navigate_before,
      ReaderGestureAction.nextPage => Icons.navigate_next,
      ReaderGestureAction.previousChapter => Icons.skip_previous_outlined,
      ReaderGestureAction.nextChapter => Icons.skip_next_outlined,
    };
