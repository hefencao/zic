import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reader/reader.dart';
import 'package:resource_cache/resource_cache.dart';
import 'startup_platform.dart';
import 'package:storage_bridge/storage_bridge.dart';

import 'dialog_actions.dart';

import 'app_preferences.dart';
import 'directory_picker.dart';

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
const appearanceAmoledKey = ValueKey<String>('appearance-amoled');
const dataBackupExportKey = ValueKey<String>('data-backup-export');
const dataCacheClearKey = ValueKey<String>('data-cache-clear');
const dataCacheRefreshKey = ValueKey<String>('data-cache-refresh');
const dataDownloadDirectoryKey = ValueKey<String>('data-download-directory');
const dataCacheLimitKey = ValueKey<String>('data-cache-limit');
const readingAdaptiveKey = ValueKey<String>('reading-adaptive');
const readingVerticalStitchKey =
    ValueKey<String>('reading-vertical-stitch');
const readingZoomStageFirstKey =
    ValueKey<String>('reading-zoom-stage-first');
const readingZoomStageSecondKey =
    ValueKey<String>('reading-zoom-stage-second');
const readingLongPressZoomKey =
    ValueKey<String>('reading-long-press-zoom');
const readingLongPressZoomRestoreKey =
    ValueKey<String>('reading-long-press-zoom-restore');
const readingLongPressZoomMoveModeKey =
    ValueKey<String>('reading-long-press-zoom-move-mode');
const readingDoubleTapZoomOriginKey =
    ValueKey<String>('reading-double-tap-zoom-origin');
const readingLongPressZoomPanRatioKey =
    ValueKey<String>('reading-long-press-zoom-pan-ratio');
const readingLongPressZoomLimitKey =
    ValueKey<String>('reading-long-press-zoom-limit');
const readingZoomDecodeBoostKey =
    ValueKey<String>('reading-zoom-decode-boost');
const readingPreviewMaxItemsPerRowKey =
    ValueKey<String>('reading-preview-max-items-per-row');

final class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    required this.preferences,
    required this.downloads,
    required this.cacheCoordinator,
    required this.exportBackup,
    this.storageRoot,
    this.onChangeChapterDownloadDirectory,
    super.key,
  });

  final AppPreferencesController preferences;
  final WholeComicDownloadQueue downloads;
  final ResourceCacheCoordinator cacheCoordinator;
  final Future<String?> Function() exportBackup;
  final String? storageRoot;
  final Future<String?> Function({
    String? directory,
    required bool migrateFiles,
  })? onChangeChapterDownloadDirectory;

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
                preferences: preferences,
                storageRoot: storageRoot,
                cacheCoordinator: cacheCoordinator,
                exportBackup: exportBackup,
                onChangeChapterDownloadDirectory:
                    onChangeChapterDownloadDirectory,
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
            subtitle: '跟随系统、浅色、深色或 AMOLED',
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
    required this.preferences,
    required this.cacheCoordinator,
    required this.exportBackup,
    this.storageRoot,
    this.onChangeChapterDownloadDirectory,
    super.key,
  });

  final AppPreferencesController preferences;
  final String? storageRoot;
  final ResourceCacheCoordinator cacheCoordinator;
  final Future<String?> Function() exportBackup;
  final Future<String?> Function({
    String? directory,
    required bool migrateFiles,
  })? onChangeChapterDownloadDirectory;

  @override
  State<DataSettingsScreen> createState() => _DataSettingsScreenState();
}

final class _DataSettingsScreenState extends State<DataSettingsScreen> {
  ResourceCacheUsage? _usage;
  Object? _failure;
  bool _busy = false;
  bool _changingDownloadDirectory = false;

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

  String? get _effectiveDownloadDirectory {
    final root = widget.storageRoot;
    if (root == null) return null;
    final override = widget.preferences.chapterDownloadDirectoryOverride;
    return override ?? defaultChapterDownloadDirectory(root);
  }

  /// One-row download-directory setting: the tile itself shows the effective
  /// path and opens the picker; unlike Venera there is no second display row.
  Future<void> _changeDownloadDirectory() async {
    if (_changingDownloadDirectory) return;
    if (widget.onChangeChapterDownloadDirectory == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('下载服务尚未就绪，请稍后重试')),
      );
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    String? picked;
    try {
      picked = await pickDirectory();
    } on Object catch (error) {
      debugPrint('directory picker failed: $error');
      messenger.showSnackBar(
        SnackBar(content: Text('无法打开目录选择器：$error')),
      );
      return;
    }
    if (!mounted || picked == null || picked.isEmpty) return;
    // SAF trees bypass the Venera old/new-file rules entirely: the tree IS
    // the store root, nothing needs creating, and writability comes from the
    // persisted document-tree grant rather than a POSIX probe.
    final safPicked = picked.startsWith('content://')
        ? 'saf://$picked'
        : null;
    String target;
    if (safPicked != null) {
      target = safPicked;
    } else if (picked.startsWith('saf://')) {
      target = picked;
    } else {
      try {
        // The preview must not create anything on disk — a cancelled dialog
        // would otherwise leave empty offline_chapters(N) directories.
        target = await resolveChapterDownloadDirectory(picked, create: false);
      } on Object catch (error) {
        debugPrint('download directory resolve failed: $error');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法使用所选目录')),
        );
        return;
      }
    }
    if (!mounted) return;
    final migrate = await _confirmDownloadDirectoryChange(target);
    if (!mounted || migrate == null) return;
    await _applyDownloadDirectoryChange(
      directory: picked,
      migrateFiles: migrate,
      successMessage: '下载目录已更新',
    );
  }

  /// Trailing reset control: restores the in-app default store location by
  /// reusing the same confirmation + move flow as an explicit change.
  Future<void> _resetDownloadDirectory() async {
    if (_changingDownloadDirectory) return;
    final root = widget.storageRoot;
    if (widget.onChangeChapterDownloadDirectory == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('下载服务尚未就绪，请稍后重试')),
      );
      return;
    }
    if (root == null) return;
    final target = defaultChapterDownloadDirectory(root);
    final migrate = await _confirmDownloadDirectoryChange(
      target,
      title: '重置默认下载目录',
    );
    if (!mounted || migrate == null) return;
    await _applyDownloadDirectoryChange(
      directory: null,
      migrateFiles: migrate,
      successMessage: '已恢复默认下载目录',
    );
  }

  Future<void> _applyDownloadDirectoryChange({
    required String? directory,
    required bool migrateFiles,
    required String successMessage,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _changingDownloadDirectory = true);
    String? failure;
    try {
      failure = await widget.onChangeChapterDownloadDirectory!(
        directory: directory,
        migrateFiles: migrateFiles,
      );
      // Scoped storage rejects POSIX writes on shared storage until the user
      // grants All-files-access. Offer the system toggle once, then retry the
      // exact same change after they return.
      if (failure != null && failure.contains('所选目录不可写')) {
        final granted = await _offerAllFilesAccess();
        if (granted) {
          failure = await widget.onChangeChapterDownloadDirectory!(
            directory: directory,
            migrateFiles: migrateFiles,
          );
        }
      }
    } finally {
      if (mounted) setState(() => _changingDownloadDirectory = false);
    }
    messenger.showSnackBar(
      SnackBar(content: Text(failure ?? successMessage)),
    );
    if (failure == null && mounted) {
      await _refreshUsage();
    }
  }

  /// Shows the storage-permission guide. Returns true when the user chose to
  /// open the system page (and has now returned), signalling a retry.
  Future<bool> _offerAllFilesAccess() async {
    final retry = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('需要"所有文件访问"权限'),
        content: const Text(
          '所选目录位于共享存储或 SD 卡，Android 11+ 默认禁止应用直接写入文件。'
          '授予"所有文件访问"后即可把下载目录设到这里。\n\n'
          '点击"去授权"跳转系统开关，开启后返回本页会自动重试。',
        ),
        actions: <Widget>[
          AppDialogActions(
            onClose: () => Navigator.pop(dialogContext, false),
            actions: <Widget>[
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('去授权'),
              ),
            ],
          ),
        ],
      ),
    );
    if (retry != true) {
      return false;
    }
    return openAllFilesAccessSettings();
  }

  /// Returns whether to migrate files (null = cancelled).
  Future<bool?> _confirmDownloadDirectoryChange(
    String target, {
    String title = '设置默认下载目录',
  }) {
    final isSaf = target.startsWith('saf://');
    var migrate = !isSaf;
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(target),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('迁移已下载文件'),
                subtitle: Text(
                  isSaf
                      ? 'SAF 目录暂不支持跨存储方案自动搬运文件；旧下载将保留在原目录。'
                      : '索引与文件一起移动；不迁移时旧下载保留在原目录，'
                          '应用内会显示为未下载。',
                ),
                value: isSaf ? false : migrate,
                onChanged: isSaf
                    ? null
                    : (value) =>
                        setDialogState(() => migrate = value ?? false),
              ),
            ],
          ),
          actions: <Widget>[
            AppDialogActions(
              onClose: () => Navigator.pop(dialogContext, null),
              actions: <Widget>[
                FilledButton(
                  onPressed: () =>
                      Navigator.pop(dialogContext, isSaf ? false : migrate),
                  child: const Text('设置'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editCacheLimit() async {
    final controller = TextEditingController(
      text: '${widget.preferences.cacheLimitMb}',
    );
    final confirmed = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('设置缓存上限'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly,
          ],
          decoration: const InputDecoration(
            labelText: '大小（MB）',
            helperText:
                '范围 $minCacheLimitMb–$maxCacheLimitMb MB；超过后自动清理最久未用的页面缓存。',
            border: OutlineInputBorder(),
          ),
        ),
        actions: <Widget>[
          AppDialogActions(
            onClose: () => Navigator.pop(dialogContext, null),
            actions: <Widget>[
              FilledButton(
                onPressed: () {
                  final value = int.tryParse(controller.text);
                  Navigator.pop(
                    dialogContext,
                    value?.clamp(0, 1 << 30).toInt(),
                  );
                },
                child: const Text('设置'),
              ),
            ],
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || confirmed == null) return;
    setState(() => _busy = true);
    try {
      widget.preferences.setCacheLimitMb(confirmed);
      widget.cacheCoordinator.updateMaintenancePolicy(
        ResourceCacheMaintenancePolicy.forArtifactLimitBytes(
          widget.preferences.cacheLimitMb * 1024 * 1024,
        ),
      );
      // Enforce the new limit immediately instead of waiting for the next
      // scheduled maintenance pass.
      final report = await widget.cacheCoordinator.trim();
      await _refreshUsageQuietly();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            report.totalReleasedBytes > 0
                ? '缓存上限已设为 ${widget.preferences.cacheLimitMb} MB，'
                    '已释放 ${_formatBytes(report.totalReleasedBytes)}'
                : '缓存上限已设为 ${widget.preferences.cacheLimitMb} MB',
          ),
        ),
      );
    } on Object catch (error) {
      if (mounted) setState(() => _failure = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshUsageQuietly() async {
    try {
      final usage = await widget.cacheCoordinator.inspect();
      if (mounted) setState(() => _usage = usage);
    } on Object catch (error) {
      if (mounted) setState(() => _failure = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final root = widget.storageRoot;
    final downloadDirectory = _effectiveDownloadDirectory;
    return Scaffold(
      key: dataSettingsScreenKey,
      appBar: AppBar(title: const Text('数据')),
      body: AnimatedBuilder(
        animation: widget.preferences,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: <Widget>[
            const _SettingsSectionTitle('目录'),
            _DirectoryTile(
              title: '应用数据目录',
              path: root,
            ),
            ListTile(
              key: dataDownloadDirectoryKey,
              enabled: !_changingDownloadDirectory,
              leading: const Icon(Icons.folder_special_outlined),
              title: const Text('默认下载目录'),
              subtitle: Text(
                downloadDirectory == null
                    ? '当前使用内存服务'
                    : widget.onChangeChapterDownloadDirectory == null
                        ? '$downloadDirectory\n下载服务未运行，下载不会写入磁盘'
                        : downloadDirectory,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: _changingDownloadDirectory
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : widget.preferences.chapterDownloadDirectoryOverride != null
                      ? TextButton(
                          onPressed: _resetDownloadDirectory,
                          child: const Text('重置默认'),
                        )
                      : const Icon(Icons.edit_outlined),
              onTap: _changeDownloadDirectory,
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
              child: Text(
                '更改下载目录时索引与文件一起迁移；'
                '不允许只改字符串路径。',
              ),
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
              key: dataCacheLimitKey,
              enabled: !_busy && root != null,
              leading: const Icon(Icons.speed_outlined),
              title: const Text('缓存上限'),
              subtitle: Text(
                '${widget.preferences.cacheLimitMb} MB · '
                '超出后自动清理最久未使用的页面缓存',
              ),
              trailing: const Icon(Icons.edit_outlined),
              onTap: _busy ? null : _editCacheLimit,
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
            const _SettingsSectionTitle('缩放'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: DropdownButtonFormField<double>(
                      key: readingZoomStageFirstKey,
                      initialValue: preferences.defaultZoomStageFirst,
                      decoration: const InputDecoration(
                        labelText: '双击放大 · 一级',
                      ),
                      items: const <double>[1.5, 2.0, 2.5, 3.0]
                          .map<DropdownMenuItem<double>>(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text('${value}x'),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          preferences.setDefaultZoomStageFirst(value);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<double>(
                      key: readingZoomStageSecondKey,
                      initialValue: preferences.defaultZoomStageSecond,
                      decoration: const InputDecoration(
                        labelText: '双击放大 · 二级',
                      ),
                      items: const <double>[2.0, 2.5, 3.0, 4.0, 5.0, 6.0]
                          .map<DropdownMenuItem<double>>(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text('${value}x'),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          preferences.setDefaultZoomStageSecond(value);
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
            SwitchListTile(
              key: readingLongPressZoomKey,
              title: const Text('长按放大（分页模式）'),
              subtitle: const Text('长按后随手指拖动查看细节；连续模式需在本漫画设置中单独开启。'),
              value: preferences.longPressZoomEnabled,
              onChanged: preferences.setLongPressZoomEnabled,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButtonFormField<ReaderDoubleTapZoomOrigin>(
                key: readingDoubleTapZoomOriginKey,
                initialValue: preferences.doubleTapZoomOrigin,
                decoration: const InputDecoration(
                  labelText: '双击放大图片位置',
                  helperText: '居中：以屏幕中心放大；吸附：按点击侧贴齐边缘；聚焦：以点击位置为中心。',
                  border: OutlineInputBorder(),
                ),
                items: const <DropdownMenuItem<ReaderDoubleTapZoomOrigin>>[
                  DropdownMenuItem(
                    value: ReaderDoubleTapZoomOrigin.center,
                    child: Text('居中'),
                  ),
                  DropdownMenuItem(
                    value: ReaderDoubleTapZoomOrigin.snap,
                    child: Text('吸附'),
                  ),
                  DropdownMenuItem(
                    value: ReaderDoubleTapZoomOrigin.focus,
                    child: Text('聚焦'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    preferences.setDoubleTapZoomOrigin(value);
                  }
                },
              ),
            ),
            SwitchListTile(
              key: readingLongPressZoomRestoreKey,
              title: const Text('长按放大松手复原'),
              subtitle: const Text(
                '松手后恢复原始大小；关闭后保持放大，'
                '双击页面或切换页面退出。',
              ),
              value: preferences.longPressZoomRestoreOnRelease,
              onChanged: preferences.setLongPressZoomRestoreOnRelease,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButtonFormField<ReaderLongPressMoveMode>(
                key: readingLongPressZoomMoveModeKey,
                initialValue: preferences.longPressZoomMoveMode,
                decoration: const InputDecoration(
                  labelText: '长按放大移动方式',
                  helperText: '拖动：内容跟随手指移动；聚焦：手指作为放大镜位置。',
                  border: OutlineInputBorder(),
                ),
                items: const <DropdownMenuItem<ReaderLongPressMoveMode>>[
                  DropdownMenuItem(
                    value: ReaderLongPressMoveMode.drag,
                    child: Text('拖动'),
                  ),
                  DropdownMenuItem(
                    value: ReaderLongPressMoveMode.focus,
                    child: Text('聚焦'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    preferences.setLongPressZoomMoveMode(value);
                  }
                },
              ),
            ),
            ListTile(
              key: readingLongPressZoomPanRatioKey,
              title: const Text('长按放大拖动比率'),
              subtitle: Slider(
                min: 0.25,
                max: 3,
                divisions: 11,
                label:
                    '${preferences.longPressZoomPanRatio.toStringAsFixed(2)}x',
                value: preferences.longPressZoomPanRatio.clamp(0.25, 3).toDouble(),
                onChanged: preferences.setLongPressZoomPanRatio,
              ),
              trailing: Text(
                '${preferences.longPressZoomPanRatio.toStringAsFixed(2)}x',
              ),
            ),
            SwitchListTile(
              key: readingLongPressZoomLimitKey,
              title: const Text('放大拖动限制在可视范围'),
              subtitle: const Text(
                '顶部超出上边界时底部不得超出下边界；'
                '关闭后可自由把页面拖出屏幕。',
              ),
              value: preferences.longPressZoomLimitToViewport,
              onChanged: preferences.setLongPressZoomLimitToViewport,
            ),
            SwitchListTile(
              key: readingZoomDecodeBoostKey,
              title: const Text('放大时提升解码分辨率'),
              subtitle: const Text(
                '仅对可视区域涉及的页面按当前倍率提高解码尺寸，'
                '不超过原图分辨率。',
              ),
              value: preferences.zoomDecodeBoostEnabled,
              onChanged: preferences.setZoomDecodeBoostEnabled,
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
            const SizedBox(height: 8),
            SwitchListTile(
              key: appearanceAmoledKey,
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.brightness_1_outlined),
              title: const Text('AMOLED 纯黑'),
              subtitle: const Text('深色模式使用纯黑背景，适合 OLED 屏幕'),
              value: preferences.amoledDarkTheme,
              onChanged: preferences.setAmoledDarkTheme,
            ),
            const SizedBox(height: 16),
            const Text(
              '主题切换立即作用于整个应用，并持久化到应用数据目录。'
              'AMOLED 仅在深色模式生效。',
            ),
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
