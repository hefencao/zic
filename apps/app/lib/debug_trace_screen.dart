import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:telemetry/telemetry.dart';
import 'diagnostic_error_ui.dart';

import 'debug_trace.dart';
import 'debug_trace_export.dart';

const debugTraceScreenKey = ValueKey<String>('debug-trace-screen');
const debugTraceClearKey = ValueKey<String>('debug-trace-clear');
const debugTraceCopyKey = ValueKey<String>('debug-trace-copy');
const debugTraceExportKey = ValueKey<String>('debug-trace-export');
const debugTraceExportDirectoryKey =
    ValueKey<String>('debug-trace-export-directory');
const debugTraceSearchKey = ValueKey<String>('debug-trace-search');
const debugTraceSessionFilterKey =
    ValueKey<String>('debug-trace-session-filter');
const debugTraceLevelFilterKey =
    ValueKey<String>('debug-trace-level-filter');

enum _TraceLevelFilter { all, normal, activity, warning, error }

typedef DebugTraceEventsExporter = Future<DebugTraceExportResult?> Function(
  Iterable<TraceEvent> events,
);

typedef DebugTraceClipboardWriter = Future<void> Function(String text);

const debugTraceClipboardMaxBytes = 64 * 1024;

final class DebugTraceScreen extends StatefulWidget {
  const DebugTraceScreen({
    required this.log,
    this.exportDirectory = defaultDebugTraceExportDirectory,
    this.exportEvents,
    this.onExportDirectoryChanged,
    this.writeClipboard,
    super.key,
  });

  final DebugTraceLog log;
  final String exportDirectory;
  final DebugTraceEventsExporter? exportEvents;
  final ValueChanged<String>? onExportDirectoryChanged;
  final DebugTraceClipboardWriter? writeClipboard;

  @override
  State<DebugTraceScreen> createState() => _DebugTraceScreenState();
}

final class _DebugTraceScreenState extends State<DebugTraceScreen> {
  String _query = '';
  String? _sessionId;
  _TraceLevelFilter _level = _TraceLevelFilter.all;
  bool _exporting = false;
  late String _exportDirectory;

  DebugTraceLog get log => widget.log;

  @override
  void initState() {
    super.initState();
    _exportDirectory = normalizeDebugTraceExportDirectory(
      widget.exportDirectory,
    );
  }

  @override
  void didUpdateWidget(covariant DebugTraceScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.exportDirectory != widget.exportDirectory) {
      _exportDirectory = normalizeDebugTraceExportDirectory(
        widget.exportDirectory,
      );
    }
  }

  List<TraceEvent> _filteredEvents(Iterable<TraceEvent> source) {
    final query = _query.trim().toLowerCase();
    return source.where((event) {
      if (_sessionId != null && event.sessionId != _sessionId) return false;
      final level = traceHighlightLevel(event);
      final levelMatches = switch (_level) {
        _TraceLevelFilter.all => true,
        _TraceLevelFilter.normal => level == TraceHighlightLevel.normal,
        _TraceLevelFilter.activity => level == TraceHighlightLevel.activity,
        _TraceLevelFilter.warning => level == TraceHighlightLevel.warning,
        _TraceLevelFilter.error => level == TraceHighlightLevel.error,
      };
      if (!levelMatches) return false;
      if (query.isEmpty) return true;
      return event.kind.name.toLowerCase().contains(query) ||
          event.sessionId.toLowerCase().contains(query) ||
          event.toJsonLine().toLowerCase().contains(query);
    }).toList(growable: false);
  }

  Future<void> _copyFiltered() async {
    final events = _filteredEvents(log.exportEvents);
    final payload = _boundedClipboardPayload(events);
    try {
      final writer = widget.writeClipboard ?? _writeSystemClipboard;
      await writer(payload.text);
      if (!mounted) return;
      final suffix = payload.copiedCount == events.length
          ? ''
          : '（剪贴板上限，仅复制前 ${payload.copiedCount}/${events.length} 条）';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已复制 ${payload.copiedCount} 条诊断 Trace$suffix')),
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        copyableDiagnosticSnackBar('Trace 复制失败：$error'),
      );
    }
  }

  Future<void> _exportFiltered() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    await WidgetsBinding.instance.endOfFrame;
    try {
      final events = _filteredEvents(log.exportEvents);
      final exporter = widget.exportEvents ??
          (events) => exportDebugTraceEvents(
                events: events,
                relativeDirectory: _exportDirectory,
              );
      final result = await exporter(events);
      if (!mounted || result == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已导出 ${result.eventCount} 条诊断 Trace 到 '
            '${debugTraceExportDisplayPath(result.relativeDirectory)}',
          ),
        ),
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        copyableDiagnosticSnackBar('Trace 导出失败：$error'),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _editExportDirectory() async {
    final onChanged = widget.onExportDirectoryChanged;
    if (onChanged == null) return;
    var draft = _exportDirectory;
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Trace 导出目录'),
        content: TextFormField(
          initialValue: draft,
          onChanged: (value) => draft = value,
          autofocus: true,
          decoration: const InputDecoration(
            prefixText: 'Download/',
            hintText: 'Debug',
            helperText: '可使用多级相对子目录，例如 Debug/Reader',
          ),
          onFieldSubmitted: (value) =>
              Navigator.of(dialogContext).pop(value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(draft),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (value == null) return;
    final normalized = normalizeDebugTraceExportDirectory(value);
    if (!mounted) return;
    setState(() => _exportDirectory = normalized);
    onChanged(normalized);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: debugTraceScreenKey,
      appBar: AppBar(
        title: const Text('Debug trace'),
        actions: <Widget>[
          IconButton(
            key: debugTraceCopyKey,
            tooltip: '复制筛选后的诊断结果',
            onPressed: () => unawaited(_copyFiltered()),
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            key: debugTraceExportKey,
            tooltip: _exporting ? '正在准备诊断导出' : '导出筛选后的诊断结果',
            onPressed: _exporting ? null : () => unawaited(_exportFiltered()),
            icon: _exporting
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.file_download_outlined),
          ),
          IconButton(
            key: debugTraceClearKey,
            tooltip: '清空',
            onPressed: log.clear,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: log,
        builder: (context, _) {
          final sessions = log.sessionIds.toList()..sort();
          if (_sessionId != null && !sessions.contains(_sessionId)) {
            _sessionId = null;
          }
          final events = _filteredEvents(log.events)
              .reversed
              .toList(growable: false);
          return Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                child: TextField(
                  key: debugTraceSearchKey,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: '搜索类型、会话或内容',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: debugTraceSessionFilterKey,
                        value: _sessionId ?? '',
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: '会话',
                          isDense: true,
                        ),
                        items: <DropdownMenuItem<String>>[
                          const DropdownMenuItem<String>(
                            value: '',
                            child: Text('全部会话'),
                          ),
                          for (final session in sessions)
                            DropdownMenuItem<String>(
                              value: session,
                              child: Text(
                                session,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (value) => setState(
                          () => _sessionId = value == null || value.isEmpty
                              ? null
                              : value,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<_TraceLevelFilter>(
                        key: debugTraceLevelFilterKey,
                        value: _level,
                        decoration: const InputDecoration(
                          labelText: '级别',
                          isDense: true,
                        ),
                        items: <DropdownMenuItem<_TraceLevelFilter>>[
                          for (final value in _TraceLevelFilter.values)
                            DropdownMenuItem<_TraceLevelFilter>(
                              value: value,
                              child: Text(_traceLevelFilterLabel(value)),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) setState(() => _level = value);
                        },
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: debugTraceExportDirectoryKey,
                    onPressed: widget.onExportDirectoryChanged == null
                        ? null
                        : () => unawaited(_editExportDirectory()),
                    icon: const Icon(Icons.folder_outlined, size: 18),
                    label: Text(
                      '导出目录 ${debugTraceExportDisplayPath(_exportDirectory)}',
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '显示 ${events.length}/${log.events.length} 条 · '
                    '导出缓冲 ${log.exportEvents.length} 条 · '
                    '累计 ${log.recordedCount} 条 · '
                    '合并 ${log.coalescedCount} 条 · '
                    '导出合并 ${log.exportCoalescedCount} 条 · '
                    '导出丢弃 ${log.exportDroppedCount} 条',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: events.isEmpty
                    ? Center(
                        child: Text(
                          log.enabled ? '当前筛选没有 Trace 事件' : '记录已关闭',
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(8, 6, 8, 24),
                        itemCount: events.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 4),
                        itemBuilder: (context, index) =>
                            _DebugTraceTile(event: events[index]),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

final class _DebugTraceTile extends StatelessWidget {
  const _DebugTraceTile({required this.event});

  final TraceEvent event;

  @override
  Widget build(BuildContext context) {
    final level = traceHighlightLevel(event);
    final color = switch (level) {
      TraceHighlightLevel.error => Theme.of(context).colorScheme.error,
      TraceHighlightLevel.warning => Theme.of(context).colorScheme.tertiary,
      TraceHighlightLevel.activity => Theme.of(context).colorScheme.primary,
      TraceHighlightLevel.normal => Theme.of(context).colorScheme.outline,
    };
    final count = event.payload['coalescedCount'];
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(width: 4, color: color)),
        color: color.withAlpha(14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: ListTile(
        dense: true,
        title: Row(
          children: <Widget>[
            Expanded(child: Text(event.kind.name)),
            if (count is int && count > 1)
              Text('×$count', style: TextStyle(color: color)),
          ],
        ),
        subtitle: SelectableText(event.toJsonLine()),
      ),
    );
  }
}

Future<void> _writeSystemClipboard(String text) =>
    Clipboard.setData(ClipboardData(text: text));

({String text, int copiedCount}) _boundedClipboardPayload(
  List<TraceEvent> events, {
  int maxBytes = debugTraceClipboardMaxBytes,
}) {
  if (maxBytes <= 0 || events.isEmpty) {
    return (text: '', copiedCount: 0);
  }
  final buffer = StringBuffer();
  var usedBytes = 0;
  var copiedCount = 0;
  for (final event in events) {
    final line = event.toJsonLine();
    final lineBytes = utf8.encode(line);
    final separatorBytes = copiedCount == 0 ? 0 : 1;
    if (usedBytes + separatorBytes + lineBytes.length > maxBytes) {
      break;
    }
    if (copiedCount > 0) {
      buffer.write('\n');
      usedBytes++;
    }
    buffer.write(line);
    usedBytes += lineBytes.length;
    copiedCount++;
  }
  return (text: buffer.toString(), copiedCount: copiedCount);
}

String _traceLevelFilterLabel(_TraceLevelFilter value) => switch (value) {
      _TraceLevelFilter.all => '全部级别',
      _TraceLevelFilter.normal => '普通',
      _TraceLevelFilter.activity => '活动',
      _TraceLevelFilter.warning => '警告',
      _TraceLevelFilter.error => '错误',
    };
