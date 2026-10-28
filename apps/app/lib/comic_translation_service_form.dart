import 'package:comic_translation/comic_translation.dart';
import 'package:flutter/material.dart';

import 'directory_picker.dart';
import 'saf_store.dart';

/// App-owned editing state. Switching providers never persists credentials.
final class ComicTranslationServiceDraft {
  ComicTranslationServiceDraft(Map<String, Object?> values) {
    backend = values['comicTranslationBackend'] as String;
    localModel = values['comicTranslationLocalModel'] as String;
    profiles = (values['comicTranslationRemoteProfiles'] as List).map((value) =>
      ComicTranslationRemoteProfile.fromJson(Map<String, dynamic>.from(value as Map))).toList();
    profileId = values['comicTranslationRemoteProfile'] as String;
    _legacy = ComicTranslationRemoteProfile(id: 'default', backend: 'openaiCompatible',
      name: values['comicTranslationRemoteModel'] as String,
      endpoint: values['comicTranslationRemoteEndpoint'] as String,
      model: values['comicTranslationRemoteModel'] as String,
      additionalPrompt: values['comicTranslationAdditionalPrompt'] as String);
    if (remote) _selectBackendProfile();
    if (backend == 'local' && localModel.isEmpty) {
      localModel = ComicLocalTranslationModelManager.instance.models.firstOrNull?.id ?? '';
    }
  }

  final name = TextEditingController();
  final endpoint = TextEditingController();
  final model = TextEditingController();
  final prompt = TextEditingController();
  final apiKey = TextEditingController();
  late String backend;
  late String localModel;
  late String profileId;
  late List<ComicTranslationRemoteProfile> profiles;
  late final ComicTranslationRemoteProfile _legacy;
  final _pendingKeys = <String, String>{};
  final _removedProfiles = <String>{};
  bool _disposed = false;

  bool get remote => backend == 'openaiCompatible' || backend == 'deepl';
  bool get hasSavedKey => _pendingKeys[profileId] != '' &&
      ComicTranslationSecrets.instance.hasApiKey(profileId) &&
      ComicTranslationSettings.instance.permitsCredentialService(profileId, backend, endpoint.text);

  ComicTranslationRemoteProfile _profile() => ComicTranslationRemoteProfile(
    id: profileId, backend: backend, name: name.text.trim(), endpoint: endpoint.text.trim(),
    model: model.text.trim(), additionalPrompt: prompt.text.trim());

  void _stashProfile() {
    if (!remote) return;
    profiles.removeWhere((profile) => profile.id == profileId);
    profiles.add(_profile());
    if (apiKey.text.trim().isNotEmpty) _pendingKeys[profileId] = apiKey.text;
  }

  void _applyProfile(ComicTranslationRemoteProfile profile) {
    profileId = profile.id;
    name.text = profile.name;
    endpoint.text = profile.endpoint;
    model.text = profile.model;
    prompt.text = profile.additionalPrompt;
    apiKey.text = _pendingKeys[profileId] ?? '';
  }

  void _selectBackendProfile() {
    var profile = profiles.where((p) => p.id == profileId && p.backend == backend).firstOrNull;
    profile ??= profiles.where((p) => p.backend == backend).firstOrNull;
    if (profile == null) {
      profile = backend == 'openaiCompatible' && profileId == 'default' ? _legacy :
        ComicTranslationRemoteProfile(id: 'profile-${DateTime.now().microsecondsSinceEpoch}',
          backend: backend, name: backend == 'deepl' ? 'DeepL' : 'OpenAI compatible',
          endpoint: backend == 'deepl' ? 'https://api-free.deepl.com/v2/translate' :
            'https://api.openai.com/v1/chat/completions', model: '', additionalPrompt: '');
      profiles.add(profile);
    }
    _applyProfile(profile);
  }

  void selectBackend(String value) {
    _stashProfile();
    backend = value;
    if (remote) _selectBackendProfile();
    if (backend == 'local' && ComicLocalTranslationModelManager.instance.modelById(localModel) == null) {
      localModel = ComicLocalTranslationModelManager.instance.models.firstOrNull?.id ?? '';
    }
  }

  void selectProfile(String id) {
    _stashProfile();
    _applyProfile(profiles.firstWhere((p) => p.id == id));
  }

  void addProfile() {
    _stashProfile();
    final profile = ComicTranslationRemoteProfile(
      id: 'profile-${DateTime.now().microsecondsSinceEpoch}', backend: backend,
      name: '新配置', endpoint: endpoint.text, model: model.text, additionalPrompt: prompt.text);
    profiles.add(profile);
    _applyProfile(profile);
  }

  void deleteProfile() {
    _removedProfiles.add(profileId);
    _pendingKeys.remove(profileId);
    profiles.removeWhere((p) => p.id == profileId);
    profileId = '';
    _selectBackendProfile();
  }

  void clearKey() {
    _pendingKeys[profileId] = '';
    apiKey.clear();
  }

  Future<void> apply() async {
    if (remote) {
      final uri = Uri.tryParse(endpoint.text.trim());
      if (uri == null || !uri.hasAuthority || !{'http', 'https'}.contains(uri.scheme)) {
        throw const FormatException('请输入完整的 HTTP(S) API 地址');
      }
      if (backend == 'openaiCompatible' && model.text.trim().isEmpty) {
        throw const FormatException('请输入模型名称');
      }
    }
    _stashProfile();
    if (backend == 'local') {
      final selected = ComicLocalTranslationModelManager.instance.modelById(localModel);
      if (selected == null) throw StateError('请先下载或导入本地翻译模型');
      if (!await LocalComicTranslationEngine.isNativeAvailable(selected)) {
        throw StateError('当前设备或构建不支持所选模型，请更换模型或使用 API 后端');
      }
    }
    for (final id in _removedProfiles) {
      await ComicTranslationSecrets.instance.removeProfile(id);
    }
    for (final entry in _pendingKeys.entries) {
      await ComicTranslationSecrets.instance.setApiKey(entry.key, entry.value);
      final profile = profiles.where((profile) => profile.id == entry.key).firstOrNull;
      if (entry.value.trim().isNotEmpty && profile != null) {
        ComicTranslationSettings.instance.approveCredentialService(
          profile.id, profile.backend, profile.endpoint);
      }
    }
    ComicTranslationSettings.instance.values.addAll({
      'comicTranslationBackend': backend,
      'comicTranslationLocalModel': localModel,
      'comicTranslationRemoteProfile': profileId,
      'comicTranslationRemoteProfiles': profiles.map((p) => p.toJson()).toList(),
    });
    _removedProfiles.clear();
    _pendingKeys.clear();
    if (!_disposed) apiKey.clear();
  }

  void dispose() {
    _disposed = true;
    for (final controller in [name, endpoint, model, prompt, apiKey]) {
      controller.dispose();
    }
  }
}

bool hasComicTranslationServiceConfiguration() {
  final values = ComicTranslationSettings.instance.values;
  final backend = values['comicTranslationBackend'];
  if (backend == 'local') {
    final models = ComicLocalTranslationModelManager.instance;
    final id = values['comicTranslationLocalModel'] as String;
    return id.isEmpty ? models.models.isNotEmpty : models.modelById(id) != null;
  }
  if (backend != 'openaiCompatible' && backend != 'deepl') return false;
  final draft = ComicTranslationServiceDraft(values);
  try {
    final uri = Uri.tryParse(draft.endpoint.text.trim());
    return uri != null && uri.hasAuthority && {'http', 'https'}.contains(uri.scheme) &&
        (backend == 'deepl' || draft.model.text.trim().isNotEmpty);
  } finally {
    draft.dispose();
  }
}

final class ComicTranslationServiceForm extends StatelessWidget {
  const ComicTranslationServiceForm({required this.draft, required this.working,
    required this.run, required this.onChanged, this.showBackend = true,
    this.showManagement = true, this.showHelp = false, super.key});

  final ComicTranslationServiceDraft draft;
  final bool working;
  final Future<void> Function(Future<void> Function()) run;
  final VoidCallback onChanged;
  final bool showBackend;
  final bool showManagement;
  final bool showHelp;

  @override
  Widget build(BuildContext context) {
    final local = ComicLocalTranslationModelManager.instance;
    void change(VoidCallback update) { update(); onChanged(); }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (showBackend) DropdownButtonFormField<String>(
        initialValue: draft.backend,
        decoration: const InputDecoration(labelText: '翻译方式'),
        isExpanded: true,
        items: const [
          DropdownMenuItem(value: 'none', child: Text('未配置（仅文字识别）')),
          DropdownMenuItem(value: 'openaiCompatible', child: Text('在线 API（兼容 OpenAI 接口）')),
          DropdownMenuItem(value: 'local', child: Text('本地离线')),
          DropdownMenuItem(value: 'deepl', child: Text('DeepL API')),
        ],
        onChanged: working ? null : (value) => change(() => draft.selectBackend(value!))),
      if (showHelp) Padding(padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(switch (draft.backend) {
          'openaiCompatible' => '填写服务商提供的完整 API 地址、模型名称和密钥。无需下载本地翻译模型。',
          'deepl' => '填写 DeepL API 密钥，并使用账号对应的免费版或 Pro 地址。无需下载本地翻译模型。',
          'local' => '下载内置模型即可将日语、韩语译为中文；也支持繁体中文显示。仅限兼容的 Android 设备，速度和内存占用取决于设备。',
          _ => '',
        })),
      if (draft.backend == 'local') ...[
        if (local.models.isNotEmpty) DropdownButtonFormField<String>(
          key: ValueKey('translation-local-${draft.localModel}'),
          initialValue: local.models.any((m) => m.id == draft.localModel) ? draft.localModel : null,
          decoration: const InputDecoration(labelText: '已安装的翻译模型', hintText: '请选择模型'),
          items: [for (final m in local.models) DropdownMenuItem(value: m.id,
            child: Text('${m.displayName} · ${m.sourceLanguages.map(_languageName).join('/')} → ${_languageName(m.targetLanguage)}',
              maxLines: 2, overflow: TextOverflow.ellipsis))],
          onChanged: working ? null : (value) => change(() => draft.localModel = value!),
          isExpanded: true),
        if (!local.models.any((model) => model.id == hyMt15TwoBitModel.id))
          ValueListenableBuilder<ComicLocalModelProgress>(
            valueListenable: local.progress,
            builder: (_, progress, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (local.installing) ...[
                LinearProgressIndicator(value: progress.fraction),
                Text(switch (progress.phase) {
                  ComicLocalModelPhase.verifying => '正在校验离线翻译模型…',
                  ComicLocalModelPhase.copying => '正在导入离线翻译模型…',
                  _ => '正在下载离线翻译模型… ${(progress.fraction * 100).round()}%',
                }),
              ],
              TextButton.icon(onPressed: working || local.installing ? null : () => run(() async {
                final model = await local.installHyMt15TwoBit();
                draft.localModel = model.id;
              }), icon: const Icon(Icons.download_outlined),
                label: Text('下载内置翻译模型 · 约 ${(hyMt15TwoBitModel.bytes / 1048576).round()} MiB')),
              const Text('Hy-MT1.5 1.8B 2-bit · 日语 / 韩语 → 中文'),
            ])),
        if (showManagement) ExpansionTile(title: const Text('导入与管理翻译模型'),
          tilePadding: EdgeInsets.zero, children: [
            TextButton(onPressed: working ? null : () => run(_importModel),
              child: const Text('导入本地模型目录（CTranslate2 / GGUF）')),
            if (draft.localModel.isNotEmpty) TextButton(
              onPressed: working ? null : () => run(() async {
                await local.remove(draft.localModel);
                draft.localModel = '';
              }), child: const Text('移除当前模型')),
          ]),
      ],
      if (draft.remote) ...[
        if (draft.profiles.where((p) => p.backend == draft.backend).length > 1)
          DropdownButtonFormField<String>(
            key: ValueKey('translation-profile-${draft.profileId}'),
            initialValue: draft.profileId,
            decoration: const InputDecoration(labelText: '使用已保存的 API 配置'),
            isExpanded: true,
            items: [for (final p in draft.profiles.where((p) => p.backend == draft.backend))
              DropdownMenuItem(value: p.id, child: Text(p.name.isEmpty ? p.model : p.name,
                maxLines: 1, overflow: TextOverflow.ellipsis))],
            onChanged: working ? null : (value) => change(() => draft.selectProfile(value!))),
        TextField(controller: draft.endpoint, enabled: !working,
          decoration: InputDecoration(labelText: 'API 地址', helperText: showHelp ?
            (draft.backend == 'deepl' ? '免费版可保留默认地址' : '通常以 /chat/completions 结尾') : null,
            helperMaxLines: 2), keyboardType: TextInputType.url, autocorrect: false),
        if (draft.backend == 'openaiCompatible') TextField(controller: draft.model, enabled: !working,
          decoration: InputDecoration(labelText: '模型名称', helperText: showHelp ?
            '填写服务商提供的模型 ID，无需在设备上下载' : null, helperMaxLines: 2), autocorrect: false),
        TextField(controller: draft.apiKey, enabled: !working, obscureText: true,
          enableSuggestions: false, autocorrect: false,
          decoration: InputDecoration(labelText: 'API 密钥', helperText:
            draft.hasSavedKey ? '已保存密钥，留空保留' : '填写服务商提供的 API key')),
        if (showHelp) const Padding(padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('在线翻译会发送识别后的文字，图片仍在本机处理。')),
        if (showManagement) ExpansionTile(title: const Text('管理 API 配置'),
          tilePadding: EdgeInsets.zero, children: [
            TextField(controller: draft.name, enabled: !working,
              decoration: const InputDecoration(labelText: '配置名称')),
            if (draft.backend == 'deepl') TextField(controller: draft.model, enabled: !working,
              decoration: const InputDecoration(labelText: 'model_type（可留空）'), autocorrect: false),
            Wrap(spacing: 8, children: [
              TextButton(onPressed: working ? null : () => change(draft.addProfile), child: const Text('新增配置')),
              TextButton(onPressed: working ? null : () => change(draft.deleteProfile), child: const Text('删除配置')),
              TextButton(onPressed: working ? null : () => change(draft.clearKey), child: const Text('清除 API 密钥')),
            ]),
          ]),
      ],
    ]);
  }

  static String _languageName(String code) => switch (code.toLowerCase()) {
    'ja' => '日语', 'ko' => '韩语', 'en' => '英语', 'zh' || 'zh-cn' => '中文',
    'zh-tw' => '繁体中文', _ => code,
  };

  Future<void> _importModel() async {
    final path = await pickDirectory();
    if (path == null) return;
    final models = ComicLocalTranslationModelManager.instance;
    if (!path.startsWith('saf://')) {
      draft.localModel = (await models.installFromDirectory(path)).id;
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
    draft.localModel = (await importComicTranslationModelDirectory(path, readFile: readFile)).id;
  }
}
