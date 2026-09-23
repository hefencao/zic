import 'package:domain/domain.dart';
import 'package:flutter/material.dart';

import 'reader_session_settings.dart';
import 'reader_settings_fields.dart';

const readerComicSettingsEnabledKey =
    ValueKey<String>('reader-comic-settings-enabled');
const readerAdaptiveSettingsKey = ValueKey<String>('reader-adaptive-settings');
const readerVerticalStitchKey = ValueKey<String>('reader-vertical-stitch');
const readerLongPressZoomKey = ValueKey<String>('reader-long-press-zoom');

enum _ComicDirectionChoice { follow, ltr, rtl, vertical }

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
                    '启用后可单独覆盖阅读方向、拼接、长按放大与阅读顺序。',
                  ),
                  value: draft.comicSpecificEnabled,
                  onChanged: (value) => setSheetState(
                    () => draft = draft.copyWith(comicSpecificEnabled: value),
                  ),
                ),
                SwitchListTile(
                  key: readerAdaptiveSettingsKey,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('使用自适应设置'),
                  subtitle: Text(
                    _adaptivePolicyDescription(
                      draft,
                      adaptiveProfile: adaptiveProfile,
                    ),
                  ),
                  value: draft.comicAdaptiveEnabled,
                  onChanged: draft.globalAdaptiveEnabled
                      ? (value) => setSheetState(
                            () => draft = draft.copyWith(
                              comicAdaptiveEnabled: value,
                            ),
                          )
                      : null,
                ),
                if (draft.comicSpecificEnabled) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    '阅读方向',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final choice in _ComicDirectionChoice.values)
                        ChoiceChip(
                          key: ValueKey<String>(
                            'reader-comic-direction-${choice.name}',
                          ),
                          label: Text(_directionChoiceLabel(choice)),
                          selected: _directionChoice(draft) == choice,
                          onSelected: (_) => setSheetState(
                            () => draft = _withDirectionChoice(
                              draft,
                              choice,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _directionChoiceDescription(
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
                  readerLongPressZoomOverrideField(
                    key: readerLongPressZoomKey,
                    value: draft.longPressZoomOverride,
                    onChanged: (value) => setSheetState(
                      () => draft = draft.copyWith(
                        longPressZoomOverride: value,
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
      longPressZoomOverride: null,
      invertPageOrderOverride: null,
    );

_ComicDirectionChoice _directionChoice(ReaderSessionSettings settings) {
  final direction = settings.directionOverride;
  if (direction != null) {
    return switch (direction) {
      ReadingDirection.ltr => _ComicDirectionChoice.ltr,
      ReadingDirection.rtl => _ComicDirectionChoice.rtl,
      ReadingDirection.vertical => _ComicDirectionChoice.vertical,
    };
  }
  return _ComicDirectionChoice.follow;
}

ReaderSessionSettings _withDirectionChoice(
  ReaderSessionSettings settings,
  _ComicDirectionChoice choice,
) =>
    switch (choice) {
      _ComicDirectionChoice.follow => settings.copyWith(directionOverride: null),
      _ComicDirectionChoice.ltr => settings.copyWith(
          directionOverride: ReadingDirection.ltr,
        ),
      _ComicDirectionChoice.rtl => settings.copyWith(
          directionOverride: ReadingDirection.rtl,
        ),
      _ComicDirectionChoice.vertical => settings.copyWith(
          directionOverride: ReadingDirection.vertical,
        ),
    };

String _directionChoiceLabel(_ComicDirectionChoice choice) => switch (choice) {
      _ComicDirectionChoice.follow => '跟随',
      _ComicDirectionChoice.ltr => 'LTR',
      _ComicDirectionChoice.rtl => 'RTL',
      _ComicDirectionChoice.vertical => '纵向',
    };

String _directionChoiceDescription(
  ReaderSessionSettings settings, {
  required AdaptiveReaderProfile? adaptiveProfile,
}) {
  final choice = _directionChoice(settings);
  if (choice == _ComicDirectionChoice.follow) {
    if (settings.effectiveAdaptiveEnabled &&
        adaptiveProfile != null &&
        adaptiveProfile.confidence >= AdaptiveReaderProfile.applyConfidence) {
      return '未固定方向；当前自适应可按识别结果选择'
          '${_adaptiveTypeLabel(adaptiveProfile)}阅读方向。';
    }
    return '未固定方向；跟随来源方向或既有阅读进度。';
  }
  return '本漫画固定阅读方向；自适应仍可调整未被手动覆盖的其他行为。';
}

String _adaptivePolicyDescription(
  ReaderSessionSettings settings, {
  required AdaptiveReaderProfile? adaptiveProfile,
}) {
  if (!settings.globalAdaptiveEnabled) {
    return '全局自适应未启用；保留本漫画选择但当前不执行。';
  }
  if (!settings.comicAdaptiveEnabled) {
    return '本漫画不使用自适应结果；各项行为按手动设置或默认值。';
  }
  if (adaptiveProfile == null ||
      adaptiveProfile.confidence < AdaptiveReaderProfile.applyConfidence) {
    return '根据漫画类型与内容共同调整阅读方向、手势等行为；暂无高置信度结果。';
  }
  final confidence = (adaptiveProfile.confidence * 100).round();
  final basis = switch (adaptiveProfile.basis) {
    'animated-pages' => '动画页提示',
    'page-geometry' => '页面比例',
    'decoded-animation' || 'runtime-animation' => '实际动画页',
    _ => adaptiveProfile.basis,
  };
  final longPress = adaptiveProfile.direction == ReadingDirection.vertical
      ? '长按放大默认关闭'
      : '长按放大默认开启';
  return '识别：${_adaptiveTypeLabel(adaptiveProfile)} · $confidence% · '
      '$basis · $longPress';
}

String _adaptiveTypeLabel(AdaptiveReaderProfile profile) => profile.animated
    ? '动图/分页'
    : profile.direction == ReadingDirection.vertical
        ? '条漫/纵向'
        : '页漫/分页';
