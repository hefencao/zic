import 'dart:async';

import 'package:comic_translation/comic_translation.dart';
import 'package:flutter/material.dart';

import 'comic_translation_test_actions.dart';
import 'comic_translation_service_form.dart';
import 'comic_translation_setup_screen.dart';
import 'translation_runtime.dart';

const comicTranslationSettingsKey = ValueKey('comic-translation-settings');

final class ComicTranslationSettingsScreen extends StatefulWidget {
  const ComicTranslationSettingsScreen({super.key});

  @override
  State<ComicTranslationSettingsScreen> createState() => _ComicTranslationSettingsScreenState();
}

final class _ComicTranslationSettingsScreenState extends State<ComicTranslationSettingsScreen> {
  final _settings = ComicTranslationSettings.instance;
  late final Future<void> _ready;
  ComicTranslationServiceDraft? _service;
  ComicTranslationServiceDraft get _draft => _service!;
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
  String _indicator = 'processing';
  bool _working = false;
  String? _result;

  @override
  void initState() {
    super.initState();
    _ready = _load();
  }

  Future<void> _load() async {
    await initializeComicTranslation();
    if (!mounted) return;
    final values = _settings.values;
    _service = ComicTranslationServiceDraft(values);
    _enabled = values['enabled'] == true;
    _source = values['sourceLanguage'] as String;
    _target = values['targetLanguage'] as String;
    _loadTuning(values);
    _soundEffects = values['translateSoundEffects'] == true;
    _cleanOverlay = values['useCleanOverlay'] == true;
    _indicator = values['showIndicator'] != true ? 'off' :
        values['indicatorOnlyWhileProcessing'] == true ? 'processing' : 'always';
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

  Future<void> _save() async {
    await _draft.apply();
    final reader = <String, Object?>{
      'comicTranslationSetupCompleted': true,
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
    _service?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        key: comicTranslationSettingsKey,
        appBar: AppBar(title: const Text('全局翻译设置'), actions: [
          IconButton(tooltip: '重新运行初始设置', icon: const Icon(Icons.auto_fix_high_outlined),
            onPressed: _working ? null : () => _run(_openSetup)),
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
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ExpansionTile(
                  title: const Text('模型管理'),
                  subtitle: Text(ocr.installed ? '文字识别模型已安装' : '文字识别模型未安装'),
                  tilePadding: EdgeInsets.zero,
                  children: [
                    ListTile(title: const Text('文字识别模型'),
                      subtitle: Text('${ComicOcrModelManager.bundle.displayName} · ${ocr.installed ? '已安装' : '未安装'}')),
                    if (!ocr.installed) ValueListenableBuilder<ComicOcrModelProgress>(
                      valueListenable: ocr.progress,
                      builder: (_, progress, _) => Column(children: [
                        if (ocr.installing) LinearProgressIndicator(value: progress.fraction),
                        TextButton.icon(onPressed: _working || ocr.installing ? null : () => _run(() async {
                          await ocr.install();
                          ComicTranslationRuntime.instance.configure();
                        }), icon: const Icon(Icons.download_outlined),
                          label: Text('下载文字识别模型 · 约 ${(ComicOcrModelManager.bundle.bytes / 1048576).round()} MiB')),
                      ])),
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
                const Divider(height: 32),
                const ListTile(title: Text('翻译服务'), contentPadding: EdgeInsets.zero),
                ComicTranslationServiceForm(key: ObjectKey(_draft), draft: _draft,
                  working: _working, run: _run, onChanged: () => setState(() {})),
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
                    if (_draft.backend == 'openaiCompatible') TextField(controller: _draft.prompt, maxLines: 3,
                      decoration: const InputDecoration(labelText: '追加提示词')),
                  ],
                ),
                const Divider(height: 32),
                const ListTile(title: Text('翻译测试'), contentPadding: EdgeInsets.zero,
                  subtitle: Text('运行测试前会保存当前配置。')),
                Wrap(spacing: 8, runSpacing: 4, children: [
                  OutlinedButton(onPressed: _working || _draft.backend == 'none' ? null :
                    () => _run(_testConnection), child: const Text('测试文字翻译')),
                  OutlinedButton(onPressed: _working ? null : () => _run(_benchmark),
                    child: const Text('选择图片测试识别与翻译')),
                ]),
                const Text('文字测试确认翻译服务可用；图片测试检查识别与翻译。暂不配置翻译时，图片测试仅识别文字。'),
                if (_working) const LinearProgressIndicator(),
                if (_result != null) SelectableText(_result!),
                const Divider(height: 32),
                const ListTile(title: Text('阅读默认设置'), contentPadding: EdgeInsets.zero,
                  subtitle: Text('本漫画面板中已单独设置的选项优先。')),
                SwitchListTile(contentPadding: EdgeInsets.zero,
                  title: const Text('默认开启漫画翻译'), value: _enabled,
                  onChanged: _working ? null : (value) => setState(() => _enabled = value)),
                DropdownButtonFormField<String>(
                  key: ValueKey('translation-target-$_target'), initialValue: _target,
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
                  title: Text('翻译指示器'), subtitle: Text('在阅读视口右上角显示当前阶段；自动模式仅在处理中显示。')),
                Wrap(spacing: 8, runSpacing: 4, children: [
                  for (final entry in const {'always': '常驻', 'processing': '自动', 'off': '关闭'}.entries)
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
                const SizedBox(height: 16),
              ],
            );
          },
        ),
      );

  Future<void> _openSetup() async {
    await _ready;
    if (!mounted) return;
    final result = await Navigator.of(context).push<ComicTranslationSetupResult>(MaterialPageRoute(
      builder: (_) => const ComicTranslationSetupScreen(allowManualSettings: false)));
    if (!mounted || result != ComicTranslationSetupResult.completed) return;
    _service?.dispose();
    _service = ComicTranslationServiceDraft(_settings.values);
    _target = _settings.values['targetLanguage'] as String;
  }

  Future<void> _testConnection() async {
    await _save();
    final result = await testComicTranslationText(
      sourceLanguage: _source, targetLanguage: _target, backend: _draft.backend, localModel: _draft.localModel,
    );
    if (mounted) setState(() => _result = result);
  }

  Future<void> _benchmark() async {
    await _save();
    final result = await selectComicTranslationTestImage(
      sourceLanguage: _source, targetLanguage: _target, runTranslation: _draft.backend != 'none',
      ocrParameters: ComicOcrParameters.fromSettings(_tuning),
    );
    if (mounted && result != null) setState(() => _result = result);
  }
}
