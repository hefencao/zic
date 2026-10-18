import 'package:comic_translation/comic_translation.dart';
import 'package:flutter/material.dart';

import 'comic_translation_service_form.dart';
import 'translation_runtime.dart';

const comicTranslationSetupKey = ValueKey('comic-translation-setup');
enum ComicTranslationSetupResult { completed, manual }

final class ComicTranslationSetupScreen extends StatefulWidget {
  const ComicTranslationSetupScreen({this.allowManualSettings = true, super.key});

  final bool allowManualSettings;

  @override
  State<ComicTranslationSetupScreen> createState() => _ComicTranslationSetupScreenState();
}

final class _ComicTranslationSetupScreenState extends State<ComicTranslationSetupScreen> {
  late final Future<void> _ready;
  ComicTranslationServiceDraft? _draft;
  int _step = 0;
  bool _working = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ready = _load();
    ComicOcrModelManager.instance.progress.addListener(_ocrChanged);
    ComicLocalTranslationModelManager.instance.progress.addListener(_localChanged);
  }

  void _ocrChanged() {
    if (mounted && !ComicOcrModelManager.instance.installing) setState(() {});
  }

  void _localChanged() {
    if (mounted && !ComicLocalTranslationModelManager.instance.installing) setState(() {});
  }

  Future<void> _load() async {
    await initializeComicTranslation();
    if (!mounted) return;
    _draft = ComicTranslationServiceDraft(ComicTranslationSettings.instance.values);
    if (_draft!.backend == 'none') _draft!.selectBackend('openaiCompatible');
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_working) return;
    setState(() { _working = true; _error = null; });
    try {
      await action();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _finish() => _run(() async {
    _saving = true;
    try {
      if (!ComicOcrModelManager.instance.installed) throw StateError('请先下载文字识别模型');
      await _draft!.apply();
      final settings = ComicTranslationSettings.instance;
      settings.values['comicTranslationSetupCompleted'] = true;
      await settings.save();
      ComicTranslationRuntime.instance.configure();
      if (mounted) Navigator.of(context).pop(ComicTranslationSetupResult.completed);
    } finally {
      _saving = false;
    }
  });

  @override
  void dispose() {
    ComicOcrModelManager.instance.progress.removeListener(_ocrChanged);
    ComicLocalTranslationModelManager.instance.progress.removeListener(_localChanged);
    _draft?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: Scaffold(
      key: comicTranslationSetupKey,
      appBar: AppBar(title: const Text('翻译初始设置'), actions: [
        if (widget.allowManualSettings) TextButton(
          onPressed: _working ? null : () => Navigator.of(context).pop(ComicTranslationSetupResult.manual),
          child: const Text('手动设置')),
      ]),
      body: FutureBuilder<void>(future: _ready, builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: SelectableText('${snapshot.error}'));
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final draft = _draft!;
        final ocr = ComicOcrModelManager.instance;
        return SafeArea(child: Column(children: [
          LinearProgressIndicator(value: (_step + 1) / 3),
          Expanded(child: SingleChildScrollView(key: ValueKey(_step),
            padding: const EdgeInsets.all(24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('第 ${_step + 1} 步，共 3 步', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 12),
              Text(const ['选择翻译方式', '准备文字识别', '完成翻译配置'][_step],
                style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 16),
              if (_step == 0) ...[
                const Text('先选择一种方式，只需准备对应的服务或模型。'),
                const SizedBox(height: 12),
                for (final option in const [
                  ('openaiCompatible', '在线 API', '已有兼容 OpenAI 接口的服务账号。需要 API 地址、模型名称和密钥，无需下载翻译模型。'),
                  ('local', '本地离线', '无需服务账号。内置翻译模型约 573 MiB，支持日语、韩语译为中文，需要兼容的 Android 设备。'),
                  ('deepl', 'DeepL API', '已有 DeepL API 账号。需要密钥，无需下载翻译模型。'),
                ]) Card(margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    leading: Icon(draft.backend == option.$1 ? Icons.radio_button_checked : Icons.radio_button_off),
                    title: Text(option.$2), subtitle: Text(option.$3),
                    selected: draft.backend == option.$1,
                    onTap: _working ? null : () => setState(() => draft.selectBackend(option.$1)))),
              ],
              if (_step == 1) ...[
                const Text('所有翻译方式都需要先在设备上识别图片中的文字。日语、韩语共用一套模型，下载一次即可。'),
                const SizedBox(height: 16),
                ListTile(contentPadding: EdgeInsets.zero,
                  leading: Icon(ocr.installed ? Icons.check_circle_outline : Icons.download_outlined),
                  title: Text(ocr.installed ? '文字识别已就绪' : '文字识别模型'),
                  subtitle: Text('约 ${(ComicOcrModelManager.bundle.bytes / 1048576).round()} MiB')),
                if (!ocr.installed) ValueListenableBuilder<ComicOcrModelProgress>(
                  valueListenable: ocr.progress,
                  builder: (_, progress, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (ocr.installing) ...[
                      LinearProgressIndicator(value: progress.fraction),
                      Text(progress.phase == ComicOcrModelPhase.verifying ? '正在校验文字识别模型…' :
                        '正在下载文字识别模型… ${(progress.fraction * 100).round()}%'),
                    ],
                    FilledButton.icon(onPressed: _working || ocr.installing ? null : () => _run(() async {
                      await ocr.install();
                      ComicTranslationRuntime.instance.configure();
                    }), icon: const Icon(Icons.download_outlined), label: const Text('下载文字识别模型')),
                  ])),
              ],
              if (_step == 2) ...[
                ComicTranslationServiceForm(draft: draft, working: _working, run: _run,
                  onChanged: () => setState(() {}), showBackend: false, showManagement: false, showHelp: true),
                const SizedBox(height: 16),
                const Text('完成后，在阅读器底栏第三项开启本漫画翻译。更多选项和翻译测试可在全局设置中调整。'),
              ],
              if (_error != null) Padding(padding: const EdgeInsets.only(top: 16),
                child: SelectableText(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
            ]))),
          if (_saving) const LinearProgressIndicator(),
          Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), child: Row(children: [
            if (_step == 0) TextButton(onPressed: _working ? null : () => Navigator.of(context).pop(),
              child: const Text('稍后设置'))
            else TextButton(onPressed: _working ? null : () => setState(() { _step--; _error = null; }),
              child: const Text('上一步')),
            const Spacer(),
            FilledButton(onPressed: _working || (_step == 1 && !ocr.installed) ? null :
              _step == 2 ? _finish : () => setState(() { _step++; _error = null; }),
              child: Text(_step == 2 ? '完成设置' : '下一步')),
          ])),
        ]));
      }),
    ),
  );
}
