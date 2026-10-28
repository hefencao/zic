import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:flutter/material.dart';

import 'app_preferences.dart';
import 'dialog_actions.dart';
import 'extension_repositories.dart';

final class ExtensionRepositoryManagementScreen extends StatefulWidget {
  const ExtensionRepositoryManagementScreen({required this.format,
    required this.preferences, required this.onSelectionChanged,
    this.initialIndex = '', super.key});

  final ExternalComicPluginFormat format;
  final AppPreferencesController preferences;
  final VoidCallback onSelectionChanged;
  final String initialIndex;

  @override
  State<ExtensionRepositoryManagementScreen> createState() =>
      _ExtensionRepositoryManagementScreenState();
}

enum _RepositoryAction { edit, remove }

final class _ExtensionRepositoryManagementScreenState
    extends State<ExtensionRepositoryManagementScreen> {
  List<ExtensionRepository> get _repositories => widget.preferences.extensionRepositories
      .where((repository) => repository.format == widget.format).toList(growable: false);

  ExtensionRepository _current(ExtensionRepository repository) {
    final current = _repositories.where((item) => item.identity == repository.identity).firstOrNull;
    if (current == null) throw const FormatException('仓库已被移除，请重新添加');
    return current;
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(error is FormatException ? error.message.toString() : error.toString()),
    ));
  }

  Future<void> _edit([ExtensionRepository? previous]) => showDialog<void>(
    context: context,
    builder: (_) => _RepositoryEditor(
      format: widget.format, previous: previous, initialIndex: widget.initialIndex,
      onSave: (updated) async {
        if (previous == null) {
          if (_repositories.any((item) => item.identity == updated.identity)) {
            throw const FormatException('该仓库地址已存在');
          }
          widget.preferences.setExtensionRepository(updated);
          if (updated.enabled) widget.onSelectionChanged();
        } else {
          final current = _current(previous);
          final next = updated.copyWith(enabled: current.enabled);
          if (current.index == next.index && current.name == next.name) return;
          widget.preferences.replaceExtensionRepository(current, next);
          if (current.enabled && current.index != next.index) widget.onSelectionChanged();
        }
        await widget.preferences.flush();
      },
    ),
  );

  Future<void> _toggle(ExtensionRepository repository, bool enabled) async {
    try {
      final current = _current(repository);
      widget.preferences.replaceExtensionRepository(current, current.copyWith(enabled: enabled));
      widget.onSelectionChanged();
      await widget.preferences.flush();
    } on Object catch (error) { _showError(error); }
  }

  Future<void> _remove(ExtensionRepository repository) async {
    try {
      final current = _current(repository);
      widget.preferences.removeExtensionRepository(current);
      if (current.enabled) widget.onSelectionChanged();
      await widget.preferences.flush();
    } on Object catch (error) { _showError(error); }
  }

  String? _subtitle(ExtensionRepository repository, List<ExtensionRepository> repositories) {
    final hosted = repository.hostedRepository;
    final parts = <String>[
      if (repository.displayName != repository.index.host) repository.index.host,
      if (repository.name.trim().isNotEmpty && hosted != null && hosted != repository.displayName) hosted,
    ];
    final peers = repositories.where((other) => other.index.host == repository.index.host &&
        other.hostedRepository == hosted).toList();
    if (peers.length > 1) {
      try {
        final path = repository.index.pathSegments;
        var length = 1;
        while (length < path.length && peers.any((other) => other.identity != repository.identity &&
            other.index.pathSegments.reversed.take(length).join('/') ==
              path.reversed.take(length).join('/'))) {
          length++;
        }
        final hint = path.skip(path.length > length ? path.length - length : 0).join('/');
        if (hint.isNotEmpty) parts.add(hint);
        if (peers.any((other) => other.identity != repository.identity &&
            other.index.path == repository.index.path)) {
          parts.add('索引 ${peers.indexOf(repository) + 1}');
        }
      } on FormatException { /* The editor still exposes the exact URL. */ }
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('仓库管理'), actions: <Widget>[
      IconButton(tooltip: '添加仓库', onPressed: () => unawaited(_edit()),
        icon: const Icon(Icons.add)),
    ]),
    body: AnimatedBuilder(animation: widget.preferences, builder: (context, _) {
      final repositories = _repositories;
      if (repositories.isEmpty) return const Center(child: Text('暂无仓库，点击右上角添加'));
      return ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: repositories.length,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 16, endIndent: 16),
        itemBuilder: (context, index) {
          final repository = repositories[index];
          final subtitle = _subtitle(repository, repositories);
          return ListTile(
            key: ValueKey<String>('extension-repository:${repository.identity}'),
            leading: Switch(value: repository.enabled,
              onChanged: (value) => unawaited(_toggle(repository, value))),
            title: Text(repository.displayName, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: subtitle == null ? null : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
            onTap: () => unawaited(_edit(repository)),
            trailing: PopupMenuButton<_RepositoryAction>(
              tooltip: '仓库操作',
              onSelected: (action) => unawaited(action == _RepositoryAction.edit
                  ? _edit(repository) : _remove(repository)),
              itemBuilder: (_) => const <PopupMenuEntry<_RepositoryAction>>[
                PopupMenuItem(value: _RepositoryAction.edit, child: Text('编辑仓库')),
                PopupMenuItem(value: _RepositoryAction.remove, child: Text('移除仓库')),
              ],
            ),
          );
        },
      );
    }),
  );
}

final class _RepositoryEditor extends StatefulWidget {
  const _RepositoryEditor({required this.format, required this.previous,
    required this.initialIndex, required this.onSave});

  final ExternalComicPluginFormat format;
  final ExtensionRepository? previous;
  final String initialIndex;
  final Future<void> Function(ExtensionRepository repository) onSave;

  @override
  State<_RepositoryEditor> createState() => _RepositoryEditorState();
}

final class _RepositoryEditorState extends State<_RepositoryEditor> {
  late final _name = TextEditingController(text: widget.previous?.name ?? '');
  late final _url = TextEditingController(text: widget.previous?.index.toString() ?? widget.initialIndex);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() { _saving = true; _error = null; });
    try {
      final repository = ExtensionRepository(format: widget.format,
        index: Uri.parse(_url.text.trim()), name: _name.text.trim(),
        enabled: widget.previous?.enabled ?? true);
      final validated = ExtensionRepository.parse(repository.identity, repository.data);
      await widget.onSave(validated);
      if (mounted) Navigator.pop(context);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error is FormatException
          ? error.message.toString() : error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.previous == null ? '添加仓库' : '编辑仓库'),
    content: SizedBox(width: 440, child: SingleChildScrollView(child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TextField(controller: _name, enabled: !_saving, maxLength: 120,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: '仓库名称（可选）',
            hintText: '留空则自动识别', counterText: '', border: OutlineInputBorder())),
        const SizedBox(height: 16),
        TextField(controller: _url, enabled: !_saving, keyboardType: TextInputType.url,
          autocorrect: false, minLines: 1, maxLines: 4,
          decoration: const InputDecoration(labelText: 'HTTPS 仓库索引',
            border: OutlineInputBorder()),
          onSubmitted: (_) => unawaited(_save())),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12),
          child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      ],
    ))),
    actions: <Widget>[
      AppDialogActions(
        onClose: _saving ? null : () => Navigator.pop(context),
        actions: <Widget>[
          FilledButton(onPressed: _saving ? null : () => unawaited(_save()), child: const Text('保存')),
        ],
      ),
    ],
  );
}
