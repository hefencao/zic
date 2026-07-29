import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chapter_downloads.dart';

const downloadManagerScreenKey = ValueKey<String>('download-manager-screen');
const downloadManagerRefreshKey = ValueKey<String>('download-manager-refresh');

Key downloadManagerTaskKey(String identity) =>
    ValueKey<String>('download-task:$identity');
Key downloadManagerCancelKey(String identity) =>
    ValueKey<String>('download-cancel:$identity');
Key downloadManagerRetryKey(String identity) =>
    ValueKey<String>('download-retry:$identity');
Key downloadManagerDeleteKey(String identity) =>
    ValueKey<String>('download-delete:$identity');
Key downloadManagerCopyErrorKey(String identity) =>
    ValueKey<String>('download-copy-error:$identity');

final class DownloadManagerScreen extends StatefulWidget {
  const DownloadManagerScreen({
    required this.entries,
    required this.downloads,
    super.key,
  });

  final List<ImportedLibraryEntry> entries;
  final ChapterDownloadService downloads;

  @override
  State<DownloadManagerScreen> createState() => _DownloadManagerScreenState();
}

final class _DownloadManagerScreenState extends State<DownloadManagerScreen> {
  final Map<String, ImportedLibraryEntry> _entries =
      <String, ImportedLibraryEntry>{};
  final Map<String, ChapterDownloadSnapshot> _snapshots =
      <String, ChapterDownloadSnapshot>{};
  StreamSubscription<ChapterDownloadSnapshot>? _subscription;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    for (final entry in widget.entries) {
      _entries[_identity(entry)] = entry;
    }
    _subscription = widget.downloads.changes.listen(_acceptSnapshot);
    scheduleMicrotask(_reload);
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  void _acceptSnapshot(ChapterDownloadSnapshot snapshot) {
    if (!mounted) {
      return;
    }
    setState(() => _snapshots[snapshot.identity] = snapshot);
  }

  Future<void> _reload() async {
    if (mounted) {
      setState(() => _loading = true);
    }
    try {
      final snapshots = await Future.wait<ChapterDownloadSnapshot>(
        _entries.values.map(widget.downloads.inspect),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        for (final snapshot in snapshots) {
          _snapshots[snapshot.identity] = snapshot;
        }
      });
    } on Object catch (error) {
      if (mounted) {
        _showError(error);
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  List<ChapterDownloadSnapshot> get _visibleSnapshots {
    final values = _snapshots.values.where((snapshot) {
      return snapshot.phase != ChapterDownloadPhase.idle ||
          snapshot.hasDurableBytes;
    }).toList(growable: false);
    values.sort((left, right) {
      final phase = _phasePriority(left.phase).compareTo(
        _phasePriority(right.phase),
      );
      if (phase != 0) {
        return phase;
      }
      final comic = left.comicId.compareTo(right.comicId);
      if (comic != 0) {
        return comic;
      }
      return left.title.compareTo(right.title);
    });
    return values;
  }

  ImportedLibraryEntry? _entryFor(ChapterDownloadSnapshot snapshot) =>
      _entries[snapshot.identity];

  Future<void> _act(
    ChapterDownloadSnapshot snapshot,
    Future<void> Function(ImportedLibraryEntry entry) action,
  ) async {
    final entry = _entryFor(snapshot);
    if (entry == null) {
      _showError(StateError('下载任务对应的章节记录已不存在'));
      return;
    }
    try {
      await action(entry);
      final next = await widget.downloads.inspect(entry);
      _acceptSnapshot(next);
    } on Object catch (error) {
      if (mounted) {
        _showError(error);
      }
    }
  }

  Future<void> _delete(ChapterDownloadSnapshot snapshot) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除离线章节？'),
        content: Text('将删除“${snapshot.title}”的离线页面，阅读记录不会被删除。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _act(snapshot, widget.downloads.delete);
    }
  }

  void _showError(Object error) {
    final details = error.toString();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(details, maxLines: 3),
        action: SnackBarAction(
          label: '复制',
          onPressed: () => unawaited(
            Clipboard.setData(ClipboardData(text: details)),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshots = _visibleSnapshots;
    return Scaffold(
      key: downloadManagerScreenKey,
      appBar: AppBar(
        title: const Text('下载管理'),
        actions: <Widget>[
          IconButton(
            key: downloadManagerRefreshKey,
            tooltip: '刷新下载状态',
            onPressed: _loading ? null : _reload,
            icon: _loading
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: snapshots.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const <Widget>[
                  SizedBox(height: 160),
                  Icon(Icons.download_done_outlined, size: 48),
                  SizedBox(height: 12),
                  Center(child: Text('暂无下载任务或离线章节')),
                ],
              )
            : ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: snapshots.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) => _DownloadTaskTile(
                  key: downloadManagerTaskKey(snapshots[index].identity),
                  snapshot: snapshots[index],
                  onCancel: () => _act(
                    snapshots[index],
                    widget.downloads.cancel,
                  ),
                  onRetry: () => _act(
                    snapshots[index],
                    widget.downloads.retry,
                  ),
                  onDelete: () => _delete(snapshots[index]),
                ),
              ),
      ),
    );
  }
}

final class _DownloadTaskTile extends StatelessWidget {
  const _DownloadTaskTile({
    required this.snapshot,
    required this.onCancel,
    required this.onRetry,
    required this.onDelete,
    super.key,
  });

  final ChapterDownloadSnapshot snapshot;
  final VoidCallback onCancel;
  final VoidCallback onRetry;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final failure = snapshot.failure;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      snapshot.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      '${snapshot.comicTitle} · ${snapshot.sourceId}'
                      ' · ${_phaseLabel(snapshot.phase)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (snapshot.phase == ChapterDownloadPhase.downloading)
                IconButton(
                  key: downloadManagerCancelKey(snapshot.identity),
                  tooltip: '取消下载',
                  onPressed: onCancel,
                  icon: const Icon(Icons.stop_circle_outlined),
                )
              else if (snapshot.phase == ChapterDownloadPhase.failed ||
                  snapshot.phase == ChapterDownloadPhase.cancelled)
                IconButton(
                  key: downloadManagerRetryKey(snapshot.identity),
                  tooltip: '重试下载',
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                ),
              const SizedBox(width: 12),
              IconButton(
                key: downloadManagerDeleteKey(snapshot.identity),
                tooltip: '删除离线章节',
                color: Theme.of(context).colorScheme.error,
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          if (snapshot.phase != ChapterDownloadPhase.complete) ...<Widget>[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: snapshot.phase == ChapterDownloadPhase.downloading &&
                      snapshot.totalBytes == null &&
                      snapshot.completedPages == 0
                  ? null
                  : snapshot.fraction,
            ),
            const SizedBox(height: 6),
          ] else
            const SizedBox(height: 4),
          Text(
            '${snapshot.completedPages}/${snapshot.totalPages} 页'
            ' · ${_formatBytes(snapshot.receivedBytes)}'
            '${snapshot.totalBytes == null ? '' : ' / ${_formatBytes(snapshot.totalBytes!)}'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (failure != null && failure.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: SelectableText(
                    failure,
                    maxLines: 3,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                IconButton(
                  key: downloadManagerCopyErrorKey(snapshot.identity),
                  tooltip: '复制下载错误',
                  onPressed: () => unawaited(
                    Clipboard.setData(ClipboardData(text: failure)),
                  ),
                  icon: const Icon(Icons.copy_outlined),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

String _identity(ImportedLibraryEntry entry) => chapterDownloadIdentity(
      entry.chapter.sourceId,
      entry.chapter.chapterId,
      entry.chapter.sourceRevision,
    );

int _phasePriority(ChapterDownloadPhase phase) => switch (phase) {
      ChapterDownloadPhase.downloading => 0,
      ChapterDownloadPhase.failed => 1,
      ChapterDownloadPhase.cancelled => 2,
      ChapterDownloadPhase.complete => 3,
      ChapterDownloadPhase.idle => 4,
    };

String _phaseLabel(ChapterDownloadPhase phase) => switch (phase) {
      ChapterDownloadPhase.idle => '未下载',
      ChapterDownloadPhase.downloading => '下载中',
      ChapterDownloadPhase.complete => '已下载',
      ChapterDownloadPhase.failed => '下载失败',
      ChapterDownloadPhase.cancelled => '已取消',
    };

String _formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  final kib = bytes / 1024;
  if (kib < 1024) {
    return '${kib.toStringAsFixed(kib < 10 ? 1 : 0)} KiB';
  }
  final mib = kib / 1024;
  if (mib < 1024) {
    return '${mib.toStringAsFixed(mib < 10 ? 1 : 0)} MiB';
  }
  final gib = mib / 1024;
  return '${gib.toStringAsFixed(gib < 10 ? 1 : 0)} GiB';
}
