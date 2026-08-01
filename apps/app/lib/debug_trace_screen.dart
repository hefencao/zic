import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:telemetry/telemetry.dart';

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

final class DebugTraceScreen extends StatefulWidget {
  const DebugTraceScreen({required this.log, super.key});

  final DebugTraceLog log;

  @override
  State<DebugTraceScreen> createState() => _DebugTraceScreenState();
}

final class _DebugTraceScreenState extends State<DebugTraceScreen> {
  String _query = '';
  String? _sessionId;
  _TraceLevelFilter _level = _TraceLevelFilter.all;

  DebugTraceLog get log => widget.log;

  List<TraceEvent> _filteredEvents() {
    final query = _query.trim().toLowerCase();
    return log.events.where((event) {
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
    final text = _filteredEvents()
        .map((event) => event.toJsonLine())
        .join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制当前筛选结果')),
    );
  }

  Future<void> _exportFiltered() async {
    final events = _filteredEvents();
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.').first;
    final name = 'zic-debug-trace-$stamp.jsonl';
    final location = await getSaveLocation(suggestedName: name);
    if (location == null) return;
    final text = events.map((event) => event.toJsonLine()).join('\n');
    await XFile.fromData(
      Uint8List.fromList(utf8.encode(text)),
      mimeType: 'application/x-ndjson',
      name: name,
    ).saveTo(location.path);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已导出 ${events.length} 条 Trace')),
    );
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
            tooltip: '复制筛选结果',
            onPressed: () => unawaited(_copyFiltered()),
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            key: debugTraceExportKey,
            tooltip: '导出筛选结果',
            onPressed: () => unawaited(_exportFiltered()),
            icon: const Icon(Icons.file_download_outlined),
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
          final events = _filteredEvents().reversed.toList(growable: false);
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
                    '原始 ${log.recordedCount} 条 · '
                    '合并 ${log.coalescedCount} 条高频事件',
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

String _traceLevelFilterLabel(_TraceLevelFilter value) => switch (value) {
      _TraceLevelFilter.all => '全部级别',
      _TraceLevelFilter.normal => '普通',
      _TraceLevelFilter.activity => '活动',
      _TraceLevelFilter.warning => '警告',
      _TraceLevelFilter.error => '错误',
    };
