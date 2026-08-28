import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:flutter/material.dart';
import 'package:plugin_host/plugin_host.dart';
import 'package:plugin_host_bridge/plugin_host_bridge.dart';
import 'package:storage_bridge/storage_bridge.dart';

import 'dialog_actions.dart';
import 'external_plugin_repository_model.dart';
import 'app_preferences.dart';
import 'directory_picker.dart';
import 'venera_plugin_editor_screen.dart';

enum _ExternalPluginPage { installed, repository }

const externalPluginInstalledLanguageBarKey =
    ValueKey<String>('external-plugin-installed-language-bar');
const externalPluginRepositoryLanguageBarKey =
    ValueKey<String>('external-plugin-repository-language-bar');
Key externalPluginLanguageChoiceKey(String scope, String language) =>
    ValueKey<String>('external-plugin-language:$scope:$language');

final class ExternalPluginRepositoryScreen extends StatefulWidget {
  const ExternalPluginRepositoryScreen({
    required this.format,
    required this.controller,
    required this.onSourcesChanged,
    this.preferences,
    super.key,
  });

  final ExternalComicPluginFormat format;
  final ExternalPluginController controller;
  final Future<void> Function() onSourcesChanged;

  /// Application preferences owning the per-source download directory map.
  ///
  /// When absent, the per-plugin download directory row stays hidden and the
  /// rest of the management screen keeps working (widget-only harnesses).
  final AppPreferencesController? preferences;

  @override
  State<ExternalPluginRepositoryScreen> createState() =>
      _ExternalPluginRepositoryScreenState();
}

final class _ExternalPluginRepositoryScreenState
    extends State<ExternalPluginRepositoryScreen> {
  late final TextEditingController _url = TextEditingController(
    text: switch (widget.format) {
      ExternalComicPluginFormat.mihonExtension =>
        'https://github.com/keiyoushi/extensions/raw/repo/index.pb',
      ExternalComicPluginFormat.veneraJavaScript =>
        'https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/index.json',
    },
  );
  List<ExternalComicPluginCatalogEntry> _entries =
      const <ExternalComicPluginCatalogEntry>[];
  Map<String, ExternalComicPluginCatalogEntry> _updates =
      const <String, ExternalComicPluginCatalogEntry>{};
  bool _remindedUpdates = false;
  bool _checkingUpdates = false;
  final Set<String> _working = <String>{};
  StreamSubscription<void>? _controllerChanges;
  _ExternalPluginPage _page = _ExternalPluginPage.installed;
  Object? _repositoryError;
  Object? _deviceError;
  bool _loadingRepository = false;
  bool _loadingDevice = false;
  String _installedLanguage = 'all';
  String _repositoryLanguage = 'all';

  String get _ecosystem => switch (widget.format) {
        ExternalComicPluginFormat.mihonExtension => 'Mihon 扩展',
        ExternalComicPluginFormat.veneraJavaScript => 'Venera 漫画源',
      };

  List<InstalledExternalPlugin> get _installed => widget.controller.installed
      .where((item) => item.plugin.format == widget.format)
      .toList(growable: false)
    ..sort((left, right) => left.plugin.name.compareTo(right.plugin.name));

  Set<String> get _installedPluginIds => <String>{
        for (final item in widget.controller.installed) item.plugin.pluginId,
      };

  Iterable<String> get _knownMihonPackageNames sync* {
    if (widget.format != ExternalComicPluginFormat.mihonExtension) return;
    for (final entry in _entries) {
      final pluginId = entry.pluginId;
      if (pluginId.startsWith('mihon:')) {
        final packageName = pluginId.substring('mihon:'.length).trim();
        if (packageName.isNotEmpty) yield packageName;
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _controllerChanges = widget.controller.sourceChanges.listen((_) {
      if (mounted) setState(() {});
    });
    _deviceError = widget.controller.deviceMihonDiscoveryError;
    scheduleMicrotask(_checkUpdates);
    if (widget.format == ExternalComicPluginFormat.mihonExtension) {
      scheduleMicrotask(_loadRepository);
    }
  }

  @override
  void dispose() {
    final controllerChanges = _controllerChanges;
    _controllerChanges = null;
    if (controllerChanges != null) {
      unawaited(controllerChanges.cancel());
    }
    _url.dispose();
    super.dispose();
  }

  Future<void> _loadRepository() async {
    final uri = Uri.tryParse(_url.text.trim());
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      setState(
        () => _repositoryError = const FormatException('仓库地址无效'),
      );
      return;
    }
    setState(() {
      _loadingRepository = true;
      _repositoryError = null;
    });
    try {
      final entries = await widget.controller.loadRepository(
        format: widget.format,
        index: uri,
      );
      if (!mounted) return;
      setState(() => _entries = entries);
      if (widget.format == ExternalComicPluginFormat.mihonExtension) {
        try {
          await widget.controller.refreshDeviceMihonExtensions(
            knownPackageNames: _knownMihonPackageNames,
          );
          if (mounted) {
            setState(
              () => _deviceError = widget.controller.deviceMihonDiscoveryError,
            );
          }
        } on Object catch (error) {
          if (mounted) setState(() => _deviceError = error);
        }
      }
    } on Object catch (error) {
      if (mounted) setState(() => _repositoryError = error);
    } finally {
      if (mounted) setState(() => _loadingRepository = false);
    }
  }

  Map<String, ExternalComicPluginCatalogEntry> get _installedEntries =>
      <String, ExternalComicPluginCatalogEntry>{
        for (final item in widget.controller.installed)
          item.plugin.pluginId: item.plugin,
      };

  /// Update reminder: installed plugins are compared against every trusted
  /// repository origin they were installed from. One reminder dialog per
  /// screen visit; badges stay visible afterwards.
  Future<void> _checkUpdates() async {
    if (_checkingUpdates) return;
    setState(() => _checkingUpdates = true);
    try {
      final updates = await widget.controller.checkUpdates(
        format: widget.format,
      );
      if (!mounted) return;
      setState(() => _updates = updates);
      if (updates.isEmpty || _remindedUpdates) return;
      _remindedUpdates = true;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('发现 ${updates.length} 个插件更新'),
          content: SizedBox(
            width: 420,
            child: ListView(
              shrinkWrap: true,
              children: <Widget>[
                for (final entry in updates.values)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading:
                        const Icon(Icons.system_update_alt_outlined),
                    title: Text(entry.name),
                    subtitle: Text('新版本 v${entry.version}'),
                  ),
              ],
            ),
          ),
          actions: <Widget>[
            AppDialogActions(
              onClose: () => Navigator.pop(context),
              actions: <Widget>[
                FilledButton(
                  onPressed: () {
                    Navigator.pop(context);
                    setState(() => _page = _ExternalPluginPage.repository);
                  },
                  child: const Text('前往更新'),
                ),
              ],
            ),
          ],
        ),
      );
    } on Object catch (error) {
      debugPrint('plugin update check failed: $error');
    } finally {
      if (mounted) setState(() => _checkingUpdates = false);
    }
  }

  Future<void> _install(
    ExternalComicPluginCatalogEntry plugin, {
    Uri? repository,
  }) async {
    if (!_working.add(plugin.pluginId)) return;
    setState(() {});
    try {
      final effectiveRepository =
          repository ?? Uri.parse(_url.text.trim());
      final preview = await widget.controller.inspect(
        plugin: plugin,
        repository: effectiveRepository,
      );
      if (!mounted) {
        await widget.controller.discardPreview(preview);
        return;
      }
      final approved = await showDialog<bool>(
            context: context,
            builder: (context) => _TrustDialog(preview: preview),
          ) ??
          false;
      if (!approved) {
        await widget.controller.discardPreview(preview);
        return;
      }
      await widget.controller.approveAndActivate(preview);
      await widget.onSourcesChanged();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${plugin.name} 已启用')),
      );
      unawaited(_checkUpdates());
      setState(() {});
    } on Object catch (error) {
      if (mounted) await _showOperationError('无法启用 ${plugin.name}', error);
    } finally {
      _working.remove(plugin.pluginId);
      if (mounted) setState(() {});
    }
  }

  Future<void> _updateFromInstalled(InstalledExternalPlugin installed) async {
    final entry = _updates[installed.plugin.pluginId];
    if (entry == null) return;
    final repository = Uri.tryParse(installed.repositoryOrigin);
    if (repository == null) return;
    await _install(entry, repository: repository);
  }

  Future<void> _editVeneraJavaScript(
    InstalledExternalPlugin installed,
  ) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => VeneraPluginEditorScreen(
          controller: widget.controller,
          installed: installed,
        ),
      ),
    );
    if (changed == true) {
      await widget.onSourcesChanged();
    }
  }

  Set<String> _pluginSourceIds(InstalledExternalPlugin item) =>
      <String>{
        for (final source in item.plugin.sources) source.sourceId,
        // Source identities discovered at the last successful activation.
        // Device-imported Mihon extensions only expose them here and through
        // the runtime, never through repository metadata.
        ...item.sourceIds,
        if (item.plugin.format == ExternalComicPluginFormat.veneraJavaScript &&
            item.sourceKey != null &&
            item.sourceKey!.trim().isNotEmpty)
          'venera:${item.sourceKey}',
      };

  String? _pluginDownloadDirectory(InstalledExternalPlugin item) {
    final preferences = widget.preferences;
    if (preferences == null) return null;
    for (final sourceId in _pluginSourceIds(item)) {
      final directory = preferences.sourceDownloadDirectoryFor(sourceId);
      if (directory != null) return directory;
    }
    return null;
  }

  /// Per-plugin download directory: one row per plugin; the choice applies to
  /// every external source the plugin exposes and only steers where NEW
  /// downloads are written. Existing bytes stay at their recorded location.
  Future<void> _changePluginDownloadDirectory(
    InstalledExternalPlugin item,
  ) async {
    final preferences = widget.preferences;
    if (preferences == null) return;
    final sourceIds = _pluginSourceIds(item);
    if (sourceIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '该插件尚未成功加载来源，无法确定下载目录作用范围；'
            '请先重新加载插件后再设置。',
          ),
        ),
      );
      return;
    }
    final current = _pluginDownloadDirectory(item);
    final decision = await showDialog<_DownloadDirectoryDecision>(
      context: context,
      builder: (dialogContext) => _PluginDownloadDirectoryDialog(
        pluginName: item.plugin.name,
        currentDirectory: current,
      ),
    );
    if (!mounted || decision == null) return;
    String? target = decision.directory;
    if (!decision.restoreDefault && target == null) return;
    if (decision.restoreDefault) {
      target = null;
    } else {
      if (target!.startsWith('saf://')) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('单插件独立目录仅支持本地文件夹；如需使用 SAF 请设置全局默认下载目录'),
          ),
        );
        return;
      }
      try {
        target = await resolveChapterDownloadDirectory(target);
        // Same scoped-storage probe as the global setting: a directory
        // that lists fine but rejects file writes must fail here, not
        // silently degrade every download of this plugin later.
        await probeChapterDownloadDirectoryWritable(target);
      } on Object catch (error) {
        debugPrint('download directory resolve failed: $error');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法使用所选目录：$error')),
        );
        return;
      }
    }
    for (final sourceId in sourceIds) {
      preferences.setSourceDownloadDirectory(sourceId, target);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          decision.restoreDefault
              ? '${item.plugin.name} 已恢复默认下载目录'
              : '新下载将写入：$target',
        ),
      ),
    );
    setState(() {});
  }

  Future<void> _remove(InstalledExternalPlugin installed) async {
    final plugin = installed.plugin;
    if (!_working.add(plugin.pluginId)) return;
    setState(() {});
    try {
      await widget.controller.remove(plugin.pluginId);
      await widget.onSourcesChanged();
      if (mounted) setState(() {});
    } on Object catch (error) {
      if (mounted) await _showOperationError('无法移除 ${plugin.name}', error);
    } finally {
      _working.remove(plugin.pluginId);
      if (mounted) setState(() {});
    }
  }

  Future<void> _retry(InstalledExternalPlugin installed) async {
    final plugin = installed.plugin;
    if (!_working.add(plugin.pluginId)) return;
    setState(() {});
    try {
      await widget.controller.retryActivation(plugin.pluginId);
      await widget.onSourcesChanged();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${plugin.name} 已重新加载')),
      );
    } on Object catch (error) {
      if (mounted) await _showOperationError('无法加载 ${plugin.name}', error);
    } finally {
      _working.remove(plugin.pluginId);
      if (mounted) setState(() {});
    }
  }

  Future<void> _installDeviceMihon(InstalledMihonExtension extension) async {
    final pluginId = 'mihon:${extension.packageName}';
    if (!_working.add(pluginId)) return;
    setState(() {});
    try {
      final preview = await widget.controller.inspectInstalledMihon(extension);
      if (!mounted) {
        await widget.controller.discardPreview(preview);
        return;
      }
      final approved = await showDialog<bool>(
            context: context,
            builder: (context) => _TrustDialog(preview: preview),
          ) ??
          false;
      if (!approved) {
        await widget.controller.discardPreview(preview);
        return;
      }
      await widget.controller.approveAndActivate(preview);
      await widget.onSourcesChanged();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${extension.displayName} 已启用')),
      );
      setState(() {});
    } on Object catch (error) {
      if (mounted) {
        await _showOperationError('无法启用 ${extension.displayName}', error);
      }
    } finally {
      _working.remove(pluginId);
      if (mounted) setState(() {});
    }
  }

  Future<void> _refreshDeviceMihon() async {
    if (_loadingDevice) return;
    setState(() {
      _loadingDevice = true;
      _deviceError = null;
    });
    try {
      await widget.controller.refreshDeviceMihonExtensions(
        knownPackageNames: _knownMihonPackageNames,
      );
      if (mounted) {
        setState(() => _deviceError = widget.controller.deviceMihonDiscoveryError);
      }
    } on Object catch (error) {
      if (mounted) setState(() => _deviceError = error);
    } finally {
      if (mounted) setState(() => _loadingDevice = false);
    }
  }

  Future<void> _showOperationError(String title, Object error) =>
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SelectableText(error.toString()),
          actions: <Widget>[
            AppDialogActions(
              onClose: () => Navigator.pop(context),
              actions: const <Widget>[],
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_ecosystem)),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<_ExternalPluginPage>(
                segments: const <ButtonSegment<_ExternalPluginPage>>[
                  ButtonSegment<_ExternalPluginPage>(
                    value: _ExternalPluginPage.installed,
                    icon: Icon(Icons.download_done_outlined),
                    label: Text('已安装'),
                  ),
                  ButtonSegment<_ExternalPluginPage>(
                    value: _ExternalPluginPage.repository,
                    icon: Icon(Icons.cloud_download_outlined),
                    label: Text('仓库'),
                  ),
                ],
                selected: <_ExternalPluginPage>{_page},
                showSelectedIcon: false,
                onSelectionChanged: (selection) {
                  setState(() => _page = selection.single);
                },
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: switch (_page) {
              _ExternalPluginPage.installed => _InstalledPluginsPane(
                  format: widget.format,
                  ecosystem: _ecosystem,
                  installed: _installed,
                  updates: _updates,
                  deviceMihonExtensions:
                      widget.controller.deviceMihonExtensions,
                  deviceMihonScan: widget.controller.deviceMihonScan,
                  installedPluginIds: _installedPluginIds,
                  activationFailures: widget.controller.activationFailures,
                  retryablePluginIds: <String>{
                    for (final pluginId
                        in widget.controller.activationFailures.keys)
                      if (widget.controller.canRetryActivation(pluginId))
                        pluginId,
                  },
                  manifestRestoreFailures:
                      widget.controller.manifestRestoreFailures,
                  working: _working,
                  loadingDevice: _loadingDevice,
                  deviceError: _deviceError,
                  onRemove: (installed) => unawaited(_remove(installed)),
                  onRetry: (installed) => unawaited(_retry(installed)),
                  onInstallDeviceMihon: (extension) =>
                      unawaited(_installDeviceMihon(extension)),
                  selectedLanguage: _installedLanguage,
                  onLanguageSelected: (language) {
                    setState(() => _installedLanguage = language);
                  },
                  onRefreshDeviceMihon: () =>
                      unawaited(_refreshDeviceMihon()),
                  onUpdate: (installed) =>
                      unawaited(_updateFromInstalled(installed)),
                  onEditJavaScript: (installed) =>
                      unawaited(_editVeneraJavaScript(installed)),
                  downloadDirectoryOf: _pluginDownloadDirectory,
                  onChangeDownloadDirectory: (installed) => unawaited(
                    _changePluginDownloadDirectory(installed),
                  ),
                ),
              _ExternalPluginPage.repository => _RepositoryPane(
                  format: widget.format,
                  url: _url,
                  entries: _entries,
                  installedEntries: _installedEntries,
                  working: _working,
                  loading: _loadingRepository,
                  error: _repositoryError,
                  selectedLanguage: _repositoryLanguage,
                  onLanguageSelected: (language) {
                    setState(() => _repositoryLanguage = language);
                  },
                  onLoad: () => unawaited(_loadRepository()),
                  onInstall: (plugin) => unawaited(_install(plugin)),
                ),
            },
          ),
        ],
      ),
    );
  }
}

final class _InstalledPluginsPane extends StatelessWidget {
  const _InstalledPluginsPane({
    required this.format,
    required this.ecosystem,
    required this.installed,
    required this.updates,
    required this.deviceMihonExtensions,
    required this.deviceMihonScan,
    required this.installedPluginIds,
    required this.activationFailures,
    required this.retryablePluginIds,
    required this.manifestRestoreFailures,
    required this.working,
    required this.loadingDevice,
    required this.deviceError,
    required this.onRemove,
    required this.onRetry,
    required this.onInstallDeviceMihon,
    required this.selectedLanguage,
    required this.onLanguageSelected,
    required this.onRefreshDeviceMihon,
    required this.onUpdate,
    required this.onEditJavaScript,
    required this.downloadDirectoryOf,
    required this.onChangeDownloadDirectory,
  });

  final ExternalComicPluginFormat format;
  final String ecosystem;
  final List<InstalledExternalPlugin> installed;
  final Map<String, ExternalComicPluginCatalogEntry> updates;
  final List<InstalledMihonExtension> deviceMihonExtensions;
  final InstalledMihonScan deviceMihonScan;
  final Set<String> installedPluginIds;
  final Map<String, Object> activationFailures;
  final Set<String> retryablePluginIds;
  final Map<String, Object> manifestRestoreFailures;
  final Set<String> working;
  final bool loadingDevice;
  final Object? deviceError;
  final ValueChanged<InstalledExternalPlugin> onRemove;
  final ValueChanged<InstalledExternalPlugin> onRetry;
  final ValueChanged<InstalledMihonExtension> onInstallDeviceMihon;
  final String selectedLanguage;
  final ValueChanged<String> onLanguageSelected;
  final VoidCallback onRefreshDeviceMihon;
  final ValueChanged<InstalledExternalPlugin> onUpdate;
  final ValueChanged<InstalledExternalPlugin> onEditJavaScript;
  final String? Function(InstalledExternalPlugin) downloadDirectoryOf;
  final ValueChanged<InstalledExternalPlugin> onChangeDownloadDirectory;

  @override
  Widget build(BuildContext context) {
    final preferredLanguage = Localizations.localeOf(context).languageCode;
    final languageCategories = format == ExternalComicPluginFormat.mihonExtension
        ? externalPluginLanguageCategories(
            installed.map((item) => item.plugin),
            preferredLanguage: preferredLanguage,
          )
        : const <String>[];
    final effectiveLanguage = languageCategories.contains(selectedLanguage)
        ? selectedLanguage
        : 'all';
    final visibleInstalled = effectiveLanguage == 'all'
        ? installed
        : installed
            .where(
              (item) => externalPluginMatchesLanguage(
                item.plugin,
                effectiveLanguage,
              ),
            )
            .toList(growable: false);
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 24),
      children: <Widget>[
        if (format == ExternalComicPluginFormat.mihonExtension) ...<Widget>[
          _DeviceMihonSection(
            extensions: deviceMihonExtensions,
            scan: deviceMihonScan,
            installedPluginIds: installedPluginIds,
            working: working,
            loading: loadingDevice,
            error: deviceError,
            onInstall: onInstallDeviceMihon,
            onRefresh: onRefreshDeviceMihon,
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 8),
        ],
        if (manifestRestoreFailures.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '插件持久记录恢复失败 ${manifestRestoreFailures.length} 项；'
                '其余有效插件已保留。${manifestRestoreFailures.values.first}',
              ),
            ),
          ),
        if (manifestRestoreFailures.isNotEmpty) const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text(
            'ZIC 已安装（${visibleInstalled.length}/${installed.length}）',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        if (format == ExternalComicPluginFormat.mihonExtension &&
            languageCategories.isNotEmpty) ...<Widget>[
          _MihonLanguageFilterBar(
            key: externalPluginInstalledLanguageBarKey,
            scope: 'installed',
            languages: languageCategories,
            selectedLanguage: effectiveLanguage,
            onSelected: onLanguageSelected,
          ),
          const SizedBox(height: 4),
        ],
        if (installed.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(child: Text('尚未安装 $ecosystem')),
          )
        else if (visibleInstalled.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('该语言分类下没有已安装插件')),
          )
        else
          for (final item in visibleInstalled) ...<Widget>[
            _InstalledPluginTile(
              item: item,
              failure: activationFailures[item.plugin.pluginId],
              retryable: retryablePluginIds.contains(item.plugin.pluginId),
              busy: working.contains(item.plugin.pluginId),
              update: updates[item.plugin.pluginId],
              onRemove: onRemove,
              onRetry: onRetry,
              onUpdate: onUpdate,
              onEditJavaScript:
                  format == ExternalComicPluginFormat.veneraJavaScript
                      ? onEditJavaScript
                      : null,
              downloadDirectory: downloadDirectoryOf(item),
              onChangeDownloadDirectory: onChangeDownloadDirectory,
            ),
            const Divider(height: 1),
          ],
      ],
    );
  }

}

final class _InstalledPluginTile extends StatelessWidget {
  const _InstalledPluginTile({
    required this.item,
    required this.failure,
    required this.retryable,
    required this.busy,
    required this.update,
    required this.onRemove,
    required this.onRetry,
    required this.onUpdate,
    required this.onEditJavaScript,
    required this.downloadDirectory,
    required this.onChangeDownloadDirectory,
  });

  final InstalledExternalPlugin item;
  final Object? failure;
  final bool retryable;
  final bool busy;
  final ExternalComicPluginCatalogEntry? update;
  final ValueChanged<InstalledExternalPlugin> onRemove;
  final ValueChanged<InstalledExternalPlugin> onRetry;
  final ValueChanged<InstalledExternalPlugin> onUpdate;
  final ValueChanged<InstalledExternalPlugin>? onEditJavaScript;
  final String? downloadDirectory;
  final ValueChanged<InstalledExternalPlugin> onChangeDownloadDirectory;

  @override
  Widget build(BuildContext context) {
    final plugin = item.plugin;
    final canRetry = failure != null && retryable && !busy;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      onTap: canRetry ? () => onRetry(item) : null,
      leading: Icon(
        failure == null
            ? Icons.check_circle_outline
            : retryable
                ? Icons.refresh_outlined
                : Icons.error_outline,
      ),
      title: Text(plugin.name),
      subtitle: Text(
        failure == null
            ? <String?>[
                plugin.language,
                'v${plugin.version}',
                if (plugin.sources.isNotEmpty) '${plugin.sources.length} 个源',
              ].whereType<String>().join(' · ')
            : '${retryable ? '加载失败，点击重试' : '加载失败，请重新安装'} · $failure',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: busy
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (failure == null && update != null)
                  IconButton(
                    tooltip: '更新到 v${update!.version}',
                    onPressed: () => onUpdate(item),
                    icon: Badge(
                      label: const Text('!'),
                      child: const Icon(Icons.system_update_alt_outlined),
                    ),
                  ),
                if (onEditJavaScript != null && failure == null)
                  IconButton(
                    tooltip: '编辑 JS',
                    onPressed: () => onEditJavaScript!(item),
                    icon: const Icon(Icons.code_outlined),
                  ),
                if (failure == null)
                  IconButton(
                    tooltip: downloadDirectory == null
                        ? '下载目录（默认）'
                        : '下载目录：$downloadDirectory',
                    onPressed: () => onChangeDownloadDirectory(item),
                    icon: Icon(
                      Icons.folder_copy_outlined,
                      color: downloadDirectory == null
                          ? null
                          : Theme.of(context).colorScheme.primary,
                    ),
                  ),
                if (canRetry)
                  IconButton(
                    tooltip: '重新加载',
                    onPressed: () => onRetry(item),
                    icon: const Icon(Icons.refresh),
                  ),
                IconButton(
                  tooltip: '移除',
                  onPressed: () => onRemove(item),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
    );
  }
}

final class _RepositoryPane extends StatelessWidget {
  const _RepositoryPane({
    required this.format,
    required this.url,
    required this.entries,
    required this.installedEntries,
    required this.working,
    required this.loading,
    required this.error,
    required this.selectedLanguage,
    required this.onLanguageSelected,
    required this.onLoad,
    required this.onInstall,
  });

  final ExternalComicPluginFormat format;
  final TextEditingController url;
  final List<ExternalComicPluginCatalogEntry> entries;
  final Map<String, ExternalComicPluginCatalogEntry> installedEntries;
  final Set<String> working;
  final bool loading;
  final Object? error;
  final String selectedLanguage;
  final ValueChanged<String> onLanguageSelected;
  final VoidCallback onLoad;
  final ValueChanged<ExternalComicPluginCatalogEntry> onInstall;

  Widget _repositoryTile(
    BuildContext context,
    ExternalComicPluginCatalogEntry plugin, {
    bool indent = false,
  }) {
    final installed = installedEntries[plugin.pluginId];
    final updatable = installed != null &&
        externalPluginCatalogEntryIsNewer(plugin, installed: installed);
    return _RepositoryPluginTile(
      plugin: plugin,
      active: installed != null,
      updatable: updatable,
      working: working.contains(plugin.pluginId),
      indent: indent,
      onInstall: onInstall,
    );
  }

  @override
  Widget build(BuildContext context) {
    final preferredLanguage = Localizations.localeOf(context).languageCode;
    final languageCategories = format == ExternalComicPluginFormat.mihonExtension
        ? externalPluginLanguageCategories(
            entries,
            preferredLanguage: preferredLanguage,
          )
        : const <String>[];
    final effectiveLanguage = languageCategories.contains(selectedLanguage)
        ? selectedLanguage
        : 'all';
    final visibleEntries = effectiveLanguage == 'all'
        ? entries
        : entries
            .where(
              (entry) => externalPluginMatchesLanguage(
                entry,
                effectiveLanguage,
              ),
            )
            .toList(growable: false);
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 24),
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'HTTPS 仓库索引',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => onLoad(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: loading ? null : onLoad,
              icon: loading
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: const Text('加载'),
            ),
          ],
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Material(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(error.toString()),
              ),
            ),
          ),
        const SizedBox(height: 10),
        if (format == ExternalComicPluginFormat.mihonExtension &&
            languageCategories.isNotEmpty) ...<Widget>[
          _MihonLanguageFilterBar(
            key: externalPluginRepositoryLanguageBarKey,
            scope: 'repository',
            languages: languageCategories,
            selectedLanguage: effectiveLanguage,
            onSelected: onLanguageSelected,
          ),
          const SizedBox(height: 8),
        ],
        if (entries.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('加载仓库后选择扩展或脚本源')),
          )
        else if (visibleEntries.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('该语言分类下没有仓库插件')),
          )
        else if (format == ExternalComicPluginFormat.mihonExtension)
          for (final group in groupMihonEntriesByLanguage(
            visibleEntries,
            preferredLanguage: preferredLanguage,
          )) ...<Widget>[
            _repositoryTile(context, group.defaultEntry),
            if (group.otherLanguages.isNotEmpty)
              ExpansionTile(
                key: PageStorageKey<String>(
                  'mihon-languages:${group.groupKey}',
                ),
                initiallyExpanded: false,
                dense: true,
                leading: const Icon(Icons.translate_outlined),
                title: Text('其他语言（${group.otherLanguages.length}）'),
                subtitle: Text(
                  group.otherLanguages
                      .map(externalPluginEntryLanguage)
                      .join('、'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                children: <Widget>[
                  for (final plugin in group.otherLanguages)
                    _repositoryTile(context, plugin, indent: true),
                ],
              ),
            const Divider(height: 1),
          ]
        else
          for (final plugin in visibleEntries) ...<Widget>[
            _repositoryTile(context, plugin),
            const Divider(height: 1),
          ],
      ],
    );
  }
}

final class _MihonLanguageFilterBar extends StatelessWidget {
  const _MihonLanguageFilterBar({
    required this.scope,
    required this.languages,
    required this.selectedLanguage,
    required this.onSelected,
    super.key,
  });

  final String scope;
  final List<String> languages;
  final String selectedLanguage;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final categories = <String>['all', ...languages];
    return SizedBox(
      height: 44,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        scrollDirection: Axis.horizontal,
        itemCount: categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final language = categories[index];
          return ChoiceChip(
            key: externalPluginLanguageChoiceKey(scope, language),
            label: Text(
              language == 'all'
                  ? '全部'
                  : externalPluginLanguageLabel(language),
            ),
            selected: language == selectedLanguage,
            showCheckmark: false,
            onSelected: (_) => onSelected(language),
          );
        },
      ),
    );
  }
}

final class _DeviceMihonSection extends StatelessWidget {
  const _DeviceMihonSection({
    required this.extensions,
    required this.scan,
    required this.installedPluginIds,
    required this.working,
    required this.loading,
    required this.error,
    required this.onInstall,
    required this.onRefresh,
  });

  final List<InstalledMihonExtension> extensions;
  final InstalledMihonScan scan;
  final Set<String> installedPluginIds;
  final Set<String> working;
  final bool loading;
  final Object? error;
  final ValueChanged<InstalledMihonExtension> onInstall;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Icon(Icons.phone_android_outlined),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '设备上的 Mihon 扩展（${extensions.length}）',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    '仅检测系统共享 APK；Mihon 私有扩展请从 ZIC 仓库安装',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            IconButton.filledTonal(
              key: const ValueKey<String>('refresh-device-mihon-extensions'),
              tooltip: '重新检测设备扩展',
              onPressed: loading ? null : onRefresh,
              icon: loading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Material(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: SelectableText(error.toString()),
              ),
            ),
          ),
        const SizedBox(height: 6),
        if (scan.visibilityLimited)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: Theme.of(context).colorScheme.tertiaryContainer,
              borderRadius: BorderRadius.circular(12),
              child: const Padding(
                padding: EdgeInsets.all(10),
                child: Text(
                  '系统可能限制了“获取已安装应用信息”。ZIC 已同时使用应用列表和精确包名探测；请在系统隐私/权限设置中允许 ZIC 获取已安装应用信息。',
                ),
              ),
            ),
          ),
        if (scan.failures.isNotEmpty)
          ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 8),
            title: Text('识别失败（${scan.failures.length}）'),
            subtitle: const Text('展开查看每个 APK 的实际失败阶段'),
            children: <Widget>[
              for (final failure in scan.failures)
                ListTile(
                  dense: true,
                  title: Text(failure.displayName),
                  subtitle: SelectableText(
                    '${failure.packageName}\n'
                    '${failure.stage}: ${failure.message}',
                  ),
                ),
            ],
          ),
        if (scan.enumerationErrors.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SelectableText(scan.enumerationErrors.join('\n')),
          ),
        if (scan.directProbeCount > 0 || scan.enumeratedPackageCount > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '系统枚举 ${scan.enumeratedPackageCount} 个包 · '
              '候选 ${scan.candidatePackageCount} · '
              '精确探测 ${scan.directProbeCount} · '
              '命中 ${scan.directMatchCount}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (extensions.isEmpty)
          const ListTile(
            contentPadding: EdgeInsets.symmetric(horizontal: 8),
            title: Text('未检测到可用扩展'),
          )
        else
          for (final extension in extensions)
            Builder(
              builder: (context) {
                final pluginId = 'mihon:${extension.packageName}';
                final active = installedPluginIds.contains(pluginId);
                final busy = working.contains(pluginId);
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  title: Text(extension.displayName),
                  subtitle: Text(
                    '${extension.packageName}\n'
                    'v${extension.versionName} · ABI ${extension.extensionLib}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: busy
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton.tonal(
                          onPressed: () => onInstall(extension),
                          child: Text(active ? '重新导入' : '启用'),
                        ),
                );
              },
            ),
      ],
    );
  }
}

final class _RepositoryPluginTile extends StatelessWidget {
  const _RepositoryPluginTile({
    required this.plugin,
    required this.active,
    required this.updatable,
    required this.working,
    required this.onInstall,
    this.indent = false,
  });

  final ExternalComicPluginCatalogEntry plugin;
  final bool active;
  final bool updatable;
  final bool working;
  final ValueChanged<ExternalComicPluginCatalogEntry> onInstall;
  final bool indent;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.symmetric(horizontal: indent ? 24 : 8, vertical: 4),
      leading: Icon(
        plugin.format == ExternalComicPluginFormat.mihonExtension
            ? Icons.extension_outlined
            : Icons.javascript_outlined,
      ),
      title: Text(plugin.name),
      subtitle: Text(
        <String?>[
          externalPluginEntryLanguage(plugin),
          'v${plugin.version}',
          if (plugin.sources.isNotEmpty) '${plugin.sources.length} 个源',
          if (plugin.adult) '成人内容',
        ].whereType<String>().join(' · '),
      ),
      trailing: working
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : FilledButton.tonal(
              onPressed: active && !updatable ? null : () => onInstall(plugin),
              child: Text(
                !active ? '安装' : (updatable ? '更新' : '已安装'),
              ),
            ),
    );
  }
}

final class _TrustDialog extends StatelessWidget {
  const _TrustDialog({required this.preview});

  final ExternalPluginInstallPreview preview;

  @override
  Widget build(BuildContext context) {
    final inspection = preview.inspection;
    final isMihon =
        preview.plugin.format == ExternalComicPluginFormat.mihonExtension;
    return AlertDialog(
      title: Text('信任并启用 ${preview.plugin.name}？'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                isMihon
                    ? '该 APK 将在独立 Android 进程中加载，可执行原生代码并使用网络、Cookie、凭据和插件私有存储。'
                    : '该 JavaScript 将在独立 Android 进程的受限 WebView 中执行，网络、Cookie 和插件私有存储只能通过显式桥接访问。',
              ),
              const SizedBox(height: 12),
              SelectableText('仓库：${preview.repository}'),
              SelectableText('入口：${preview.plugin.entrypoint}'),
              SelectableText('SHA-256：${inspection.payloadSha256}'),
              if (inspection.packageName != null)
                SelectableText('包名：${inspection.packageName}'),
              if (inspection.signerSha256 != null)
                SelectableText('签名：${inspection.signerSha256}'),
              if (inspection.extensionLib != null)
                SelectableText('Mihon ABI：${inspection.extensionLib}'),
              if (inspection.sourceKey != null)
                SelectableText('Venera key：${inspection.sourceKey}'),
              const SizedBox(height: 8),
              Text(
                '授权：${inspection.requestedCapabilities.map((e) => e.name).join(', ')}',
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        AppDialogActions(
          onClose: () => Navigator.pop(context, false),
          actions: <Widget>[
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('信任并启用'),
            ),
          ],
        ),
      ],
    );
  }
}

/// User decision from the per-plugin download directory dialog.
final class _DownloadDirectoryDecision {
  const _DownloadDirectoryDecision({
    required this.restoreDefault,
    this.directory,
  });

  final bool restoreDefault;
  final String? directory;
}

final class _PluginDownloadDirectoryDialog extends StatefulWidget {
  const _PluginDownloadDirectoryDialog({
    required this.pluginName,
    required this.currentDirectory,
  });

  final String pluginName;
  final String? currentDirectory;

  @override
  State<_PluginDownloadDirectoryDialog> createState() =>
      _PluginDownloadDirectoryDialogState();
}

final class _PluginDownloadDirectoryDialogState
    extends State<_PluginDownloadDirectoryDialog> {
  String? _picked;
  bool _picking = false;

  Future<void> _pick() async {
    if (_picking) return;
    setState(() => _picking = true);
    String? picked;
    Object? failure;
    try {
      picked = await pickDirectory();
    } on Object catch (error) {
      debugPrint('directory picker failed: $error');
      failure = error;
    } finally {
      if (mounted) setState(() => _picking = false);
    }
    if (!mounted) return;
    if (failure != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法打开目录选择器：$failure')),
      );
      return;
    }
    if (picked == null || picked.isEmpty) return;
    setState(() => _picked = picked);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('下载目录 · ${widget.pluginName}'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SelectableText(
              '当前：${widget.currentDirectory ?? '默认下载目录'}',
            ),
            if (_picked != null) ...<Widget>[
              const SizedBox(height: 8),
              SelectableText('新目录：$_picked'),
            ],
            const SizedBox(height: 8),
            const Text(
              '该插件的来源新下载将写入所选目录；'
              '已存在的文件保留原位置，不受影响。',
            ),
          ],
        ),
      ),
      actions: <Widget>[
        AppDialogActions(
          onClose: () => Navigator.pop(context),
          actions: <Widget>[
            TextButton(
              onPressed: _picking ? null : _pick,
              child: _picking
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('选择目录'),
            ),
            if (widget.currentDirectory != null)
              TextButton(
                onPressed: () => Navigator.pop(
                  context,
                  const _DownloadDirectoryDecision(
                    restoreDefault: true,
                  ),
                ),
                child: const Text('恢复默认'),
              ),
            FilledButton(
              onPressed: _picked == null
                  ? null
                  : () => Navigator.pop(
                        context,
                        _DownloadDirectoryDecision(
                          restoreDefault: false,
                          directory: _picked,
                        ),
                      ),
              child: const Text('设置'),
            ),
          ],
        ),
      ],
    );
  }
}
