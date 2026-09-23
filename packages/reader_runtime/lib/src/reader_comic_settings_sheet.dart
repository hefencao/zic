import 'package:domain/domain.dart';
import 'package:flutter/material.dart';

import 'reader_session_settings.dart';
import 'reader_settings_fields.dart';

const readerComicSettingsEnabledKey =
    ValueKey<String>('reader-comic-settings-enabled');
const readerAdaptiveSettingsKey = ValueKey<String>('reader-adaptive-settings');
const readerVerticalStitchKey = ValueKey<String>('reader-vertical-stitch');
const readerVerticalLongPressZoomKey =
    ValueKey<String>('reader-vertical-long-press-zoom');

enum _ComicLayoutChoice { adaptive, follow, ltr, rtl, vertical }

Future<ReaderSessionSettings?> showReaderComicSettingsSheet(
  BuildContext context, {
  required ReaderSessionSettings initialSettings,
  required AdaptiveReaderProfile? adaptiveProfile,
}) {
  var draft = initialSettings;
  return showModalBottomSheet<ReaderSessionSettings>(
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
                  '本漫画阅读设置',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                SwitchListTile(
                  key: readerComicSettingsEnabledKey,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用本漫画设置'),
                  subtitle: const Text(
                    '启用后可单独选择布局、拼接、纵向缩放与阅读顺序。',
                  ),
                  value: draft.comicSpecificEnabled,
                  onChanged: (value) => setSheetState(
                    () => draft = draft.copyWith(
                      comicSpecificEnabled: value,
                      comicAdaptiveEnabled:
                          value ? draft.comicAdaptiveEnabled : true,
                    ),
                  ),
                ),
                if (draft.comicSpecificEnabled) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    '布局策略',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final choice in _ComicLayoutChoice.values)
                        ChoiceChip(
                          key: choice == _ComicLayoutChoice.adaptive
                              ? readerAdaptiveSettingsKey
                              : ValueKey<String>(
                                  'reader-comic-layout-${choice.name}',
                                ),
                          label: Text(_layoutChoiceLabel(choice)),
                          selected: _layoutChoice(draft) == choice,
                          onSelected: choice == _ComicLayoutChoice.adaptive &&
                                  !draft.globalAdaptiveEnabled
                              ? null
                              : (_) => setSheetState(
                                    () => draft = _withLayoutChoice(
                                      draft,
                                      choice,
                                    ),
                                  ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _layoutChoiceDescription(
                      draft,
                      adaptiveProfile: adaptiveProfile,
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  readerVerticalStitchOverrideField(
                    key: readerVerticalStitchKey,
                    value: draft.verticalStitchOverride,
                    onChanged: (value) => setSheetState(
                      () => draft = draft.copyWith(
                        verticalStitchOverride: value,
                      ),
                    ),
                  ),
                  readerVerticalLongPressZoomField(
                    key: readerVerticalLongPressZoomKey,
                    value: draft.verticalLongPressZoomOverride,
                    onChanged: (value) => setSheetState(
                      () => draft = draft.copyWith(
                        verticalLongPressZoomOverride: value,
                      ),
                    ),
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('翻转阅读顺序'),
                    subtitle: const Text('由旧到新正序阅读（末页作为第一话）'),
                    value: draft.effectiveInvertPageOrder,
                    onChanged: (value) => setSheetState(
                      () => draft = draft.copyWith(
                        invertPageOrderOverride: value,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.pop(
                        context,
                        _clearComicOverrides(initialSettings),
                      ),
                      child: const Text('清除本漫画设置'),
                    ),
                    const Spacer(),
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

ReaderSessionSettings _clearComicOverrides(ReaderSessionSettings settings) =>
    settings.copyWith(
      comicSpecificEnabled: false,
      directionOverride: null,
      verticalStitchOverride: null,
      comicAdaptiveEnabled: true,
      adaptiveProfile: null,
      verticalLongPressZoomOverride: null,
      invertPageOrderOverride: null,
    );

_ComicLayoutChoice _layoutChoice(ReaderSessionSettings settings) {
  final direction = settings.directionOverride;
  if (direction != null) {
    return switch (direction) {
      ReadingDirection.ltr => _ComicLayoutChoice.ltr,
      ReadingDirection.rtl => _ComicLayoutChoice.rtl,
      ReadingDirection.vertical => _ComicLayoutChoice.vertical,
    };
  }
  // Layout policy is the comic's persisted intent. Global adaptive enablement
  // only controls whether that policy can currently execute; it must not
  // silently turn an Adaptive choice into Follow.
  if (settings.comicAdaptiveEnabled) {
    return _ComicLayoutChoice.adaptive;
  }
  return _ComicLayoutChoice.follow;
}

ReaderSessionSettings _withLayoutChoice(
  ReaderSessionSettings settings,
  _ComicLayoutChoice choice,
) =>
    switch (choice) {
      _ComicLayoutChoice.adaptive => settings.copyWith(
          directionOverride: null,
          comicAdaptiveEnabled: true,
        ),
      _ComicLayoutChoice.follow => settings.copyWith(
          directionOverride: null,
          comicAdaptiveEnabled: false,
        ),
      _ComicLayoutChoice.ltr => settings.copyWith(
          directionOverride: ReadingDirection.ltr,
          comicAdaptiveEnabled: false,
        ),
      _ComicLayoutChoice.rtl => settings.copyWith(
          directionOverride: ReadingDirection.rtl,
          comicAdaptiveEnabled: false,
        ),
      _ComicLayoutChoice.vertical => settings.copyWith(
          directionOverride: ReadingDirection.vertical,
          comicAdaptiveEnabled: false,
        ),
    };

String _layoutChoiceLabel(_ComicLayoutChoice choice) => switch (choice) {
      _ComicLayoutChoice.adaptive => '自适应',
      _ComicLayoutChoice.follow => '跟随',
      _ComicLayoutChoice.ltr => 'LTR',
      _ComicLayoutChoice.rtl => 'RTL',
      _ComicLayoutChoice.vertical => '纵向',
    };

String _layoutChoiceDescription(
  ReaderSessionSettings settings, {
  required AdaptiveReaderProfile? adaptiveProfile,
}) {
  final choice = _layoutChoice(settings);
  if (choice == _ComicLayoutChoice.follow) {
    return '不使用本漫画自适应结果，跟随来源方向或阅读进度。';
  }
  if (choice != _ComicLayoutChoice.adaptive) {
    return '本漫画使用固定阅读方向；自适应结果不参与方向选择。';
  }
  if (!settings.globalAdaptiveEnabled) return '全局自适应未启用';
  if (adaptiveProfile == null) return '暂无高置信度结果';
  final confidence = (adaptiveProfile.confidence * 100).round();
  final kind = adaptiveProfile.animated
      ? '动画分页'
      : switch (adaptiveProfile.direction) {
          ReadingDirection.ltr => 'LTR',
          ReadingDirection.rtl => 'RTL',
          ReadingDirection.vertical => '纵向',
        };
  final basis = switch (adaptiveProfile.basis) {
    'animated-pages' => '动画页提示',
    'page-geometry' => '页面比例',
    'decoded-animation' || 'runtime-animation' => '实际动画页',
    _ => adaptiveProfile.basis,
  };
  return '$kind · $confidence% · $basis';
}
