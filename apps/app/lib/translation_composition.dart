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

import 'comic_translation_settings_screen.dart';
import 'local_media_composition.dart';
import 'startup_platform.dart';

Future<void>? _translationInitialization;

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
    _session?.setEnabled(false);
    unawaited(_reload());
  }

  Future<void> _reload() {
    final task = _reloadTail.then((_) async {
      _inputToken.cancel();
      await _session?.close();
      _session = null;
      if (_closed) return;
      ComicTranslationRuntime.instance.configure();
      final preferences = _preferences;
      _inputToken = MediaLoadToken();
      _session = ComicTranslationSession(
        enabled: preferences['enabled'] == true,
        sourceLanguage: preferences['sourceLanguage'] as String,
        targetLanguage: preferences['targetLanguage'] as String,
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
    return ComicTranslationOverlay(
      session: _session,
      identity: _identity(asset.index),
      controller: _overlays,
      fit: fit,
      child: child,
    );
  }

  @override
  bool handleSingleTap(Offset globalPosition) => _overlays.peekSourceAt(globalPosition);

  @override
  Widget buildControls(BuildContext context) {
    final session = _session;
    Widget button(ComicTranslationPageState? state) {
      final phase = state?.phase;
      final status = _error != null ? '翻译初始化失败：$_error' : switch (phase) {
        ComicTranslationPhase.waitingForImage => '等待完整图片',
        ComicTranslationPhase.recognizing => '正在识别文字',
        ComicTranslationPhase.translating => '正在翻译',
        ComicTranslationPhase.ready => '译文已就绪',
        ComicTranslationPhase.unsupportedMedia => '暂不支持动图翻译',
        ComicTranslationPhase.unavailable => '请先配置翻译模型与 API',
        ComicTranslationPhase.failed => '翻译失败：${state?.error}',
        _ => session?.enabled == true ? '翻译已开启' : '翻译已关闭',
      };
      return IconButton(
        key: const ValueKey('reader-translation'),
        tooltip: status,
        icon: Icon(session?.enabled == true ? Icons.translate : Icons.g_translate),
        onPressed: () => _edit(context, status),
      );
    }
    if (session == null) return button(null);
    return ValueListenableBuilder<int>(
      valueListenable: _currentIndex,
      builder: (_, index, __) => ValueListenableBuilder<ComicTranslationPageState>(
        valueListenable: session.listenable(_identity(index)),
        builder: (_, state, __) => button(state),
      ),
    );
  }

  Future<void> _edit(BuildContext context, String status) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: const Text('漫画翻译'), subtitle: Text(status)),
            SwitchListTile(
              title: const Text('翻译本漫画'),
              value: _session?.enabled == true,
              onChanged: (enabled) async {
                Navigator.pop(sheetContext);
                await _settings.setComic(_chapter.sourceId, _chapter.comicId, {
                  'enabled': enabled,
                });
              },
            ),
            ListTile(
              title: const Text('重试当前页'),
              leading: const Icon(Icons.refresh),
              onTap: () {
                Navigator.pop(sheetContext);
                final current = _observation?.currentIndex;
                if (current != null) _session?.retry(_identity(current));
              },
            ),
            ListTile(
              title: const Text('翻译模型与 API'),
              leading: const Icon(Icons.settings_outlined),
              onTap: () {
                Navigator.pop(sheetContext);
                Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => ComicTranslationSettingsScreen(
                    sourceId: _chapter.sourceId,
                    comicId: _chapter.comicId,
                  ),
                ));
              },
            ),
          ],
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
