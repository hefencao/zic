import 'dart:async';

import 'package:flutter/material.dart';
import 'package:storage_bridge/storage_bridge.dart';

import 'app_preferences.dart';
import 'diagnostic_error_ui.dart';
import 'dialog_actions.dart';
import 'directory_picker.dart';

const sourceSettingsScreenKey = ValueKey<String>('source-settings-screen');
const sourceSettingsLayoutConfidenceKey = ValueKey<String>(
  'source-settings-layout-confidence',
);
const sourceSettingsDataTrustKey = ValueKey<String>(
  'source-settings-data-trust',
);
const sourceSettingsDownloadDirectoryKey = ValueKey<String>(
  'source-settings-download-directory',
);

enum _SourceHistoricalTrustChoice { inherit, strict, trust }

final class SourceSettingsScreen extends StatefulWidget {
  const SourceSettingsScreen({
    required this.sourceId,
    required this.sourceName,
    required this.preferences,
    super.key,
  });

  final String sourceId;
  final String sourceName;
  final AppPreferencesController preferences;

  @override
  State<SourceSettingsScreen> createState() => _SourceSettingsScreenState();
}

final class _SourceSettingsScreenState extends State<SourceSettingsScreen> {
  bool _changingDownloadDirectory = false;

  AppPreferencesController get _preferences => widget.preferences;

  double get _webtoonConfidence =>
      _preferences.sourceAdaptiveWebtoonConfidenceFor(widget.sourceId);

  bool? get _trustOverride => _preferences
      .conflictingHistoricalCarrierTrustOverrideForSource(widget.sourceId);

  bool get _effectiveTrust =>
      _preferences.trustConflictingHistoricalCarriersForSource(widget.sourceId);

  String? get _downloadDirectory =>
      _preferences.sourceDownloadDirectoryFor(widget.sourceId);

  String _confidenceLabel(double confidence) {
    final percent = (confidence * 100).round();
    if (confidence == 0.5) return '自动/中性 · 条漫置信 50%';
    if (confidence < 0.5) return '偏页漫 · 条漫置信 $percent%';
    return '偏条漫 · 条漫置信 $percent%';
  }

  Future<void> _editLayoutConfidence() async {
    var draft = _webtoonConfidence;
    final value = await showDialog<double>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('自适应布局'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '设置这个来源的条漫置信：0% 强页漫，50% 自动/中性，'
                  '100% 强条漫。漫画自身明确标签和手动方向仍优先。',
                ),
                const SizedBox(height: 12),
                Slider(
                  key: sourceSettingsLayoutConfidenceKey,
                  value: draft,
                  min: 0,
                  max: 1,
                  divisions: 20,
                  label: '${(draft * 100).round()}%',
                  onChanged: (next) => setDialogState(() => draft = next),
                ),
                Text(_confidenceLabel(draft)),
              ],
            ),
          ),
          actions: <Widget>[
            AppDialogActions(
              onClose: () => Navigator.pop(dialogContext),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, 0.5),
                  child: const Text('恢复自动'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, draft),
                  child: const Text('保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (!mounted || value == null) return;
    _preferences.setSourceAdaptiveWebtoonConfidence(widget.sourceId, value);
    setState(() {});
  }

  Future<void> _editDataTrust() async {
    final currentOverride = _trustOverride;
    final selected = await showDialog<_SourceHistoricalTrustChoice>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('数据信任'),
        content: Text(
          '当同一页面和同一 sourceRevision 下存在多个完整历史缓存，'
          '但 length/CRC 不一致时：严格校验会拒绝冲突缓存并重新请求来源；'
          '“完整文件也信任”会优先使用最近的完整历史缓存。\n\n'
          '跟随全局当前为“${_preferences.trustConflictingHistoricalCarriersByDefault ? '完整文件也信任' : '严格校验'}”。',
        ),
        actions: <Widget>[
          AppDialogActions(
            onClose: () => Navigator.pop(dialogContext),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  _SourceHistoricalTrustChoice.inherit,
                ),
                child: Text(currentOverride == null ? '跟随全局（当前）' : '跟随全局'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  _SourceHistoricalTrustChoice.strict,
                ),
                child: Text(currentOverride == false ? '严格校验（当前）' : '严格校验'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  _SourceHistoricalTrustChoice.trust,
                ),
                child: Text(
                  currentOverride == true ? '完整文件也信任（当前）' : '完整文件也信任',
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (!mounted || selected == null) return;
    switch (selected) {
      case _SourceHistoricalTrustChoice.inherit:
        _preferences.clearSourceTrustConflictingHistoricalCarriersOverride(
          widget.sourceId,
        );
        break;
      case _SourceHistoricalTrustChoice.strict:
        _preferences.setSourceTrustConflictingHistoricalCarriers(
          widget.sourceId,
          false,
        );
        break;
      case _SourceHistoricalTrustChoice.trust:
        _preferences.setSourceTrustConflictingHistoricalCarriers(
          widget.sourceId,
          true,
        );
        break;
    }
    setState(() {});
  }

  Future<void> _editDownloadDirectory() async {
    if (_changingDownloadDirectory) return;
    final decision = await showDialog<_SourceDownloadDirectoryDecision>(
      context: context,
      builder: (dialogContext) => _SourceDownloadDirectoryDialog(
        sourceName: widget.sourceName,
        currentDirectory: _downloadDirectory,
      ),
    );
    if (!mounted || decision == null) return;
    String? target = decision.directory;
    if (decision.restoreDefault) {
      target = null;
    } else {
      if (target == null) return;
      if (target.startsWith('saf://')) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('来源独立目录仅支持本地文件夹；如需使用 SAF 请设置全局默认下载目录')),
        );
        return;
      }
      setState(() => _changingDownloadDirectory = true);
      try {
        target = await resolveChapterDownloadDirectory(target);
        await probeChapterDownloadDirectoryWritable(target);
      } on Object catch (error) {
        debugPrint('source download directory resolve failed: $error');
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(copyableDiagnosticSnackBar('无法使用所选目录：$error'));
        }
        return;
      } finally {
        if (mounted) setState(() => _changingDownloadDirectory = false);
      }
    }
    _preferences.setSourceDownloadDirectory(widget.sourceId, target);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(target == null ? '已恢复默认下载目录' : '这个来源的新下载将写入：$target'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: sourceSettingsScreenKey,
      appBar: AppBar(title: Text('源设置 · ${widget.sourceName}')),
      body: AnimatedBuilder(
        animation: _preferences,
        builder: (context, _) {
          final confidence = _webtoonConfidence;
          final trustOverride = _trustOverride;
          final directory = _downloadDirectory;
          return ListView(
            children: <Widget>[
              const _SourceSettingsSectionTitle('阅读布局'),
              ListTile(
                leading: const Icon(Icons.view_stream_outlined),
                title: const Text('自适应布局'),
                subtitle: Text(_confidenceLabel(confidence)),
                trailing: const Icon(Icons.chevron_right),
                onTap: _editLayoutConfidence,
              ),
              const Divider(),
              const _SourceSettingsSectionTitle('数据'),
              ListTile(
                key: sourceSettingsDataTrustKey,
                leading: Icon(
                  _effectiveTrust
                      ? Icons.verified_user_outlined
                      : Icons.shield_outlined,
                ),
                title: const Text('数据信任'),
                subtitle: Text(
                  trustOverride == null
                      ? '跟随全局 · ${_effectiveTrust ? '完整文件也信任' : '严格校验'}'
                      : trustOverride
                      ? '完整文件也信任'
                      : '严格校验',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: _editDataTrust,
              ),
              ListTile(
                key: sourceSettingsDownloadDirectoryKey,
                leading: const Icon(Icons.folder_copy_outlined),
                title: const Text('下载目录'),
                subtitle: Text(directory ?? '跟随全局默认下载目录'),
                trailing: _changingDownloadDirectory
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.chevron_right),
                onTap: _changingDownloadDirectory
                    ? null
                    : _editDownloadDirectory,
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text(
                  '来源独立目录只决定这个来源的新下载写入位置；'
                  '已有文件仍按索引中的原位置读取，不会在这里自动搬迁。',
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

final class _SourceSettingsSectionTitle extends StatelessWidget {
  const _SourceSettingsSectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(title, style: Theme.of(context).textTheme.titleSmall),
  );
}

final class _SourceDownloadDirectoryDecision {
  const _SourceDownloadDirectoryDecision({
    required this.restoreDefault,
    this.directory,
  });

  final bool restoreDefault;
  final String? directory;
}

final class _SourceDownloadDirectoryDialog extends StatefulWidget {
  const _SourceDownloadDirectoryDialog({
    required this.sourceName,
    required this.currentDirectory,
  });

  final String sourceName;
  final String? currentDirectory;

  @override
  State<_SourceDownloadDirectoryDialog> createState() =>
      _SourceDownloadDirectoryDialogState();
}

final class _SourceDownloadDirectoryDialogState
    extends State<_SourceDownloadDirectoryDialog> {
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
      failure = error;
    } finally {
      if (mounted) setState(() => _picking = false);
    }
    if (!mounted) return;
    if (failure != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(copyableDiagnosticSnackBar('无法打开目录选择器：$failure'));
      return;
    }
    if (picked == null || picked.isEmpty) return;
    setState(() => _picked = picked);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('下载目录 · ${widget.sourceName}'),
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SelectableText('当前：${widget.currentDirectory ?? '默认下载目录'}'),
          if (_picked != null) ...<Widget>[
            const SizedBox(height: 8),
            SelectableText('新目录：$_picked'),
          ],
          const SizedBox(height: 8),
          const Text('只影响这个来源的新下载；已有文件保留原位置。'),
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
                const _SourceDownloadDirectoryDecision(restoreDefault: true),
              ),
              child: const Text('恢复默认'),
            ),
          FilledButton(
            onPressed: _picked == null
                ? null
                : () => Navigator.pop(
                    context,
                    _SourceDownloadDirectoryDecision(
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
