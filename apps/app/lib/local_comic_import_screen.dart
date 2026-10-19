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
typedef LocalChapterLink = Future<ImportedLibraryEntry> Function(
  ExternalDownloadTree tree, ExternalDownloadComic comic, ExternalDownloadChapter chapter,
  {required void Function() checkCancelled});

enum LocalComicImportMode { copy, direct }

/// Selection/progress only. Catalog publication and durable placement remain
/// in HomeDownloadCommands; byte ownership remains in the download service.
final class LocalComicImportScreen extends StatefulWidget {
  const LocalComicImportScreen({super.key,
    required this.importChapter, required this.linkChapter, required this.stopImports,
    this.directoryPicker = pickDirectory});
  final ExternalChapterImport importChapter;
  final LocalChapterLink linkChapter;
  final Future<void> Function() stopImports;
  final Future<String?> Function() directoryPicker;

  @override
  State<LocalComicImportScreen> createState() => _LocalComicImportScreenState();
}

final class _LocalComicImportScreenState extends State<LocalComicImportScreen> {
  ExternalDownloadTree? _tree;
  ExternalDownloadScan? _scan;
  final Set<String> _selected = {};
  final Map<String, LocalComicImportMode> _modes = {};
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
      final path = await widget.directoryPicker();
      if (!mounted || path == null) return;
      final tree = path.startsWith('saf://')
          ? SafExternalDownloadTree(
              io: SafTreeIoAdapter(SafStore(treeUri: path.substring(6))),
              identity: path, displayName: _safRootName(path),
            )
          : DirectoryExternalDownloadTree(path);
      setState(() { _tree = tree; _scan = null; _selected.clear(); _modes.clear(); _results.clear(); });
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
      _progress = '正在识别漫画格式与章节…'; _results.clear();
    });
    try {
      final scan = await DownloadCommandLifetimes.instance.run((command) =>
        ExternalDownloadScanner().scan(tree,
          checkCancelled: () => _check(command)));
      if (!mounted) return;
      setState(() {
        _scan = scan;
        _selected..clear()..addAll(scan.comics.map((comic) => comic.path));
        _modes.clear();
        _progress = scan.comics.isEmpty ? '没有找到可导入的漫画' : '核对漫画与章节后导入';
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
        // This screen admits one import operation; its private run directory is
        // cleaned only after all transfer/worker futures have physically exited.
        ExternalDownloadImportRun? run;
        try {
          if (comics.any((comic) => !comic.canReadDirectly ||
              _modes[comic.path] != LocalComicImportMode.direct)) {
            final root = await getDefaultZicStorageRoot(applicationSupportPath: getStartupApplicationSupportPath);
            _check(command);
            run = await ExternalDownloadImportRun.open('$root/external_import_staging',
              checkCancelled: () => _check(command));
          }
          for (final comic in comics) {
            for (final chapter in comic.chapters) {
              _check(command);
              PreparedExternalChapter? prepared;
              try {
                setState(() => _progress = '${completed + failed + 1}/$total · ${comic.title} · ${chapter.title}');
                final direct = comic.canReadDirectly &&
                    _modes[comic.path] == LocalComicImportMode.direct;
                if (direct) {
                  await widget.linkChapter(tree, comic, chapter,
                    checkCancelled: () => _check(command));
                } else {
                  prepared = await run!.prepare(
                    tree: tree, comic: comic, chapter: chapter,
                    checkCancelled: () => _check(command),
                  );
                  _check(command);
                  await widget.importChapter(prepared, checkCancelled: () => _check(command));
                }
                _check(command);
                completed++;
                setState(() => _results.add('${comic.title} · ${chapter.title}：'
                  '${direct ? '已添加，直接读取' : '已复制到 ZIC'} · ${chapter.pages.length} 页'));
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
          await run?.dispose();
        }
      });
      if (mounted) setState(() => _progress = '完成 $completed 章，失败 $failed 章');
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _progress = '已导入 $completed 章，失败 $failed 章';
          _error = '$error。已完成的漫画保留，可重新扫描后继续导入。';
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
        appBar: AppBar(title: const Text('导入本地漫画')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('选择目录后自动识别普通图片目录、EHViewer、Mihon / Tachiyomi 和 Venera 下载，预览漫画与章节后导入。'),
          const SizedBox(height: 12),
          const Text('默认复制到 ZIC，原文件保留。普通图片目录可自行选择直接读取；App 下载与 CBZ 使用复制导入。扫描 App 下载前请先停止原 App 的下载；Venera 可附带导出的 local.db 保留章节信息。'),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: _busy ? null : _chooseDirectory,
            icon: const Icon(Icons.folder_open), label: const Text('选择目录')),
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
            for (final comic in scan.comics) _comicPreview(comic),
            FilledButton.icon(onPressed: _busy || _selected.isEmpty ? null : _import,
              icon: const Icon(Icons.file_download_outlined), label: const Text('导入所选漫画')),
          ],
          for (final result in _results) Padding(padding: const EdgeInsets.only(top: 8),
            child: SelectableText(result)),
        ]),
      ),
    );
  }

  Widget _comicPreview(ExternalDownloadComic comic) {
    final mode = _modes[comic.path] ?? LocalComicImportMode.copy;
    return Card(key: ValueKey(comic.path),
      child: Padding(padding: const EdgeInsets.only(bottom: 8), child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CheckboxListTile(
          title: Text(comic.title),
          subtitle: Text('${externalDownloadFormatName(comic.format)} · ${comic.chapters.length} 章 · ${comic.pageCount} 页\n'
            '${comic.path.isEmpty ? _tree!.displayName : comic.path}'),
          value: _selected.contains(comic.path),
          onChanged: _busy ? null : (selected) => setState(() {
            if (selected == true) { _selected.add(comic.path); }
            else { _selected.remove(comic.path); }
          }),
        ),
        if (comic.canReadDirectly) Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SegmentedButton<LocalComicImportMode>(
            segments: const [
              ButtonSegment(value: LocalComicImportMode.copy, label: Text('复制到 ZIC')),
              ButtonSegment(value: LocalComicImportMode.direct, label: Text('直接读取')),
            ],
            selected: {mode},
            onSelectionChanged: _busy ? null : (modes) => setState(() => _modes[comic.path] = modes.single),
          )),
        if (comic.canReadDirectly && mode == LocalComicImportMode.direct)
          const Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text('直接读取依赖原目录和访问权限；移走或删除原文件后将无法阅读。')),
        ExpansionTile(title: const Text('查看章节'), children: [
          for (final chapter in comic.chapters) ListTile(dense: true,
            title: Text(chapter.title),
            subtitle: Text('${chapter.archive ? 'CBZ · ' : ''}${chapter.pages.length} 页'
              '${chapter.warning == null ? '' : '\n${chapter.warning}'}')),
        ]),
      ],
    )));
  }
}

String _safRootName(String path) {
  final uri = Uri.tryParse(path.substring(6));
  if (uri == null || uri.pathSegments.isEmpty) return '所选下载目录';
  final document = uri.pathSegments.last;
  final name = document.split('/').last.split(':').last;
  return name.isEmpty ? '所选下载目录' : name;
}
