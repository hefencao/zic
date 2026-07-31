import 'package:flutter/material.dart';

Widget readerVerticalStitchOverrideField({
  required Key key,
  required bool? value,
  required ValueChanged<bool?> onChanged,
}) =>
    DropdownButtonFormField<String>(
      key: key,
      value: switch (value) {
        true => 'on',
        false => 'off',
        null => 'inherit',
      },
      decoration: const InputDecoration(
        labelText: '纵向拼接',
        helperText: '继承全局设置，或仅为本漫画启用/停用。',
      ),
      items: const <DropdownMenuItem<String>>[
        DropdownMenuItem(value: 'inherit', child: Text('继承全局设置')),
        DropdownMenuItem(value: 'on', child: Text('启用拼接')),
        DropdownMenuItem(value: 'off', child: Text('保留页间距')),
      ],
      onChanged: (next) => onChanged(
        switch (next) {
          'on' => true,
          'off' => false,
          _ => null,
        },
      ),
    );
