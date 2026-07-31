import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:flutter/material.dart';

final class ExternalSourceSettingsScreen extends StatefulWidget {
  const ExternalSourceSettingsScreen({
    required this.source,
    required this.onApply,
    this.onLogin,
    super.key,
  });

  final BrowsableComicSource source;
  final Future<void> Function() onApply;
  final Future<void> Function()? onLogin;

  @override
  State<ExternalSourceSettingsScreen> createState() =>
      _ExternalSourceSettingsScreenState();
}

final class _ExternalSourceSettingsScreenState
    extends State<ExternalSourceSettingsScreen> {
  List<ComicSourceSetting> _settings = const <ComicSourceSetting>[];
  Object? _error;
  bool _loading = true;
  bool _working = false;
  bool _changed = false;

  ConfigurableComicSource get _source =>
      widget.source as ConfigurableComicSource;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final settings = await _source.loadSettings();
      if (mounted) setState(() => _settings = settings);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _update(ComicSourceSetting setting, Object value) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await _source.updateSetting(setting.key, value);
      final index = _settings.indexWhere((item) => item.key == setting.key);
      if (!mounted) return;
      setState(() {
        if (index >= 0) {
          _settings = _settings.toList(growable: false)
            ..[index] = ComicSourceSetting(
              key: setting.key,
              title: setting.title,
              summary: setting.summary,
              kind: setting.kind,
              value: value,
              sensitive: setting.sensitive,
              choices: setting.choices,
            );
        }
        _changed = true;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _apply() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.onApply();
      if (mounted) Navigator.pop(context, true);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _editText(ComicSourceSetting setting) async {
    final controller = TextEditingController(text: setting.value as String);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(setting.title),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: setting.sensitive,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            hintText: setting.summary,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null && value != setting.value) {
      await _update(setting, value);
    }
  }

  Future<void> _select(ComicSourceSetting setting) async {
    final value = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(setting.title),
        children: setting.choices.map((choice) {
          return RadioListTile<String>(
            value: choice.value,
            groupValue: setting.value as String,
            title: Text(choice.label),
            onChanged: (value) => Navigator.pop(context, value),
          );
        }).toList(growable: false),
      ),
    );
    if (value != null && value != setting.value) {
      await _update(setting, value);
    }
  }

  Future<void> _invokeAction(ComicSourceSetting setting) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await _source.updateSetting(setting.key, true);
      final settings = await _source.loadSettings();
      if (!mounted) return;
      setState(() => _settings = settings);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('插件操作已执行')),
      );
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _selectMany(ComicSourceSetting setting) async {
    final selected = Set<String>.from(setting.value as List<String>);
    final value = await showDialog<List<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(setting.title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: setting.choices.map((choice) {
                return CheckboxListTile(
                  value: selected.contains(choice.value),
                  title: Text(choice.label),
                  onChanged: (enabled) {
                    setDialogState(() {
                      if (enabled ?? false) {
                        selected.add(choice.value);
                      } else {
                        selected.remove(choice.value);
                      }
                    });
                  },
                );
              }).toList(growable: false),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                selected.toList(growable: false)..sort(),
              ),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (value != null) await _update(setting, value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.source.descriptor.name} 设置'),
        actions: <Widget>[
          TextButton(
            onPressed: _changed && !_working ? () => unawaited(_apply()) : null,
            child: const Text('应用并重启'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: <Widget>[
                if (widget.onLogin != null)
                  ListTile(
                    leading: const Icon(Icons.login),
                    title: const Text('网页登录'),
                    subtitle: Text(widget.source.descriptor.website.toString()),
                    onTap: _working
                        ? null
                        : () => unawaited(widget.onLogin!()),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      _error.toString(),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (_settings.isEmpty)
                  ListTile(
                    title: const Text('该漫画源没有扩展自定义设置'),
                    subtitle: widget.onLogin == null
                        ? null
                        : const Text('仍可使用网页登录建立 Cookie 会话'),
                  ),
                for (final setting in _settings) _settingTile(setting),
                if (_working) const LinearProgressIndicator(),
              ],
            ),
    );
  }

  Widget _settingTile(ComicSourceSetting setting) {
    switch (setting.kind) {
      case ComicSourceSettingKind.toggle:
        return SwitchListTile(
          value: setting.value as bool,
          title: Text(setting.title),
          subtitle: setting.summary == null ? null : Text(setting.summary!),
          onChanged: _working
              ? null
              : (value) => unawaited(_update(setting, value)),
        );
      case ComicSourceSettingKind.text:
        return ListTile(
          title: Text(setting.title),
          subtitle: Text(
            setting.sensitive
                ? '••••••••'
                : (setting.value as String).isEmpty
                    ? setting.summary ?? '未设置'
                    : setting.value as String,
          ),
          trailing: const Icon(Icons.edit_outlined),
          onTap: _working ? null : () => unawaited(_editText(setting)),
        );
      case ComicSourceSettingKind.select:
        final currentChoices = setting.choices
            .where((choice) => choice.value == setting.value)
            .toList(growable: false);
        final current =
            currentChoices.isEmpty ? null : currentChoices.first.label;
        return ListTile(
          title: Text(setting.title),
          subtitle: Text(current ?? setting.summary ?? '未选择'),
          trailing: const Icon(Icons.arrow_drop_down),
          onTap: _working ? null : () => unawaited(_select(setting)),
        );
      case ComicSourceSettingKind.multiSelect:
        return ListTile(
          title: Text(setting.title),
          subtitle: Text(
            '${(setting.value as List<String>).length} 项已选择',
          ),
          trailing: const Icon(Icons.checklist),
          onTap: _working ? null : () => unawaited(_selectMany(setting)),
        );
      case ComicSourceSettingKind.action:
        return ListTile(
          title: Text(setting.title),
          subtitle: setting.summary == null ? null : Text(setting.summary!),
          trailing: FilledButton.tonal(
            onPressed: _working
                ? null
                : () => unawaited(_invokeAction(setting)),
            child: Text(setting.value as String),
          ),
        );
    }
  }
}
