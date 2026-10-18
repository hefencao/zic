import 'package:comic_translation/comic_translation.dart';
import 'package:flutter/material.dart';

import 'comic_translation_settings_entry.dart';
import 'comic_translation_test_actions.dart';
import 'translation_composition.dart';

const comicTranslationTestEntryKey = ValueKey('comic-translation-test-entry');
const comicTranslationTestScreenKey = ValueKey('comic-translation-test-screen');

final class ComicTranslationTestScreen extends StatefulWidget {
  const ComicTranslationTestScreen({super.key});

  @override
  State<ComicTranslationTestScreen> createState() => _ComicTranslationTestScreenState();
}

final class _ComicTranslationTestScreenState extends State<ComicTranslationTestScreen> {
  late final Future<void> _ready;
  String _source = 'auto';
  String _target = 'zh-CN';
  String _backend = 'none';
  String _localModel = '';
  String _backendLabel = '未配置';
  bool _working = false;
  String? _result;

  @override
  void initState() {
    super.initState();
    _ready = _load();
  }

  Future<void> _load() async {
    await initializeComicTranslation();
    final values = ComicTranslationSettings.instance.values;
    _source = values['sourceLanguage'] as String;
    _target = values['targetLanguage'] as String;
    _backend = values['comicTranslationBackend'] as String;
    _localModel = values['comicTranslationLocalModel'] as String;
    _backendLabel = switch (_backend) {
      'local' => ComicLocalTranslationModelManager.instance.modelById(_localModel)?.displayName ?? '本地翻译',
      'openaiCompatible' => 'OpenAI compatible',
      'deepl' => 'DeepL',
      _ => '未配置（仅测试 OCR）',
    };
  }

  Future<void> _openSettings() async {
    await openComicTranslationSettings(context);
    await _load();
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<String?> Function() action) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final result = await action();
      if (mounted && result != null) setState(() => _result = result);
    } on Object catch (error) {
      if (mounted) setState(() => _result = error.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    key: comicTranslationTestScreenKey,
    appBar: AppBar(title: const Text('翻译测试'), actions: [
      IconButton(tooltip: '翻译设置', onPressed: _working ? null : _openSettings,
        icon: const Icon(Icons.settings_outlined)),
    ]),
    body: FutureBuilder<void>(future: _ready, builder: (context, snapshot) {
      if (snapshot.hasError) return Center(child: SelectableText('${snapshot.error}'));
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      return ListView(padding: const EdgeInsets.all(16), children: [
        Text('当前后端：$_backendLabel'),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey('test-source-$_source'), initialValue: _source,
          decoration: const InputDecoration(labelText: '测试源语言'),
          items: const [
            DropdownMenuItem(value: 'auto', child: Text('自动（韩语请单独选择）')),
            DropdownMenuItem(value: 'ja', child: Text('日语')),
            DropdownMenuItem(value: 'ko', child: Text('韩语')),
            DropdownMenuItem(value: 'en', child: Text('英语')),
            DropdownMenuItem(value: 'zh', child: Text('中文')),
          ],
          onChanged: _working ? null : (value) => setState(() => _source = value!),
        ),
        DropdownButtonFormField<String>(
          key: ValueKey('test-target-$_target'), initialValue: _target,
          decoration: const InputDecoration(labelText: '测试目标语言'),
          items: const [
            DropdownMenuItem(value: 'zh-CN', child: Text('简体中文')),
            DropdownMenuItem(value: 'zh-TW', child: Text('繁体中文')),
            DropdownMenuItem(value: 'en', child: Text('英语')),
            DropdownMenuItem(value: 'ja', child: Text('日语')),
            DropdownMenuItem(value: 'ko', child: Text('韩语')),
          ],
          onChanged: _working ? null : (value) => setState(() => _target = value!),
        ),
        const SizedBox(height: 16),
        if (_backend != 'none') OutlinedButton(
          onPressed: _working ? null : () => _run(() => testComicTranslationText(
            sourceLanguage: _source, targetLanguage: _target, backend: _backend, localModel: _localModel)),
          child: const Text('测试文字翻译')),
        FilledButton.icon(
          onPressed: _working ? null : () => _run(() => selectComicTranslationTestImage(
            sourceLanguage: _source, targetLanguage: _target, runTranslation: _backend != 'none')),
          icon: const Icon(Icons.image_outlined), label: const Text('选择图片测试 OCR 与翻译')),
        const Text('测试语言只用于本页，不更改阅读设置。动图暂不翻译。'),
        if (_working) const LinearProgressIndicator(),
        if (_result != null) Padding(padding: const EdgeInsets.only(top: 16), child: SelectableText(_result!)),
      ]);
    }),
  );
}
