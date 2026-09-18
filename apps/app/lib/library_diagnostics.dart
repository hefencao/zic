import 'dart:async';
import 'dart:convert';

import 'package:catalog/catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const libraryDiagnosticsScreenKey =
    ValueKey<String>('library-diagnostics-screen');
const libraryDiagnosticsEntryKey =
    ValueKey<String>('library-diagnostics-entry');
const libraryDiagnosticsRefreshKey =
    ValueKey<String>('library-diagnostics-refresh');
const libraryDiagnosticsCopyKey = ValueKey<String>('library-diagnostics-copy');
const libraryDiagnosticsShowAcknowledgedKey =
    ValueKey<String>('library-diagnostics-show-acknowledged');
const libraryDiagnosticsAcknowledgeAllKey =
    ValueKey<String>('library-diagnostics-acknowledge-all');

Key libraryDiagnosticsIssueKey(int issueId) =>
    ValueKey<String>('library-diagnostics-issue:$issueId');
Key libraryDiagnosticsAcknowledgeKey(int issueId) =>
    ValueKey<String>('library-diagnostics-acknowledge:$issueId');

final class LibraryDiagnosticsScreen extends StatefulWidget {
  const LibraryDiagnosticsScreen({
    required this.readStore,
    this.storeChanges,
    super.key,
  });

  final ImportedLibraryStore Function() readStore;
  final Listenable? storeChanges;

  @override
  State<LibraryDiagnosticsScreen> createState() =>
      _LibraryDiagnosticsScreenState();
}

final class _LibraryDiagnosticsScreenState
    extends State<LibraryDiagnosticsScreen> {
  List<LibraryMigrationIssue> _issues = const <LibraryMigrationIssue>[];
  bool _includeAcknowledged = false;
  bool _loading = true;
  Object? _error;
  int _storeGeneration = 0;
  int _reloadRequest = 0;

  @override
  void initState() {
    super.initState();
    widget.storeChanges?.addListener(_handleStoreChanged);
    scheduleMicrotask(() => unawaited(_reload()));
  }

  @override
  void didUpdateWidget(LibraryDiagnosticsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.storeChanges, widget.storeChanges)) {
      oldWidget.storeChanges?.removeListener(_handleStoreChanged);
      widget.storeChanges?.addListener(_handleStoreChanged);
      _invalidateStore();
      unawaited(_reload());
    } else if (oldWidget.readStore != widget.readStore) {
      _invalidateStore();
      unawaited(_reload());
    }
  }

  @override
  void dispose() {
    widget.storeChanges?.removeListener(_handleStoreChanged);
    super.dispose();
  }

  void _invalidateStore() {
    _storeGeneration++;
  }

  void _handleStoreChanged() {
    _invalidateStore();
    if (mounted) {
      unawaited(_reload());
    }
  }

  Future<T> _withCurrentStore<T>(
    Future<T> Function(ImportedLibraryStore store) operation,
  ) async {
    while (true) {
      final generation = _storeGeneration;
      final store = widget.readStore();
      try {
        final result = await operation(store);
        if (generation == _storeGeneration &&
            identical(store, widget.readStore())) {
          return result;
        }
      } on Object {
        if (generation == _storeGeneration &&
            identical(store, widget.readStore())) {
          rethrow;
        }
      }
    }
  }

  Future<void> _reload() async {
    final request = ++_reloadRequest;
    final includeAcknowledged = _includeAcknowledged;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final issues = await _withCurrentStore(
        (store) => store.listMigrationIssues(
          includeAcknowledged: includeAcknowledged,
        ),
      );
      if (mounted &&
          request == _reloadRequest &&
          includeAcknowledged == _includeAcknowledged) {
        setState(() => _issues = issues);
      }
    } on Object catch (error) {
      if (mounted && request == _reloadRequest) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted && request == _reloadRequest) {
        setState(() => _loading = false);
      }
    }
  }

  String _issueSemanticKey(LibraryMigrationIssue issue) => jsonEncode(
        <String, Object?>{
          'schemaFrom': issue.schemaFrom,
          'entityKind': issue.entityKind,
          'legacyKey': issue.legacyKey,
          'resolvedSourceId': issue.resolvedSourceId,
          'details': issue.details,
          'createdAt': issue.createdAt.toUtc().microsecondsSinceEpoch,
        },
      );

  Future<int> _acknowledgeCurrentIssues(
    Set<String> targetKeys, {
    required DateTime acknowledgedAt,
  }) async {
    while (true) {
      final generation = _storeGeneration;
      final store = widget.readStore();
      final retained = await store.listMigrationIssues(
        includeAcknowledged: true,
      );
      if (generation != _storeGeneration ||
          !identical(store, widget.readStore())) {
        continue;
      }
      final matches = retained
          .where((issue) => targetKeys.contains(_issueSemanticKey(issue)))
          .toList(growable: false);
      final pendingIds = matches
          .where((issue) => !issue.acknowledged)
          .map((issue) => issue.issueId)
          .toSet();
      if (pendingIds.isNotEmpty) {
        await store.acknowledgeMigrationIssues(
          pendingIds,
          acknowledgedAt: acknowledgedAt,
        );
        if (generation != _storeGeneration ||
            !identical(store, widget.readStore())) {
          continue;
        }
      }
      return matches.length;
    }
  }

  Future<void> _acknowledge(Iterable<int> issueIds) async {
    final ids = issueIds.toSet();
    if (ids.isEmpty) {
      return;
    }
    final targets = _issues
        .where((issue) => ids.contains(issue.issueId))
        .toList(growable: false);
    if (targets.isEmpty) {
      return;
    }
    final targetKeys = targets.map(_issueSemanticKey).toSet();
    final acknowledgedAt = DateTime.now().toUtc();
    try {
      final matched = await _acknowledgeCurrentIssues(
        targetKeys,
        acknowledgedAt: acknowledgedAt,
      );
      await _reload();
      if (mounted) {
        final message = matched == 0
            ? '诊断库已更新；当前库中没有对应记录'
            : '已确认 $matched 条迁移诊断；记录仍被保留';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } on Object catch (error) {
      if (mounted) {
        _showError(error);
      }
    }
  }

  Future<void> _copyJson() async {
    try {
      final export = await _withCurrentStore((store) async {
        final retained = await store.listMigrationIssues(
          includeAcknowledged: true,
        );
        final encoded = const JsonEncoder.withIndent('  ').convert(
          <String, Object?>{
            'schema': 'zic-library-migration-diagnostics-v1',
            'exportedAt': DateTime.now().toUtc().toIso8601String(),
            'issues': retained
                .map((issue) => issue.toJson())
                .toList(growable: false),
          },
        );
        return (encoded: encoded, count: retained.length);
      });
      await Clipboard.setData(ClipboardData(text: export.encoded));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已复制 ${export.count} 条迁移诊断 JSON')),
        );
      }
    } on Object catch (error) {
      if (mounted) {
        _showError(error);
      }
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
    final pending = _issues.where((issue) => !issue.acknowledged).toList();
    return Scaffold(
      key: libraryDiagnosticsScreenKey,
      appBar: AppBar(
        title: const Text('书架迁移诊断'),
        actions: <Widget>[
          IconButton(
            key: libraryDiagnosticsCopyKey,
            tooltip: '复制诊断 JSON',
            onPressed: _loading ? null : _copyJson,
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            key: libraryDiagnosticsRefreshKey,
            tooltip: '刷新诊断',
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
      body: Column(
        children: <Widget>[
          SwitchListTile(
            key: libraryDiagnosticsShowAcknowledgedKey,
            title: const Text('显示已确认记录'),
            subtitle: const Text('确认只隐藏提示，不删除或改写迁移记录'),
            value: _includeAcknowledged,
            onChanged: (value) {
              setState(() => _includeAcknowledged = value);
              unawaited(_reload());
            },
          ),
          if (pending.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  key: libraryDiagnosticsAcknowledgeAllKey,
                  onPressed: () => _acknowledge(
                    pending.map((issue) => issue.issueId),
                  ),
                  icon: const Icon(Icons.done_all),
                  label: Text('确认全部 ${pending.length} 条未处理记录'),
                ),
              ),
            ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _issues.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null && _issues.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.error_outline, size: 44),
              const SizedBox(height: 12),
              const Text('迁移诊断加载失败'),
              const SizedBox(height: 8),
              SelectableText(error.toString(), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _reload,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_issues.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: const <Widget>[
          SizedBox(height: 80),
          Icon(Icons.verified_outlined, size: 52),
          SizedBox(height: 12),
          Center(child: Text('没有未确认的迁移诊断')),
          SizedBox(height: 6),
          Center(child: Text('系统不会自动删除来源不明确的旧记录')),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        itemCount: _issues.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) => _MigrationIssueCard(
          key: libraryDiagnosticsIssueKey(_issues[index].issueId),
          issue: _issues[index],
          onAcknowledge: _issues[index].acknowledged
              ? null
              : () => _acknowledge(<int>[_issues[index].issueId]),
        ),
      ),
    );
  }
}

final class _MigrationIssueCard extends StatelessWidget {
  const _MigrationIssueCard({
    required this.issue,
    required this.onAcknowledge,
    super.key,
  });

  final LibraryMigrationIssue issue;
  final VoidCallback? onAcknowledge;

  @override
  Widget build(BuildContext context) {
    final details = const JsonEncoder.withIndent('  ').convert(issue.details);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '${issue.entityKind} · ${issue.legacyKey}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (issue.acknowledged)
                  const Chip(
                    avatar: Icon(Icons.done, size: 16),
                    label: Text('已确认'),
                    visualDensity: VisualDensity.compact,
                  )
                else
                  TextButton.icon(
                    key: libraryDiagnosticsAcknowledgeKey(issue.issueId),
                    onPressed: onAcknowledge,
                    icon: const Icon(Icons.done),
                    label: const Text('确认'),
                  ),
              ],
            ),
            Text(
              '来自 schema ${issue.schemaFrom}'
              '${issue.resolvedSourceId == null ? '' : ' · 归属 ${issue.resolvedSourceId}'}'
              ' · ${issue.createdAt.toLocal()}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            SelectableText(details),
            if (issue.acknowledgedAt != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '确认时间：${issue.acknowledgedAt!.toLocal()}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
