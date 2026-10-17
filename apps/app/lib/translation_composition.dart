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

import 'app_preferences.dart';
import 'comic_translation_settings_screen.dart';
import 'local_media_composition.dart';
import 'startup_platform.dart';
import 'translation_indicator.dart';

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
  ComicTranslationReaderExtension(this.pipeline, {required this.appPreferences}) {
    _initialization = _initialize();
  }

  final PipelineReaderSession pipeline;
  final AppPreferencesController appPreferences;
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
      final wasEnabled = session.enabled;
      session.setEnabled(preferences['enabled'] == true);
      final observation = _observation;
      if (!wasEnabled && session.enabled && observation != null) observe(observation);
      notifyListeners();
      return;
    }
    _session?.setEnabled(false);
    unawaited(_reload());
  }

  _ReaderTranslationConfiguration _configuration(Map<String, Object?> preferences) => (
    preferences: jsonEncode({
      for (final entry in preferences.entries)
        if (entry.key != 'enabled' && entry.key != 'showIndicator' &&
            entry.key != 'indicatorOnlyWhileProcessing') entry.key: entry.value,
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
    return ListenableBuilder(listenable: appPreferences,
      builder: (_, __) => _buildCurrentState((index, state) => ComicTranslationIndicator(
        pageIndex: index,
        phase: _error == null ? state?.phase : ComicTranslationPhase.failed,
        status: _status(state),
        showPageNumber: appPreferences.debugModeEnabled,
        onlyWhileProcessing: _preferences['indicatorOnlyWhileProcessing'] == true,
      )),
    );
  }

  Future<void> _edit(BuildContext context, String status) async {
    const languages = {'auto': '自动', 'ja': '日语', 'ko': '韩语', 'en': '英语', 'zh': '中文'};
    const indicatorModes = {'always': '常驻', 'processing': '处理中', 'off': '关闭'};
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => ListenableBuilder(
        listenable: _settings,
        builder: (_, __) => ListenableBuilder(
          listenable: _session?.detectedLanguageListenable ?? this,
          builder: (_, __) {
            final theme = Theme.of(sheetContext);
            ChoiceChip pill(String label, bool isSelected, ValueChanged<bool> onSelected) => ChoiceChip(
              label: Text(label, maxLines: 1, softWrap: false),
              selected: isSelected,
              showCheckmark: false,
              shape: const StadiumBorder(),
              labelStyle: theme.textTheme.labelLarge,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              labelPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.standard,
              materialTapTargetSize: MaterialTapTargetSize.padded,
              onSelected: onSelected,
            );
            final selected = _preferences['sourceLanguage'] as String;
            final indicatorMode = _preferences['showIndicator'] == false ? 'off'
                : _preferences['indicatorOnlyWhileProcessing'] == true ? 'processing' : 'always';
            final detected = _session?.detectedLanguageListenable.value;
            final subtitle = selected == 'auto' && detected != null
                ? '$status · ${languages[detected] ?? detected}' : status;
            return SafeArea(child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                  Flexible(child: Semantics(label: '原文语言', child: Wrap(
                    key: const ValueKey('reader-translation-source-language'),
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final entry in languages.entries)
                        pill(entry.value, selected == entry.key, (_) async {
                          Navigator.pop(sheetContext);
                          await _settings.setComic(_chapter.sourceId, _chapter.comicId,
                            {'sourceLanguage': entry.key});
                        }),
                    ],
                  ))),
                ]),
                const SizedBox(height: 4),
                Row(children: [
                  Text('翻译指示器', style: theme.textTheme.bodyMedium),
                  const SizedBox(width: 8),
                  Flexible(child: Semantics(label: '翻译指示器', child: Wrap(
                    key: const ValueKey('reader-translation-indicator-mode'),
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final entry in indicatorModes.entries)
                        pill(entry.value, indicatorMode == entry.key, (_) {
                          _settings.setComic(_chapter.sourceId, _chapter.comicId, {
                            'showIndicator': entry.key != 'off',
                            'indicatorOnlyWhileProcessing': entry.key == 'processing',
                          });
                        }),
                    ],
                  ))),
                ]),
                const SizedBox(height: 4),
                Align(alignment: Alignment.centerLeft, child: Semantics(label: '翻译本漫画',
                  child: Switch(
                    key: const ValueKey('reader-translation-enable'),
                    value: _session?.enabled == true,
                    padding: EdgeInsets.zero,
                    onChanged: (enabled) async {
                      Navigator.pop(sheetContext);
                      await _settings.setComic(_chapter.sourceId, _chapter.comicId, {'enabled': enabled});
                    },
                  ),
                )),
              ]),
            ));
          },
        ),
      ),
    );
  }

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
