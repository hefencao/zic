import 'dart:async';

import 'package:flutter/material.dart';

import 'app_preferences.dart';
import 'debug_trace.dart';
import 'debug_trace_export.dart';
import 'debug_trace_screen.dart';

export 'debug_trace_screen.dart';

const miscPageKey = ValueKey<String>('misc-page');
const miscQuickSettingsKey = ValueKey<String>('misc-quick-settings');
const miscSettingsEntryKey = ValueKey<String>('misc-settings-entry');
const miscAboutEntryKey = ValueKey<String>('misc-about-entry');
const miscDebugTraceEntryKey = ValueKey<String>('misc-debug-trace-entry');
const miscDownloadEntryKey = ValueKey<String>('misc-download-entry');
const miscImportEntryKey = ValueKey<String>('misc-import-entry');
const aboutScreenKey = ValueKey<String>('about-screen');

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
                  subtitle: const Text('最多保留最近 500 条诊断事件，高频生命周期会合并显示'),
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
                        ? '${debugTrace.events.length} 条显示 · ${debugTrace.exportEventCount} 条诊断导出 · 已合并 ${debugTrace.exportCoalescedCount} 条'
                        : '记录已关闭',
                  ),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => unawaited(
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => DebugTraceScreen(
                        log: debugTrace,
                        exportDirectory: preferences.debugTraceExportDirectory,
                        onExportDirectoryChanged:
                            preferences.setDebugTraceExportDirectory,
                      ),
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
            '0.31.0-dev.76',
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
