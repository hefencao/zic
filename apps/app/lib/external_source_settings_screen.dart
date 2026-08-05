import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:flutter/material.dart';

import 'dialog_actions.dart';

typedef ExternalSourceLoginSnapshot = ({
  Uri currentUrl,
  String title,
  Map<String, String> cookies,
  Map<String, String> localStorage,
});

final class ExternalSourceSettingsScreen extends StatefulWidget {
  const ExternalSourceSettingsScreen({
    required this.source,
    required this.onApply,
    this.onLogin,
    this.onReadLogin,
    super.key,
  });

  final BrowsableComicSource source;
  final Future<void> Function() onApply;
  final Future<void> Function(Uri url)? onLogin;
  final Future<ExternalSourceLoginSnapshot?> Function(Uri url)? onReadLogin;

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
  ComicSourceAccount? _account;

  ConfigurableComicSource get _source =>
      widget.source as ConfigurableComicSource;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    var settings = const <ComicSourceSetting>[];
    ComicSourceAccount? account;
    Object? firstError;
    try {
      settings = await _source.loadSettings();
    } on Object catch (error) {
      firstError = error;
    }
    if (widget.source.sourceId.startsWith('venera:') &&
        widget.source is AuthenticatableComicSource) {
      try {
        account = await (widget.source as AuthenticatableComicSource)
            .loadAccount();
      } on Object catch (error) {
        firstError ??= error;
      }
    }
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _account = account;
      _error = firstError;
      _loading = false;
    });
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
          AppDialogActions(
            onClose: () => Navigator.pop(context),
            actions: <Widget>[
              FilledButton(
                onPressed: () => Navigator.pop(context, controller.text.trim()),
                child: const Text('保存'),
              ),
            ],
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
      builder: (context) => AlertDialog(
        title: Text(setting.title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: setting.choices.map((choice) {
              return RadioListTile<String>(
                value: choice.value,
                groupValue: setting.value as String,
                title: Text(choice.label),
                onChanged: (value) => Navigator.pop(context, value),
              );
            }).toList(growable: false),
          ),
        ),
        actions: <Widget>[
          AppDialogActions(
            onClose: () => Navigator.pop(context),
            actions: const <Widget>[],
          ),
        ],
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
            AppDialogActions(
              onClose: () => Navigator.pop(context),
              actions: <Widget>[
                FilledButton(
                  onPressed: () => Navigator.pop(
                    context,
                    selected.toList(growable: false)..sort(),
                  ),
                  child: const Text('保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (value != null) await _update(setting, value);
  }


  AuthenticatableComicSource get _accountSource =>
      widget.source as AuthenticatableComicSource;

  Future<void> _withAccountWork(Future<void> Function() action) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await action();
      final account = await _accountSource.loadAccount();
      if (mounted) setState(() => _account = account);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _loginCredentials() async {
    final accountController = TextEditingController();
    final passwordController = TextEditingController();
    final values = await showDialog<(String, String)>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('登录漫画源'),
        content: AutofillGroup(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: accountController,
                autofocus: true,
                autofillHints: const <String>[AutofillHints.username],
                decoration: const InputDecoration(
                  labelText: '账号',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passwordController,
                obscureText: true,
                autofillHints: const <String>[AutofillHints.password],
                decoration: const InputDecoration(
                  labelText: '密码',
                  border: OutlineInputBorder(),
                ),
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
                  final account = accountController.text.trim();
                  final password = passwordController.text;
                  if (account.isNotEmpty && password.isNotEmpty) {
                    Navigator.pop(context, (account, password));
                  }
                },
                child: const Text('登录'),
              ),
            ],
          ),
        ],
      ),
    );
    accountController.dispose();
    passwordController.dispose();
    if (values == null) return;
    await _withAccountWork(
      () => _accountSource.loginWithCredentials(values.$1, values.$2),
    );
  }

  Future<void> _loginCookies(List<String> fields) async {
    final controllers = <String, TextEditingController>{
      for (final field in fields) field: TextEditingController(),
    };
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cookie 登录'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final entry in controllers.entries) ...<Widget>[
                TextField(
                  controller: entry.value,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: entry.key,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ],
          ),
        ),
        actions: <Widget>[
          AppDialogActions(
            onClose: () => Navigator.pop(context),
            actions: <Widget>[
              FilledButton(
                onPressed: () {
                  final result = <String, String>{
                    for (final entry in controllers.entries)
                      entry.key: entry.value.text.trim(),
                  };
                  if (result.values.every((value) => value.isNotEmpty)) {
                    Navigator.pop(context, result);
                  }
                },
                child: const Text('验证并登录'),
              ),
            ],
          ),
        ],
      ),
    );
    for (final controller in controllers.values) {
      controller.dispose();
    }
    if (values == null) return;
    await _withAccountWork(() => _accountSource.loginWithCookies(values));
  }

  Future<void> _openWebLogin() async {
    final open = widget.onLogin;
    if (open == null) return;
    final website = _account?.loginWebsite;
    if (website == null) return;
    await open(website);
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('完成网页登录'),
        content: const Text('返回后确认登录状态。若网页仍未完成登录，请关闭此面板后重新打开。'),
        actions: <Widget>[
          AppDialogActions(
            onClose: () => Navigator.pop(context, false),
            actions: <Widget>[
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('验证登录'),
              ),
            ],
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      final snapshot = await widget.onReadLogin?.call(website);
      await _withAccountWork(
        () => _accountSource.confirmWebLogin(
          currentUrl: snapshot?.currentUrl.toString(),
          title: snapshot?.title,
          cookies: snapshot?.cookies ?? const <String, String>{},
          localStorage:
              snapshot?.localStorage ?? const <String, String>{},
        ),
      );
    }
  }

  Widget _accountSection() {
    final account = _account;
    if (account == null) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Column(
        children: <Widget>[
          ListTile(
            leading: Icon(
              account.loggedIn ? Icons.verified_user : Icons.person_outline,
            ),
            title: Text(account.loggedIn ? '已登录' : '账号登录'),
            subtitle: Text(
              account.loggedIn
                  ? '登录状态由插件隔离存储维护'
                  : '选择该插件支持的登录方式',
            ),
          ),
          if (!account.loggedIn && account.supportsCredentials)
            ListTile(
              leading: const Icon(Icons.password),
              title: const Text('账号与密码'),
              onTap: _working ? null : () => unawaited(_loginCredentials()),
            ),
          if (!account.loggedIn && account.cookieFields.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.cookie_outlined),
              title: const Text('Cookie 登录'),
              subtitle: Text(account.cookieFields.join('、')),
              onTap: _working
                  ? null
                  : () => unawaited(_loginCookies(account.cookieFields)),
            ),
          if (!account.loggedIn && account.loginWebsite != null)
            ListTile(
              leading: const Icon(Icons.open_in_browser),
              title: const Text('网页登录'),
              subtitle: Text(account.loginWebsite.toString()),
              onTap: _working ? null : () => unawaited(_openWebLogin()),
            ),
          if (account.loggedIn)
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('退出登录'),
              onTap: _working
                  ? null
                  : () => unawaited(_withAccountWork(_accountSource.logout)),
            ),
        ],
      ),
    );
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
                if (_account != null) _accountSection(),
                if (_account == null && widget.onLogin != null)
                  ListTile(
                    leading: const Icon(Icons.login),
                    title: const Text('网页登录'),
                    subtitle: Text(widget.source.descriptor.website.toString()),
                    onTap: _working
                        ? null
                        : () => unawaited(
                              widget.onLogin!(widget.source.descriptor.website),
                            ),
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
                    subtitle: widget.onLogin == null && _account == null
                        ? null
                        : const Text('仍可使用上方账号功能建立会话'),
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
