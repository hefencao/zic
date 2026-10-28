import 'package:flutter/material.dart';

import 'dialog_actions.dart';
import 'library_data_scope.dart';

String libraryDataLabel(LibraryDataSection section) => switch (section) {
  LibraryDataSection.shelf => '书架与分类',
  LibraryDataSection.history => '阅读记录',
  LibraryDataSection.readingSettings => '阅读设置',
  LibraryDataSection.appSettings => '应用设置',
  LibraryDataSection.translation => '翻译设置',
  LibraryDataSection.extensions => '扩展与插件',
};

String _description(LibraryDataSection section) => switch (section) {
  LibraryDataSection.shelf => '书架漫画、收藏、分类与排序',
  LibraryDataSection.history => '历史、进度、已读状态及恢复所需的章节信息',
  LibraryDataSection.readingSettings => '全局及每漫画阅读设置',
  LibraryDataSection.appSettings => '外观、书架筛选、漫画源、下载策略与访问方式',
  LibraryDataSection.translation => '全局及每漫画翻译设置',
  LibraryDataSection.extensions => '扩展仓库、启用状态与插件选项',
};

final class LibraryDataSelector extends StatelessWidget {
  const LibraryDataSelector({required this.selected, required this.onChanged,
    this.counts, this.enabled = true, super.key});
  final Set<LibraryDataSection> selected;
  final ValueChanged<Set<LibraryDataSection>> onChanged;
  final Map<LibraryDataSection, int>? counts;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
    for (final section in LibraryDataSection.values)
      CheckboxListTile(
        key: ValueKey('library-data-' + section.name),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(libraryDataLabel(section) +
          (counts == null ? '' : ' · ' + (counts![section] ?? 0).toString())),
        subtitle: Text(_description(section)),
        value: selected.contains(section),
        onChanged: !enabled || (counts != null && (counts![section] ?? 0) == 0) ? null : (checked) {
          final next = Set<LibraryDataSection>.of(selected);
          if (checked == true) { next.add(section); } else { next.remove(section); }
          onChanged(next);
        },
      ),
  ]);
}

Future<Set<LibraryDataSection>?> chooseLibraryBackupSections(BuildContext context) {
  var selected = Set<LibraryDataSection>.of(allLibraryDataSections);
  return showDialog<Set<LibraryDataSection>>(context: context, builder: (context) =>
    StatefulBuilder(builder: (context, setState) => AlertDialog(
      title: const Text('导出哪些数据'),
      content: SizedBox(width: 420, child: SingleChildScrollView(child:
        LibraryDataSelector(selected: selected, onChanged: (next) => setState(() => selected = next)))),
      actions: [AppDialogActions(onClose: () => Navigator.pop(context), actions: [
        FilledButton(onPressed: selected.isEmpty ? null : () => Navigator.pop(context, selected),
          child: const Text('导出')),
      ])],
    )));
}
