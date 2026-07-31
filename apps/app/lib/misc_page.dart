import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_preferences.dart';
import 'debug_trace.dart';

const miscPageKey = ValueKey<String>('misc-page');
const miscQuickSettingsKey = ValueKey<String>('misc-quick-settings');
const miscSettingsEntryKey = ValueKey<String>('misc-settings-entry');
const miscAboutEntryKey = ValueKey<String>('misc-about-entry');
const miscDebugTraceEntryKey = ValueKey<String>('misc-debug-trace-entry');
const miscDownloadEntryKey = ValueKey<String>('misc-download-entry');
const miscImportEntryKey = ValueKey<String>('misc-import-entry');
const aboutScreenKey = ValueKey<String>('about-screen');
const debugTraceScreenKey = ValueKey<String>('debug-trace-screen');
const debugTraceClearKey = ValueKey<String>('debug-trace-clear');
const debugTraceCopyKey = ValueKey<String>('debug-trace-copy');

final class MiscPage extends StatelessWidget {
  const MiscPage({
    required this.preferences,
    required this.debugTrace,
    required this.onOpenSettings,
    required this.onOpenDownloads,
    required this.onImportFolder,
    super.key,
  });

  final AppPreferencesController preferences;
  final DebugTraceLog debugTrace;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenDownloads;
  final VoidCallback? onImportFolder;

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: miscPageKey,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: <Widget>[
        Text('快捷设置', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        Card(
          key: miscQuickSettingsKey,
          clipBehavior: Clip.antiAlias,
          child: AnimatedBuilder(
            animation: preferences,
            builder: (context, _) => Column(
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('外观'),
                  subtitle: Text(_themeLabel(preferences.themeMode)),
                  trailing: DropdownButton<ThemeMode>(
                    value: preferences.themeMode,
                    underline: const SizedBox.shrink(),
                    items: const <DropdownMenuItem<ThemeMode>>[
                      DropdownMenuItem(
                        value: ThemeMode.system,
                        child: Text('系统'),
                      ),
                      DropdownMenuItem(
                        value: ThemeMode.light,
                        child: Text('浅色'),
                      ),
                      DropdownMenuItem(
                        value: ThemeMode.dark,
                        child: Text('深色'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) preferences.setThemeMode(value);
                    },
                  ),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.fullscreen_outlined),
                  title: const Text('默认沉浸阅读'),
                  value: preferences.readerStartsImmersive,
                  onChanged: preferences.setReaderStartsImmersive,
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.bug_report_outlined),
                  title: const Text('记录 Debug trace'),
                  subtitle: const Text('最多保留最近 500 条事件'),
                  value: preferences.debugTraceEnabled,
                  onChanged: preferences.setDebugTraceEnabled,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        Text('快捷操作', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            Expanded(
              child: _QuickAction(
                key: miscDownloadEntryKey,
                icon: Icons.download_for_offline_outlined,
                label: '下载管理',
                onTap: onOpenDownloads,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _QuickAction(
                key: miscImportEntryKey,
                icon: Icons.create_new_folder_outlined,
                label: '导入漫画',
                onTap: onImportFolder,
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Text('更多', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: <Widget>[
              ListTile(
                key: miscSettingsEntryKey,
                leading: const Icon(Icons.settings_outlined),
                title: const Text('设置'),
                subtitle: const Text('数据、网络、书架、阅读、下载与外观'),
                trailing: const Icon(Icons.chevron_right),
                onTap: onOpenSettings,
              ),
              const Divider(height: 1),
              ListTile(
                key: miscAboutEntryKey,
                leading: const Icon(Icons.info_outline),
                title: const Text('关于'),
                subtitle: const Text('版本、架构边界与开源说明'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => unawaited(
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const AboutScreen(),
                    ),
                  ),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                key: miscDebugTraceEntryKey,
                leading: const Icon(Icons.bug_report_outlined),
                title: const Text('Debug trace'),
                subtitle: AnimatedBuilder(
                  animation: debugTrace,
                  builder: (context, _) => Text(
                    debugTrace.enabled
                        ? '${debugTrace.events.length} 条事件'
                        : '记录已关闭',
                  ),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => unawaited(
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => DebugTraceScreen(log: debugTrace),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

final class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: aboutScreenKey,
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: <Widget>[
          const Icon(Icons.auto_stories, size: 64),
          const SizedBox(height: 16),
          Text(
            'zic',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 6),
          const Text(
            '0.31.0-dev.64',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          const Text(
            '高性能漫画阅读器。Reader demand、下载 session、缓存 artifact、插件运行时与 Presentation 保持明确所有权边界。',
          ),
          const SizedBox(height: 16),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.extension_outlined),
            title: Text('外部漫画源'),
            subtitle: Text('支持受控的 Mihon 与 Venera 兼容运行时。'),
          ),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.image_outlined),
            title: Text('媒体'),
            subtitle: Text('支持静态图片、WebP 动图与 Reader 增量媒体管线。'),
          ),
        ],
      ),
    );
  }
}

final class DebugTraceScreen extends StatelessWidget {
  const DebugTraceScreen({required this.log, super.key});

  final DebugTraceLog log;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: debugTraceScreenKey,
      appBar: AppBar(
        title: const Text('Debug trace'),
        actions: <Widget>[
          IconButton(
            key: debugTraceCopyKey,
            tooltip: '复制全部',
            onPressed: () {
              final text = log.events
                  .map((event) => event.toJsonLine())
                  .join('\n');
              unawaited(Clipboard.setData(ClipboardData(text: text)));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Trace 已复制')),
              );
            },
            icon: const Icon(Icons.copy_all_outlined),
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
          final events = log.events.reversed.toList(growable: false);
          if (events.isEmpty) {
            return Center(
              child: Text(log.enabled ? '暂无 Trace 事件' : 'Debug trace 记录已关闭'),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            itemCount: events.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final event = events[index];
              return ListTile(
                dense: true,
                title: Text(event.kind.name),
                subtitle: SelectableText(event.toJsonLine()),
              );
            },
          );
        },
      ),
    );
  }
}

final class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: onTap,
      icon: Icon(icon),
      label: Text(label),
    );
  }
}

String _themeLabel(ThemeMode mode) => switch (mode) {
      ThemeMode.system => '跟随系统',
      ThemeMode.light => '浅色',
      ThemeMode.dark => '深色',
    };
