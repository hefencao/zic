import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/material.dart';
import 'package:storage_bridge/storage_bridge.dart';

import 'directory_picker.dart';
import 'download_command_lifetimes.dart';
import 'saf_store.dart';
import 'saf_tree_io.dart';
import 'startup_platform.dart';

typedef ExternalChapterImport = Future<ImportedLibraryEntry> Function(
  PreparedExternalChapter prepared, {required void Function() checkCancelled});

/// Selection/progress only. Catalog publication and durable placement remain
/// in HomeDownloadCommands; byte ownership remains in the download service.
final class ExternalDownloadImportScreen extends StatefulWidget {
  const ExternalDownloadImportScreen({super.key,
    required this.importChapter, required this.stopImports});
  final ExternalChapterImport importChapter;
  final Future<void> Function() stopImports;

  @override
  State<ExternalDownloadImportScreen> createState() => _ExternalDownloadImportScreenState();
}

final class _ExternalDownloadImportScreenState extends State<ExternalDownloadImportScreen> {
  ExternalDownloadFormat _format = ExternalDownloadFormat.auto;
  ExternalDownloadTree? _tree;
  ExternalDownloadScan? _scan;
  final Set<String> _selected = {};
  bool _busy = false;
  bool _stopped = false;
  String _progress = '';
  final List<String> _results = [];
  String? _error;

  void _check(DownloadCommandLifetime command) {
    command.check();
    if (_stopped || !mounted) {
      throw const Failure(code: ErrorCode.cancelled, message: '导入已停止');
    }
  }

  Future<void> _stop() async {
    setState(() { _stopped = true; _progress = '正在停止，等待当前文件处理结束…'; });
    await widget.stopImports();
  }

  Future<void> _chooseDirectory() async {
    setState(() { _busy = true; _error = null; });
    try {
      final path = await pickDirectory();
      if (!mounted || path == null) return;
      final tree = path.startsWith('saf://')
          ? SafExternalDownloadTree(
              io: SafTreeIoAdapter(SafStore(treeUri: path.substring(6))),
              identity: path, displayName: _safRootName(path),
            )
          : DirectoryExternalDownloadTree(path);
      setState(() { _tree = tree; _scan = null; _selected.clear(); _results.clear(); });
    } on Object catch (error) {
      if (mounted) setState(() => _error = '选择目录失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _tree != null) await _scanDirectory();
  }

  Future<void> _scanDirectory() async {
    final tree = _tree;
    if (tree == null || _busy) return;
    setState(() {
      _busy = true; _stopped = false; _error = null; _scan = null;
      _progress = '正在扫描下载目录与文件清单…'; _results.clear();
    });
    try {
      final scan = await DownloadCommandLifetimes.instance.run((command) =>
        ExternalDownloadScanner().scan(tree, format: _format,
          checkCancelled: () => _check(command)));
      if (!mounted) return;
      setState(() {
        _scan = scan;
        _selected..clear()..addAll(scan.comics.map((comic) => comic.path));
        _progress = scan.comics.isEmpty ? '没有找到可导入的下载内容' : '请选择要复制到 ZIC 的漫画';
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = '扫描未完成：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final tree = _tree;
    final comics = _scan?.comics.where((comic) => _selected.contains(comic.path)).toList();
    if (tree == null || comics == null || comics.isEmpty || _busy) return;
    setState(() { _busy = true; _stopped = false; _error = null; _results.clear(); });
    var completed = 0;
    var failed = 0;
    final total = comics.fold(0, (sum, comic) => sum + comic.chapters.length);
    try {
      await DownloadCommandLifetimes.instance.run((command) async {
        final root = await getDefaultZicStorageRoot(applicationSupportPath: getStartupApplicationSupportPath);
        _check(command);
        // This screen admits one import operation; its private run directory is
        // cleaned only after all transfer/worker futures have physically exited.
        final run = await ExternalDownloadImportRun.open('$root/external_import_staging',
          checkCancelled: () => _check(command));
        try {
          for (final comic in comics) {
            for (final chapter in comic.chapters) {
              _check(command);
              PreparedExternalChapter? prepared;
              try {
                setState(() => _progress = '${completed + failed + 1}/$total · ${comic.title} · ${chapter.title}');
                prepared = await run.prepare(
                  tree: tree, comic: comic, chapter: chapter,
                  checkCancelled: () => _check(command),
                );
                _check(command);
                await widget.importChapter(prepared, checkCancelled: () => _check(command));
                _check(command);
                completed++;
                setState(() => _results.add('${comic.title} · ${chapter.title}：已导入 ${chapter.pages.length} 页'));
              } on Object catch (error) {
                _check(command);
                failed++;
                setState(() => _results.add('${comic.title} · ${chapter.title}：失败，$error'));
              } finally {
                await prepared?.dispose();
              }
            }
          }
        } finally {
          await run.dispose();
        }
      });
      if (mounted) setState(() => _progress = '完成 $completed 章，失败 $failed 章');
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _progress = '已导入 $completed 章，失败 $failed 章';
          _error = '$error。已完成的副本保留，可重新扫描后继续导入。';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scan = _scan;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('导入其他 App 下载')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('将 EHViewer、Mihon 或 Venera 的下载复制到 ZIC，原文件保留。导入后可离线阅读；同名漫画会使用独立目录。'),
          const SizedBox(height: 12),
          DropdownButtonFormField<ExternalDownloadFormat>(
            initialValue: _format,
            decoration: const InputDecoration(labelText: '原 App 格式'),
            items: [for (final format in ExternalDownloadFormat.values)
              DropdownMenuItem(value: format, child: Text(externalDownloadFormatName(format)))],
            onChanged: _busy ? null : (format) => setState(() {
              _format = format!; _scan = null; _selected.clear(); _results.clear();
            }),
          ),
          const SizedBox(height: 12),
          const Text('选择下载根目录或单本漫画目录。Mihon 支持图片章节与 CBZ；Venera 可在目录中附带导出的 local.db，以保留章节标题和顺序。请先停止原 App 的下载，再扫描。'),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: _busy ? null : _chooseDirectory,
            icon: const Icon(Icons.folder_open), label: const Text('选择下载目录')),
          if (_tree != null) ...[
            SelectableText(_tree!.displayName),
            TextButton(onPressed: _busy ? null : _scanDirectory, child: const Text('重新扫描')),
          ],
          if (_busy) const LinearProgressIndicator(),
          if (_progress.isNotEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(_progress)),
          if (_busy) OutlinedButton(onPressed: _stopped ? null : _stop,
            child: const Text('停止导入')),
          if (_error != null) SelectableText(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (scan != null) ...[
            for (final warning in scan.warnings) Padding(padding: const EdgeInsets.only(bottom: 8),
              child: Text(warning)),
            for (final comic in scan.comics) CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(comic.title),
              subtitle: Text('${externalDownloadFormatName(comic.format)} · ${comic.chapters.length} 章 · ${comic.pageCount} 页\n'
                '${comic.path.isEmpty ? _tree!.displayName : comic.path}'
                '${comic.chapters.any((c) => c.warning != null) ? '\n${comic.chapters.where((c) => c.warning != null).map((c) => '${c.title}：${c.warning}').join('\n')}' : ''}'),
              value: _selected.contains(comic.path),
              onChanged: _busy ? null : (selected) => setState(() {
                if (selected == true) { _selected.add(comic.path); }
                else { _selected.remove(comic.path); }
              }),
            ),
            FilledButton.icon(onPressed: _busy || _selected.isEmpty ? null : _import,
              icon: const Icon(Icons.file_download_outlined), label: const Text('复制并导入到 ZIC')),
          ],
          for (final result in _results) Padding(padding: const EdgeInsets.only(top: 8),
            child: SelectableText(result)),
        ]),
      ),
    );
  }
}

String _safRootName(String path) {
  final uri = Uri.tryParse(path.substring(6));
  if (uri == null || uri.pathSegments.isEmpty) return '所选下载目录';
  final document = uri.pathSegments.last;
  final name = document.split('/').last.split(':').last;
  return name.isEmpty ? '所选下载目录' : name;
}
