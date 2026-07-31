import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:flutter/material.dart';
import 'package:plugin_host/plugin_host.dart';
import 'package:plugin_host_bridge/plugin_host_bridge.dart';

import 'external_plugin_repository_model.dart';

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
  Object? _error;
  bool _loading = false;

  String get _ecosystem => switch (widget.format) {
        ExternalComicPluginFormat.mihonExtension => 'Mihon 扩展',
        ExternalComicPluginFormat.veneraJavaScript => 'Venera 漫画源',
      };

  List<InstalledExternalPlugin> get _installed => widget.controller.installed
      .where((item) => item.plugin.format == widget.format)
      .toList(growable: false)
    ..sort((left, right) => left.plugin.name.compareTo(right.plugin.name));

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final uri = Uri.tryParse(_url.text.trim());
    if (uri == null) {
      setState(() => _error = const FormatException('仓库地址无效'));
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await widget.controller.loadRepository(
        format: widget.format,
        index: uri,
      );
      if (!mounted) return;
      setState(() => _entries = entries);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
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
      if (!mounted) return;
      await _showOperationError('无法启用 ${plugin.name}', error);
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
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.controller.refreshDeviceMihonExtensions();
      if (mounted) setState(() {});
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _showOperationError(String title, Object error) =>
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SelectableText(error.toString()),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_ecosystem)),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            flex: 4,
            child: _InstalledPluginsPane(
              ecosystem: _ecosystem,
              installed: _installed,
              activationFailures: widget.controller.activationFailures,
              working: _working,
              onRemove: (installed) => unawaited(_remove(installed)),
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            flex: 6,
            child: _RepositoryPane(
              format: widget.format,
              url: _url,
              entries: _entries,
              deviceMihonExtensions: widget.controller.deviceMihonExtensions,
              installedPluginIds: <String>{
                for (final item in widget.controller.installed)
                  item.plugin.pluginId,
              },
              working: _working,
              loading: _loading,
              error: _error,
              onLoad: () => unawaited(_load()),
              onInstall: (plugin) => unawaited(_install(plugin)),
              onInstallDeviceMihon: (extension) =>
                  unawaited(_installDeviceMihon(extension)),
              onRefreshDeviceMihon: () => unawaited(_refreshDeviceMihon()),
            ),
          ),
        ],
      ),
    );
  }
}

final class _InstalledPluginsPane extends StatelessWidget {
  const _InstalledPluginsPane({
    required this.ecosystem,
    required this.installed,
    required this.activationFailures,
    required this.working,
    required this.onRemove,
  });

  final String ecosystem;
  final List<InstalledExternalPlugin> installed;
  final Map<String, Object> activationFailures;
  final Set<String> working;
  final ValueChanged<InstalledExternalPlugin> onRemove;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 10, 8),
          child: Text(
            '已安装（${installed.length}）',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        Expanded(
          child: installed.isEmpty
              ? Center(child: Text('尚未安装 $ecosystem'))
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                  itemCount: installed.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = installed[index];
                    final plugin = item.plugin;
                    final failure = activationFailures[plugin.pluginId];
                    final busy = working.contains(plugin.pluginId);
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(10, 9, 6, 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Icon(
                                  failure == null
                                      ? Icons.check_circle_outline
                                      : Icons.error_outline,
                                  size: 18,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    plugin.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodyMedium,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              failure == null
                                  ? [
                                      plugin.language,
                                      'v${plugin.version}',
                                      if (plugin.sources.isNotEmpty)
                                        '${plugin.sources.length} 个源',
                                    ].whereType<String>().join(' · ')
                                  : '启动失败 · $failure',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: busy
                                  ? const Padding(
                                      padding: EdgeInsets.all(8),
                                      child: SizedBox.square(
                                        dimension: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    )
                                  : IconButton(
                                      tooltip: '移除',
                                      visualDensity: VisualDensity.compact,
                                      onPressed: () => onRemove(item),
                                      icon: const Icon(Icons.delete_outline),
                                    ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

final class _RepositoryPane extends StatelessWidget {
  const _RepositoryPane({
    required this.format,
    required this.url,
    required this.entries,
    required this.deviceMihonExtensions,
    required this.installedPluginIds,
    required this.working,
    required this.loading,
    required this.error,
    required this.onLoad,
    required this.onInstall,
    required this.onInstallDeviceMihon,
    required this.onRefreshDeviceMihon,
  });

  final ExternalComicPluginFormat format;
  final TextEditingController url;
  final List<ExternalComicPluginCatalogEntry> entries;
  final List<InstalledMihonExtension> deviceMihonExtensions;
  final Set<String> installedPluginIds;
  final Set<String> working;
  final bool loading;
  final Object? error;
  final VoidCallback onLoad;
  final ValueChanged<ExternalComicPluginCatalogEntry> onInstall;
  final ValueChanged<InstalledMihonExtension> onInstallDeviceMihon;
  final VoidCallback onRefreshDeviceMihon;

  @override
  Widget build(BuildContext context) {
    final content = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
        child: Text('仓库', style: Theme.of(context).textTheme.titleMedium),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Row(
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
      ),
      if (error != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Material(
            color: Theme.of(context).colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(error.toString()),
            ),
          ),
        ),
      if (format == ExternalComicPluginFormat.mihonExtension)
        _DeviceMihonSection(
          extensions: deviceMihonExtensions,
          installedPluginIds: installedPluginIds,
          working: working,
          loading: loading,
          onInstall: onInstallDeviceMihon,
          onRefresh: onRefreshDeviceMihon,
        ),
      if (entries.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: Text('加载仓库后选择扩展或脚本源')),
        )
      else if (format == ExternalComicPluginFormat.mihonExtension)
        ..._mihonRepositoryWidgets(context)
      else
        for (final plugin in entries)
          _RepositoryPluginTile(
            plugin: plugin,
            active: installedPluginIds.contains(plugin.pluginId),
            working: working.contains(plugin.pluginId),
            onInstall: onInstall,
          ),
      const SizedBox(height: 24),
    ];

    return ListView(children: content);
  }

  List<Widget> _mihonRepositoryWidgets(BuildContext context) {
    final localeLanguage = Localizations.localeOf(context).languageCode;
    final groups = groupMihonEntriesByLanguage(
      entries,
      preferredLanguage: localeLanguage,
    );
    return <Widget>[
      for (final group in groups) ...<Widget>[
        _RepositoryPluginTile(
          plugin: group.defaultEntry,
          active: installedPluginIds.contains(group.defaultEntry.pluginId),
          working: working.contains(group.defaultEntry.pluginId),
          onInstall: onInstall,
        ),
        if (group.otherLanguages.isNotEmpty)
          ExpansionTile(
            key: PageStorageKey<String>('mihon-languages:${group.groupKey}'),
            initiallyExpanded: false,
            dense: true,
            leading: const Icon(Icons.translate_outlined),
            title: Text('其他语言（${group.otherLanguages.length}）'),
            subtitle: Text(
              group.otherLanguages
                  .map((entry) => externalPluginEntryLanguage(entry))
                  .join('、'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            children: <Widget>[
              for (final plugin in group.otherLanguages)
                _RepositoryPluginTile(
                  plugin: plugin,
                  active: installedPluginIds.contains(plugin.pluginId),
                  working: working.contains(plugin.pluginId),
                  onInstall: onInstall,
                  indent: true,
                ),
            ],
          ),
        const Divider(height: 1),
      ],
    ];
  }
}

final class _DeviceMihonSection extends StatelessWidget {
  const _DeviceMihonSection({
    required this.extensions,
    required this.installedPluginIds,
    required this.working,
    required this.loading,
    required this.onInstall,
    required this.onRefresh,
  });

  final List<InstalledMihonExtension> extensions;
  final Set<String> installedPluginIds;
  final Set<String> working;
  final bool loading;
  final ValueChanged<InstalledMihonExtension> onInstall;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      initiallyExpanded: false,
      leading: const Icon(Icons.phone_android_outlined),
      title: Text('设备上的 Mihon 扩展（${extensions.length}）'),
      subtitle: const Text('确认信任后复制到 ZIC 私有运行目录'),
      trailing: IconButton(
        tooltip: '重新检测',
        onPressed: loading ? null : onRefresh,
        icon: const Icon(Icons.refresh),
      ),
      children: extensions.isEmpty
          ? const <Widget>[ListTile(title: Text('未检测到可用扩展'))]
          : <Widget>[
              for (final extension in extensions)
                Builder(
                  builder: (context) {
                    final pluginId = 'mihon:${extension.packageName}';
                    final active = installedPluginIds.contains(pluginId);
                    final busy = working.contains(pluginId);
                    return ListTile(
                      dense: true,
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
    this.indent = false,
  });

  final ExternalComicPluginCatalogEntry plugin;
  final bool active;
  final bool working;
  final ValueChanged<ExternalComicPluginCatalogEntry> onInstall;
  final bool indent;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.fromLTRB(indent ? 24 : 10, 3, 10, 3),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 9, 8, 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  plugin.format == ExternalComicPluginFormat.mihonExtension
                      ? Icons.extension_outlined
                      : Icons.javascript_outlined,
                  size: 19,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    plugin.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              <String?>[
                externalPluginEntryLanguage(plugin),
                'v${plugin.version}',
                if (plugin.sources.isNotEmpty) '${plugin.sources.length} 个源',
                if (plugin.adult) '成人内容',
              ].whereType<String>().join(' · '),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 5),
            Align(
              alignment: Alignment.centerRight,
              child: working
                  ? const Padding(
                      padding: EdgeInsets.all(8),
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : FilledButton.tonal(
                      onPressed: () => onInstall(plugin),
                      child: Text(active ? '更新' : '安装'),
                    ),
            ),
          ],
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
              Text('授权：${inspection.requestedCapabilities.map((e) => e.name).join(', ')}'),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('信任并启用'),
        ),
      ],
    );
  }
}
