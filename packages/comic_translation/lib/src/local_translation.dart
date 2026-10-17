import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'opencc.dart';

import 'engine.dart';
import 'local_model_manager.dart';

final class LocalComicTranslationEngine
    implements
        ComicTextTranslationEngine,
        ComicTextTranslationEngineDiagnostics {
  static const _ctranslate2Channel = MethodChannel(
    'dev.zic/comic_translation_local',
  );
  static const _hyMtChannel = MethodChannel('dev.zic/comic_translation_hymt');

  final ComicLocalTranslationModelManager models;
  final String selectedModelId;
  final _loadedModels = <String>{};
  final _loadedEngines = <String>{};
  ComicTextTranslationRunMetrics? _lastRunMetrics;
  List<String> _lastRawResponses = const [];

  LocalComicTranslationEngine(this.models, {this.selectedModelId = ''});

  static Future<bool> isNativeAvailable(
    ComicLocalTranslationModel model,
  ) async =>
      Platform.isAndroid &&
      await _channelFor(model).invokeMethod<bool>('isAvailable') == true;

  @override
  ComicTranslationContextMode get contextMode =>
      _selectedModel?.engine == ComicLocalTranslationModel.hyMtGgufEngine
      ? ComicTranslationContextMode.previousPages
      : ComicTranslationContextMode.none;

  @override
  ComicTranslationEngineIdentity identityFor(ComicTranslationRequest request) {
    final pipeline = _pipelineFor(request);
    return ComicTranslationEngineIdentity(
      id: 'local:${pipeline.map((model) => model.id).join('+')}',
      modelVersion:
          '${pipeline.map((model) => model.runtimeKey).join('>')}:'
          'package-v${ComicLocalTranslationModel.schemaVersion}:'
          'group-local-protocol-v${pipeline.any((model) => model.engine == ComicLocalTranslationModel.hyMtGgufEngine) ? 7 : 6}',
    );
  }

  @override
  ComicTextTranslationRunMetrics? get lastRunMetrics => _lastRunMetrics;

  @override
  List<String> get lastRawResponses => _lastRawResponses;

  @override
  Future<void> load() async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('Local translation is currently Android-only');
    }
    final model = selectedModelId.isEmpty
        ? models.models.firstOrNull
        : models.modelById(selectedModelId);
    if (model == null) {
      throw StateError('No local translation model is selected');
    }
    if (!await isNativeAvailable(model)) {
      throw StateError(
        '${model.engine} native runtime is not included in this build',
      );
    }
  }

  @override
  Future<ComicTranslationResult> translate(
    ComicTranslationRequest request,
  ) async {
    _lastRunMetrics = null;
    _lastRawResponses = const [];
    if (request.units.isEmpty) return const ComicTranslationResult({});
    final pipeline = _pipelineFor(request);
    final timer = Stopwatch()..start();
    var texts = request.units
        .map((unit) => unit.sourceLines.join('\n'))
        .toList(growable: false);
    final sourceCharacters = texts.fold(
      0,
      (sum, text) => sum + text.runes.length,
    );
    final batchDurations = <Duration>[];
    for (final model in pipeline) {
      await _loadModel(model);
      final stageTimer = Stopwatch()..start();
      final active = <int>[
        for (var i = 0; i < texts.length; i++)
          if (texts[i].isNotEmpty) i,
      ];
      if (active.isEmpty) break;
      final raw = await _channelFor(model).invokeListMethod<String>(
        'translate',
        {
          'modelKey': model.runtimeKey,
          'texts': [
            for (final i in active)
              _inputFor(
                model,
                model.engine == ComicLocalTranslationModel.hyMtGgufEngine
                    ? _hyMtUnitText(request.units[i])
                    : texts[i],
                request,
              ),
          ],
        },
      );
      stageTimer.stop();
      batchDurations.add(stageTimer.elapsed);
      if (raw == null || raw.length != active.length) {
        throw StateError(
          'Local translator returned ${raw?.length} results for '
          '${active.length} units',
        );
      }
      final next = List<String>.filled(texts.length, '');
      for (var i = 0; i < active.length; i++) {
        next[active[i]] =
            model.engine == ComicLocalTranslationModel.hyMtGgufEngine
            ? _normalizeHyMtUnitOutput(raw[i], request.units[active[i]])
            : raw[i].trim();
      }
      _lastRawResponses = [
        ..._lastRawResponses,
        '${model.displayName} (${model.sourceLanguage} → ${model.targetLanguage})\n'
            '${List.generate(active.length, (i) => '${request.units[active[i]].id}: ${texts[active[i]].replaceAll('\n', ' | ')} → ${raw[i].isEmpty ? '[empty]' : raw[i]}').join('\n')}',
      ];
      texts = next;
    }
    timer.stop();
    final traditional = _isTraditionalTarget(request.targetLanguage);
    final translations = <String, List<String>>{};
    for (var i = 0; i < request.units.length; i++) {
      if (texts[i].isEmpty) {
        translations[request.units[i].id] = [
          request.units[i].sourceLines.join(),
        ];
        continue;
      }
      final lines = texts[i].split('\n');
      final output = pipeline.last.engine == ComicLocalTranslationModel.hyMtGgufEngine &&
              lines.length == request.units[i].sourceLines.length
          ? lines : [texts[i]];
      translations[request.units[i].id] = [for (final line in output) traditional
          ? OpenCC.simplifiedToTraditional(OpenCC.traditionalToSimplified(line))
          : OpenCC.traditionalToSimplified(line)];
    }
    _lastRunMetrics = ComicTextTranslationRunMetrics(
      elapsed: timer.elapsed,
      batchDurations: batchDurations,
      unitCount: request.units.length,
      sourceCharacters: sourceCharacters,
    );
    return ComicTranslationResult(translations);
  }

  Future<void> _loadModel(ComicLocalTranslationModel model) async {
    if (_loadedModels.contains(model.runtimeKey)) return;
    final arguments = <String, dynamic>{
      'modelKey': model.runtimeKey,
      'threads': math.min(4, math.max(1, Platform.numberOfProcessors ~/ 2)),
      if (model.engine == ComicLocalTranslationModel.hyMtGgufEngine) ...{
        'modelPath': model.filePath('model.gguf'),
        'contextSize': model.contextSize,
        'maxOutputTokens': model.maxOutputTokens,
      } else ...{
        'modelPath': model.path,
        'sourceSpm': model.filePath('source.spm'),
        'targetSpm': model.filePath('target.spm'),
        'sourcePrefixTokens': model.sourcePrefixTokens,
        'sourceEosToken': model.sourceEosToken,
        'targetPrefixTokens': model.targetPrefixTokens,
        'beamSize': model.beamSize,
      },
    };
    await _channelFor(model).invokeMethod<void>('load', arguments);
    _loadedModels.add(model.runtimeKey);
    _loadedEngines.add(model.engine);
  }

  ComicLocalTranslationModel? get _selectedModel => selectedModelId.isEmpty
      ? models.models.firstOrNull
      : models.modelById(selectedModelId);

  String _inputFor(
    ComicLocalTranslationModel model,
    String text,
    ComicTranslationRequest request,
  ) {
    if (model.engine != ComicLocalTranslationModel.hyMtGgufEngine) {
      return text;
    }
    final sourceLanguage = _sourceLanguage(request);
    final context = _contextForHyMt(request.previousPages, text);
    if (context.isNotEmpty) {
      return '$context\n参考上面的信息，把下面的文本翻译为'
          '${_languageName(model.targetLanguage, chinese: true)}，'
          '注意不需要翻译上文，也不要额外解释：\n\n$text';
    }
    if (request.glossary.isNotEmpty) {
      final terms = request.glossary.entries
          .map((entry) => '${entry.key} 翻译成 ${entry.value}')
          .join('\n');
      return '参考下面的翻译：\n$terms\n\n将以下文本翻译为'
          '${_languageName(model.targetLanguage, chinese: true)}，'
          '注意只需要输出翻译后的结果，不要额外解释：\n\n$text';
    }
    final chineseInstruction =
        _isChinese(sourceLanguage) || _isChinese(model.targetLanguage);
    if (chineseInstruction) {
      return '将以下文本翻译为${_languageName(model.targetLanguage, chinese: true)}，'
          '注意只需要输出翻译后的结果，不要额外解释：\n\n$text';
    }
    return 'Translate the following segment into '
        '${_languageName(model.targetLanguage, chinese: false)}, '
        'without additional explanation.\n\n$text';
  }

  String _contextForHyMt(
    List<ComicTranslationContextEntry> pages,
    String sourceText,
  ) {
    // Hy-MT has a 1024-token window. A short, recent context preserves enough
    // room for the prompt and response without repeating a long prefill for
    // every bubble on the page.
    const maxContextRunes = 256;
    final remaining = maxContextRunes - sourceText.runes.length;
    if (remaining <= 0 || pages.isEmpty) return '';
    final lines = <String>[];
    var used = 0;
    for (final page in pages.reversed) {
      final pairs = <String>[];
      final length = math.min(
        page.sourceTexts.length,
        page.translatedTexts.length,
      );
      for (var index = length - 1; index >= 0; index--) {
        final source = page.sourceTexts[index].trim();
        final translation = page.translatedTexts[index].trim();
        if (source.isEmpty || translation.isEmpty) continue;
        final pair = '原文：$source\n译文：$translation';
        final pairRunes = pair.runes.length;
        if (used + pairRunes > remaining) continue;
        pairs.add(pair);
        used += pairRunes;
      }
      if (pairs.isNotEmpty) {
        lines.add('[第 ${page.pageIndex + 1} 页]\n${pairs.reversed.join('\n')}');
      }
    }
    return lines.isEmpty ? '' : '上文（仅供参考）：\n${lines.reversed.join('\n')}';
  }

  static bool _isChinese(String language) =>
      language.trim().replaceAll('_', '-').toLowerCase().split('-').first ==
      'zh';

  static String _hyMtUnitText(ComicTranslationUnit unit) =>
      unit.sourceLines.join('\n');

  static String _normalizeHyMtUnitOutput(String output, ComicTranslationUnit unit) {
    final lines = output.split(RegExp(r'[\r\n]+')).map(_normalizeHyMtOutput)
        .where((line) => line.isNotEmpty).toList();
    return lines.length == unit.sourceLines.length
        ? lines.join('\n') : _normalizeHyMtOutput(output);
  }

  static String _normalizeHyMtOutput(String output) {
    // Hy-MT occasionally exposes SentencePiece's word-boundary marker or
    // inserts Unicode spaces between CJK glyphs. Those spaces are semantic in
    // Latin output, but make vertical comic text appear to have an empty cell
    // after every character.
    final runes = output.replaceAll('\u2581', ' ').runes.toList();
    final normalized = StringBuffer();
    var index = 0;
    while (index < runes.length) {
      if (!_isCjkSeparator(runes[index])) {
        normalized.writeCharCode(runes[index++]);
        continue;
      }
      var end = index + 1;
      while (end < runes.length && _isCjkSeparator(runes[end])) {
        end++;
      }
      final before = index == 0 ? null : runes[index - 1];
      final after = end == runes.length ? null : runes[end];
      if (before == null ||
          after == null ||
          !_isCompactCjkGlyph(before) ||
          !_isCompactCjkGlyph(after)) {
        normalized.write(String.fromCharCodes(runes.sublist(index, end)));
      }
      index = end;
    }
    return normalized.toString().trim();
  }

  static bool _isCjkSeparator(int rune) =>
      rune == 0x0a ||
      rune == 0x0b ||
      rune == 0x0c ||
      rune == 0x0d ||
      rune == 0x09 ||
      rune == 0x20 ||
      rune == 0x00a0 ||
      rune == 0x1680 ||
      (rune >= 0x2000 && rune <= 0x200a) ||
      rune == 0x0085 ||
      rune == 0x2028 ||
      rune == 0x2029 ||
      rune == 0x202f ||
      rune == 0x205f ||
      rune == 0x3000;

  static bool _isCompactCjkGlyph(int rune) =>
      (rune >= 0x3040 && rune <= 0x30ff) ||
      (rune >= 0x3400 && rune <= 0x4dbf) ||
      (rune >= 0x4e00 && rune <= 0x9fff) ||
      (rune >= 0xac00 && rune <= 0xd7af) ||
      (rune >= 0xf900 && rune <= 0xfaff) ||
      (rune >= 0x3001 && rune <= 0x303f) ||
      (rune >= 0xff01 && rune <= 0xff0f) ||
      (rune >= 0xff1a && rune <= 0xff20) ||
      (rune >= 0xff3b && rune <= 0xff40) ||
      (rune >= 0xff5b && rune <= 0xff65);

  static String _languageName(String language, {required bool chinese}) {
    final code = language.trim().replaceAll('_', '-').toLowerCase();
    final base = code.split('-').first;
    return switch ((base, chinese)) {
      ('zh', true) => '中文',
      ('ja', true) => '日语',
      ('ko', true) => '韩语',
      ('en', true) => '英语',
      ('zh', false) => 'Chinese',
      ('ja', false) => 'Japanese',
      ('ko', false) => 'Korean',
      ('en', false) => 'English',
      _ => language,
    };
  }

  static MethodChannel _channelFor(ComicLocalTranslationModel model) =>
      model.engine == ComicLocalTranslationModel.hyMtGgufEngine
      ? _hyMtChannel
      : _ctranslate2Channel;

  List<ComicLocalTranslationModel> _pipelineFor(
    ComicTranslationRequest request,
  ) {
    final source = _sourceLanguage(request);
    final pipeline = models.pipelineFor(
      source,
      request.targetLanguage,
      modelId: selectedModelId,
    );
    if (pipeline == null) {
      throw StateError(
        'No local translation pipeline for $source → ${request.targetLanguage}',
      );
    }
    return pipeline;
  }

  String _sourceLanguage(ComicTranslationRequest request) {
    final configured = request.ocr.sourceLanguage
        .trim()
        .replaceAll('_', '-')
        .toLowerCase()
        .split('-')
        .first;
    if (configured != 'auto') return configured;
    var hangul = 0;
    var japanese = 0;
    var han = 0;
    for (final rune in request.ocr.regions.expand(
      (region) => region.text.runes,
    )) {
      if (rune >= 0xac00 && rune <= 0xd7af) hangul++;
      if (rune >= 0x3040 && rune <= 0x30ff) japanese++;
      if (rune >= 0x3400 && rune <= 0x9fff) han++;
    }
    if (hangul > japanese) return 'ko';
    if (japanese > 0) return 'ja';
    if (han > 0 &&
        models.pipelineFor(
              'ja',
              request.targetLanguage,
              modelId: selectedModelId,
            ) !=
            null) {
      return 'ja';
    }
    throw StateError('Local translation cannot infer the source language');
  }

  bool _isTraditionalTarget(String language) {
    final value = language.trim().replaceAll('_', '-').toLowerCase();
    return value == 'zh-tw' || value == 'zh-hk' || value == 'zh-hant';
  }

  @override
  Future<void> unload() async {
    if (_loadedModels.isEmpty) return;
    if (_loadedEngines.contains(ComicLocalTranslationModel.ctranslate2Engine)) {
      await _ctranslate2Channel.invokeMethod<void>('unload');
    }
    if (_loadedEngines.contains(ComicLocalTranslationModel.hyMtGgufEngine)) {
      await _hyMtChannel.invokeMethod<void>('unload');
    }
    _loadedModels.clear();
    _loadedEngines.clear();
  }
}
