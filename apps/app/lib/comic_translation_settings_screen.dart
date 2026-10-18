import 'dart:async';

import 'package:comic_translation/comic_translation.dart';
import 'package:flutter/material.dart';

import 'comic_translation_test_actions.dart';
import 'directory_picker.dart';
import 'saf_store.dart';
import 'translation_composition.dart';

const comicTranslationSettingsKey = ValueKey('comic-translation-settings');

final class ComicTranslationSettingsScreen extends StatefulWidget {
  const ComicTranslationSettingsScreen({super.key});

  @override
  State<ComicTranslationSettingsScreen> createState() => _ComicTranslationSettingsScreenState();
}

final class _ComicTranslationSettingsScreenState extends State<ComicTranslationSettingsScreen> {
  final _settings = ComicTranslationSettings.instance;
  late final Future<void> _ready;
  final _name = TextEditingController();
  final _endpoint = TextEditingController();
  final _model = TextEditingController();
  final _prompt = TextEditingController();
  final _key = TextEditingController();
  List<ComicTranslationRemoteProfile> _profiles = [];
  String _profileId = 'default';
  String _backend = 'none';
  String _localModel = '';
  String _source = 'auto';
  String _target = 'zh-CN';
  int _contextPages = 2;
  ComicTranslationQuality _quality = ComicTranslationQuality.balanced;
  int _analysisSide = 1600;
  double _detectionThreshold = .45;
  double _recognitionThreshold = .35;
  double _unclipRatio = 1.4;
  int _prefetchPages = 4;
  int _cachePrefetchPages = 4;
  bool _enabled = false;
  bool _soundEffects = false;
  bool _cleanOverlay = true;
  String _indicator = 'always';
  bool _working = false;
  String? _result;
  bool get _remote => _backend == 'openaiCompatible' || _backend == 'deepl';

  @override
  void initState() {
    super.initState();
    _ready = _load();
  }

  Future<void> _load() async {
    await initializeComicTranslation();
    if (!mounted) return;
    final values = _settings.values;
    _backend = values['comicTranslationBackend'] as String;
    _localModel = values['comicTranslationLocalModel'] as String;
    _profiles = (values['comicTranslationRemoteProfiles'] as List).map((value) =>
        ComicTranslationRemoteProfile.fromJson(Map<String, dynamic>.from(value as Map))).toList();
    _profileId = values['comicTranslationRemoteProfile'] as String;
    _enabled = values['enabled'] == true;
    _source = values['sourceLanguage'] as String;
    _target = values['targetLanguage'] as String;
    _loadTuning(values);
    _soundEffects = values['translateSoundEffects'] == true;
    _cleanOverlay = values['useCleanOverlay'] == true;
    _indicator = values['showIndicator'] != true ? 'off' :
        values['indicatorOnlyWhileProcessing'] == true ? 'processing' : 'always';
    if (_remote) _selectBackendProfile();
  }

  void _loadTuning(Map<String, Object?> values) {
    _quality = ComicTranslationQuality.values.where((q) => q.name == values['translationQuality'])
        .firstOrNull ?? ComicTranslationQuality.custom;
    final ocr = ComicOcrParameters.fromSettings(values);
    _analysisSide = ocr.maxAnalysisSide;
    _detectionThreshold = ocr.detectionThreshold;
    _recognitionThreshold = ocr.recognitionThreshold;
    _unclipRatio = ocr.unclipRatio;
    _contextPages = values['contextPages'] as int? ?? 2;
    _prefetchPages = values['translationPrefetchPages'] as int? ?? 4;
    _cachePrefetchPages = values['translationCachePrefetchPages'] as int? ?? 4;
    if (_quality != ComicTranslationQuality.custom &&
        !_quality.settings.entries.every((entry) => _tuning[entry.key] == entry.value)) {
      _quality = ComicTranslationQuality.custom;
    }
  }

  Map<String, Object?> get _tuning => {
    ...ComicOcrParameters(maxAnalysisSide: _analysisSide,
      detectionThreshold: _detectionThreshold, recognitionThreshold: _recognitionThreshold,
      unclipRatio: _unclipRatio).toSettings(),
    'translationQuality': _quality.name,
    'translationPrefetchPages': _prefetchPages,
    'translationCachePrefetchPages': _cachePrefetchPages,
    'contextPages': _contextPages,
  };

  void _custom(VoidCallback update) => setState(() {
    update();
    _quality = ComicTranslationQuality.custom;
  });

  ComicTranslationRemoteProfile _draft() => ComicTranslationRemoteProfile(
        id: _profileId,
        backend: _backend,
        name: _name.text.trim(),
        endpoint: _endpoint.text.trim(),
        model: _model.text.trim(),
        additionalPrompt: _prompt.text.trim(),
      );

  void _selectBackendProfile() {
    var profile = _profiles.where((p) => p.id == _profileId && p.backend == _backend).firstOrNull;
    profile ??= _profiles.where((p) => p.backend == _backend).firstOrNull;
    if (profile == null) {
      profile = ComicTranslationRemoteProfile(
        id: 'profile-${DateTime.now().microsecondsSinceEpoch}',
        backend: _backend,
        name: _backend == 'deepl' ? 'DeepL' : 'OpenAI compatible',
        endpoint: _backend == 'deepl' ? 'https://api-free.deepl.com/v2/translate' :
            'https://api.openai.com/v1/chat/completions',
        model: '',
        additionalPrompt: '',
      );
      _profiles.add(profile);
    }
    _applyProfile(profile);
  }

  void _applyProfile(ComicTranslationRemoteProfile profile) {
    _profileId = profile.id;
    _name.text = profile.name;
    _endpoint.text = profile.endpoint;
    _model.text = profile.model;
    _prompt.text = profile.additionalPrompt;
    _key.clear();
  }

  Future<void> _saveProfile() async {
    if (!_remote) return;
    _profiles.removeWhere((profile) => profile.id == _profileId);
    _profiles.add(_draft());
    if (_key.text.trim().isNotEmpty) {
      await ComicTranslationSecrets.instance.setApiKey(_profileId, _key.text);
      if (mounted) _key.clear();
    }
  }

  Future<void> _save() async {
    if (_remote) {
      final endpoint = Uri.tryParse(_endpoint.text.trim());
      if (endpoint == null || !endpoint.hasAuthority ||
          !{'http', 'https'}.contains(endpoint.scheme)) {
        throw const FormatException('请输入完整的 HTTP(S) API 地址');
      }
      if (_backend == 'openaiCompatible' && _model.text.trim().isEmpty) {
        throw const FormatException('请输入模型名称');
      }
    }
    if (_backend == 'local') {
      final model = ComicLocalTranslationModelManager.instance.models
          .where((model) => model.id == _localModel).firstOrNull;
      if (model == null) throw StateError('请先下载或导入本地翻译模型');
      if (!await LocalComicTranslationEngine.isNativeAvailable(model)) {
        throw StateError('当前设备或构建不支持所选模型，请更换模型或使用 API 后端');
      }
    }
    await _saveProfile();
    _settings.values.addAll({
      'comicTranslationBackend': _backend,
      'comicTranslationLocalModel': _localModel,
      'comicTranslationRemoteProfile': _profileId,
      'comicTranslationRemoteProfiles': _profiles.map((p) => p.toJson()).toList(),
    });
    final reader = <String, Object?>{
      'enabled': _enabled,
      'sourceLanguage': _source,
      'targetLanguage': _target,
      ..._tuning,
      'translateSoundEffects': _soundEffects,
      'useCleanOverlay': _cleanOverlay,
      'showIndicator': _indicator != 'off',
      'indicatorOnlyWhileProcessing': _indicator == 'processing',
    };
    _settings.values.addAll(reader);
    await _settings.save();
    ComicTranslationRuntime.instance.configure();
    if (mounted) setState(() => _result = '已保存');
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await action();
    } on Object catch (error) {
      if (mounted) {
        setState(() => _result = error.toString());
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  void dispose() {
    for (final controller in [_name, _endpoint, _model, _prompt, _key]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        key: comicTranslationSettingsKey,
        appBar: AppBar(title: const Text('全局翻译设置'), actions: [
          Tooltip(message: '保存翻译设置', child: TextButton(
            onPressed: _working ? null : () => _run(() async {
              await _ready;
              await _save();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存')));
              }
            }), child: const Text('保存'))),
        ]),
        body: FutureBuilder<void>(
          future: _ready,
          builder: (context, snapshot) {
            if (snapshot.hasError) return Center(child: SelectableText('${snapshot.error}'));
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final ocr = ComicOcrModelManager.instance;
            final local = ComicLocalTranslationModelManager.instance;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const ListTile(title: Text('1. 下载文字识别模型'), contentPadding: EdgeInsets.zero,
                  subtitle: Text('所有翻译方式都需要。日语、韩语共用一套，下载一次即可。')),
                ListTile(contentPadding: EdgeInsets.zero,
                  leading: Icon(ocr.installed ? Icons.check_circle_outline : Icons.download_outlined),
                  title: Text(ocr.installed ? '文字识别已就绪' :
                    '约 ${(ComicOcrModelManager.bundle.bytes / 1048576).round()} MiB'),
                  subtitle: const Text('在设备上识别图片中的文字。')),
                if (!ocr.installed) ValueListenableBuilder<ComicOcrModelProgress>(
                  valueListenable: ocr.progress,
                  builder: (_, progress, __) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (ocr.installing) ...[
                      LinearProgressIndicator(value: progress.fraction),
                      Text(progress.phase == ComicOcrModelPhase.verifying ? '正在校验文字识别模型…' :
                        '正在下载文字识别模型… ${(progress.fraction * 100).round()}%'),
                    ],
                    FilledButton.icon(
                      onPressed: _working || ocr.installing ? null : () => _run(() async {
                        await ocr.install();
                        ComicTranslationRuntime.instance.configure();
                      }),
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('下载文字识别模型'),
                    ),
                  ]),
                ),
                const Divider(height: 32),
                const ListTile(title: Text('2. 选择翻译方式'), contentPadding: EdgeInsets.zero),
                DropdownButtonFormField<String>(
                  initialValue: _backend,
                  decoration: const InputDecoration(labelText: '翻译方式'),
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(value: 'none', child: Text('暂不配置（仅测试文字识别）')),
                    DropdownMenuItem(value: 'openaiCompatible', child: Text('在线 API（兼容 OpenAI 接口）')),
                    DropdownMenuItem(value: 'local', child: Text('本地离线（无需 API）')),
                    DropdownMenuItem(value: 'deepl', child: Text('DeepL API')),
                  ],
                  onChanged: _working ? null : (value) => _run(() async {
                    await _saveProfile();
                    if (!mounted) return;
                    setState(() { _backend = value!; if (_remote) _selectBackendProfile(); });
                  }),
                ),
                const SizedBox(height: 12),
                Text(switch (_backend) {
                  'openaiCompatible' => '已有翻译或大模型服务账号：填写服务商提供的 API 地址、模型名称和密钥。无需下载本地翻译模型。',
                  'deepl' => '填写 DeepL API 密钥，并使用账号对应的免费版或 Pro 地址。无需下载本地翻译模型。',
                  'local' => '无需服务账号。下载下方内置模型即可将日语、韩语译为中文；也支持繁体中文显示。仅限兼容的 Android 设备，速度和内存占用取决于设备。',
                  _ => '有服务账号可选择在线 API；希望离线使用可选择本地离线。只测试文字识别时可暂不配置。',
                }),
                if (_backend == 'local') ...[
                  if (local.models.isNotEmpty) DropdownButtonFormField<String>(
                    initialValue: local.models.any((m) => m.id == _localModel) ? _localModel : null,
                    decoration: const InputDecoration(labelText: '已安装的翻译模型', hintText: '请选择模型'),
                    items: [for (final m in local.models) DropdownMenuItem(value: m.id,
                      child: Text('${m.displayName} · ${m.sourceLanguages.map(_languageName).join('/')} → ${_languageName(m.targetLanguage)}',
                        maxLines: 2, overflow: TextOverflow.ellipsis))],
                    onChanged: _working ? null : (value) => setState(() => _localModel = value!),
                    isExpanded: true,
                  ),
                  if (!local.models.any((model) => model.id == hyMt15TwoBitModel.id))
                    ValueListenableBuilder<ComicLocalModelProgress>(
                      valueListenable: local.progress,
                      builder: (_, progress, __) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (local.installing) ...[
                          LinearProgressIndicator(value: progress.fraction),
                          Text(switch (progress.phase) {
                            ComicLocalModelPhase.verifying => '正在校验离线翻译模型…',
                            ComicLocalModelPhase.copying => '正在导入离线翻译模型…',
                            _ => '正在下载离线翻译模型… ${(progress.fraction * 100).round()}%',
                          }),
                        ],
                        TextButton.icon(
                          onPressed: _working || local.installing ? null : () => _run(() async {
                            final model = await local.installHyMt15TwoBit();
                            _localModel = model.id;
                          }),
                          icon: const Icon(Icons.download_outlined),
                          label: Text('下载内置翻译模型 · 约 ${(hyMt15TwoBitModel.bytes / 1048576).round()} MiB'),
                        ),
                        const Text('Hy-MT1.5 1.8B 2-bit · 日语 / 韩语 → 中文'),
                      ]),
                    ),
                  ExpansionTile(title: const Text('导入与管理翻译模型'),
                    tilePadding: EdgeInsets.zero,
                    children: [
                      TextButton(onPressed: _working ? null : () => _run(_importModel),
                        child: const Text('导入本地模型目录（CTranslate2 / GGUF）')),
                      if (_localModel.isNotEmpty) TextButton(
                        onPressed: _working ? null : () => _run(() async {
                          await local.remove(_localModel);
                          _localModel = '';
                        }),
                        child: const Text('移除当前模型'),
                      ),
                    ],
                  ),
                ],
                if (_remote) ...[
                  if (_profiles.where((p) => p.backend == _backend).length > 1)
                    DropdownButtonFormField<String>(
                      key: ValueKey('translation-profile-$_profileId'),
                      initialValue: _profileId,
                      decoration: const InputDecoration(labelText: '使用已保存的 API 配置'),
                      isExpanded: true,
                      items: [for (final p in _profiles.where((p) => p.backend == _backend))
                        DropdownMenuItem(value: p.id, child: Text(p.name.isEmpty ? p.model : p.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis))],
                      onChanged: _working ? null : (value) => _run(() async {
                        await _saveProfile();
                        _applyProfile(_profiles.firstWhere((p) => p.id == value));
                      }),
                    ),
                  TextField(controller: _endpoint, decoration: InputDecoration(labelText: 'API 地址',
                    helperText: _backend == 'deepl' ? '免费版可保留默认地址' :
                      '填写完整接口地址，通常以 /chat/completions 结尾', helperMaxLines: 2),
                    keyboardType: TextInputType.url, autocorrect: false),
                  if (_backend == 'openaiCompatible') TextField(controller: _model,
                    decoration: const InputDecoration(labelText: '模型名称',
                      helperText: '填写服务商提供的模型 ID，无需在设备上下载', helperMaxLines: 2), autocorrect: false),
                  TextField(controller: _key, obscureText: true, enableSuggestions: false, autocorrect: false,
                    decoration: InputDecoration(labelText: 'API 密钥', helperText:
                      ComicTranslationSecrets.instance.hasApiKey(_profileId) ? '已保存密钥，留空保留' : '填写服务商提供的 API key')),
                  const Padding(padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('在线翻译会发送识别后的文字，图片仍在本机处理。')),
                  ExpansionTile(title: const Text('管理 API 配置'), tilePadding: EdgeInsets.zero,
                    children: [
                      TextField(controller: _name, decoration: const InputDecoration(labelText: '配置名称')),
                      if (_backend == 'deepl') TextField(controller: _model,
                        decoration: const InputDecoration(labelText: 'model_type（可留空）'), autocorrect: false),
                      Wrap(spacing: 8, children: [
                        TextButton(onPressed: _working ? null : () => _run(() async {
                          await _saveProfile();
                          final profile = ComicTranslationRemoteProfile(
                            id: 'profile-${DateTime.now().microsecondsSinceEpoch}', backend: _backend,
                            name: '新配置', endpoint: _endpoint.text, model: _model.text, additionalPrompt: _prompt.text);
                          _profiles.add(profile); _applyProfile(profile);
                        }), child: const Text('新增配置')),
                        TextButton(onPressed: _working ? null : () => _run(() async {
                          await ComicTranslationSecrets.instance.removeProfile(_profileId);
                          _profiles.removeWhere((p) => p.id == _profileId);
                          _selectBackendProfile();
                        }), child: const Text('删除配置')),
                        TextButton(onPressed: _working ? null : () => _run(() async {
                          await ComicTranslationSecrets.instance.setApiKey(_profileId, '');
                          _key.clear();
                        }), child: const Text('清除 API 密钥')),
                      ]),
                    ],
                  ),
                ],
                const Divider(height: 32),
                const ListTile(title: Text('3. 测试并开始阅读'), contentPadding: EdgeInsets.zero,
                  subtitle: Text('测试会保存当前配置。确认正常后，在阅读器底栏第三项开启本漫画翻译。')),
                if (!ocr.installed) const Text('还需完成第 1 步，才能翻译漫画图片。'),
                Wrap(spacing: 8, runSpacing: 4, children: [
                  OutlinedButton(onPressed: _working || _backend == 'none' ? null :
                    () => _run(_testConnection), child: const Text('测试文字翻译')),
                  OutlinedButton(onPressed: _working ? null : () => _run(_benchmark),
                    child: const Text('选择图片测试识别与翻译')),
                ]),
                const Text('文字测试确认翻译服务可用；图片测试检查识别与翻译。暂不配置翻译时，图片测试仅识别文字。'),
                if (_working) const LinearProgressIndicator(),
                if (_result != null) SelectableText(_result!),
                const Divider(height: 32),
                const ListTile(title: Text('阅读默认设置'), contentPadding: EdgeInsets.zero,
                  subtitle: Text('初次使用可保持默认值。本漫画面板中已单独设置的选项优先。')),
                SwitchListTile(contentPadding: EdgeInsets.zero,
                  title: const Text('默认开启漫画翻译'), value: _enabled,
                  onChanged: _working ? null : (value) => setState(() => _enabled = value)),
                DropdownButtonFormField<String>(
                  initialValue: _target,
                  decoration: const InputDecoration(labelText: '目标语言'),
                  items: const [
                    DropdownMenuItem(value: 'zh-CN', child: Text('简体中文')),
                    DropdownMenuItem(value: 'zh-TW', child: Text('繁体中文')),
                    DropdownMenuItem(value: 'en', child: Text('英语')),
                    DropdownMenuItem(value: 'ja', child: Text('日语')),
                    DropdownMenuItem(value: 'ko', child: Text('韩语')),
                  ],
                  onChanged: _working ? null : (value) => setState(() => _target = value!),
                ),
                DropdownButtonFormField<String>(
                  initialValue: _source,
                  decoration: const InputDecoration(labelText: '默认原文语言'),
                  items: const [
                    DropdownMenuItem(value: 'auto', child: Text('自动（日语 / 韩语）')),
                    DropdownMenuItem(value: 'ja', child: Text('日语')),
                    DropdownMenuItem(value: 'ko', child: Text('韩语')),
                    DropdownMenuItem(value: 'en', child: Text('英语')),
                    DropdownMenuItem(value: 'zh', child: Text('中文')),
                  ],
                  onChanged: _working ? null : (value) => setState(() => _source = value!),
                ),
                const ListTile(contentPadding: EdgeInsets.zero,
                  title: Text('翻译指示器'), subtitle: Text('在阅读视口右上角显示当前阶段；处理中模式在完成后隐藏。')),
                Wrap(spacing: 8, runSpacing: 4, children: [
                  for (final entry in const {'always': '常驻', 'processing': '处理中', 'off': '关闭'}.entries)
                    ChoiceChip(label: Text(entry.value), selected: _indicator == entry.key,
                      showCheckmark: false, shape: const StadiumBorder(),
                      onSelected: _working ? null : (_) => setState(() => _indicator = entry.key)),
                ]),
                SwitchListTile(contentPadding: EdgeInsets.zero,
                  title: const Text('默认翻译拟声词'), value: _soundEffects,
                  onChanged: _working ? null : (value) => setState(() => _soundEffects = value)),
                SwitchListTile(contentPadding: EdgeInsets.zero,
                  title: const Text('默认清除原文背景'), value: _cleanOverlay,
                  onChanged: _working ? null : (value) => setState(() => _cleanOverlay = value)),
                const Divider(),
                const ListTile(title: Text('翻译档位'), contentPadding: EdgeInsets.zero),
                Wrap(spacing: 8, runSpacing: 4, children: [
                  for (final entry in const {
                    ComicTranslationQuality.fast: '快速', ComicTranslationQuality.balanced: '均衡',
                    ComicTranslationQuality.precise: '精细', ComicTranslationQuality.custom: '自定义',
                  }.entries)
                    ChoiceChip(label: Text(entry.value), selected: _quality == entry.key,
                      showCheckmark: false, shape: const StadiumBorder(),
                      onSelected: _working ? null : (_) => setState(() => _loadTuning({
                        ..._tuning, ...entry.key.settings, 'translationQuality': entry.key.name,
                      }))),
                ]),
                Text(switch (_quality) {
                  ComicTranslationQuality.fast => '适合字大、清晰的漫画 · 更省时 · 提前翻译 2 页',
                  ComicTranslationQuality.balanced => '适合多数漫画，初次使用建议保留 · 提前翻译 4 页',
                  ComicTranslationQuality.precise => '提高细字识别分辨率 · 更耗时和内存 · 提前翻译 6 页',
                  ComicTranslationQuality.custom => '按高级设置中的参数处理。已完成的译文优先使用缓存。',
                }, style: Theme.of(context).textTheme.bodySmall),
                const Divider(height: 32),
                ExpansionTile(
                  title: const Text('高级设置'),
                  subtitle: const Text('上下文、预读、OCR 参数与追加提示词'),
                  tilePadding: EdgeInsets.zero,
                  children: [
                    ListTile(title: const Text('前页上下文'), trailing: DropdownButton<int>(
                      value: _contextPages,
                      items: [for (var i = 0; i <= 4; i++) DropdownMenuItem(value: i, child: Text('$i 页'))],
                      onChanged: (value) => _custom(() => _contextPages = value!),
                    )),
                    for (final cached in [false, true]) ListTile(
                      title: Text(cached ? '提前加载译文缓存' : '提前翻译'),
                      trailing: DropdownButton<int>(value: cached ? _cachePrefetchPages : _prefetchPages,
                        items: [for (var i = 0; i <= 8; i++)
                          DropdownMenuItem(value: i, child: Text(i == 0 ? '仅当前页' : '$i 页'))],
                        onChanged: (value) => _custom(() {
                          if (cached) { _cachePrefetchPages = value!; } else { _prefetchPages = value!; }
                        })),
                    ),
                    ExpansionTile(title: const Text('OCR 参数'),
                      subtitle: Text('$_analysisSide px · 检测 ${_detectionThreshold.toStringAsFixed(2)} · '
                        '识别 ${_recognitionThreshold.toStringAsFixed(2)}'),
                      tilePadding: EdgeInsets.zero,
                      children: [
                        ListTile(title: const Text('分析分辨率'), trailing: Text('$_analysisSide px')),
                        Slider(value: _analysisSide.toDouble(), min: 320, max: 4096, divisions: 59,
                          label: '$_analysisSide px', onChanged: _working ? null :
                            (value) => _custom(() => _analysisSide = value.round())),
                        const Padding(padding: EdgeInsets.symmetric(horizontal: 16),
                          child: Text('分辨率越高越利于识别细字，同时增加耗时与内存占用。')),
                        for (final recognition in [false, true]) ...[
                          ListTile(title: Text(recognition ? '识别置信度下限' : '检测阈值'),
                            subtitle: Text(recognition ? '提高可减少误识别，也可能漏掉模糊对白。' : '提高可减少候选文字框，也可能漏字。'),
                            trailing: Text((recognition ? _recognitionThreshold : _detectionThreshold).toStringAsFixed(2))),
                          Slider(value: recognition ? _recognitionThreshold : _detectionThreshold,
                            min: .1, max: .9, divisions: 16,
                            onChanged: _working ? null : (value) => _custom(() {
                              final threshold = (value * 100).round() / 100;
                              if (recognition) { _recognitionThreshold = threshold; } else { _detectionThreshold = threshold; }
                            })),
                        ],
                        ListTile(title: const Text('文字框扩展倍率'), trailing: Text(_unclipRatio.toStringAsFixed(1))),
                        Slider(value: _unclipRatio, min: 1, max: 3, divisions: 20,
                          onChanged: _working ? null : (value) => _custom(() => _unclipRatio = (value * 10).round() / 10)),
                      ],
                    ),
                    if (_backend == 'openaiCompatible') TextField(controller: _prompt, maxLines: 3,
                      decoration: const InputDecoration(labelText: '追加提示词')),
                  ],
                ),
                ExpansionTile(
                  title: const Text('模型管理'),
                  subtitle: const Text('文字识别模型详情与卸载'),
                  tilePadding: EdgeInsets.zero,
                  children: [
                    ListTile(title: const Text('文字识别模型'),
                      subtitle: Text('${ComicOcrModelManager.bundle.displayName} · ${ocr.installed ? '已安装' : '未安装'}')),
                    if (ocr.installed) TextButton.icon(
                      onPressed: _working || ocr.installing ? null : () => _run(() async {
                        await ocr.remove();
                        ComicTranslationRuntime.instance.configure();
                      }),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('移除文字识别模型'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            );
          },
        ),
      );

  static String _languageName(String code) => switch (code.toLowerCase()) {
    'ja' => '日语', 'ko' => '韩语', 'en' => '英语', 'zh' || 'zh-cn' => '中文',
    'zh-tw' => '繁体中文', _ => code,
  };

  Future<void> _importModel() async {
    final path = await pickDirectory();
    if (path == null) return;
    final models = ComicLocalTranslationModelManager.instance;
    if (!path.startsWith('saf://')) {
      _localModel = (await models.installFromDirectory(path)).id;
      return;
    }
    final store = SafStore(treeUri: path.substring('saf://'.length));
    Stream<List<int>> readFile(String name) async* {
      final handle = await store.open(name);
      if (handle == null) throw StateError('无法打开模型文件：$name');
      try {
        while (true) {
          final bytes = await store.read(handle, 256 * 1024);
          if (bytes.isEmpty) break;
          yield bytes;
        }
      } finally {
        await store.close(handle);
      }
    }
    _localModel = (await importComicTranslationModelDirectory(path, readFile: readFile)).id;
  }

  Future<void> _testConnection() async {
    await _save();
    final result = await testComicTranslationText(
      sourceLanguage: _source, targetLanguage: _target, backend: _backend, localModel: _localModel,
    );
    if (mounted) setState(() => _result = result);
  }

  Future<void> _benchmark() async {
    await _save();
    final result = await selectComicTranslationTestImage(
      sourceLanguage: _source, targetLanguage: _target, runTranslation: _backend != 'none',
      ocrParameters: ComicOcrParameters.fromSettings(_tuning),
    );
    if (mounted && result != null) setState(() => _result = result);
  }
}
