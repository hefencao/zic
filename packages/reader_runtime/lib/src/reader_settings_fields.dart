import 'package:flutter/material.dart';

enum _ReaderOverrideChoice { inherit, enabled, disabled }

Widget readerVerticalStitchOverrideField({
  required Key key,
  required bool? value,
  required ValueChanged<bool?> onChanged,
}) =>
    _ReaderOverrideChips(
      key: key,
      title: '纵向拼接',
      helperText: '跟随全局设置，或仅为本漫画启用/停用。',
      value: value,
      inheritLabel: '跟随全局',
      enabledLabel: '拼接',
      disabledLabel: '保留间距',
      onChanged: onChanged,
    );

Widget readerLongPressZoomOverrideField({
  required Key key,
  required bool? value,
  required ValueChanged<bool?> onChanged,
}) =>
    _ReaderOverrideChips(
      key: key,
      title: '长按放大',
      helperText: '跟随自适应与阅读模式，或仅为本漫画强制启用/停用。',
      value: value,
      inheritLabel: '自适应/默认',
      enabledLabel: '启用',
      disabledLabel: '停用',
      onChanged: onChanged,
    );

final class _ReaderOverrideChips extends StatelessWidget {
  const _ReaderOverrideChips({
    required this.title,
    required this.helperText,
    required this.value,
    required this.inheritLabel,
    required this.enabledLabel,
    required this.disabledLabel,
    required this.onChanged,
    super.key,
  });

  final String title;
  final String helperText;
  final bool? value;
  final String inheritLabel;
  final String enabledLabel;
  final String disabledLabel;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = switch (value) {
      true => _ReaderOverrideChoice.enabled,
      false => _ReaderOverrideChoice.disabled,
      null => _ReaderOverrideChoice.inherit,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(title, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final choice in _ReaderOverrideChoice.values)
                ChoiceChip(
                  label: Text(
                    switch (choice) {
                      _ReaderOverrideChoice.inherit => inheritLabel,
                      _ReaderOverrideChoice.enabled => enabledLabel,
                      _ReaderOverrideChoice.disabled => disabledLabel,
                    },
                  ),
                  selected: selected == choice,
                  onSelected: (_) => onChanged(
                    switch (choice) {
                      _ReaderOverrideChoice.inherit => null,
                      _ReaderOverrideChoice.enabled => true,
                      _ReaderOverrideChoice.disabled => false,
                    },
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(helperText, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
