import 'dart:async';

import 'package:network_bridge/network_bridge.dart';
import 'package:flutter/material.dart';

import 'webdav_sync.dart';
import 'library_data_scope.dart';
import 'library_data_selector.dart';

const webDavScreenKey = ValueKey<String>('webdav-screen');
const webDavAddressKey = ValueKey<String>('webdav-address');
const webDavUsernameKey = ValueKey<String>('webdav-username');
const webDavPasswordKey = ValueKey<String>('webdav-password');
const webDavSaveKey = ValueKey<String>('webdav-save');
const webDavTestKey = ValueKey<String>('webdav-test');
const webDavSyncKey = ValueKey<String>('webdav-sync');
const webDavCancelKey = ValueKey<String>('webdav-cancel');
const webDavDisconnectKey = ValueKey<String>('webdav-disconnect');

final class WebDavSyncScreen extends StatefulWidget {
  const WebDavSyncScreen({required this.controller, super.key});
  final WebDavSyncController controller;
  @override
  State<WebDavSyncScreen> createState() => _WebDavSyncScreenState();
}

final class _WebDavSyncScreenState extends State<WebDavSyncScreen> {
  final _form = GlobalKey<FormState>();
  final _address = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _loading = true;
  bool _acting = false;
  bool _actionCancelled = false;
  bool _obscure = true;
  String? _loadError;
  Set<LibraryDataSection> _sections = Set.of(allLibraryDataSections);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await widget.controller.initialize();
      if (!mounted) return;
      final config = widget.controller.config;
      _address.text = config?.base.toString() ?? '';
      _username.text = config?.username ?? '';
      _password.text = config?.password ?? '';
      _sections = widget.controller.sections;
    } on Object {
      _loadError = '无法读取本机 WebDAV 配置';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _act(String action) async {
    if (!(_form.currentState?.validate() ?? false)) return;
    _actionCancelled = false;
    setState(() => _acting = true);
    try {
      final config = WebDavConfig(address: _address.text,
        username: _username.text, password: _password.text);
      await widget.controller.saveConfiguration(config, sections: _sections);
      if (_actionCancelled) return;
      if (action == 'test') await widget.controller.testConnection();
      if (action == 'sync') await widget.controller.synchronize();
    } on Object {
      // The controller publishes a redacted operation error.
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _cancelAction() async {
    _actionCancelled = true;
    await widget.controller.cancel();
  }

  Future<void> _disconnect() async {
    setState(() => _acting = true);
    try {
      await widget.controller.disconnect();
      _address.clear();
      _username.clear();
      _password.clear();
      _sections = widget.controller.sections;
    } on Object {
      // Preserve the existing form if persistence fails.
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  @override
  void dispose() {
    _address.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final busy = _loading || _acting || controller.busy;
        final last = controller.lastResult;
        final localTime = last?.completedAt.toLocal();
        return Scaffold(
          key: webDavScreenKey,
          appBar: AppBar(title: const Text('WebDAV 同步')),
          body: Form(
            key: _form,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                const Text('选择要在设备间同步的数据。未勾选的数据保留在两端，不会删除或覆盖。'),
                const SizedBox(height: 8),
                Text('连接信息仅保存在本机。漫画文件、缓存、下载任务、API 密钥、登录配置和设备目录不上传；'
                  '本地漫画需在对应设备导入文件后才能恢复阅读。',
                  style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 20),
                TextFormField(
                  key: webDavAddressKey,
                  controller: _address,
                  enabled: !busy,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'WebDAV 目录地址',
                    hintText: 'https://example.com/dav/',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    try {
                      WebDavConfig(address: value ?? '',
                        username: _username.text, password: _password.text);
                      return null;
                    } on FormatException catch (error) {
                      return error.message;
                    }
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: webDavUsernameKey,
                  controller: _username,
                  enabled: !busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: '用户名', border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: webDavPasswordKey,
                  controller: _password,
                  enabled: !busy,
                  obscureText: _obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: '密码或应用专用密码',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: _obscure ? '显示密码' : '隐藏密码',
                      onPressed: () => setState(() => _obscure = !_obscure),
                      icon: Icon(_obscure ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('同步数据'),
                  subtitle: Text(_sections.isEmpty ? '请至少选择一类'
                    : _sections.length.toString() + ' 类数据'),
                  children: [LibraryDataSelector(selected: _sections, enabled: !busy,
                    onChanged: (next) => setState(() => _sections = next))],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12, runSpacing: 8,
                  children: <Widget>[
                    OutlinedButton(
                      key: webDavSaveKey, onPressed: busy || _sections.isEmpty ? null : () => _act('save'),
                      child: const Text('保存配置'),
                    ),
                    OutlinedButton(
                      key: webDavTestKey, onPressed: busy || _sections.isEmpty ? null : () => _act('test'),
                      child: const Text('测试连接'),
                    ),
                    FilledButton.icon(
                      key: webDavSyncKey, onPressed: busy || _sections.isEmpty ? null : () => _act('sync'),
                      icon: const Icon(Icons.sync), label: const Text('立即同步'),
                    ),
                    if (controller.busy)
                      TextButton(
                        key: webDavCancelKey,
                        onPressed: _cancelAction,
                        child: const Text('取消'),
                      ),
                  ],
                ),
                if (_loading || controller.busy) ...<Widget>[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                ],
                if (_loadError != null || controller.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(_loadError ?? controller.error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  )
                else if (controller.message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(controller.message!),
                  ),
                const SizedBox(height: 24),
                Text(localTime == null ? '尚未同步'
                  : '上次同步：' + localTime.toString().split('.').first +
                    '\n' + last!.records.toString() + ' 项记录'),
                const SizedBox(height: 8),
                Text('首次同步会合并两边已有数据；同一记录使用更新的修改，删除标记会同步。'
                  '云端每日保留一份备份，按 7 日、4 周、12 月保留历史，并定期整理过期数据。'
                  '同步读取最新完整版本，仅上传变化数据。'
                  '在此页点“立即同步”开始，不影响日常启动和阅读。',
                  style: Theme.of(context).textTheme.bodySmall),
                if (controller.config != null) ...<Widget>[
                  const SizedBox(height: 16),
                  TextButton(
                    key: webDavDisconnectKey,
                    onPressed: busy ? null : _disconnect,
                    child: const Text('移除本机连接配置'),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
