import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:plugin_host_bridge/plugin_host_bridge.dart';

import 'dialog_actions.dart';

const veneraPluginEditorScreenKey = ValueKey<String>('venera-plugin-editor');
const veneraPluginEditorInputKey = ValueKey<String>(
  'venera-plugin-editor-input',
);
const veneraPluginEditorSaveKey = ValueKey<String>(
  'venera-plugin-editor-save',
);
const veneraPluginEditorResetKey = ValueKey<String>(
  'venera-plugin-editor-reset',
);

/// Full-screen editor for an installed Venera plugin's JavaScript payload.
///
/// Saving re-inspects and re-activates the edited script through the plugin
/// controller; the previously trusted payload stays authoritative until that
/// succeeds, so a broken edit never takes the source offline silently.
final class VeneraPluginEditorScreen extends StatefulWidget {
  const VeneraPluginEditorScreen({
    required this.controller,
    required this.installed,
    super.key,
  });

  final ExternalPluginController controller;
  final InstalledExternalPlugin installed;

  @override
  State<VeneraPluginEditorScreen> createState() =>
      _VeneraPluginEditorScreenState();
}

final class _VeneraPluginEditorScreenState
    extends State<VeneraPluginEditorScreen> {
  final TextEditingController _input = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  Object? _loadError;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final source = await widget.controller.readVeneraJavaScript(
        widget.installed.plugin.pluginId,
      );
      if (!mounted) return;
      setState(() {
        _input.text = source;
        _input.selection = TextSelection.collapsed(
          offset: source.length,
        );
        _dirty = false;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error;
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    if (_saving || !_dirty) return;
    setState(() => _saving = true);
    try {
      await widget.controller.saveVeneraJavaScript(
        widget.installed.plugin.pluginId,
        _input.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('脚本已保存并重新加载')),
      );
      Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('保存失败'),
          content: SelectableText(
            '$error\n\n已信任的旧脚本保持不变。',
          ),
          actions: <Widget>[
            AppDialogActions(
              onClose: () => Navigator.pop(context),
              actions: const <Widget>[],
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pluginName = widget.installed.plugin.name;
    return Scaffold(
      key: veneraPluginEditorScreenKey,
      appBar: AppBar(
        title: Text('编辑 JS · $pluginName'),
        actions: <Widget>[
          IconButton(
            key: veneraPluginEditorResetKey,
            tooltip: '放弃更改并重新载入',
            onPressed: _loading || _saving || !_dirty ? null : _load,
            icon: const Icon(Icons.undo_outlined),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              key: veneraPluginEditorSaveKey,
              onPressed: _loading || _saving || !_dirty ? null : _save,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: const Text('保存'),
            ),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          SelectableText('无法读取脚本：$_loadError'),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _load, child: const Text('重试')),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Text(
            '${widget.installed.plugin.pluginId} · '
            'v${widget.installed.plugin.version} · '
            'SHA-256 ${widget.installed.payloadSha256}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            '编辑在独立进程中受限执行的来源脚本；保存后立即校验并重新加载，'
            '失败时保留旧脚本。',
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: TextField(
              key: veneraPluginEditorInputKey,
              controller: _input,
              maxLines: null,
              expands: true,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.35,
              ),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.all(12),
              ),
              onChanged: (_) {
                if (!_dirty) setState(() => _dirty = true);
              },
            ),
          ),
        ),
      ],
    );
  }
}
