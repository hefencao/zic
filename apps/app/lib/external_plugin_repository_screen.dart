import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:flutter/material.dart';
import 'package:plugin_host/plugin_host.dart';
import 'package:plugin_host_bridge/plugin_host_bridge.dart';

import 'dialog_actions.dart';
import 'external_plugin_repository_model.dart';

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
    super.key,
  });

  final ExternalComicPluginFormat format;
  final ExternalPluginController controller;
  final Future<void> Function() onSourcesChanged;

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
  final Set<String> _working = <String>{};
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
    _deviceError = widget.controller.deviceMihonDiscoveryError;
    if (widget.format == ExternalComicPluginFormat.mihonExtension) {
      scheduleMicrotask(_loadRepository);
    }
  }

  @override
  void dispose() {
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

  Future<void> _install(ExternalComicPluginCatalogEntry plugin) async {
    if (!_working.add(plugin.pluginId)) return;
    setState(() {});
    try {
      final repository = Uri.parse(_url.text.trim());
      final preview = await widget.controller.inspect(
        plugin: plugin,
        repository: repository,
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
      setState(() {});
    } on Object catch (error) {
      if (mounted) await _showOperationError('无法启用 ${plugin.name}', error);
    } finally {
      _working.remove(plugin.pluginId);
      if (mounted) setState(() {});
    }
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
                  deviceMihonExtensions:
                      widget.controller.deviceMihonExtensions,
                  deviceMihonScan: widget.controller.deviceMihonScan,
                  installedPluginIds: _installedPluginIds,
                  activationFailures: widget.controller.activationFailures,
                  manifestRestoreFailures:
                      widget.controller.manifestRestoreFailures,
                  working: _working,
                  loadingDevice: _loadingDevice,
                  deviceError: _deviceError,
                  onRemove: (installed) => unawaited(_remove(installed)),
                  onInstallDeviceMihon: (extension) =>
                      unawaited(_installDeviceMihon(extension)),
                  selectedLanguage: _installedLanguage,
                  onLanguageSelected: (language) {
                    setState(() => _installedLanguage = language);
                  },
                  onRefreshDeviceMihon: () =>
                      unawaited(_refreshDeviceMihon()),
                ),
              _ExternalPluginPage.repository => _RepositoryPane(
                  format: widget.format,
                  url: _url,
                  entries: _entries,
                  installedPluginIds: _installedPluginIds,
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
    required this.deviceMihonExtensions,
    required this.deviceMihonScan,
    required this.installedPluginIds,
    required this.activationFailures,
    required this.manifestRestoreFailures,
    required this.working,
    required this.loadingDevice,
    required this.deviceError,
    required this.onRemove,
    required this.onInstallDeviceMihon,
    required this.selectedLanguage,
    required this.onLanguageSelected,
    required this.onRefreshDeviceMihon,
  });

  final ExternalComicPluginFormat format;
  final String ecosystem;
  final List<InstalledExternalPlugin> installed;
  final List<InstalledMihonExtension> deviceMihonExtensions;
  final InstalledMihonScan deviceMihonScan;
  final Set<String> installedPluginIds;
  final Map<String, Object> activationFailures;
  final Map<String, Object> manifestRestoreFailures;
  final Set<String> working;
  final bool loadingDevice;
  final Object? deviceError;
  final ValueChanged<InstalledExternalPlugin> onRemove;
  final ValueChanged<InstalledMihonExtension> onInstallDeviceMihon;
  final String selectedLanguage;
  final ValueChanged<String> onLanguageSelected;
  final VoidCallback onRefreshDeviceMihon;

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
              busy: working.contains(item.plugin.pluginId),
              onRemove: onRemove,
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
    required this.busy,
    required this.onRemove,
  });

  final InstalledExternalPlugin item;
  final Object? failure;
  final bool busy;
  final ValueChanged<InstalledExternalPlugin> onRemove;

  @override
  Widget build(BuildContext context) {
    final plugin = item.plugin;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      leading: Icon(
        failure == null ? Icons.check_circle_outline : Icons.error_outline,
      ),
      title: Text(plugin.name),
      subtitle: Text(
        failure == null
            ? <String?>[
                plugin.language,
                'v${plugin.version}',
                if (plugin.sources.isNotEmpty) '${plugin.sources.length} 个源',
              ].whereType<String>().join(' · ')
            : '启动失败 · $failure',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: busy
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : IconButton(
              tooltip: '移除',
              onPressed: () => onRemove(item),
              icon: const Icon(Icons.delete_outline),
            ),
    );
  }
}

final class _RepositoryPane extends StatelessWidget {
  const _RepositoryPane({
    required this.format,
    required this.url,
    required this.entries,
    required this.installedPluginIds,
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
  final Set<String> installedPluginIds;
  final Set<String> working;
  final bool loading;
  final Object? error;
  final String selectedLanguage;
  final ValueChanged<String> onLanguageSelected;
  final VoidCallback onLoad;
  final ValueChanged<ExternalComicPluginCatalogEntry> onInstall;

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
        else
          for (final plugin in visibleEntries) ...<Widget>[
            _RepositoryPluginTile(
              plugin: plugin,
              active: installedPluginIds.contains(plugin.pluginId),
              working: working.contains(plugin.pluginId),
              onInstall: onInstall,
            ),
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
    required this.working,
    required this.onInstall,
  });

  final ExternalComicPluginCatalogEntry plugin;
  final bool active;
  final bool working;
  final ValueChanged<ExternalComicPluginCatalogEntry> onInstall;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
              onPressed: () => onInstall(plugin),
              child: Text(active ? '更新' : '安装'),
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
