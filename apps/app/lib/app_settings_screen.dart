import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:resource_cache/resource_cache.dart';

import 'dialog_actions.dart';

import 'app_preferences.dart';

const settingsScreenKey = ValueKey<String>('settings-screen');
const settingsDataEntryKey = ValueKey<String>('settings-data-entry');
const settingsNetworkEntryKey = ValueKey<String>('settings-network-entry');
const settingsBookshelfEntryKey =
    ValueKey<String>('settings-bookshelf-entry');
const settingsReadingEntryKey = ValueKey<String>('settings-reading-entry');
const settingsDownloadEntryKey = ValueKey<String>('settings-download-entry');
const settingsAppearanceEntryKey =
    ValueKey<String>('settings-appearance-entry');
const dataSettingsScreenKey = ValueKey<String>('data-settings-screen');
const networkSettingsScreenKey = ValueKey<String>('network-settings-screen');
const bookshelfSettingsScreenKey =
    ValueKey<String>('bookshelf-settings-screen');
const readingSettingsScreenKey = ValueKey<String>('reading-settings-screen');
const downloadSettingsScreenKey = ValueKey<String>('download-settings-screen');
const appearanceSettingsScreenKey =
    ValueKey<String>('appearance-settings-screen');
const dataBackupExportKey = ValueKey<String>('data-backup-export');
const dataCacheClearKey = ValueKey<String>('data-cache-clear');
const dataCacheRefreshKey = ValueKey<String>('data-cache-refresh');
const readingAdaptiveKey = ValueKey<String>('reading-adaptive');
const readingVerticalStitchKey =
    ValueKey<String>('reading-vertical-stitch');
const readingPreviewMaxItemsPerRowKey =
    ValueKey<String>('reading-preview-max-items-per-row');

final class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    required this.preferences,
    required this.downloads,
    required this.cacheCoordinator,
    required this.exportBackup,
    this.storageRoot,
    super.key,
  });

  final AppPreferencesController preferences;
  final WholeComicDownloadQueue downloads;
  final ResourceCacheCoordinator cacheCoordinator;
  final Future<String?> Function() exportBackup;
  final String? storageRoot;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: settingsScreenKey,
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: <Widget>[
          _SettingsEntry(
            key: settingsDataEntryKey,
            icon: Icons.storage_outlined,
            title: '数据',
            subtitle: '目录、数据备份与缓存维护',
            onTap: () => _push(
              context,
              DataSettingsScreen(
                storageRoot: storageRoot,
                cacheCoordinator: cacheCoordinator,
                exportBackup: exportBackup,
              ),
            ),
          ),
          _SettingsEntry(
            key: settingsNetworkEntryKey,
            icon: Icons.language_outlined,
            title: '网络',
            subtitle: '网络限制与漫画源请求边界',
            onTap: () => _push(
              context,
              NetworkSettingsScreen(
                downloads: downloads,
                preferences: preferences,
              ),
            ),
          ),
          _SettingsEntry(
            key: settingsBookshelfEntryKey,
            icon: Icons.collections_bookmark_outlined,
            title: '书架',
            subtitle: '默认筛选、排序与视图',
            onTap: () => _push(
              context,
              BookshelfSettingsScreen(preferences: preferences),
            ),
          ),
          _SettingsEntry(
            key: settingsReadingEntryKey,
            icon: Icons.menu_book_outlined,
            title: '阅读',
            subtitle: '默认阅读模式与沉浸行为',
            onTap: () => _push(
              context,
              ReadingSettingsScreen(preferences: preferences),
            ),
          ),
          _SettingsEntry(
            key: settingsDownloadEntryKey,
            icon: Icons.download_outlined,
            title: '下载',
            subtitle: '并发、网络与供电策略',
            onTap: () => _push(
              context,
              DownloadSettingsScreen(downloads: downloads),
            ),
          ),
          _SettingsEntry(
            key: settingsAppearanceEntryKey,
            icon: Icons.palette_outlined,
            title: '外观',
            subtitle: '跟随系统、浅色或深色',
            onTap: () => _push(
              context,
              AppearanceSettingsScreen(preferences: preferences),
            ),
          ),
        ],
      ),
    );
  }

  void _push(BuildContext context, Widget screen) {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => screen),
      ),
    );
  }
}

final class DataSettingsScreen extends StatefulWidget {
  const DataSettingsScreen({
    required this.cacheCoordinator,
    required this.exportBackup,
    this.storageRoot,
    super.key,
  });

  final String? storageRoot;
  final ResourceCacheCoordinator cacheCoordinator;
  final Future<String?> Function() exportBackup;

  @override
  State<DataSettingsScreen> createState() => _DataSettingsScreenState();
}

final class _DataSettingsScreenState extends State<DataSettingsScreen> {
  ResourceCacheUsage? _usage;
  Object? _failure;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshUsage());
  }

  Future<void> _refreshUsage() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final usage = await widget.cacheCoordinator.inspect();
      if (mounted) setState(() => _usage = usage);
    } on Object catch (error) {
      if (mounted) setState(() => _failure = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清理缓存'),
        content: const Text(
          '清理响应缓存与可安全移除的页面 artifact。正在使用的资源会由各自 owner 保留。',
        ),
        actions: <Widget>[
          AppDialogActions(
            onClose: () => Navigator.pop(context, false),
            actions: <Widget>[
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('清理'),
              ),
            ],
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final report = await widget.cacheCoordinator.clear();
      final usage = await widget.cacheCoordinator.inspect();
      if (!mounted) return;
      setState(() => _usage = usage);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已释放 ${_formatBytes(report.totalReleasedBytes)}',
          ),
        ),
      );
    } on Object catch (error) {
      if (mounted) setState(() => _failure = error);
    } finally {
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  Future<void> _exportBackup() async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final path = await widget.exportBackup();
      if (!mounted || path == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('备份已导出：$path')),
      );
    } on Object catch (error) {
      if (mounted) setState(() => _failure = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final root = widget.storageRoot;
    return Scaffold(
      key: dataSettingsScreenKey,
      appBar: AppBar(title: const Text('数据')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: <Widget>[
          const _SettingsSectionTitle('目录'),
          _DirectoryTile(
            title: '应用数据目录',
            path: root,
          ),
          _DirectoryTile(
            title: '章节下载目录',
            path: root == null ? null : '$root/offline_chapters',
          ),
          _DirectoryTile(
            title: '响应缓存目录',
            path: root == null ? null : '$root/resource_cache/responses',
          ),
          _DirectoryTile(
            title: '插件数据目录',
            path: root == null ? null : '$root/external_plugins',
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text('目录迁移必须同时迁移索引与 artifact，不允许只改字符串路径。'),
          ),
          const Divider(),
          const _SettingsSectionTitle('备份'),
          ListTile(
            key: dataBackupExportKey,
            enabled: !_busy,
            leading: const Icon(Icons.backup_outlined),
            title: const Text('导出数据备份'),
            subtitle: const Text('导出漫画、章节、进度、书架分类与来源偏好；不复制缓存字节。'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : _exportBackup,
          ),
          const Divider(),
          const _SettingsSectionTitle('缓存'),
          ListTile(
            title: const Text('当前缓存'),
            subtitle: Text(
              _failure != null
                  ? '读取失败：$_failure'
                  : _usage == null
                      ? '正在读取…'
                      : '${_formatBytes(_usage!.totalBytes)} · ${_usage!.totalEntries} 项',
            ),
            trailing: IconButton(
              key: dataCacheRefreshKey,
              tooltip: '刷新缓存统计',
              onPressed: _busy ? null : _refreshUsage,
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ),
          ListTile(
            key: dataCacheClearKey,
            enabled: !_busy,
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('清理缓存'),
            subtitle: const Text('通过统一缓存协调器清理，不直接遍历或删除 Reader 文件。'),
            onTap: _busy ? null : _clearCache,
          ),
        ],
      ),
    );
  }
}

final class NetworkSettingsScreen extends StatefulWidget {
  const NetworkSettingsScreen({
    required this.downloads,
    required this.preferences,
    super.key,
  });

  final WholeComicDownloadQueue downloads;
  final AppPreferencesController preferences;

  @override
  State<NetworkSettingsScreen> createState() => _NetworkSettingsScreenState();
}

final class _NetworkSettingsScreenState extends State<NetworkSettingsScreen> {
  late final TextEditingController _userAgent = TextEditingController(
    text: widget.preferences.networkUserAgent,
  );

  @override
  void dispose() {
    _userAgent.dispose();
    super.dispose();
  }

  void _applyUserAgent() {
    widget.preferences.setNetworkUserAgent(_userAgent.text);
    _userAgent.text = widget.preferences.networkUserAgent;
    _userAgent.selection = TextSelection.collapsed(offset: _userAgent.text.length);
  }

  void _resetUserAgent() {
    widget.preferences.resetNetworkUserAgent();
    _userAgent.text = widget.preferences.networkUserAgent;
    _userAgent.selection = TextSelection.collapsed(offset: _userAgent.text.length);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: networkSettingsScreenKey,
      appBar: AppBar(title: const Text('网络')),
      body: StreamBuilder<WholeComicQueueSnapshot>(
        stream: widget.downloads.changes,
        initialData: widget.downloads.snapshot,
        builder: (context, snapshot) {
          final policy = snapshot.requireData.policy;
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: <Widget>[
              SwitchListTile(
                title: const Text('整本下载仅使用非计费网络'),
                subtitle: const Text('移动网络或计费网络下将进入等待策略状态。'),
                value: policy.network == WholeComicNetworkPolicy.unmetered,
                onChanged: (value) => unawaited(
                  widget.downloads.updatePolicy(
                    policy.copyWith(
                      network: value
                          ? WholeComicNetworkPolicy.unmetered
                          : WholeComicNetworkPolicy.any,
                    ),
                  ),
                ),
              ),
              const Divider(),
              const _SettingsSectionTitle('请求标识'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextField(
                  key: const ValueKey<String>('network-user-agent'),
                  controller: _userAgent,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'User-Agent',
                    helperText: '作为通用网络请求的默认 UA；来源明确提供 UA 或 Mihon 浏览器会话 UA 时优先使用来源值。',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _applyUserAgent(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    TextButton(
                      onPressed: _resetUserAgent,
                      child: const Text('恢复 Chrome 默认值'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const ValueKey<String>('network-user-agent-apply'),
                      onPressed: _applyUserAgent,
                      child: const Text('应用'),
                    ),
                  ],
                ),
              ),
              const Divider(),
              const ListTile(
                leading: Icon(Icons.security_outlined),
                title: Text('漫画源网络边界'),
                subtitle: Text(
                  '目录/详情/封面等可重新获取响应必须经过统一缓存；章节正文由 DownloadSession/artifact owner流式处理。来源 Cookie、拦截器和显式 UA不得被全局默认值覆盖。',
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

final class BookshelfSettingsScreen extends StatelessWidget {
  const BookshelfSettingsScreen({required this.preferences, super.key});

  final AppPreferencesController preferences;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: bookshelfSettingsScreenKey,
      appBar: AppBar(title: const Text('书架')),
      body: AnimatedBuilder(
        animation: preferences,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            const _SettingsSectionTitle('默认来源筛选'),
            SegmentedButton<ShelfSourceFilter>(
              showSelectedIcon: false,
              segments: const <ButtonSegment<ShelfSourceFilter>>[
                ButtonSegment(
                  value: ShelfSourceFilter.all,
                  label: Text('全部'),
                ),
                ButtonSegment(
                  value: ShelfSourceFilter.local,
                  label: Text('本地'),
                ),
                ButtonSegment(
                  value: ShelfSourceFilter.remote,
                  label: Text('远程'),
                ),
              ],
              selected: <ShelfSourceFilter>{preferences.shelfSourceFilter},
              onSelectionChanged: (values) =>
                  preferences.setShelfSourceFilter(values.single),
            ),
            const SizedBox(height: 20),
            DropdownButtonFormField<LibrarySortMode>(
              value: preferences.shelfSortMode,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '默认排序',
              ),
              items: <DropdownMenuItem<LibrarySortMode>>[
                for (final mode in LibrarySortMode.values)
                  DropdownMenuItem(
                    value: mode,
                    child: Text(_sortLabel(mode)),
                  ),
              ],
              onChanged: (value) {
                if (value != null) preferences.setShelfSortMode(value);
              },
            ),
            const SizedBox(height: 20),
            const _SettingsSectionTitle('默认视图'),
            SegmentedButton<ShelfViewPreference>(
              showSelectedIcon: false,
              segments: const <ButtonSegment<ShelfViewPreference>>[
                ButtonSegment(
                  value: ShelfViewPreference.gallery,
                  icon: Icon(Icons.grid_view_outlined),
                  label: Text('画廊'),
                ),
                ButtonSegment(
                  value: ShelfViewPreference.list,
                  icon: Icon(Icons.view_list_outlined),
                  label: Text('列表'),
                ),
              ],
              selected: <ShelfViewPreference>{preferences.shelfView},
              onSelectionChanged: (values) =>
                  preferences.setShelfView(values.single),
            ),
          ],
        ),
      ),
    );
  }
}

final class ReadingSettingsScreen extends StatelessWidget {
  const ReadingSettingsScreen({required this.preferences, super.key});

  final AppPreferencesController preferences;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: readingSettingsScreenKey,
      appBar: AppBar(title: const Text('阅读')),
      body: AnimatedBuilder(
        animation: preferences,
        builder: (context, _) => ListView(
          children: <Widget>[
            const _SettingsSectionTitle('新章节默认行为'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<ReaderMode>(
                showSelectedIcon: false,
                segments: const <ButtonSegment<ReaderMode>>[
                  ButtonSegment(
                    value: ReaderMode.paged,
                    icon: Icon(Icons.menu_book_outlined),
                    label: Text('分页'),
                  ),
                  ButtonSegment(
                    value: ReaderMode.continuous,
                    icon: Icon(Icons.view_day_outlined),
                    label: Text('连续'),
                  ),
                ],
                selected: <ReaderMode>{preferences.defaultReaderMode},
                onSelectionChanged: (values) =>
                    preferences.setDefaultReaderMode(values.single),
              ),
            ),
            SwitchListTile(
              title: const Text('默认沉浸阅读'),
              subtitle: const Text('打开 Reader 时隐藏系统栏和控制栏；点击页面仍可呼出控制。'),
              value: preferences.readerStartsImmersive,
              onChanged: preferences.setReaderStartsImmersive,
            ),
            SwitchListTile(
              key: readingAdaptiveKey,
              title: const Text('自适应阅读布局'),
              subtitle: const Text(
                '依据来源方向、页面宽高与动画提示选择分页或纵向；'
                '低置信度时保持既有默认。',
              ),
              value: preferences.adaptiveReaderEnabled,
              onChanged: preferences.setAdaptiveReaderEnabled,
            ),
            SwitchListTile(
              key: readingVerticalStitchKey,
              title: const Text('纵向拼接'),
              subtitle: const Text('纵向连续模式移除页间距；不合并页面文件或缓存身份。'),
              value: preferences.defaultVerticalStitch,
              onChanged: preferences.setDefaultVerticalStitch,
            ),
            ListTile(
              key: readingPreviewMaxItemsPerRowKey,
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('详情页预览每行最多数量'),
              subtitle: Slider(
                min: 1,
                max: 8,
                divisions: 7,
                label: '${preferences.detailsPreviewMaxItemsPerRow}',
                value: preferences.detailsPreviewMaxItemsPerRow.toDouble(),
                onChanged: (value) =>
                    preferences.setDetailsPreviewMaxItemsPerRow(value.round()),
              ),
              trailing: Text('${preferences.detailsPreviewMaxItemsPerRow}'),
            ),
            const ListTile(
              leading: Icon(Icons.swap_horiz),
              title: Text('分页方向'),
              subtitle: Text('分页模式继续尊重漫画源或本地元数据中的 LTR / RTL 方向。'),
            ),
          ],
        ),
      ),
    );
  }
}

final class DownloadSettingsScreen extends StatelessWidget {
  const DownloadSettingsScreen({required this.downloads, super.key});

  final WholeComicDownloadQueue downloads;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: downloadSettingsScreenKey,
      appBar: AppBar(title: const Text('下载')),
      body: StreamBuilder<WholeComicQueueSnapshot>(
        stream: downloads.changes,
        initialData: downloads.snapshot,
        builder: (context, snapshot) {
          final policy = snapshot.requireData.policy;
          return ListView(
            children: <Widget>[
              ListTile(
                title: const Text('整本下载并发'),
                subtitle: Slider(
                  min: 1,
                  max: 4,
                  divisions: 3,
                  label: '${policy.concurrency}',
                  value: policy.concurrency.toDouble(),
                  onChanged: (value) => unawaited(
                    downloads.updatePolicy(
                      policy.copyWith(concurrency: value.round()),
                    ),
                  ),
                ),
                trailing: Text('${policy.concurrency}'),
              ),
              SwitchListTile(
                title: const Text('仅充电时下载'),
                value: policy.power == WholeComicPowerPolicy.charging,
                onChanged: (value) => unawaited(
                  downloads.updatePolicy(
                    policy.copyWith(
                      power: value
                          ? WholeComicPowerPolicy.charging
                          : WholeComicPowerPolicy.any,
                    ),
                  ),
                ),
              ),
              const ListTile(
                leading: Icon(Icons.layers_outlined),
                title: Text('章节下载'),
                subtitle: Text(
                  '章节下载继续复用统一 page artifact 与插件 source transport，'
                  '不建立第二套下载缓存。',
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

final class AppearanceSettingsScreen extends StatelessWidget {
  const AppearanceSettingsScreen({required this.preferences, super.key});

  final AppPreferencesController preferences;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: appearanceSettingsScreenKey,
      appBar: AppBar(title: const Text('外观')),
      body: AnimatedBuilder(
        animation: preferences,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            const _SettingsSectionTitle('主题'),
            SegmentedButton<ThemeMode>(
              showSelectedIcon: false,
              segments: const <ButtonSegment<ThemeMode>>[
                ButtonSegment(value: ThemeMode.system, label: Text('系统')),
                ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
                ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
              ],
              selected: <ThemeMode>{preferences.themeMode},
              onSelectionChanged: (values) =>
                  preferences.setThemeMode(values.single),
            ),
            const SizedBox(height: 16),
            const Text('主题切换立即作用于整个应用，并持久化到应用数据目录。'),
          ],
        ),
      ),
    );
  }
}

final class _SettingsEntry extends StatelessWidget {
  const _SettingsEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

final class _SettingsSectionTitle extends StatelessWidget {
  const _SettingsSectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(title, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}

final class _DirectoryTile extends StatelessWidget {
  const _DirectoryTile({required this.title, required this.path});

  final String title;
  final String? path;

  @override
  Widget build(BuildContext context) {
    final value = path ?? '当前使用内存服务';
    return ListTile(
      leading: const Icon(Icons.folder_outlined),
      title: Text(title),
      subtitle: Text(value),
      trailing: path == null
          ? null
          : IconButton(
              tooltip: '复制路径',
              onPressed: () {
                unawaited(Clipboard.setData(ClipboardData(text: path!)));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('路径已复制')),
                );
              },
              icon: const Icon(Icons.copy_outlined),
            ),
    );
  }
}

String _sortLabel(LibrarySortMode mode) => switch (mode) {
      LibrarySortMode.recent => '最近更新',
      LibrarySortMode.title => '标题',
      LibrarySortMode.pageCount => '页数',
      LibrarySortMode.custom => '自定义排序',
    };

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kib = bytes / 1024;
  if (kib < 1024) return '${kib.toStringAsFixed(1)} KiB';
  final mib = kib / 1024;
  if (mib < 1024) return '${mib.toStringAsFixed(1)} MiB';
  return '${(mib / 1024).toStringAsFixed(2)} GiB';
}
