import 'dart:async';
import 'dart:convert';

import 'package:comic_translation/comic_translation.dart';
import 'package:domain/domain.dart';
import 'package:downloads_bridge/downloads_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:local_media_bridge/local_media_bridge.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';
import 'package:reader_runtime/reader_runtime.dart';
import 'package:storage_bridge/storage_bridge.dart';
import 'package:telemetry/telemetry.dart';

import 'comic_translation_settings_screen.dart';
import 'local_media_composition.dart';
import 'startup_platform.dart';

Future<void>? _translationInitialization;

typedef _ReaderTranslationConfiguration = ({
  String preferences,
  ComicOcrEngine? ocr,
  ComicTextTranslationEngine? translator,
});

Future<void> initializeComicTranslation() =>
    _translationInitialization ??= _initializeComicTranslation();

Future<void> _initializeComicTranslation() async {
  ComicTranslationHttp.adapterFactory = () => ScheduledDioAdapter(
        defaultDownloadResourceCoordinator.networkLane,
      );
  if (defaultTargetPlatform == TargetPlatform.android) {
    await startupPlatformChannel.invokeMethod<void>(
      'attachPlugin',
      const <String, Object?>{'name': 'comic_translation'},
    );
  }
  final root = await getDefaultZicStorageRoot(
    applicationSupportPath: getStartupApplicationSupportPath,
  );
  await ComicTranslationRuntime.instance.init('$root/translation');
}

/// App-owned sidecar. Reader forwards observations and paints its read-only output.
final class ComicTranslationReaderExtension extends ReaderPresentationExtension {
  ComicTranslationReaderExtension(this.pipeline) {
    _initialization = _initialize();
  }

  final PipelineReaderSession pipeline;
  final _overlays = ComicTranslationOverlayController();
  final _currentIndex = ValueNotifier<int>(0);
  final _settings = ComicTranslationSettings.instance;
  final Map<int, PipelinePageStreamListener> _listeners = {};
  final Map<int, PipelinePageTransferState> _transferStates = {};
  late final Future<void> _initialization;
  Future<void> _reloadTail = Future<void>.value();
  Future<void>? _closing;
  ComicTranslationSession? _session;
  _ReaderTranslationConfiguration? _appliedConfiguration;
  ReaderObs? _observation;
  MediaLoadToken _inputToken = MediaLoadToken();
  Object? _error;
  bool _closed = false;

  ChapterManifest get _chapter => pipeline.chapter;
  Map<String, Object?> get _preferences =>
      _settings.forComic(_chapter.sourceId, _chapter.comicId);

  Future<void> _initialize() async {
    try {
      await initializeComicTranslation();
      if (_closed) return;
      _settings.addListener(_settingsChanged);
      await _reload();
    } on Object catch (error) {
      if (!_closed) {
        _error = error;
        notifyListeners();
      }
    }
  }

  void _settingsChanged() {
    if (_closed) return;
    try {
      ComicTranslationRuntime.instance.configure();
    } on Object catch (error) {
      _session?.setEnabled(false);
      _error = error;
      notifyListeners();
      return;
    }
    final preferences = _preferences;
    final session = _session;
    if (session != null && _appliedConfiguration == _configuration(preferences)) {
      _error = null;
      session.setEnabled(preferences['enabled'] == true);
      final observation = _observation;
      if (session.enabled && observation != null) observe(observation);
      notifyListeners();
      return;
    }
    _session?.setEnabled(false);
    unawaited(_reload());
  }

  _ReaderTranslationConfiguration _configuration(Map<String, Object?> preferences) => (
    preferences: jsonEncode({
      for (final entry in preferences.entries)
        if (entry.key != 'enabled' && entry.key != 'showIndicator') entry.key: entry.value,
    }),
    ocr: ComicTranslationEngineRegistry.instance.ocrEngine,
    translator: ComicTranslationEngineRegistry.instance.translationEngine,
  );

  Future<void> _reload() {
    final task = _reloadTail.then((_) async {
      _inputToken.cancel();
      final previous = _session;
      _session = null;
      _appliedConfiguration = null;
      await previous?.close();
      if (_closed) return;
      ComicTranslationRuntime.instance.configure();
      final preferences = _preferences;
      _appliedConfiguration = _configuration(preferences);
      _inputToken = MediaLoadToken();
      _session = ComicTranslationSession(
        enabled: preferences['enabled'] == true,
        sourceLanguage: preferences['sourceLanguage'] as String,
        targetLanguage: preferences['targetLanguage'] as String,
        detectedSourceLanguage: _settings.detectedLanguage(_chapter.sourceId, _chapter.comicId,
          ComicTranslationEngineRegistry.instance.ocrEngine?.modelVersion ?? ''),
        onSourceLanguageDetected: (language) => _settings.rememberLanguage(
          _chapter.sourceId, _chapter.comicId, language,
          ComicTranslationEngineRegistry.instance.ocrEngine?.modelVersion ?? ''),
        onDiagnostic: (identity, details) => pipeline.trace.record(TraceEvent(
          monotonicMicros: const SystemClock().nowMicros(), sessionId: pipeline.sessionId,
          kind: TraceEventKind.comicTranslation,
          payload: {'pageIndex': identity.pageIndex, ...details},
        )),
        policy: ComicTranslationPolicy(
          contextPages: preferences['contextPages'] as int,
          translateSoundEffects: preferences['translateSoundEffects'] == true,
          useCleanOverlay: preferences['useCleanOverlay'] == true,
        ),
        inputResolver: ComicTranslationInputResolver(openFile: _openInput),
      );
      _error = null;
      final observation = _observation;
      if (observation != null) observe(observation);
      notifyListeners();
    });
    _reloadTail = task.then<void>((_) {}, onError: (Object error, StackTrace _) {
      if (!_closed) {
        _error = error;
        notifyListeners();
      }
    });
    return _reloadTail;
  }

  ComicTranslationPageIdentity _identity(int index) {
    final asset = _chapter.pages[index];
    return ComicTranslationPageIdentity(
      imageKey: jsonEncode([_chapter.chapter.sourceRevision, asset.uri.toString()]),
      sourceKey: _chapter.sourceId,
      comicId: _chapter.comicId,
      chapterId: _chapter.chapter.chapterId,
      pageIndex: index,
      mediaKind: asset.animatedHint || asset.contentKindHint == ContentKindHint.gif
          ? ComicTranslationMediaKind.animatedImage
          : ComicTranslationMediaKind.staticImage,
    );
  }

  Future<ComicTranslationInputFile?> _openInput(
    ComicTranslationPageIdentity identity,
  ) async {
    final asset = _chapter.pages[identity.pageIndex];
    final token = _inputToken;
    final lease = await pipeline.openSealedPageFile(asset, token);
    if (lease != null) {
      return ComicTranslationInputFile(path: lease.path, release: lease.release);
    }
    token.throwIfCancelled();
    if (asset.uri.scheme == 'content') {
      final document = await const LocalMediaBridge().openDocumentFile(
        asset.uri.toString(),
      );
      if (token.isCancelled) {
        await document.close();
        token.throwIfCancelled();
      }
      return ComicTranslationInputFile(path: document.path, release: document.close);
    }
    // Imported local files remain source-owned.
    return ComicTranslationInputFile.openLocalUri(asset.uri);
  }

  @override
  void observe(ReaderObs observation) {
    if (_closed) return;
    _observation = observation;
    _currentIndex.value = observation.currentIndex;
    final session = _session;
    if (session == null || !session.enabled) return;
    final current = <int>{
      observation.currentIndex,
      for (final coverage in observation.visibleCoverages)
        if (coverage.fraction > 0) coverage.pageIndex,
    };
    final near = <int>[
      for (var offset = 1; offset <= 4; offset++)
        if (observation.currentIndex + offset < _chapter.pages.length &&
            !current.contains(observation.currentIndex + offset))
          observation.currentIndex + offset,
    ];
    final retained = {...current, ...near};
    for (final index in _listeners.keys.toList()) {
      if (!retained.contains(index)) {
        pipeline.pageStream(_chapter.pages[index]).removeListener(_listeners.remove(index)!);
        _transferStates.remove(index);
      }
    }
    for (final index in retained) {
      if (_listeners.containsKey(index)) continue;
      void changed(PipelinePageStreamSnapshot snapshot) {
        final previous = _transferStates[index];
        _transferStates[index] = snapshot.state;
        if ((previous == PipelinePageTransferState.sealed ||
                previous == PipelinePageTransferState.promoted) &&
            snapshot.state != previous &&
            snapshot.state != PipelinePageTransferState.sealed &&
            snapshot.state != PipelinePageTransferState.promoted) {
          _session?.invalidate(_identity(index));
        }
        if (snapshot.state == PipelinePageTransferState.sealed ||
            snapshot.state == PipelinePageTransferState.promoted) {
          scheduleMicrotask(() {
            if (!_closed) _session?.imageReady(_identity(index));
          });
        }
      }
      _listeners[index] = changed;
      pipeline.pageStream(_chapter.pages[index]).addListener(changed);
    }
    session.reportPages(
      current: current.map(_identity).toList(),
      near: near.map(_identity).toList(),
      interaction: switch (observation.interaction) {
        Interaction.dragging => ComicTranslationInteraction.dragging,
        Interaction.scrolling => ComicTranslationInteraction.scrolling,
        Interaction.settling => ComicTranslationInteraction.settling,
        Interaction.scrubbing || Interaction.jumping => ComicTranslationInteraction.jumping,
        Interaction.idle => ComicTranslationInteraction.idle,
      },
    );
  }

  @override
  Widget decoratePage(BuildContext context, PageAsset asset, BoxFit fit, Widget child) {
    return ListenableBuilder(
      listenable: this,
      child: child,
      builder: (_, media) => ComicTranslationOverlay(
        session: _session,
        identity: _identity(asset.index),
        controller: _overlays,
        fit: fit,
        child: media!,
      ),
    );
  }

  @override
  bool handleSingleTap(Offset globalPosition) => _overlays.peekSourceAt(globalPosition);

  String _status(ComicTranslationPageState? state) => _error != null
      ? '翻译初始化失败：$_error' : switch (state?.phase) {
        ComicTranslationPhase.waitingForImage => '等待完整图片',
        ComicTranslationPhase.queued => '等待翻译',
        ComicTranslationPhase.loadingCache => '准备图片与缓存',
        ComicTranslationPhase.recognizing => _session?.effectiveSourceLanguage == 'auto'
            ? '正在判断语言与识别文字' : '正在识别文字',
        ComicTranslationPhase.translating => '正在翻译',
        ComicTranslationPhase.ready => state!.artifact?.regions.isEmpty == true
            ? '本页未识别到文字' : '译文已就绪',
        ComicTranslationPhase.unsupportedMedia => '暂不支持动图翻译',
        ComicTranslationPhase.unavailable => '请先配置翻译模型与 API',
        ComicTranslationPhase.failed => '翻译失败：${state?.error}',
        _ => _session?.enabled == true ? '翻译已开启' : '翻译已关闭',
      };

  Widget _buildCurrentState(Widget Function(int index, ComicTranslationPageState? state) builder) {
    final session = _session;
    if (session == null) return builder(_currentIndex.value, null);
    return ValueListenableBuilder<int>(
      valueListenable: _currentIndex,
      builder: (_, index, __) => ValueListenableBuilder<ComicTranslationPageState>(
        valueListenable: session.listenable(_identity(index)),
        builder: (_, state, __) => builder(index, state),
      ),
    );
  }

  @override
  Widget buildControls(BuildContext context) => _buildCurrentState((index, state) {
    final enabled = _session?.enabled == true;
    return GestureDetector(
      onLongPress: () => _edit(context, _status(state)),
      child: TooltipTheme(
        // The settings gesture owns long press; the tooltip keeps its label.
        data: TooltipTheme.of(context).copyWith(triggerMode: TooltipTriggerMode.manual),
        child: IconButton(
          key: const ValueKey('reader-translation'),
          tooltip: '${enabled ? '关闭翻译' : '开启翻译'}（长按设置）',
          isSelected: enabled,
          icon: const Icon(Icons.g_translate),
          selectedIcon: const Icon(Icons.translate),
          onPressed: _session == null ? null : () => _settings.setComic(
            _chapter.sourceId, _chapter.comicId, {'enabled': !enabled}),
        ),
      ),
    );
  });

  @override
  Widget buildStatus(BuildContext context) {
    if (_preferences['showIndicator'] == false) return const SizedBox.shrink();
    if (_session?.enabled != true && _error == null) return const SizedBox.shrink();
    return _buildCurrentState((index, state) {
      final phase = state?.phase;
      final busy = _error == null && (phase == ComicTranslationPhase.queued ||
          phase == ComicTranslationPhase.loadingCache || phase == ComicTranslationPhase.waitingForImage ||
          phase == ComicTranslationPhase.recognizing || phase == ComicTranslationPhase.translating);
      final status = _status(state);
      return Semantics(liveRegion: true, label: '第${index + 1}页，$status',
        child: ExcludeSemantics(child: Container(
          key: const ValueKey('reader-translation-status'),
          constraints: const BoxConstraints(maxWidth: 280),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.76),
            borderRadius: BorderRadius.circular(16)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (busy) const SizedBox.square(dimension: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white))
            else Icon(phase == ComicTranslationPhase.ready ? Icons.check_circle_outline : Icons.info_outline,
              color: Colors.white, size: 14),
            const SizedBox(width: 6),
            Flexible(child: Text('第${index + 1}页 · $status', maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 12))),
          ]),
        )),
      );
    });
  }

  Future<void> _edit(BuildContext context, String status) async {
    const languages = {'auto': '自动', 'ja': '日语', 'ko': '韩语', 'en': '英语', 'zh': '中文'};
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => ListenableBuilder(
        listenable: _settings,
        builder: (_, __) => ListenableBuilder(
          listenable: _session?.detectedLanguageListenable ?? this,
          builder: (_, __) {
            final theme = Theme.of(sheetContext);
            final selected = _preferences['sourceLanguage'] as String;
            final detected = _session?.detectedLanguageListenable.value;
            final subtitle = selected == 'auto' && detected != null
                ? '$status · ${languages[detected] ?? detected}' : status;
            return SafeArea(child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  IconButton(tooltip: '重试当前页', icon: const Icon(Icons.refresh),
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      final current = _observation?.currentIndex;
                      if (current != null) _session?.retry(_identity(current));
                    }),
                  Expanded(child: Column(children: [
                    Text('漫画翻译', style: theme.textTheme.titleMedium),
                    Text(subtitle, textAlign: TextAlign.center, maxLines: 2,
                      overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                  ])),
                  IconButton(tooltip: '翻译模型与 API', icon: const Icon(Icons.settings_outlined),
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => ComicTranslationSettingsScreen(
                          sourceId: _chapter.sourceId, comicId: _chapter.comicId),
                      ));
                    }),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Text('原文', style: theme.textTheme.bodyMedium),
                  const SizedBox(width: 8),
                  for (final entry in languages.entries)
                    Expanded(child: Semantics(selected: selected == entry.key,
                      child: TextButton(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 48),
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          foregroundColor: selected == entry.key
                              ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                        ),
                        onPressed: () async {
                          Navigator.pop(sheetContext);
                          await _settings.setComic(_chapter.sourceId, _chapter.comicId,
                            {'sourceLanguage': entry.key});
                        },
                        child: Text(entry.value, maxLines: 1, softWrap: false,
                          style: TextStyle(fontWeight: selected == entry.key ? FontWeight.bold : null,
                            decoration: selected == entry.key ? TextDecoration.underline : null)),
                      ),
                    )),
                ]),
                const SizedBox(height: 4),
                Row(children: [
                  Expanded(child: _sheetToggle(label: '翻译本漫画',
                    value: _session?.enabled == true,
                    onChanged: (enabled) async {
                      Navigator.pop(sheetContext);
                      await _settings.setComic(_chapter.sourceId, _chapter.comicId, {'enabled': enabled});
                    },
                  )),
                  const SizedBox(width: 16),
                  Expanded(child: _sheetToggle(
                    key: const ValueKey('reader-translation-indicator-toggle'),
                    label: '显示指示器',
                    value: _preferences['showIndicator'] != false,
                    onChanged: (visible) => _settings.setComic(
                      _chapter.sourceId, _chapter.comicId, {'showIndicator': visible}),
                  )),
                ]),
              ]),
            ));
          },
        ),
      ),
    );
  }

  Widget _sheetToggle({Key? key, required String label, required bool value,
      required ValueChanged<bool> onChanged}) => MergeSemantics(child: InkWell(
    key: key,
    onTap: () => onChanged(!value),
    child: Row(children: [
      Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14))),
      const SizedBox(width: 8),
      Switch(value: value, onChanged: onChanged, padding: EdgeInsets.zero),
    ]),
  ));

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _inputToken.cancel();
    for (final entry in _listeners.entries) {
      pipeline.pageStream(_chapter.pages[entry.key]).removeListener(entry.value);
    }
    _listeners.clear();
    _settings.removeListener(_settingsChanged);
    await _initialization;
    await _reloadTail;
    await _session?.close();
    _currentIndex.dispose();
    dispose();
  }
}
