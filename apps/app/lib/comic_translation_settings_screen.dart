import 'dart:async';

import 'package:comic_translation/comic_translation.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'directory_picker.dart';
import 'saf_store.dart';
import 'startup_platform.dart';
import 'translation_composition.dart';

const comicTranslationSettingsKey = ValueKey('comic-translation-settings');

final class ComicTranslationSettingsScreen extends StatefulWidget {
  const ComicTranslationSettingsScreen({this.sourceId, this.comicId, super.key});

  final String? sourceId;
  final String? comicId;

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
  bool _enabled = false;
  bool _soundEffects = false;
  bool _cleanOverlay = true;
  bool _working = false;
  String? _result;
  bool get _isComic => widget.sourceId != null && widget.comicId != null;
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
    final comic = _isComic ? _settings.forComic(widget.sourceId!, widget.comicId!) : values;
    _backend = values['comicTranslationBackend'] as String;
    _localModel = values['comicTranslationLocalModel'] as String;
    _profiles = (values['comicTranslationRemoteProfiles'] as List).map((value) =>
        ComicTranslationRemoteProfile.fromJson(Map<String, dynamic>.from(value as Map))).toList();
    _profileId = values['comicTranslationRemoteProfile'] as String;
    _enabled = comic['enabled'] == true;
    _source = comic['sourceLanguage'] as String;
    _target = comic['targetLanguage'] as String;
    _contextPages = comic['contextPages'] as int;
    _soundEffects = comic['translateSoundEffects'] == true;
    _cleanOverlay = comic['useCleanOverlay'] == true;
    if (_remote) _selectBackendProfile();
  }

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
        throw StateError('当前构建未包含所选模型的本地运行时');
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
      'contextPages': _contextPages,
      'translateSoundEffects': _soundEffects,
      'useCleanOverlay': _cleanOverlay,
    };
    if (_isComic) {
      await _settings.setComic(widget.sourceId!, widget.comicId!, reader);
    } else {
      _settings.values.addAll(reader);
      await _settings.save();
    }
    ComicTranslationRuntime.instance.configure();
    if (mounted) setState(() => _result = '已保存');
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await action();
    } on Object catch (error) {
      if (mounted) setState(() => _result = error.toString());
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
        appBar: AppBar(title: Text(_isComic ? '本漫画翻译设置' : '翻译模型与 API')),
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
                SwitchListTile(
                  title: Text(_isComic ? '翻译本漫画' : '默认开启漫画翻译'),
                  value: _enabled,
                  onChanged: _working ? null : (value) => setState(() => _enabled = value),
                ),
                DropdownButtonFormField<String>(
                  initialValue: _source,
                  decoration: const InputDecoration(labelText: '源语言'),
                  items: const [
                    DropdownMenuItem(value: 'auto', child: Text('自动（韩语请单独选择）')),
                    DropdownMenuItem(value: 'ja', child: Text('日语')),
                    DropdownMenuItem(value: 'ko', child: Text('韩语')),
                    DropdownMenuItem(value: 'en', child: Text('英语')),
                    DropdownMenuItem(value: 'zh', child: Text('中文')),
                  ],
                  onChanged: (value) => setState(() => _source = value!),
                ),
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
                  onChanged: (value) => setState(() => _target = value!),
                ),
                SwitchListTile(title: const Text('翻译拟声词'), value: _soundEffects,
                  onChanged: (value) => setState(() => _soundEffects = value)),
                SwitchListTile(title: const Text('清除原文背景'), value: _cleanOverlay,
                  onChanged: (value) => setState(() => _cleanOverlay = value)),
                ListTile(title: const Text('前页上下文'), trailing: DropdownButton<int>(
                  value: _contextPages,
                  items: [for (var i = 0; i <= 4; i++) DropdownMenuItem(value: i, child: Text('$i 页'))],
                  onChanged: (value) => setState(() => _contextPages = value!),
                )),
                const Divider(),
                ListTile(
                  title: const Text('本地 OCR 模型'),
                  subtitle: Text(ocr.installed ? '${ComicOcrModelManager.bundle.displayName} · 已安装' :
                      'PP-OCRv6 · 约 ${(ComicOcrModelManager.bundle.bytes / 1048576).round()} MB'),
                ),
                ValueListenableBuilder<ComicOcrModelProgress>(
                  valueListenable: ocr.progress,
                  builder: (_, progress, __) => Column(children: [
                    if (ocr.installing) LinearProgressIndicator(value: progress.fraction),
                    TextButton.icon(
                      onPressed: _working || ocr.installing ? null : () => _run(() async {
                        if (ocr.installed) { await ocr.remove(); } else { await ocr.install(); }
                        ComicTranslationRuntime.instance.configure();
                      }),
                      icon: Icon(ocr.installed ? Icons.delete_outline : Icons.download_outlined),
                      label: Text(ocr.installed ? '移除 OCR 模型' : '下载并校验 OCR 模型'),
                    ),
                  ]),
                ),
                const Text('文字在设备上识别。远程后端仅接收识别出的文字；本地后端在设备上翻译。'),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: _backend,
                  decoration: const InputDecoration(labelText: '翻译后端'),
                  items: const [
                    DropdownMenuItem(value: 'none', child: Text('未配置')),
                    DropdownMenuItem(value: 'local', child: Text('本地翻译')),
                    DropdownMenuItem(value: 'openaiCompatible', child: Text('OpenAI compatible')),
                    DropdownMenuItem(value: 'deepl', child: Text('DeepL')),
                  ],
                  onChanged: _working ? null : (value) async {
                    await _saveProfile();
                    if (!mounted) return;
                    setState(() { _backend = value!; if (_remote) _selectBackendProfile(); });
                  },
                ),
                if (_backend == 'local') ...[
                  if (local.models.isNotEmpty) DropdownButtonFormField<String>(
                    initialValue: local.models.any((m) => m.id == _localModel) ? _localModel : null,
                    decoration: const InputDecoration(labelText: '本地模型'),
                    items: [for (final m in local.models) DropdownMenuItem(value: m.id,
                      child: Text('${m.displayName} · ${m.sourceLanguages.join('/')} → ${m.targetLanguage}'))],
                    onChanged: (value) => setState(() => _localModel = value!),
                    isExpanded: true,
                  ),
                  ValueListenableBuilder<ComicLocalModelProgress>(
                    valueListenable: local.progress,
                    builder: (_, progress, __) => Column(children: [
                      if (local.installing) LinearProgressIndicator(value: progress.fraction),
                      Text('${progress.phase.name} ${progress.fileName ?? ''}'),
                      TextButton.icon(
                        onPressed: _working || local.installing ? null : () => _run(() async {
                          final model = await local.installHyMt15TwoBit();
                          _localModel = model.id;
                        }),
                        icon: const Icon(Icons.download_outlined),
                        label: const Text('下载 Hy-MT1.5 1.8B 2-bit'),
                      ),
                    ]),
                  ),
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
                if (_remote) ...[
                  DropdownButtonFormField<String>(
                    key: ValueKey('translation-profile-$_profileId'),
                    initialValue: _profileId,
                    decoration: const InputDecoration(labelText: 'API 配置'),
                    items: [for (final p in _profiles.where((p) => p.backend == _backend))
                      DropdownMenuItem(value: p.id, child: Text(p.name.isEmpty ? p.model : p.name))],
                    onChanged: _working ? null : (value) => _run(() async {
                      await _saveProfile();
                      _applyProfile(_profiles.firstWhere((p) => p.id == value));
                    }),
                  ),
                  Row(children: [
                    TextButton(onPressed: _working ? null : () => _run(() async {
                      await _saveProfile();
                      _profileId = '';
                      // An unknown ID selects the first profile, so create explicitly.
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
                  ]),
                  TextField(controller: _name, decoration: const InputDecoration(labelText: '配置名称')),
                  TextField(controller: _endpoint, decoration: const InputDecoration(labelText: 'API 地址'),
                    keyboardType: TextInputType.url, autocorrect: false),
                  TextField(controller: _model, decoration: InputDecoration(
                    labelText: _backend == 'deepl' ? 'model_type（可留空）' : '模型名称'), autocorrect: false),
                  if (_backend == 'openaiCompatible') TextField(controller: _prompt, maxLines: 3,
                    decoration: const InputDecoration(labelText: '追加提示词')),
                  TextField(controller: _key, obscureText: true, enableSuggestions: false, autocorrect: false,
                    decoration: InputDecoration(labelText: 'API key', hintText:
                      ComicTranslationSecrets.instance.hasApiKey(_profileId) ? '已保存，留空保留' : '尚未设置')),
                  TextButton(onPressed: _working ? null : () => _run(() async {
                    await ComicTranslationSecrets.instance.setApiKey(_profileId, '');
                    _key.clear();
                  }), child: const Text('清除 API key')),
                ],
                const SizedBox(height: 16),
                FilledButton(onPressed: _working ? null : () => _run(_save), child: const Text('保存')),
                if (_backend != 'none') OutlinedButton(
                  onPressed: _working ? null : () => _run(_testConnection), child: const Text('测试文字翻译')),
                OutlinedButton(onPressed: _working ? null : () => _run(_benchmark),
                  child: const Text('选择图片测试 OCR 与翻译')),
                if (_working) const LinearProgressIndicator(),
                if (_result != null) SelectableText(_result!),
              ],
            );
          },
        ),
      );

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
    final timer = Stopwatch()..start();
    final result = await ComicTranslationEngineRegistry.instance.translateConfigured(
      ComicTranslationRequest(
        ocr: const ComicOcrArtifact(
          contentDigest: 'connection-test', engineId: 'test', modelVersion: '1', sourceLanguage: 'en',
          imageWidth: 1, imageHeight: 1, mediaKind: ComicTranslationMediaKind.staticImage,
          animatedMode: AnimatedTranslationMode.posterFrame,
          regions: [ComicOcrRegion(id: 'test', polygon: [], text: 'Hello', confidence: 1,
            orientation: ComicTextOrientation.horizontal, kind: ComicTextKind.dialogue,
            readingOrder: 0, sourceMaskPolygons: [])],
        ),
        targetLanguage: _target, previousPages: const [],
      ),
    );
    if (mounted) setState(() => _result = '${timer.elapsedMilliseconds} ms\n${result.translations}');
  }

  Future<void> _benchmark() async {
    await _save();
    await attachAndroidPlugin('file_selector_android');
    final file = await openFile(acceptedTypeGroups: [const XTypeGroup(
      label: '图片', extensions: ['png', 'jpg', 'jpeg', 'webp'],
      mimeTypes: ['image/png', 'image/jpeg', 'image/webp'],
    )]);
    if (file == null) return;
    final result = await benchmarkComicTranslationImage(
      copyImage: file.saveTo,
      sourceLanguage: _source,
      targetLanguage: _target,
      runTranslation: _backend != 'none',
    );
    final sample = result.samples.single;
    if (mounted) setState(() => _result =
        'OCR ${sample.ocrTime.inMilliseconds} ms · 翻译 ${sample.translationTime.inMilliseconds} ms\n'
        '${sample.regionCount} 个区域 · RSS ${(result.maxObservedRss / 1048576).round()} MB\n'
        '${sample.sourceTexts.join('\n')}\n${sample.translatedTexts.join('\n')}');
  }
}
