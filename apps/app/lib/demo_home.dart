import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:flutter/material.dart';

import 'static_demo.dart';
import 'webp_demo.dart';

const staticDemoEntryKey = ValueKey<String>('demo-entry-static');
const mediaPipelineReaderEntryKey =
    ValueKey<String>('demo-entry-media-pipeline-reader');
const bundledWebpEntryKey = ValueKey<String>('demo-entry-bundled-webp');
const localWebpImportKey = ValueKey<String>('demo-entry-local-webp');
const localImageFolderImportKey =
    ValueKey<String>('demo-entry-local-image-folder');
@Deprecated('Use localImageFolderImportKey')
const localWebpFolderImportKey = localImageFolderImportKey;
const localWebpPickerProgressKey =
    ValueKey<String>('local-webp-picker-progress');
const localImageFolderPickerProgressKey =
    ValueKey<String>('local-image-folder-picker-progress');
const importedLibrarySectionKey = ValueKey<String>('imported-library-section');
const importedLibraryLoadingKey = ValueKey<String>('imported-library-loading');
const importedLibraryErrorKey = ValueKey<String>('imported-library-error');
Key importedChapterEntryKey(String chapterId) =>
    ValueKey<String>('imported-chapter:$chapterId');
Key importedChapterRefreshKey(String chapterId) =>
    ValueKey<String>('refresh-imported-chapter:$chapterId');
Key importedChapterRefreshProgressKey(String chapterId) =>
    ValueKey<String>('refreshing-imported-chapter:$chapterId');
Key importedChapterRemoveKey(String chapterId) =>
    ValueKey<String>('remove-imported-chapter:$chapterId');
@Deprecated('Use localImageFolderPickerProgressKey')
const localWebpFolderPickerProgressKey = localImageFolderPickerProgressKey;

final class DemoHome extends StatefulWidget {
  const DemoHome({
    required this.picker,
    required this.folderPicker,
    this.folderRefresher = defaultImageFolderRefresher,
    this.libraryStore,
    super.key,
  });

  final WebpPicker picker;
  final ImageFolderPicker folderPicker;
  final ImageFolderRefresher folderRefresher;
  final ImportedLibraryStore? libraryStore;

  @override
  State<DemoHome> createState() => _DemoHomeState();
}

final class _DemoHomeState extends State<DemoHome> {
  late final ImportedLibraryStore _library;
  late final bool _ownsLibrary;
  late final Future<void> _libraryReady;
  List<ImportedLibraryEntry> _libraryEntries = const <ImportedLibraryEntry>[];
  Object? _libraryError;
  bool _libraryLoading = true;
  bool _picking = false;
  bool _pickingFolder = false;
  final Set<String> _refreshingChapters = <String>{};

  @override
  void initState() {
    super.initState();
    _ownsLibrary = widget.libraryStore == null;
    _library = widget.libraryStore ?? MemoryImportedLibraryStore();
    _libraryReady = _initializeLibrary();
  }

  Future<void> _initializeLibrary() async {
    try {
      await _library.open();
      await _reloadLibrary(waitForOpen: false);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _libraryError = error;
          _libraryLoading = false;
        });
      }
    }
  }

  Future<void> _reloadLibrary({bool waitForOpen = true}) async {
    if (waitForOpen) {
      await _libraryReady;
    }
    final entries = await _library.list();
    if (!mounted) {
      return;
    }
    setState(() {
      _libraryEntries = entries;
      _libraryError = null;
      _libraryLoading = false;
    });
  }

  Future<void> _ensureLibraryReady() async {
    await _libraryReady;
    if (_libraryError == null) {
      return;
    }
    await _library.open();
    await _reloadLibrary(waitForOpen: false);
  }

  Future<void> _retryLibrary() async {
    if (mounted) {
      setState(() => _libraryLoading = true);
    }
    try {
      await _library.open();
      await _reloadLibrary(waitForOpen: false);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _libraryError = error;
          _libraryLoading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    if (_ownsLibrary) {
      unawaited(_library.close());
    }
    super.dispose();
  }

  Future<void> _importWebp() async {
    if (_picking || _pickingFolder) {
      return;
    }
    setState(() => _picking = true);
    try {
      final PickedWebp? picked = await widget.picker();
      if (!mounted || picked == null) {
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => WebpPlayerScreen.picked(picked),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入 WebP 失败：$error')),
      );
    } finally {
      if (mounted) {
        setState(() => _picking = false);
      }
    }
  }

  Future<void> _importImageFolder() async {
    if (_picking || _pickingFolder) {
      return;
    }
    setState(() => _pickingFolder = true);
    try {
      final PickedImageFolder? folder = await widget.folderPicker();
      if (!mounted || folder == null) {
        return;
      }
      await _ensureLibraryReady();
      final record = imageFolderChapterRecord(folder);
      await _library.upsertChapter(record);
      final entry = await _library.get(record.chapterId);
      if (!mounted) {
        return;
      }
      await _reloadLibrary();
      if (!mounted) {
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ImageFolderScreen(
            folder: folder,
            initialProgress: entry?.progress,
            onProgressChanged: _library.saveProgress,
          ),
        ),
      );
      if (mounted) {
        await _reloadLibrary();
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入图片文件夹失败：$error')),
      );
    } finally {
      if (mounted) {
        setState(() => _pickingFolder = false);
      }
    }
  }

  Future<void> _openImportedChapter(ImportedLibraryEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ImportedImageChapterScreen(
          record: entry.chapter,
          initialProgress: entry.progress,
          onProgressChanged: _library.saveProgress,
        ),
      ),
    );
    if (mounted) {
      await _reloadLibrary();
    }
  }

  Future<void> _refreshImportedChapter(ImportedLibraryEntry entry) async {
    final chapterId = entry.chapter.chapterId;
    if (_refreshingChapters.contains(chapterId)) {
      return;
    }
    setState(() => _refreshingChapters.add(chapterId));
    try {
      await _ensureLibraryReady();
      final folder = await widget.folderRefresher(entry.chapter);
      final refreshed = imageFolderChapterRecord(
        folder,
        readingDirection: entry.chapter.readingDirection,
        importedAt: entry.chapter.importedAt,
      );
      if (refreshed.chapterId != chapterId) {
        throw StateError('刷新结果改变了目录章节 identity');
      }
      final previousSources = entry.chapter.pages
          .map((page) => page.sourceId)
          .toSet();
      final refreshedSources = refreshed.pages
          .map((page) => page.sourceId)
          .toSet();
      final added = refreshedSources.difference(previousSources).length;
      final removed = previousSources.difference(refreshedSources).length;
      await _library.upsertChapter(refreshed);
      await _reloadLibrary();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '目录已刷新：${refreshed.pages.length} 页'
            '（新增 $added，移除 $removed）',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('刷新图片文件夹失败：$error')),
      );
    } finally {
      if (mounted) {
        setState(() => _refreshingChapters.remove(chapterId));
      }
    }
  }

  Future<void> _removeImportedChapter(ImportedLibraryEntry entry) async {
    await _ensureLibraryReady();
    await _library.removeChapter(entry.chapter.chapterId);
    if (mounted) {
      await _reloadLibrary();
    }
  }

  Widget _buildImportedLibrary(BuildContext context) {
    if (_libraryLoading) {
      return const Center(
        key: importedLibraryLoadingKey,
        child: Padding(
          padding: EdgeInsets.all(16),
          child: CircularProgressIndicator(),
        ),
      );
    }
    final error = _libraryError;
    if (error != null) {
      return ListTile(
        key: importedLibraryErrorKey,
        leading: const Icon(Icons.error_outline),
        title: const Text('本地目录库加载失败'),
        subtitle: Text('$error'),
        trailing: IconButton(
          tooltip: '重试',
          onPressed: _retryLibrary,
          icon: const Icon(Icons.refresh),
        ),
      );
    }
    if (_libraryEntries.isEmpty) {
      return const ListTile(
        leading: Icon(Icons.library_books_outlined),
        title: Text('尚未导入本地章节'),
        subtitle: Text('导入图片文件夹后会保留章节记录和最后阅读页。'),
      );
    }
    return Column(
      children: <Widget>[
        for (final entry in _libraryEntries)
          ListTile(
            key: importedChapterEntryKey(entry.chapter.chapterId),
            leading: const Icon(Icons.collections_bookmark_outlined),
            title: Text(entry.chapter.displayName),
            subtitle: Text(
              entry.progress == null
                  ? '${entry.chapter.pages.length} 页 · 未开始'
                  : '${entry.chapter.pages.length} 页 · '
                      '上次第 ${entry.progress!.pageIndex + 1} 页',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (_refreshingChapters.contains(entry.chapter.chapterId))
                  SizedBox.square(
                    key: importedChapterRefreshProgressKey(
                      entry.chapter.chapterId,
                    ),
                    dimension: 24,
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    key: importedChapterRefreshKey(entry.chapter.chapterId),
                    tooltip: '重新扫描目录',
                    onPressed: () => _refreshImportedChapter(entry),
                    icon: const Icon(Icons.refresh),
                  ),
                IconButton(
                  key: importedChapterRemoveKey(entry.chapter.chapterId),
                  tooltip: '移除目录记录',
                  onPressed: _refreshingChapters.contains(
                    entry.chapter.chapterId,
                  )
                      ? null
                      : () => _removeImportedChapter(entry),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            onTap: () => _openImportedChapter(entry),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('zic')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(
            'Reader pipeline demos',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            '静态章节、Animated WebP、本地文件与图片文件夹共用 Reader 入口。',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 24),
          _DemoCard(
            key: staticDemoEntryKey,
            icon: Icons.menu_book,
            title: '100 页静态章节',
            subtitle: 'PageView、阅读方向、viewport observation 与 demand 基线。',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const StaticDemoScreen()),
            ),
          ),
          const SizedBox(height: 12),
          _DemoCard(
            key: mediaPipelineReaderEntryKey,
            icon: Icons.texture,
            title: 'Reader 媒体管线',
            subtitle: 'Reader 页面使用同一媒体管线并固定安全 codec；'
                'native 在独立预览中显式诊断。',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const MediaPipelineReaderScreen(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _DemoCard(
            key: bundledWebpEntryKey,
            icon: Icons.animation,
            title: '内置动图 WebP',
            subtitle: '真实 assets；可切换 native pipeline 与 Flutter codec。',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const WebpCatalogScreen()),
            ),
          ),
          const SizedBox(height: 12),
          _DemoCard(
            key: localWebpImportKey,
            icon: Icons.file_open,
            title: '导入本地 WebP',
            subtitle: '通过系统文件选择器读取本地 .webp；'
                '默认使用 Flutter codec，native 需显式切换。',
            trailing: _picking
                ? const SizedBox.square(
                    key: localWebpPickerProgressKey,
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _picking || _pickingFolder ? null : _importWebp,
          ),
          const SizedBox(height: 12),
          _DemoCard(
            key: localImageFolderImportKey,
            icon: Icons.folder_open,
            title: '导入图片文件夹',
            subtitle: 'Android 使用文档树授权读取；文件头优先识别图片并自然排序。',
            trailing: _pickingFolder
                ? const SizedBox.square(
                    key: localImageFolderPickerProgressKey,
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _picking || _pickingFolder ? null : _importImageFolder,
          ),
          const SizedBox(height: 24),
          Text(
            '本地目录库',
            key: importedLibrarySectionKey,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Card(child: _buildImportedLibrary(context)),
        ],
      ),
    );
  }
}

final class _DemoCard extends StatelessWidget {
  const _DemoCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Icon(icon, size: 36),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: trailing ?? const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
