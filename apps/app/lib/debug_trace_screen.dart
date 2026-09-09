import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:telemetry/telemetry.dart';
import 'diagnostic_error_ui.dart';

import 'debug_trace.dart';

const debugTraceScreenKey = ValueKey<String>('debug-trace-screen');
const debugTraceClearKey = ValueKey<String>('debug-trace-clear');
const debugTraceCopyKey = ValueKey<String>('debug-trace-copy');
const debugTraceExportKey = ValueKey<String>('debug-trace-export');
const debugTraceSearchKey = ValueKey<String>('debug-trace-search');
const debugTraceSessionFilterKey =
    ValueKey<String>('debug-trace-session-filter');
const debugTraceLevelFilterKey =
    ValueKey<String>('debug-trace-level-filter');

enum _TraceLevelFilter { all, normal, activity, warning, error }

typedef DebugTraceFileExporter = Future<String?> Function({
  required String suggestedName,
  required Uint8List bytes,
});

typedef DebugTraceClipboardWriter = Future<void> Function(String text);

const debugTraceClipboardMaxBytes = 64 * 1024;
const _debugTraceExportChunkSize = 128;

Future<Uint8List> _encodeDebugTraceEvents(Iterable<TraceEvent> events) async {
  final bytes = BytesBuilder(copy: false);
  var index = 0;
  for (final event in events) {
    if (index > 0) bytes.addByte(0x0a);
    bytes.add(utf8.encode(event.toJsonLine()));
    index++;
    if (index % _debugTraceExportChunkSize == 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }
  return bytes.takeBytes();
}

final class DebugTraceScreen extends StatefulWidget {
  const DebugTraceScreen({
    required this.log,
    this.exportFile,
    this.writeClipboard,
    super.key,
  });

  final DebugTraceLog log;
  final DebugTraceFileExporter? exportFile;
  final DebugTraceClipboardWriter? writeClipboard;

  @override
  State<DebugTraceScreen> createState() => _DebugTraceScreenState();
}

final class _DebugTraceScreenState extends State<DebugTraceScreen> {
  String _query = '';
  String? _sessionId;
  _TraceLevelFilter _level = _TraceLevelFilter.all;
  bool _exporting = false;

  DebugTraceLog get log => widget.log;

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
      final exporter = widget.exportFile;
      if (exporter == null) {
        throw UnsupportedError('当前组合未提供 Trace 文件导出能力');
      }
      final events = _filteredEvents(log.exportEvents);
      final stamp = DateTime.now()
          .toUtc()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.').first;
      final name = 'zic-debug-trace-$stamp.jsonl';
      final bytes = await _encodeDebugTraceEvents(events);
      final path = await exporter(
        suggestedName: name,
        bytes: bytes,
      );
      if (!mounted || path == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导出 ${events.length} 条诊断 Trace')),
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
