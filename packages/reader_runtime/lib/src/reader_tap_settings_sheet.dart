import 'package:domain/domain.dart';
import 'package:flutter/material.dart';

import 'reader_session_settings.dart';
import 'reader_tap_region_overlay.dart';

const readerSingleTapAnimationKey =
    ValueKey<String>('reader-single-tap-page-animation');
const readerSingleTapGridKey =
    ValueKey<String>('reader-single-tap-zone-grid');
const readerSingleTapScreenRetainKey =
    ValueKey<String>('reader-single-tap-screen-retain');

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
                if (mode == ReaderMode.continuous) ...<Widget>[
                  const SizedBox(height: 4),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('翻屏保留比例'),
                    subtitle: Text(
                      '上一屏/下一屏每次滚动 '
                      '${((1 - draft.effectiveSingleTapScreenRetainFraction) * 100).round()}%，'
                      '保留 ${(draft.effectiveSingleTapScreenRetainFraction * 100).round()}% '
                      '作为视觉锚点。',
                    ),
                  ),
                  Slider(
                    key: readerSingleTapScreenRetainKey,
                    min: 0,
                    max: 0.5,
                    divisions: 10,
                    label:
                        '${(draft.effectiveSingleTapScreenRetainFraction * 100).round()}%',
                    value: draft.effectiveSingleTapScreenRetainFraction,
                    onChanged: (value) => setSheetState(
                      () => draft = draft.copyWith(
                        singleTapScreenRetainFraction: value,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  '单击区域',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  '这里的九宫格只用于选择各区域动作；实际区域大小请在 Reader 内打开点击设置，直接在页面覆层上拖动分隔线调整。',
                  style: Theme.of(context).textTheme.bodySmall,
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
                                Icon(
                                  readerGestureActionIcon(candidate),
                                  size: 20,
                                ),
                                const SizedBox(width: 10),
                                Text(readerGestureActionLabel(candidate)),
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
                              Icon(readerGestureActionIcon(action)),
                              const SizedBox(height: 4),
                              Text(
                                _zoneLabel(index),
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                readerGestureActionLabel(action),
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
                          singleTapScreenRetainFraction: 0.10,
                          singleTapZones: readerDefaultGestureZones,
                          singleTapGridLayout:
                              readerDefaultGestureGridLayout,
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
