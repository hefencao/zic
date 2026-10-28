import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'dialog_actions.dart';
import 'library_backup.dart';
import 'library_data_scope.dart';
import 'library_data_selector.dart';
import 'library_sync.dart';
import 'webdav_sync.dart';
import 'startup_platform.dart';

const dataBackupImportKey = ValueKey<String>('data-backup-import');
const backupChooseFileKey = ValueKey<String>('backup-choose-file');
const backupApplyKey = ValueKey<String>('backup-apply');

final class LibraryBackupImportScreen extends StatefulWidget {
  const LibraryBackupImportScreen({required this.controller, this.selectFile, super.key});
  final WebDavSyncController controller;
  final Future<XFile?> Function()? selectFile;

  @override
  State<LibraryBackupImportScreen> createState() => _LibraryBackupImportScreenState();
}

final class _LibraryBackupImportScreenState extends State<LibraryBackupImportScreen> {
  Map<String, LibrarySyncRecord>? _records;
  String? _name;
  String? _message;
  bool _busy = false;
  bool _applied = false;
  Set<LibraryDataSection> _selected = Set.of(allLibraryDataSections);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_controllerChanged);
  }

  void _controllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    super.dispose();
  }

  Future<void> _choose() async {
    setState(() { _busy = true; _message = null; _records = null; _applied = false; });
    var stage = 'picker';
    try {
      if (widget.selectFile == null) await attachAndroidPlugin('file_selector_android');
      final file = await (widget.selectFile?.call() ?? openFile(acceptedTypeGroups: [
        const XTypeGroup(label: 'ZIC 备份', extensions: ['json', 'gz'],
          mimeTypes: ['application/json', 'application/gzip', 'application/x-gzip'],
          uniformTypeIdentifiers: ['public.json', 'org.gnu.gnu-zip-archive']),
      ]));
      if (file == null) return;
      stage = 'read';
      final records = await readImportedLibraryBackup(file);
      if (mounted) setState(() {
        _name = file.name; _records = records;
        _selected = records.keys.map(libraryDataSection).toSet();
      });
    } on Object catch (error, stack) {
      debugPrint('Backup import $stage failed (${error.runtimeType})\n$stack');
      if (mounted) setState(() => _message = error is LibrarySyncFormatException
        ? error.message : '无法读取备份，请检查文件格式和访问权限');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply() async {
    final records = _records;
    if (records == null || _busy || widget.controller.busy || _selected.isEmpty) return;
    final sections = Set<LibraryDataSection>.of(_selected);
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('导入备份'),
      content: const Text('只合并勾选的数据，相同记录以备份内容为准，保留其他本地记录。'
        '导入只修改本机；下次 WebDAV 同步时会合并这些修改。'),
      actions: [
        AppDialogActions(onClose: () => Navigator.pop(context, false), actions: [
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('导入')),
        ]),
      ],
    ));
    if (confirmed != true || !mounted) return;
    setState(() { _busy = true; _message = null; });
    try {
      await widget.controller.importRecords(records, sections: sections);
      if (mounted) setState(() { _applied = true; _message = widget.controller.message; });
    } on Object {
      if (mounted) setState(() => _message = widget.controller.error ?? '导入失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final counts = <LibraryDataSection, int>{};
    for (final record in _records?.values ?? <LibrarySyncRecord>[]) {
      final section = libraryDataSection(record.key);
      counts[section] = (counts[section] ?? 0) + 1;
    }
    return Scaffold(appBar: AppBar(title: const Text('导入数据备份')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('选择 ZIC 导出的 JSON 或 gzip 压缩备份，预览后导入。'),
        const SizedBox(height: 12),
        const Text('漫画文件、缓存、登录信息、API 密钥和设备目录需在本机配置。'
          '远程章节会按需从漫画源刷新，本地漫画需重新导入对应文件。'),
        const SizedBox(height: 16),
        OutlinedButton.icon(key: backupChooseFileKey, onPressed: _busy ? null : _choose,
          icon: const Icon(Icons.file_open_outlined), label: const Text('选择备份文件')),
        if (_busy) const LinearProgressIndicator(),
        if (_records != null) ...[
          const SizedBox(height: 16),
          Text(_name ?? ''),
          LibraryDataSelector(selected: _selected, counts: counts,
            enabled: !_busy && !widget.controller.busy,
            onChanged: (next) => setState(() { _selected = next; _applied = false; })),
          if (_records!.isEmpty) const Text('此备份没有可导入的记录'),
          const SizedBox(height: 12),
          FilledButton(key: backupApplyKey,
            onPressed: _busy || widget.controller.busy || _applied || _selected.isEmpty ? null : _apply,
            child: const Text('导入所选数据')),
        ],
        if (_message != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_message!)),
      ]),
    );
  }
}
