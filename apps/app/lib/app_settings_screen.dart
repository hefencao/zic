import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reader/reader.dart';
import 'package:reader_runtime/reader_runtime.dart';
import 'package:resource_cache/resource_cache.dart';
import 'startup_platform.dart';
import 'package:storage_bridge/storage_bridge.dart';

import 'dialog_actions.dart';

import 'app_preferences.dart';
import 'comic_translation_settings_screen.dart';
import 'chapter_download_directory.dart';
import 'directory_picker.dart';
import 'diagnostic_error_ui.dart';

const settingsScreenKey = ValueKey<String>('settings-screen');
const settingsDataEntryKey = ValueKey<String>('settings-data-entry');
const settingsNetworkEntryKey = ValueKey<String>('settings-network-entry');
const settingsBookshelfEntryKey =
    ValueKey<String>('settings-bookshelf-entry');
const settingsReadingEntryKey = ValueKey<String>('settings-reading-entry');
const settingsDownloadEntryKey = ValueKey<String>('settings-download-entry');
const settingsAppearanceEntryKey =
    ValueKey<String>('settings-appearance-entry');
const settingsDebugModeKey = ValueKey<String>('settings-debug-mode');
const dataSettingsScreenKey = ValueKey<String>('data-settings-screen');
const networkSettingsScreenKey = ValueKey<String>('network-settings-screen');
const networkReaderPrefetchBudgetKey =
    ValueKey<String>('network-reader-prefetch-budget');
const networkCachedCarrierTrustKey =
    ValueKey<String>('network-cached-carrier-trust');
const networkCachedCarrierConflictTrustKey =
    ValueKey<String>('network-cached-carrier-conflict-trust');
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
const dataFileAccessSettingsKey = ValueKey<String>('data-file-access-settings');
const dataCacheLimitKey = ValueKey<String>('data-cache-limit');
const readingAdaptiveKey = ValueKey<String>('reading-adaptive');
const readingPagedDirectionKey =
    ValueKey<String>('reading-paged-direction');
const readingShowStatusBarKey =
    ValueKey<String>('reading-show-status-bar');
const readingVerticalStitchKey =
    ValueKey<String>('reading-vertical-stitch');
const readingZoomStageFirstKey =
    ValueKey<String>('reading-zoom-stage-first');
const readingZoomStageSecondKey =
    ValueKey<String>('reading-zoom-stage-second');
const readingLongPressZoomKey =
    ValueKey<String>('reading-long-press-zoom');
const readingLongPressZoomScaleKey =
    ValueKey<String>('reading-long-press-zoom-scale');
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
const readingPagedContinuousReadingKey =
    ValueKey<String>('reading-paged-continuous-reading');
const readingContinuousContinuousReadingKey =
    ValueKey<String>('reading-continuous-continuous-reading');
const readingContinuousZoomStageFirstKey =
    ValueKey<String>('reading-continuous-zoom-stage-first');
const readingContinuousZoomStageSecondKey =
    ValueKey<String>('reading-continuous-zoom-stage-second');
const readingContinuousLongPressZoomKey =
    ValueKey<String>('reading-continuous-long-press-zoom');
const readingContinuousLongPressZoomScaleKey =
    ValueKey<String>('reading-continuous-long-press-zoom-scale');
const readingContinuousLongPressZoomMoveModeKey =
    ValueKey<String>('reading-continuous-long-press-zoom-move-mode');
const readingContinuousDoubleTapZoomOriginKey =
    ValueKey<String>('reading-continuous-double-tap-zoom-origin');
const readingContinuousLongPressZoomPanRatioKey =
    ValueKey<String>('reading-continuous-long-press-zoom-pan-ratio');
const readingContinuousLongPressZoomLimitKey =
    ValueKey<String>('reading-continuous-long-press-zoom-limit');
const readingContinuousZoomDecodeBoostKey =
    ValueKey<String>('reading-continuous-zoom-decode-boost');
const readingPreviewMaxItemsPerRowKey =
    ValueKey<String>('reading-preview-max-items-per-row');

final class WholeComicPolicySettingsBinding {
  const WholeComicPolicySettingsBinding({
    required this.changes,
    required this.readSnapshot,
    required this.updatePolicy,
  });

  final Listenable changes;
  final WholeComicQueueSnapshot Function() readSnapshot;
  final Future<void> Function(WholeComicQueuePolicy policy) updatePolicy;
}

final class DataSettingsCacheMutationResult {
  const DataSettingsCacheMutationResult({
    required this.report,
    required this.usage,
  });

  final ResourceCacheMaintenanceReport report;
  final ResourceCacheUsage usage;
}

final class DataSettingsRuntimeBinding {
  const DataSettingsRuntimeBinding({
    required this.changes,
    required this.readStorageRoot,
    required this.canChangeChapterDownloadDirectory,
    required this.changeChapterDownloadDirectory,
    required this.inspectCache,
    required this.clearCache,
    required this.updateCachePolicyAndTrim,
  });

  final Listenable changes;
  final String? Function() readStorageRoot;
  final bool Function() canChangeChapterDownloadDirectory;
  final Future<String?> Function({
    String? directory,
    required bool migrateFiles,
  }) changeChapterDownloadDirectory;
  final Future<ResourceCacheUsage> Function() inspectCache;
  final Future<DataSettingsCacheMutationResult> Function() clearCache;
  final Future<DataSettingsCacheMutationResult> Function(
    ResourceCacheMaintenancePolicy policy,
  ) updateCachePolicyAndTrim;
}

final class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    required this.preferences,
    required this.downloadPolicy,
    required this.dataRuntime,
    required this.exportBackup,
    super.key,
  });

  final AppPreferencesController preferences;
  final WholeComicPolicySettingsBinding downloadPolicy;
  final DataSettingsRuntimeBinding dataRuntime;
  final Future<String?> Function() exportBackup;

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
                runtime: dataRuntime,
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
                policyBinding: downloadPolicy,
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
            subtitle: '布局、界面与阅读操作',
            onTap: () => _push(
              context,
              ReadingSettingsScreen(preferences: preferences),
            ),
          ),
          _SettingsEntry(
            key: const ValueKey('settings-translation-entry'),
            icon: Icons.translate,
            title: '翻译模型与 API',
            subtitle: 'OCR、本地翻译与远程 API',
            onTap: () => _push(context, const ComicTranslationSettingsScreen()),
          ),
          _SettingsEntry(
            key: settingsDownloadEntryKey,
            icon: Icons.download_outlined,
            title: '下载',
            subtitle: '并发、网络与供电策略',
            onTap: () => _push(
              context,
              DownloadSettingsScreen(policyBinding: downloadPolicy),
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
          const Divider(height: 24),
          AnimatedBuilder(
            animation: preferences,
            builder: (context, _) => SwitchListTile(
              key: settingsDebugModeKey,
              secondary: const Icon(Icons.developer_mode_outlined),
              title: const Text('Debug 模式'),
              subtitle: const Text('显示 Trace、媒体诊断与测试入口'),
              value: preferences.debugModeEnabled,
              onChanged: preferences.setDebugModeEnabled,
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
    required this.runtime,
    required this.exportBackup,
    super.key,
  });

  final AppPreferencesController preferences;
  final DataSettingsRuntimeBinding runtime;
  final Future<String?> Function() exportBackup;

  @override
  State<DataSettingsScreen> createState() => _DataSettingsScreenState();
}

final class _DataSettingsScreenState extends State<DataSettingsScreen>
    with WidgetsBindingObserver {
  ResourceCacheUsage? _usage;
  Object? _failure;
  bool _busy = false;
  bool _changingDownloadDirectory = false;
  bool? _allFilesAccessGranted;
  bool _openingFileAccessSettings = false;
  bool _runtimeRefreshPending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.runtime.changes.addListener(_handleRuntimeChanged);
    unawaited(_refreshUsage());
    unawaited(_refreshFileAccessStatus());
  }

  @override
  void didUpdateWidget(DataSettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.runtime, widget.runtime)) {
      oldWidget.runtime.changes.removeListener(_handleRuntimeChanged);
      widget.runtime.changes.addListener(_handleRuntimeChanged);
      _handleRuntimeChanged();
    }
  }

  @override
  void dispose() {
    widget.runtime.changes.removeListener(_handleRuntimeChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _handleRuntimeChanged() {
    if (!mounted) return;
    setState(() => _runtimeRefreshPending = true);
    if (!_busy) {
      unawaited(_refreshUsage());
    }
  }

  void _finishBusy() {
    if (!mounted) return;
    setState(() => _busy = false);
    if (_runtimeRefreshPending) {
      unawaited(_refreshUsage());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshFileAccessStatus());
    }
  }

  Future<void> _refreshFileAccessStatus() async {
    final granted = await allFilesAccessGranted();
    if (!mounted || _allFilesAccessGranted == granted) return;
    setState(() => _allFilesAccessGranted = granted);
  }

  Future<void> _openFileAccessSettings() async {
    if (_openingFileAccessSettings) return;
    setState(() => _openingFileAccessSettings = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final opened = await openAllFilesAccessSettings();
      if (!mounted) return;
      if (!opened) {
        messenger.showSnackBar(
          const SnackBar(content: Text('当前平台没有可用的“所有文件访问”设置页')),
        );
      }
    } finally {
      if (mounted) setState(() => _openingFileAccessSettings = false);
    }
  }

  Future<void> _refreshUsage() async {
    if (_busy) {
      _runtimeRefreshPending = true;
      return;
    }
    _runtimeRefreshPending = false;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final usage = await widget.runtime.inspectCache();
      if (mounted) setState(() => _usage = usage);
    } on Object catch (error) {
      if (mounted) setState(() => _failure = error);
    } finally {
      _finishBusy();
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
      final result = await widget.runtime.clearCache();
      if (!mounted) return;
      setState(() => _usage = result.usage);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已释放 ${_formatBytes(result.report.totalReleasedBytes)}',
          ),
        ),
      );
    } on Object catch (error) {
      if (mounted) setState(() => _failure = error);
    } finally {
      _finishBusy();
    }
  }

  Future<void> _exportBackup() async {
    setState(() {
      _busy = true;
    });
    try {
      final path = await widget.exportBackup();
      if (!mounted || path == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('备份已导出：$path')),
      );
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          copyableDiagnosticSnackBar('备份导出失败：$error'),
        );
      }
    } finally {
      _finishBusy();
    }
  }

  String? get _effectiveDownloadDirectory {
    final root = widget.runtime.readStorageRoot();
    if (root == null) return null;
    final pendingSource =
        widget.preferences.chapterDownloadDirectoryPendingMoveFrom;
    if (pendingSource != null) return pendingSource;
    final override = widget.preferences.chapterDownloadDirectoryOverride;
    return override ?? defaultChapterDownloadDirectory(root);
  }

  /// One-row download-directory setting: the tile itself shows the effective
  /// path and opens the picker; unlike Venera there is no second display row.
  Future<void> _changeDownloadDirectory() async {
    if (_changingDownloadDirectory) return;
    if (!widget.runtime.canChangeChapterDownloadDirectory()) {
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
        copyableDiagnosticSnackBar('无法打开目录选择器：$error'),
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
    final root = widget.runtime.readStorageRoot();
    if (!widget.runtime.canChangeChapterDownloadDirectory()) {
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
      failure = await widget.runtime.changeChapterDownloadDirectory(
        directory: directory,
        migrateFiles: migrateFiles,
      );
      // Scoped storage rejects POSIX writes on shared storage until the user
      // grants All-files-access. Offer the system toggle once, then retry the
      // exact same change after they return.
      if (failure != null && failure.contains('所选目录不可写')) {
        final granted = await _offerAllFilesAccess();
        if (granted) {
          failure = await widget.runtime.changeChapterDownloadDirectory(
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
    final current = _effectiveDownloadDirectory;
    final crossesSafBoundary = current != null &&
        !chapterDownloadDirectoryMigrationSupported(current, target);
    var migrate = !crossesSafBoundary;
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
                  crossesSafBoundary
                      ? '当前目录或目标目录使用 SAF，暂不支持自动跨存储搬运；'
                          '旧下载将保留在原目录。'
                      : '已下载文件按持久化副本逐个校验并迁移；'
                          '不迁移时旧下载保留在原目录。',
                ),
                value: crossesSafBoundary ? false : migrate,
                onChanged: crossesSafBoundary
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
                      Navigator.pop(
                        dialogContext,
                        crossesSafBoundary ? false : migrate,
                      ),
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
    var draft = '${widget.preferences.cacheLimitMb}';
    final confirmed = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('设置缓存上限'),
        content: TextFormField(
          initialValue: draft,
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
          onChanged: (value) => draft = value,
        ),
        actions: <Widget>[
          AppDialogActions(
            onClose: () => Navigator.pop(dialogContext, null),
            actions: <Widget>[
              FilledButton(
                onPressed: () {
                  final value = int.tryParse(draft);
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
    if (!mounted || confirmed == null) return;
    setState(() => _busy = true);
    try {
      widget.preferences.setCacheLimitMb(confirmed);
      final result = await widget.runtime.updateCachePolicyAndTrim(
        ResourceCacheMaintenancePolicy.forArtifactLimitBytes(
          widget.preferences.cacheLimitMb * 1024 * 1024,
        ),
      );
      if (!mounted) return;
      setState(() => _usage = result.usage);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.report.totalReleasedBytes > 0
                ? '缓存上限已设为 ${widget.preferences.cacheLimitMb} MB，'
                    '已释放 ${_formatBytes(result.report.totalReleasedBytes)}'
                : '缓存上限已设为 ${widget.preferences.cacheLimitMb} MB',
          ),
        ),
      );
    } on Object catch (error) {
      if (mounted) setState(() => _failure = error);
    } finally {
      _finishBusy();
    }
  }

  @override
  Widget build(BuildContext context) {
    final root = widget.runtime.readStorageRoot();
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
                    : !widget.runtime.canChangeChapterDownloadDirectory()
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
            ListTile(
              key: dataFileAccessSettingsKey,
              enabled: !_openingFileAccessSettings,
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('文件读写设置'),
              subtitle: Text(
                _allFilesAccessGranted == null
                    ? '正在读取系统文件访问状态…'
                    : _allFilesAccessGranted!
                        ? '所有文件访问：已授权 · Direct 共享存储/SD 卡可读写；SAF 不依赖此权限'
                        : '所有文件访问：未授权 · Direct 共享存储/SD 卡需要授权；SAF 可直接使用',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: _openingFileAccessSettings
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      _allFilesAccessGranted == true
                          ? Icons.verified_user_outlined
                          : Icons.chevron_right,
                    ),
              onTap: _openingFileAccessSettings ? null : _openFileAccessSettings,
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
    required this.policyBinding,
    required this.preferences,
    super.key,
  });

  final WholeComicPolicySettingsBinding policyBinding;
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

  Future<void> _editReaderPrefetchReadBudget() async {
    var draft = '${widget.preferences.readerPrefetchReadBudgetMiB}';
    final confirmed = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('设置 Reader 预读取上限'),
        content: TextFormField(
          initialValue: draft,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly,
          ],
          decoration: const InputDecoration(
            labelText: '大小（MB）',
            helperText:
                '范围 $minReaderPrefetchReadBudgetMiB–$maxReaderPrefetchReadBudgetMiB MB；只限制后台预下载/本地预读取，当前页不受限。',
            border: OutlineInputBorder(),
          ),
          onChanged: (value) => draft = value,
        ),
        actions: <Widget>[
          AppDialogActions(
            onClose: () => Navigator.pop(dialogContext, null),
            actions: <Widget>[
              FilledButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  int.tryParse(draft),
                ),
                child: const Text('设置'),
              ),
            ],
          ),
        ],
      ),
    );
    if (!mounted || confirmed == null) return;
    widget.preferences.setReaderPrefetchReadBudgetMiB(confirmed);
  }

  String _cachedCarrierTrustLabel(CachedCarrierTrustMode mode) => switch (mode) {
        CachedCarrierTrustMode.strictReload => '直接重新加载',
        CachedCarrierTrustMode.reuseThenRefresh => '先用缓存，后台刷新',
        CachedCarrierTrustMode.trustCached => '信任缓存，不自动刷新',
      };

  String _cachedCarrierTrustDescription(CachedCarrierTrustMode mode) =>
      switch (mode) {
        CachedCarrierTrustMode.strictReload =>
          '当前 URI 没有已验证缓存时直接请求来源。最严格，也可能因来源更换临时 URI 而重复加载。',
        CachedCarrierTrustMode.reuseThenRefresh =>
          '先显示同一页面、同一来源版本下最近的历史缓存；首帧出现后再用当前 URI 后台刷新。',
        CachedCarrierTrustMode.trustCached =>
          '同一页面、同一来源版本已有历史缓存时直接使用，不自动请求当前 URI。来源错误复用版本号时可能看到旧内容。',
      };

  Future<void> _editCachedCarrierTrustMode() async {
    final selected = await showDialog<CachedCarrierTrustMode>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('缓存地址变化策略'),
        children: <Widget>[
          for (final mode in CachedCarrierTrustMode.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, mode),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _cachedCarrierTrustLabel(mode),
                      style: Theme.of(dialogContext).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(_cachedCarrierTrustDescription(mode)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (!mounted || selected == null) return;
    widget.preferences.setCachedCarrierTrustMode(selected);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: networkSettingsScreenKey,
      appBar: AppBar(title: const Text('网络')),
      body: AnimatedBuilder(
        animation: widget.preferences,
        builder: (context, _) => AnimatedBuilder(
          animation: widget.policyBinding.changes,
          builder: (context, _) {
            final policy = widget.policyBinding.readSnapshot().policy;
            return ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: <Widget>[
              SwitchListTile(
                title: const Text('整本下载仅使用非计费网络'),
                subtitle: const Text('移动网络或计费网络下将进入等待策略状态。'),
                value: policy.network == WholeComicNetworkPolicy.unmetered,
                onChanged: (value) => unawaited(
                  widget.policyBinding.updatePolicy(
                    policy.copyWith(
                      network: value
                          ? WholeComicNetworkPolicy.unmetered
                          : WholeComicNetworkPolicy.any,
                    ),
                  ),
                ),
              ),
              ListTile(
                key: networkReaderPrefetchBudgetKey,
                leading: const Icon(Icons.speed_outlined),
                title: const Text('Reader 后台预读取上限'),
                subtitle: const Text(
                  '限制 3/7 预取窗口内实际新增的 encoded bytes；达到上限后暂停下一次读取，当前/可见过渡页直接绕过。',
                ),
                trailing: Text(
                  '${widget.preferences.readerPrefetchReadBudgetMiB} MB',
                ),
                onTap: _editReaderPrefetchReadBudget,
              ),
              ListTile(
                key: networkCachedCarrierTrustKey,
                leading: const Icon(Icons.cached_outlined),
                title: const Text('缓存地址变化策略'),
                subtitle: Text(
                  _cachedCarrierTrustDescription(
                    widget.preferences.cachedCarrierTrustMode,
                  ),
                ),
                trailing: Text(
                  _cachedCarrierTrustLabel(
                    widget.preferences.cachedCarrierTrustMode,
                  ),
                ),
                onTap: _editCachedCarrierTrustMode,
              ),
              SwitchListTile(
                key: networkCachedCarrierConflictTrustKey,
                secondary: const Icon(Icons.verified_user_outlined),
                title: const Text('默认信任完整缓存冲突'),
                subtitle: const Text(
                  '同一页面和来源版本存在多个完整 READY 历史缓存、但长度或 CRC 不一致时，默认允许使用最近的一份。插件可单独覆盖为严格校验或信任；不会把不同正文登记为等价。',
                ),
                value: widget.preferences
                    .trustConflictingHistoricalCarriersByDefault,
                onChanged: widget.preferences
                    .setTrustConflictingHistoricalCarriersByDefault,
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
            const _SettingsSectionTitle('布局'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const Text('默认阅读模式'),
                  const SizedBox(height: 6),
                  SegmentedButton<ReaderMode>(
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
                  const SizedBox(height: 12),
                  const Text('分页方向'),
                  const SizedBox(height: 6),
                  SegmentedButton<ReaderPagedDirectionPreference>(
                    key: readingPagedDirectionKey,
                    showSelectedIcon: false,
                    segments:
                        const <ButtonSegment<ReaderPagedDirectionPreference>>[
                      ButtonSegment(
                        value: ReaderPagedDirectionPreference.ltr,
                        label: Text('LTR'),
                      ),
                      ButtonSegment(
                        value: ReaderPagedDirectionPreference.rtl,
                        label: Text('RTL'),
                      ),
                      ButtonSegment(
                        value: ReaderPagedDirectionPreference.source,
                        label: Text('跟随来源'),
                      ),
                    ],
                    selected: <ReaderPagedDirectionPreference>{
                      preferences.readerPagedDirectionPreference,
                    },
                    onSelectionChanged: (values) =>
                        preferences.setReaderPagedDirectionPreference(
                      values.single,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '默认 LTR；本漫画方向和高置信自适应结果仍可覆盖。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            SwitchListTile(
              key: readingAdaptiveKey,
              title: const Text('自适应阅读'),
              subtitle: const Text(
                '依据来源元数据、页面比例与实测动画能力识别漫画类型，'
                '并共同调整阅读方向、手势等行为；来源可单独调整条漫置信。',
              ),
              value: preferences.adaptiveReaderEnabled,
              onChanged: preferences.setAdaptiveReaderEnabled,
            ),
            const _SettingsSectionTitle('界面'),
            SwitchListTile(
              title: const Text('进入时隐藏阅读控制'),
              subtitle: const Text('打开 Reader 时先隐藏上下控制栏与系统导航栏；点击页面仍可呼出。'),
              value: preferences.readerStartsImmersive,
              onChanged: preferences.setReaderStartsImmersive,
            ),
            Padding(
              key: readingShowStatusBarKey,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const Text('系统状态栏'),
                  const SizedBox(height: 6),
                  SegmentedButton<ReaderSystemStatusBarMode>(
                    showSelectedIcon: false,
                    segments:
                        const <ButtonSegment<ReaderSystemStatusBarMode>>[
                      ButtonSegment(
                        value: ReaderSystemStatusBarMode.show,
                        label: Text('显示'),
                      ),
                      ButtonSegment(
                        value: ReaderSystemStatusBarMode.hide,
                        label: Text('隐藏'),
                      ),
                      ButtonSegment(
                        value: ReaderSystemStatusBarMode.followControls,
                        label: Text('跟随控制栏'),
                      ),
                    ],
                    selected: <ReaderSystemStatusBarMode>{
                      preferences.systemStatusBarMode,
                    },
                    onSelectionChanged: (values) =>
                        preferences.setSystemStatusBarMode(values.single),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '跟随控制栏时，点击页面呼出或收起 Reader 控制栏会同时显示或隐藏顶部状态栏。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            ..._readerModeSettingsTiles(
              context,
              preferences,
              ReaderMode.paged,
            ),
            ..._readerModeSettingsTiles(
              context,
              preferences,
              ReaderMode.continuous,
            ),
          ],
        ),
      ),
    );
  }
}

List<Widget> _readerModeSettingsTiles(
  BuildContext context,
  AppPreferencesController preferences,
  ReaderMode mode,
) {
  final continuous = mode == ReaderMode.continuous;
  final settings = preferences.readerModeSettings(mode);
  void update(ReaderModeSettings value) =>
      preferences.setReaderModeSettings(mode, value);

  final firstKey =
      continuous ? readingContinuousZoomStageFirstKey : readingZoomStageFirstKey;
  final secondKey = continuous
      ? readingContinuousZoomStageSecondKey
      : readingZoomStageSecondKey;
  final originKey = continuous
      ? readingContinuousDoubleTapZoomOriginKey
      : readingDoubleTapZoomOriginKey;
  final longPressKey = continuous
      ? readingContinuousLongPressZoomKey
      : readingLongPressZoomKey;
  final longPressScaleKey = continuous
      ? readingContinuousLongPressZoomScaleKey
      : readingLongPressZoomScaleKey;
  final moveModeKey = continuous
      ? readingContinuousLongPressZoomMoveModeKey
      : readingLongPressZoomMoveModeKey;
  final panRatioKey = continuous
      ? readingContinuousLongPressZoomPanRatioKey
      : readingLongPressZoomPanRatioKey;
  final limitKey = continuous
      ? readingContinuousLongPressZoomLimitKey
      : readingLongPressZoomLimitKey;
  final decodeBoostKey = continuous
      ? readingContinuousZoomDecodeBoostKey
      : readingZoomDecodeBoostKey;

  return <Widget>[
    _SettingsSectionTitle(continuous ? '连续模式' : '分页模式'),
    SwitchListTile(
      key: continuous
          ? readingContinuousContinuousReadingKey
          : readingPagedContinuousReadingKey,
      title: const Text('连续阅读'),
      subtitle: const Text(
        '允许在本章边界继续滑动到相邻章节。只控制 Reader 界面；'
        '相邻章节预加载始终保持开启。',
      ),
      value: settings.crossChapterReading,
      onChanged: (value) =>
          update(settings.copyWith(crossChapterReading: value)),
    ),
    ListTile(
      leading: const Icon(Icons.grid_3x3_outlined),
      title: const Text('点击区域设置'),
      subtitle: Text(
        settings.singleTapPageAnimation
            ? '单击九宫格 · 切页动画开启'
            : '单击九宫格 · 切页动画关闭',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => unawaited(
        _editReaderTapSettings(
          context,
          preferences,
          mode,
          settings,
        ),
      ),
    ),
    if (continuous)
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text('纵向拼接'),
            const SizedBox(height: 6),
            SegmentedButton<bool>(
              key: readingVerticalStitchKey,
              showSelectedIcon: false,
              segments: const <ButtonSegment<bool>>[
                ButtonSegment(value: true, label: Text('拼接')),
                ButtonSegment(value: false, label: Text('保留间距')),
              ],
              selected: <bool>{preferences.defaultVerticalStitch},
              onSelectionChanged: (values) =>
                  preferences.setDefaultVerticalStitch(values.single),
            ),
            const SizedBox(height: 4),
            Text(
              '只改变连续模式的页间视觉间距；不合并页面文件、章节或缓存身份。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Text('双击放大', style: Theme.of(context).textTheme.labelLarge),
    ),
    _readerScaleSlider(
      key: firstKey,
      title: '一级倍率',
      value: settings.zoomStageFirst,
      min: 1.25,
      max: 4,
      divisions: 11,
      onChanged: (value) => update(
        settings.copyWith(
          zoomStages: <double>[
            value,
            settings.zoomStageSecond < value
                ? value
                : settings.zoomStageSecond,
          ],
        ),
      ),
    ),
    _readerScaleSlider(
      key: secondKey,
      title: '二级倍率',
      value: settings.zoomStageSecond,
      min: settings.zoomStageFirst.clamp(1.25, 4).toDouble(),
      max: 8,
      divisions: ((8 -
                  settings.zoomStageFirst.clamp(1.25, 4).toDouble()) *
              4)
          .round(),
      onChanged: (value) => update(
        settings.copyWith(
          zoomStages: <double>[settings.zoomStageFirst, value],
        ),
      ),
    ),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Text('双击放大图片位置'),
          const SizedBox(height: 6),
          SegmentedButton<ReaderDoubleTapZoomOrigin>(
            key: originKey,
            showSelectedIcon: false,
            segments: const <ButtonSegment<ReaderDoubleTapZoomOrigin>>[
              ButtonSegment(
                value: ReaderDoubleTapZoomOrigin.center,
                label: Text('居中'),
              ),
              ButtonSegment(
                value: ReaderDoubleTapZoomOrigin.snap,
                label: Text('吸附'),
              ),
              ButtonSegment(
                value: ReaderDoubleTapZoomOrigin.focus,
                label: Text('聚焦'),
              ),
            ],
            selected: <ReaderDoubleTapZoomOrigin>{settings.doubleTapZoomOrigin},
            onSelectionChanged: (values) => update(
              settings.copyWith(doubleTapZoomOrigin: values.single),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '居中：以屏幕中心放大；吸附：按点击侧贴齐边缘；聚焦：以点击位置为中心。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Text('长按放大', style: Theme.of(context).textTheme.labelLarge),
    ),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SegmentedButton<bool>(
            key: longPressKey,
            showSelectedIcon: false,
            segments: const <ButtonSegment<bool>>[
              ButtonSegment(value: true, label: Text('启用')),
              ButtonSegment(value: false, label: Text('停用')),
            ],
            selected: <bool>{settings.longPressZoomEnabled},
            onSelectionChanged: (values) => update(
              settings.copyWith(longPressZoomEnabled: values.single),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            continuous
                ? '连续模式单独保存；开启自适应时高置信条漫仍可覆盖默认值。'
                : '分页模式单独保存；开启自适应时高置信页漫/条漫可覆盖默认值。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
    ListTile(
      key: longPressScaleKey,
      title: const Text('长按放大倍率'),
      subtitle: Slider(
        min: 1.25,
        max: 4,
        divisions: 11,
        label: settings.effectiveLongPressZoomScale.toStringAsFixed(2) + 'x',
        value:
            settings.effectiveLongPressZoomScale.clamp(1.25, 4).toDouble(),
        onChanged: (value) =>
            update(settings.copyWith(longPressZoomScale: value)),
      ),
      trailing:
          Text(settings.effectiveLongPressZoomScale.toStringAsFixed(2) + 'x'),
    ),
    if (!continuous)
      SwitchListTile(
        key: readingLongPressZoomRestoreKey,
        title: const Text('长按放大松手复原'),
        subtitle: const Text(
          '松手后恢复原始大小；关闭后保持放大，双击页面或切换页面退出。',
        ),
        value: settings.longPressZoomRestoreOnRelease,
        onChanged: (value) => update(
          settings.copyWith(longPressZoomRestoreOnRelease: value),
        ),
      ),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Text('长按放大移动方式'),
          const SizedBox(height: 6),
          SegmentedButton<ReaderLongPressMoveMode>(
            key: moveModeKey,
            showSelectedIcon: false,
            segments: const <ButtonSegment<ReaderLongPressMoveMode>>[
              ButtonSegment(
                value: ReaderLongPressMoveMode.drag,
                label: Text('拖动'),
              ),
              ButtonSegment(
                value: ReaderLongPressMoveMode.focus,
                label: Text('聚焦'),
              ),
            ],
            selected: <ReaderLongPressMoveMode>{settings.longPressZoomMoveMode},
            onSelectionChanged: (values) => update(
              settings.copyWith(longPressZoomMoveMode: values.single),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '拖动：内容跟随手指移动；聚焦：手指作为放大镜位置。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
    ListTile(
      key: panRatioKey,
      title: const Text('长按放大拖动比率'),
      subtitle: Slider(
        min: 0.25,
        max: 3,
        divisions: 11,
        label: settings.longPressZoomPanRatio.toStringAsFixed(2) + 'x',
        value: settings.longPressZoomPanRatio.clamp(0.25, 3).toDouble(),
        onChanged: (value) =>
            update(settings.copyWith(longPressZoomPanRatio: value)),
      ),
      trailing: Text(settings.longPressZoomPanRatio.toStringAsFixed(2) + 'x'),
    ),
    SwitchListTile(
      key: limitKey,
      title: const Text('放大拖动限制在可视范围'),
      subtitle: const Text(
        '顶部超出上边界时底部不得超出下边界；关闭后可自由把页面拖出屏幕。',
      ),
      value: settings.longPressZoomLimitToViewport,
      onChanged: (value) =>
          update(settings.copyWith(longPressZoomLimitToViewport: value)),
    ),
    SwitchListTile(
      key: decodeBoostKey,
      title: const Text('放大时提升解码分辨率'),
      subtitle: const Text(
        '仅对可视区域涉及的页面按当前倍率提高解码尺寸，不超过原图分辨率。',
      ),
      value: settings.zoomDecodeBoost,
      onChanged: (value) =>
          update(settings.copyWith(zoomDecodeBoost: value)),
    ),
  ];
}

Future<void> _editReaderTapSettings(
  BuildContext context,
  AppPreferencesController preferences,
  ReaderMode mode,
  ReaderModeSettings settings,
) async {
  final saved = await showReaderGestureSettingsSheet(
    context,
    mode: mode,
    initialSettings: settings,
  );
  if (saved == null) return;
  preferences.setReaderModeSettings(mode, saved);
}

Widget _readerScaleSlider({
  required Key key,
  required String title,
  required double value,
  required double min,
  required double max,
  required int divisions,
  required ValueChanged<double> onChanged,
}) =>
    ListTile(
      key: key,
      title: Text(title),
      subtitle: Slider(
        min: min,
        max: max,
        divisions: divisions,
        label: '${value.toStringAsFixed(2)}x',
        value: value.clamp(min, max).toDouble(),
        onChanged: onChanged,
      ),
      trailing: Text('${value.toStringAsFixed(2)}x'),
    );

final class DownloadSettingsScreen extends StatelessWidget {
  const DownloadSettingsScreen({required this.policyBinding, super.key});

  final WholeComicPolicySettingsBinding policyBinding;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: downloadSettingsScreenKey,
      appBar: AppBar(title: const Text('下载')),
      body: AnimatedBuilder(
        animation: policyBinding.changes,
        builder: (context, _) {
          final policy = policyBinding.readSnapshot().policy;
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
                    policyBinding.updatePolicy(
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
                  policyBinding.updatePolicy(
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
            const SizedBox(height: 16),
            const _SettingsSectionTitle('详情页'),
            ListTile(
              key: readingPreviewMaxItemsPerRowKey,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('预览每行最多数量'),
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
