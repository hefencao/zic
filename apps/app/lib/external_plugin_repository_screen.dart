import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:flutter/material.dart';
import 'package:plugin_host/plugin_host.dart';

import 'package:plugin_host_bridge/plugin_host_bridge.dart';

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
        ExternalComicPluginFormat.mihonExtension => 'Mihon',
        ExternalComicPluginFormat.veneraJavaScript => 'Venera',
      };

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
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('无法启用 ${plugin.name}'),
          content: SelectableText(error.toString()),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
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
      final preview =
          await widget.controller.inspectInstalledMihon(extension);
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
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('无法启用 ${extension.displayName}'),
          content: SelectableText(error.toString()),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
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
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final installed = <String>{
      for (final item in widget.controller.installed) item.plugin.pluginId,
    };
    return Scaffold(
      appBar: AppBar(title: Text('$_ecosystem 仓库')),
      body: Column(
        children: <Widget>[
          if (widget.format == ExternalComicPluginFormat.mihonExtension)
            ExpansionTile(
              initiallyExpanded: true,
              leading: const Icon(Icons.phone_android_outlined),
              title: Text(
                '设备上的 Mihon 扩展'
                '（${widget.controller.deviceMihonExtensions.length}）',
              ),
              subtitle: const Text('检测 Mihon 已安装的扩展，确认信任后复制并启用'),
              trailing: IconButton(
                tooltip: '重新检测',
                onPressed: _loading
                    ? null
                    : () => unawaited(_refreshDeviceMihon()),
                icon: const Icon(Icons.refresh),
              ),
              children: widget.controller.deviceMihonExtensions.isEmpty
                  ? const <Widget>[
                      ListTile(title: Text('未检测到可用的 Mihon 扩展')),
                    ]
                  : widget.controller.deviceMihonExtensions.map((extension) {
                      final pluginId = 'mihon:${extension.packageName}';
                      final active = installed.contains(pluginId);
                      final working = _working.contains(pluginId);
                      return ListTile(
                        leading: const Icon(Icons.extension_outlined),
                        title: Text(extension.displayName),
                        subtitle: Text(
                          '${extension.packageName}\n'
                          'v${extension.versionName} · ABI '
                          '${extension.extensionLib}',
                        ),
                        isThreeLine: true,
                        trailing: working
                            ? const SizedBox.square(
                                dimension: 22,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : FilledButton.tonal(
                                onPressed: () =>
                                    unawaited(_installDeviceMihon(extension)),
                                child: Text(active ? '重新导入' : '启用'),
                              ),
                      );
                    }).toList(growable: false),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'HTTPS 仓库索引',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => unawaited(_load()),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _loading ? null : () => unawaited(_load()),
                  icon: _loading
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
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Material(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(_error.toString()),
                ),
              ),
            ),
          Expanded(
            child: _entries.isEmpty
                ? const Center(child: Text('加载仓库后选择扩展或脚本源'))
                : ListView.builder(
                    itemCount: _entries.length,
                    itemBuilder: (context, index) {
                      final plugin = _entries[index];
                      final active = installed.contains(plugin.pluginId);
                      final working = _working.contains(plugin.pluginId);
                      return ListTile(
                        leading: Icon(
                          widget.format ==
                                  ExternalComicPluginFormat.mihonExtension
                              ? Icons.extension_outlined
                              : Icons.javascript_outlined,
                        ),
                        title: Text(plugin.name),
                        subtitle: Text(
                          [
                            plugin.language,
                            'v${plugin.version}',
                            if (plugin.sources.isNotEmpty)
                              '${plugin.sources.length} 个源',
                            if (plugin.adult) '成人内容',
                          ].whereType<String>().join(' · '),
                        ),
                        trailing: working
                            ? const SizedBox.square(
                                dimension: 22,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : FilledButton.tonal(
                                onPressed: () => unawaited(_install(plugin)),
                                child: Text(active ? '更新' : '安装'),
                              ),
                      );
                    },
                  ),
          ),
        ],
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
