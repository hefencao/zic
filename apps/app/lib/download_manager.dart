import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chapter_downloads.dart';
import 'whole_comic_downloads.dart';

const downloadManagerScreenKey = ValueKey<String>('download-manager-screen');
const downloadManagerRefreshKey = ValueKey<String>('download-manager-refresh');
const downloadQueuePolicyKey = ValueKey<String>('download-queue-policy');

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
Key wholeComicQueueJobKey(String jobId) =>
    ValueKey<String>('whole-comic-queue-job:$jobId');
Key wholeComicQueuePauseKey(String jobId) =>
    ValueKey<String>('whole-comic-queue-pause:$jobId');
Key wholeComicQueueResumeKey(String jobId) =>
    ValueKey<String>('whole-comic-queue-resume:$jobId');
Key wholeComicQueueCancelKey(String jobId) =>
    ValueKey<String>('whole-comic-queue-cancel:$jobId');
Key wholeComicQueueRetryKey(String jobId) =>
    ValueKey<String>('whole-comic-queue-retry:$jobId');
Key wholeComicQueueRemoveKey(String jobId) =>
    ValueKey<String>('whole-comic-queue-remove:$jobId');

final class DownloadManagerScreen extends StatefulWidget {
  const DownloadManagerScreen({
    required this.entries,
    required this.downloads,
    required this.wholeComicDownloads,
    super.key,
  });

  final List<ImportedLibraryEntry> entries;
  final ChapterDownloadService downloads;
  final WholeComicDownloadQueue wholeComicDownloads;

  @override
  State<DownloadManagerScreen> createState() => _DownloadManagerScreenState();
}

final class _DownloadManagerScreenState extends State<DownloadManagerScreen> {
  final Map<String, ImportedLibraryEntry> _entries =
      <String, ImportedLibraryEntry>{};
  final Map<String, ChapterDownloadSnapshot> _snapshots =
      <String, ChapterDownloadSnapshot>{};
  StreamSubscription<ChapterDownloadSnapshot>? _subscription;
  StreamSubscription<WholeComicQueueSnapshot>? _wholeComicSubscription;
  late WholeComicQueueSnapshot _wholeComicSnapshot;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    for (final entry in widget.entries) {
      _entries[_identity(entry)] = entry;
    }
    _subscription = widget.downloads.changes.listen(_acceptSnapshot);
    _wholeComicSnapshot = widget.wholeComicDownloads.snapshot;
    _wholeComicSubscription = widget.wholeComicDownloads.changes.listen(
      (snapshot) {
        if (mounted) {
          setState(() => _wholeComicSnapshot = snapshot);
        }
      },
    );
    scheduleMicrotask(() async {
      await widget.wholeComicDownloads.ready;
      if (mounted) {
        setState(() {
          _wholeComicSnapshot = widget.wholeComicDownloads.snapshot;
        });
      }
    });
    scheduleMicrotask(_reload);
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_wholeComicSubscription?.cancel());
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

  Future<void> _editQueuePolicy() async {
    var next = _wholeComicSnapshot.policy;
    final selected = await showDialog<WholeComicQueuePolicy>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('整本下载队列策略'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('并发章节数'),
                const SizedBox(height: 8),
                SegmentedButton<int>(
                  segments: const <ButtonSegment<int>>[
                    ButtonSegment(value: 1, label: Text('1')),
                    ButtonSegment(value: 2, label: Text('2')),
                    ButtonSegment(value: 3, label: Text('3')),
                    ButtonSegment(value: 4, label: Text('4')),
                  ],
                  selected: <int>{next.concurrency},
                  onSelectionChanged: (value) => setDialogState(() {
                    next = next.copyWith(concurrency: value.single);
                  }),
                ),
                const SizedBox(height: 20),
                DropdownButtonFormField<WholeComicNetworkPolicy>(
                  value: next.network,
                  decoration: const InputDecoration(labelText: '网络策略'),
                  items: const <DropdownMenuItem<WholeComicNetworkPolicy>>[
                    DropdownMenuItem(
                      value: WholeComicNetworkPolicy.any,
                      child: Text('任意可用网络'),
                    ),
                    DropdownMenuItem(
                      value: WholeComicNetworkPolicy.unmetered,
                      child: Text('仅非计费网络'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(
                          () => next = next.copyWith(network: value));
                    }
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<WholeComicPowerPolicy>(
                  value: next.power,
                  decoration: const InputDecoration(labelText: '供电策略'),
                  items: const <DropdownMenuItem<WholeComicPowerPolicy>>[
                    DropdownMenuItem(
                      value: WholeComicPowerPolicy.any,
                      child: Text('任意供电状态'),
                    ),
                    DropdownMenuItem(
                      value: WholeComicPowerPolicy.charging,
                      child: Text('仅充电时'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => next = next.copyWith(power: value));
                    }
                  },
                ),
                const SizedBox(height: 12),
                Text(
                  'Android 会使用系统网络计费和充电状态；其他平台或桥不可用时使用应用注入的环境。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, next),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) {
      return;
    }
    try {
      await widget.wholeComicDownloads.updatePolicy(selected);
    } on Object catch (error) {
      if (mounted) {
        _showError(error);
      }
    }
  }

  Future<void> _queueAction(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error) {
      if (mounted) {
        _showError(error);
      }
    }
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
            key: downloadQueuePolicyKey,
            tooltip: '整本下载队列策略',
            onPressed: () => unawaited(_editQueuePolicy()),
            icon: const Icon(Icons.tune),
          ),
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
        child: snapshots.isEmpty && _wholeComicSnapshot.jobs.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const <Widget>[
                  SizedBox(height: 160),
                  Icon(Icons.download_done_outlined, size: 48),
                  SizedBox(height: 12),
                  Center(child: Text('暂无下载任务或离线章节')),
                ],
              )
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: <Widget>[
                  if (_wholeComicSnapshot.jobs.isNotEmpty) ...<Widget>[
                    const _DownloadSectionHeader(title: '整本下载队列'),
                    for (final job in _wholeComicSnapshot.jobs)
                      _WholeComicQueueTile(
                        key: wholeComicQueueJobKey(job.jobId),
                        job: job,
                        onPause: () => _queueAction(
                          () => widget.wholeComicDownloads.pause(job.jobId),
                        ),
                        onResume: () => _queueAction(
                          () => widget.wholeComicDownloads.resume(job.jobId),
                        ),
                        onCancel: () => _queueAction(
                          () => widget.wholeComicDownloads.cancel(job.jobId),
                        ),
                        onRetry: () => _queueAction(
                          () => widget.wholeComicDownloads.retry(job.jobId),
                        ),
                        onRemove: () => _queueAction(
                          () => widget.wholeComicDownloads.remove(job.jobId),
                        ),
                      ),
                    const Divider(height: 24),
                  ],
                  if (snapshots.isNotEmpty) ...<Widget>[
                    const _DownloadSectionHeader(title: '章节任务与离线文件'),
                    for (var index = 0;
                        index < snapshots.length;
                        index++) ...<Widget>[
                      if (index > 0) const Divider(height: 1),
                      _DownloadTaskTile(
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
                    ],
                  ],
                ],
              ),
      ),
    );
  }
}

final class _DownloadSectionHeader extends StatelessWidget {
  const _DownloadSectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );
}

final class _WholeComicQueueTile extends StatelessWidget {
  const _WholeComicQueueTile({
    required this.job,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
    required this.onRetry,
    required this.onRemove,
    super.key,
  });

  final WholeComicQueueJobSnapshot job;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onCancel;
  final VoidCallback onRetry;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final active = job.activeChapterTitles;
    final failure = job.failure;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
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
                      job.comicTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      '${job.sourceId} · ${_wholeQueuePhaseLabel(job.phase)}'
                      ' · ${job.completedChapters}/${job.totalChapters} 章',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (active.isNotEmpty)
                      Text(
                        '正在下载：${active.join('、')}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              if (job.canPause)
                IconButton(
                  key: wholeComicQueuePauseKey(job.jobId),
                  tooltip: '暂停整本下载',
                  onPressed: onPause,
                  icon: const Icon(Icons.pause_circle_outline),
                )
              else if (job.canResume)
                IconButton(
                  key: wholeComicQueueResumeKey(job.jobId),
                  tooltip: '继续整本下载',
                  onPressed: onResume,
                  icon: const Icon(Icons.play_circle_outline),
                )
              else if (job.canRetry)
                IconButton(
                  key: wholeComicQueueRetryKey(job.jobId),
                  tooltip: '重试整本下载',
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                ),
              if (job.phase != WholeComicQueuePhase.complete &&
                  job.phase != WholeComicQueuePhase.cancelled)
                IconButton(
                  key: wholeComicQueueCancelKey(job.jobId),
                  tooltip: '取消整本下载',
                  onPressed: onCancel,
                  icon: const Icon(Icons.stop_circle_outlined),
                ),
              IconButton(
                key: wholeComicQueueRemoveKey(job.jobId),
                tooltip: '移除队列记录',
                onPressed: onRemove,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          if (job.phase != WholeComicQueuePhase.complete) ...<Widget>[
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: job.phase == WholeComicQueuePhase.running &&
                      job.completedChapters == 0
                  ? null
                  : job.fraction,
            ),
          ],
          if (failure != null && failure.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            SelectableText(
              failure,
              maxLines: 3,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
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

String _wholeQueuePhaseLabel(WholeComicQueuePhase phase) => switch (phase) {
      WholeComicQueuePhase.queued => '排队中',
      WholeComicQueuePhase.running => '下载中',
      WholeComicQueuePhase.waitingForPolicy => '等待策略条件',
      WholeComicQueuePhase.paused => '已暂停',
      WholeComicQueuePhase.complete => '已完成',
      WholeComicQueuePhase.failed => '失败',
      WholeComicQueuePhase.cancelled => '已取消',
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
