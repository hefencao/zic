import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'engine.dart';
import 'grouping.dart';
import 'http_client.dart';
import 'input_resolver.dart';
import 'models.dart';
import 'policy.dart';
import 'store.dart';

part 'chapter_task.dart';

const _translationArtifactVersion = 'artifact-v6';

final class ComicTranslationSession {
  static final _ocrTasks = <String, Future<({ComicOcrArtifact artifact, String digest})>>{};
  static final _translationTasks = <String, _SharedTranslationWork>{};

  static Future<T> _joinWork<T>(Map<String, Future<T>> tasks, String key,
      Future<T> Function() run) {
    final existing = tasks[key];
    if (existing != null) return existing;
    late final Future<T> task;
    task = Future<T>.sync(run).whenComplete(() {
      if (identical(tasks[key], task)) tasks.remove(key);
    });
    tasks[key] = task;
    return task;
  }

  ComicTranslationPolicy _policy;
  ComicTranslationPolicy get policy => _policy;
  final ComicTranslationInputResolver inputResolver;
  final ComicTranslationEngineRegistry engines;
  final String sourceLanguage;
  final String targetLanguage;
  final Future<void> Function(String language)? onSourceLanguageDetected;
  final void Function(ComicTranslationPageIdentity identity, Map<String, Object?> details)? onDiagnostic;

  ComicTranslationSession({
    required bool enabled,
    required this.sourceLanguage,
    required this.targetLanguage,
    String? detectedSourceLanguage,
    this.onSourceLanguageDetected,
    this.onDiagnostic,
    ComicTranslationPolicy policy = const ComicTranslationPolicy(),
    this.inputResolver = const ComicTranslationInputResolver(),
    ComicTranslationEngineRegistry? engines,
    Stream<String>? imageChanges,
  }) : _policy = policy,
       engines = engines ?? ComicTranslationEngineRegistry.instance,
       _enabled = enabled,
       _detectedLanguage = ValueNotifier(detectedSourceLanguage) {
    _cacheSubscription = imageChanges?.listen(_onCacheChanged);
    this.engines.workPaused.addListener(_availabilityChanged);
  }

  bool _enabled;
  bool _running = false;
  bool _disposed = false;
  ComicTranslationEnginePair? _enginePair;
  Future<ComicTranslationEnginePair>? _acquiringEngines;
  Timer? _submissionTimer;
  late final StreamSubscription<String>? _cacheSubscription;
  Completer<void>? _pumpDone;
  Future<void>? _closing;
  _ProcessTicket? _processing;
  ComicTranslationInteraction _interaction = ComicTranslationInteraction.idle;
  List<ComicTranslationPageIdentity> _current = const [];
  List<ComicTranslationPageIdentity> _near = const [];
  final Map<String, ValueNotifier<ComicTranslationPageState>> _states = {};
  final Map<String, ComicTranslationPageIdentity> _identities = {};
  final Map<String, _QueuedTranslation> _queue = {};
  final Map<String, Future<void>> _cacheProbes = {};
  final Set<_SharedTranslationWork> _translationWork = {};
  final Map<String, int> _cacheProbeGenerations = {};
  final Map<String, Map<int, ComicTranslationArtifact>> _readyPages = {};
  final ValueNotifier<double> _fontScale = ValueNotifier(1);
  final ValueNotifier<String?> _detectedLanguage;
  bool _fontScaleResolved = false;
  int _generation = 0;
  Set<String> _retainedKeys = const {};

  bool get enabled => _enabled;

  ValueListenable<String?> get detectedLanguageListenable => _detectedLanguage;

  String get effectiveSourceLanguage => sourceLanguage == 'auto'
      ? _detectedLanguage.value ?? 'auto' : sourceLanguage;

  bool get backendReady => engines.ready;

  bool setPrefetchPages({required int pages, required int cachedPages}) {
    if (_disposed || policy.prefetchPages == pages && policy.cachePrefetchPages == cachedPages) return false;
    _policy = policy.withPrefetch(pages: pages, cachedPages: cachedPages);
    reportPages(current: _current, near: _near, interaction: _interaction);
    return true;
  }

  ValueListenable<double> get fontScaleListenable => _fontScale;

  void _availabilityChanged() {
    if (_disposed) return;
    _generation++;
    _notifyTranslationActivity();
    _submissionTimer?.cancel();
    _queue.clear();
    if (!engines.workPaused.value) {
      reportPages(current: _current, near: _near, interaction: _interaction);
    }
  }

  ValueListenable<ComicTranslationPageState> listenable(
    ComicTranslationPageIdentity identity,
  ) {
    _identities[identity.key] = identity;
    return _states.putIfAbsent(
      identity.key,
      () => ValueNotifier(_enabled
          ? const ComicTranslationPageState(ComicTranslationPhase.queued)
          : ComicTranslationPageState.disabled),
    );
  }

  void setEnabled(bool value) {
    if (_enabled == value || _disposed) return;
    _enabled = value;
    if (!value) {
      _generation++;
      _notifyTranslationActivity();
      _submissionTimer?.cancel();
      _queue.clear();
      _retainedKeys = const {};
      for (final state in _states.values) {
        state.value = ComicTranslationPageState(
          ComicTranslationPhase.disabled,
          artifact: state.value.artifact,
          cleanOverlayPng: state.value.cleanOverlayPng,
        );
      }
      unawaited(_releaseDisabledEngines());
      return;
    }
    reportPages(current: _current, near: _near, interaction: _interaction);
  }

  void setInteraction(ComicTranslationInteraction interaction) {
    if (_interaction == interaction) return;
    _interaction = interaction;
    if (interaction == ComicTranslationInteraction.idle ||
        interaction == ComicTranslationInteraction.jumping) {
      reportPages(current: _current, near: _near, interaction: interaction);
    }
  }

  void reportPages({
    required List<ComicTranslationPageIdentity> current,
    List<ComicTranslationPageIdentity> near = const [],
    required ComicTranslationInteraction interaction,
  }) {
    _current = List.unmodifiable(current);
    _near = List.unmodifiable(near);
    _interaction = interaction;
    _submissionTimer?.cancel();
    if (!_enabled || _disposed || engines.workPaused.value || current.isEmpty) {
      _queue.clear();
      _retainedKeys = const {};
      _notifyTranslationActivity();
      return;
    }
    _retainedKeys = _retainedPageKeys();
    _notifyTranslationActivity();
    _queue.removeWhere((key, _) => !_retainedKeys.contains(key));
    for (final identity in _current) {
      final artifact = _states[identity.key]?.value.artifact;
      if (artifact != null) _updateFontScale(artifact);
    }
    final delay = policy.submissionDelay(interaction);
    // Reading complete cached results is independent of the interaction delay
    // and serial inference. The idle current page already owns the serial path.
    for (final identity in [
      if (_running || delay != Duration.zero) ..._current,
      ..._near.take(policy.cachePrefetchPages),
    ]) {
      _probeCache(identity);
    }
    if (delay == Duration.zero) {
      _submitVisiblePages();
    } else {
      _submissionTimer = Timer(delay, _submitVisiblePages);
    }
  }

  void imageReady(ComicTranslationPageIdentity identity) {
    final state = _states[identity.key]?.value;
    if (!_enabled || state?.phase != ComicTranslationPhase.waitingForImage) {
      return;
    }
    _probeCache(identity);
    if (_current.any((page) => page.key == identity.key)) {
      _enqueue(identity, 1000);
    } else if (_near.take(policy.prefetchPages).any((page) => page.key == identity.key)) {
      _enqueue(identity, 500);
    }
  }

  void invalidate(ComicTranslationPageIdentity identity) {
    if (_disposed) return;
    _generation++;
    _notifyTranslationActivity();
    _readyPages[identity.chapterId]?.remove(identity.pageIndex);
    _setState(identity, const ComicTranslationPageState(ComicTranslationPhase.waitingForImage));
    if (_enabled) reportPages(current: _current, near: _near, interaction: _interaction);
  }

  void retry(ComicTranslationPageIdentity identity) {
    if (!_enabled) return;
    _enqueue(identity, 1000);
  }

  void _submitVisiblePages() {
    if (!_enabled || _disposed) return;
    final near = _near.take(policy.prefetchPages).toList(growable: false);
    _retainedKeys = _retainedPageKeys();
    _queue.removeWhere((key, _) => !_retainedKeys.contains(key));
    for (final identity in _current) {
      _enqueue(identity, policy.priority(distance: 0, current: true));
    }
    for (var i = 0; i < near.length; i++) {
      _enqueue(
        near[i],
        policy.priority(distance: i + 1, current: false),
      );
    }
  }

  Set<String> _retainedPageKeys() => {
    for (final identity in _current) identity.key,
    for (final identity in _near.take(math.max(policy.prefetchPages, policy.cachePrefetchPages)))
      identity.key,
  };

  void _enqueue(ComicTranslationPageIdentity identity, int priority) {
    if (engines.workPaused.value) return;
    _identities[identity.key] = identity;
    final state = _states.putIfAbsent(
      identity.key,
      () => ValueNotifier(ComicTranslationPageState.disabled),
    );
    if (identity.mediaKind == ComicTranslationMediaKind.animatedImage) {
      state.value = const ComicTranslationPageState(
        ComicTranslationPhase.unsupportedMedia,
      );
      return;
    }
    if (_enginePair == null && !engines.ready) {
      state.value = const ComicTranslationPageState(
        ComicTranslationPhase.unavailable,
      );
      return;
    }
    final readyArtifact = state.value.artifact;
    if (readyArtifact != null) {
      state.value = ComicTranslationPageState(
        ComicTranslationPhase.ready,
        artifact: readyArtifact,
        cleanOverlayPng: state.value.cleanOverlayPng,
      );
      return;
    }
    if (state.value.phase == ComicTranslationPhase.ready) return;
    if (_processing?.identityKey == identity.key && _processing?.generation == _generation) return;
    final queued = _queue[identity.key];
    if (queued == null || priority > queued.priority) {
      _queue[identity.key] = _QueuedTranslation(identity, priority);
    }
    if (_cacheProbes.containsKey(identity.key)) return;
    state.value = const ComicTranslationPageState(
      ComicTranslationPhase.queued,
    );
    unawaited(_pump());
  }

  void _probeCache(ComicTranslationPageIdentity identity) {
    if (_disposed || !_enabled || engines.workPaused.value || !engines.ready ||
        identity.mediaKind == ComicTranslationMediaKind.animatedImage ||
        _processing?.identityKey == identity.key || _cacheProbes.containsKey(identity.key) ||
        _cacheProbeGenerations[identity.key] == _generation ||
        _states[identity.key]?.value.artifact != null) return;
    final ticket = _ProcessTicket(generation: _generation, identityKey: identity.key);
    _identities[identity.key] = identity;
    _cacheProbeGenerations[identity.key] = _generation;
    late final Future<void> task;
    // Cache preparation may run beside inference; it never calls a model.
    task = _process(identity, ticket, cacheOnly: true).catchError((Object error, StackTrace _) {
      _diagnose(identity, {'stage': 'cache-probe-failed', 'errorType': error.runtimeType.toString()});
    }).whenComplete(() {
      _cacheProbes.remove(identity.key);
      final state = _states[identity.key]?.value;
      if (state?.phase == ComicTranslationPhase.waitingForImage) {
        _cacheProbeGenerations.remove(identity.key);
      }
      if (_isActive(ticket) && state?.phase == ComicTranslationPhase.loadingCache) {
        _setState(identity, const ComicTranslationPageState(ComicTranslationPhase.queued));
      }
      if (ticket.generation != _generation && _retainedKeys.contains(identity.key)) {
        _probeCache(identity);
      }
      if (!_disposed && _enabled && _queue.isNotEmpty) unawaited(_pump());
    });
    _cacheProbes[identity.key] = task;
  }

  void _onCacheChanged(String cacheKey) {
    if (!_enabled || _disposed) return;
    for (final entry in _states.entries) {
      if (entry.value.value.phase != ComicTranslationPhase.waitingForImage) {
        continue;
      }
      final identity = _identities[entry.key]!;
      final identityCacheKey = identity.key;
      if (cacheKey == identityCacheKey) _enqueue(identity, 1000);
    }
  }

  Future<void> _pump() async {
    if (_running || _disposed) return;
    _running = true;
    final done = _pumpDone = Completer<void>();
    try {
      while (_enabled && !_disposed && !engines.workPaused.value && _queue.isNotEmpty) {
        final item = _queue.values.reduce(
          (a, b) => a.priority >= b.priority ? a : b,
        );
        _queue.remove(item.identity.key);
        final ticket = _ProcessTicket(
          generation: _generation,
          identityKey: item.identity.key,
        );
        if (!_isActive(ticket)) continue;
        // Claim before yielding so a repeated observation cannot start a cache
        // probe for the same page between this lookup and serial processing.
        _processing = ticket;
        try {
          await _cacheProbes[item.identity.key];
          if (!_isActive(ticket) || _states[item.identity.key]?.value.artifact != null) continue;
          await _process(item.identity, ticket);
        } catch (error) {
          if (error is ComicTranslationHttpRetiredException && _isActive(ticket)) {
            // A page can leave and return while retired backoff is unwinding.
            // Replay its fresh demand rather than showing a stale cancellation.
            _queue[item.identity.key] = item;
            _setState(item.identity, const ComicTranslationPageState(ComicTranslationPhase.queued));
          } else {
            _setStateIfActive(item.identity, ticket,
              ComicTranslationPageState(ComicTranslationPhase.failed, error: error));
          }
        } finally {
          _processing = null;
        }
      }
    } finally {
      _running = false;
      done.complete();
      if (!_disposed && _enabled && _queue.isNotEmpty) {
        unawaited(_pump());
      }
    }
  }

  Future<void> _process(
    ComicTranslationPageIdentity identity,
    _ProcessTicket ticket, {
    bool cacheOnly = false,
  }) async {
    final watch = Stopwatch()..start();
    _setStateIfActive(identity, ticket, const ComicTranslationPageState(ComicTranslationPhase.loadingCache));
    final input = await inputResolver.resolve(identity);
    _diagnose(identity, {'stage': 'input-ready', 'available': input != null,
      'cacheOnly': cacheOnly, 'elapsedMicros': watch.elapsedMicroseconds});
    if (input == null) {
      _setStateIfActive(
        identity,
        ticket,
        const ComicTranslationPageState(
          ComicTranslationPhase.waitingForImage,
        ),
      );
      return;
    }
    try {
      if (!_isActive(ticket)) return;
      if (input.mediaKind == ComicTranslationMediaKind.animatedImage) {
        _setStateIfActive(
          identity,
          ticket,
          const ComicTranslationPageState(
            ComicTranslationPhase.unsupportedMedia,
          ),
        );
        return;
      }
      final pair = await _acquireEngines();
      if (!_isActive(ticket)) return;
      final ocrEngine = pair.ocr;
      final translator = pair.translator;
      final language = effectiveSourceLanguage;
      final ocrVersion = '${switch (ocrEngine) {
        ComicOcrLanguageSwitcher switcher => switcher.modelVersionForLanguage(language),
        _ => ocrEngine.modelVersion,
      }}${policy.ocrParameters.cacheSuffix}';
      var archiveRead = false;
      var archiveRestored = false;
      Future<void> restoreArchive() async {
        if (archiveRead || input.archive == null) return;
        archiveRead = true;
        try {
          final bytes = await input.archive!.read();
          if (bytes == null || !_isActive(ticket)) return;
          final count = await ComicTranslationStore.instance.restorePage(bytes,
            contentDigest: input.contentDigest);
          archiveRestored = count > 0;
          _diagnose(identity, {'stage': 'archive-restored', 'variants': count});
        } on Object catch (error) {
          _diagnose(identity, {'stage': 'archive-read-failed', 'errorType': error.runtimeType.toString()});
        }
      }
      Future<({ComicOcrArtifact artifact, String digest})?> findOcr() =>
          ComicTranslationStore.instance.findOcrEntry(
        contentDigest: input.contentDigest,
        engineId: ocrEngine.id,
        modelVersion: ocrVersion,
        sourceLanguage: language,
      );
      var cachedOcr = await findOcr();
      if (cachedOcr == null) {
        await restoreArchive();
        if (!_isActive(ticket)) return;
        if (archiveRead) cachedOcr = await findOcr();
      }
      if (cachedOcr == null && archiveRestored && language == 'auto') {
        final candidates = <({ComicOcrArtifact artifact, String digest})>[];
        for (final savedLanguage in ['ja', 'ko']) {
          final version = switch (ocrEngine) {
            ComicOcrLanguageSwitcher switcher => switcher.modelVersionForLanguage(savedLanguage),
            _ => ocrEngine.modelVersion,
          };
          final saved = await ComicTranslationStore.instance.findOcrEntry(
            contentDigest: input.contentDigest, engineId: ocrEngine.id,
            modelVersion: '$version${policy.ocrParameters.cacheSuffix}', sourceLanguage: savedLanguage);
          if (saved != null) candidates.add(saved);
        }
        if (candidates.length == 1) cachedOcr = candidates.single;
      }
      if (!_isActive(ticket)) return;
      _diagnose(identity, {'stage': 'ocr-cache', 'hit': cachedOcr != null,
        'cacheOnly': cacheOnly,
        'contentDigest': input.contentDigest, 'sourceLanguage': language,
        'engineId': ocrEngine.id, 'modelVersion': ocrEngine.modelVersion});
      var ocr = cachedOcr?.artifact;
      var ocrDigest = cachedOcr?.digest;
      if (ocr == null && cacheOnly) return;
      if (ocr == null) {
        _setStateIfActive(
          identity,
          ticket,
          const ComicTranslationPageState(
            ComicTranslationPhase.recognizing,
          ),
        );
        final workKey = jsonEncode([input.contentDigest, ocrEngine.id, ocrVersion, language]);
        if (_ocrTasks.containsKey(workKey)) _diagnose(identity, {'stage': 'ocr-shared'});
        final prepared = await _joinWork(_ocrTasks, workKey, () async {
          _diagnose(identity, {'stage': 'ocr-started', 'sourceLanguage': language,
            ...policy.ocrParameters.toSettings()});
          var recognized = await engines.recognize(
            pair,
            language,
            ComicOcrInput(
              identity: identity,
              filePath: input.file.path,
              contentDigest: input.contentDigest,
              sourceLanguage: language,
              maxAnalysisSide: policy.maxAnalysisSide,
              parameters: policy.ocrParameters,
              animatedMode: AnimatedTranslationMode.posterFrame,
            ),
          );
          if (recognized.contentDigest != input.contentDigest) {
            throw StateError('OCR result content digest does not match input');
          }
          if (policy.ocrParameters.cacheSuffix.isNotEmpty) {
            recognized = recognized.withModelVersion('${recognized.modelVersion}${policy.ocrParameters.cacheSuffix}');
          }
          return (artifact: recognized, digest: await ComicTranslationStore.instance.storeOcr(recognized));
        });
        ocr = prepared.artifact;
        ocrDigest = prepared.digest;
      }
      if (!_isActive(ticket)) return;
      if (sourceLanguage == 'auto' && ocr.sourceLanguage != 'auto' &&
          _detectedLanguage.value != ocr.sourceLanguage) {
        _detectedLanguage.value = ocr.sourceLanguage;
        await onSourceLanguageDetected?.call(ocr.sourceLanguage);
        if (!_isActive(ticket)) return;
      }
      final sourceOcr = ocr;
      final digest = ocrDigest!;
      final context = translator.contextMode ==
              ComicTranslationContextMode.previousPages
          ? _translationContext(identity.chapterId, identity.pageIndex)
          : const <ComicTranslationContextEntry>[];
      final contextDigest = sha256
          .convert(utf8.encode(jsonEncode(context.map((entry) => [
            entry.pageIndex,
            entry.sourceTexts,
            entry.translatedTexts,
          ]).toList())))
          .toString();
      final request = ComicTranslationRequest(
        ocr: sourceOcr,
        targetLanguage: targetLanguage,
        previousPages: context,
        translateSoundEffects: policy.translateSoundEffects,
      );
      final engineIdentity = request.units.isEmpty
          ? const ComicTranslationEngineIdentity(id: 'empty-ocr', modelVersion: '1')
          : translator.identityFor(request);
      final translationModelVersion =
          '$_translationArtifactVersion:${engineIdentity.modelVersion}:'
          'sfx=${policy.translateSoundEffects}';
      Future<ComicTranslationArtifact?> findTranslation() => ComicTranslationStore.instance.findTranslation(
        ocrDigest: digest,
        engineId: engineIdentity.id,
        modelVersion: translationModelVersion,
        targetLanguage: targetLanguage,
        contextDigest: contextDigest,
      );
      var translation = await findTranslation();
      if (translation == null && !archiveRead) {
        await restoreArchive();
        if (!_isActive(ticket)) return;
        if (archiveRead) translation = await findTranslation();
      }
      final translationCached = translation != null;
      _diagnose(identity, {'stage': 'translation-cache', 'hit': translationCached,
        'cacheOnly': cacheOnly,
        'ocrDigest': digest, 'sourceLanguage': sourceOcr.sourceLanguage,
        'engineId': engineIdentity.id, 'modelVersion': translationModelVersion,
        'targetLanguage': targetLanguage});
      if (translation == null && cacheOnly) return;
      if (translation == null) {
        if (!_isActive(ticket)) return;
        _setStateIfActive(
          identity,
          ticket,
          const ComicTranslationPageState(
            ComicTranslationPhase.translating,
          ),
        );
        final workKey = jsonEncode([digest, engineIdentity.id, translationModelVersion,
          targetLanguage, contextDigest]);
        if (_translationTasks.containsKey(workKey)) _diagnose(identity, {'stage': 'translation-shared'});
        translation = await _joinTranslationWork(identity, ticket, workKey, () async {
          if (request.units.isNotEmpty) {
            _diagnose(identity, {'stage': 'translation-started', 'unitCount': request.units.length});
          }
          final result = request.units.isEmpty
              ? const ComicTranslationResult({}) : await engines.translate(pair, request);
          final translatedRegions = request.expandUnitTranslations(result);
          final regions = sourceOcr.regions.map((region) {
            return ComicTranslatedRegion(
              ocrRegionId: region.id,
              sourceText: region.text,
              translatedText: translatedRegions[region.id]!,
              polygon: region.polygon,
              orientation: region.orientation,
              kind: region.kind,
              readingOrder: region.readingOrder,
              sourceMaskPolygons: region.sourceMaskPolygons,
              backgroundArgb: region.backgroundArgb,
              foregroundArgb: region.foregroundArgb,
              bubbleGroupId: region.bubbleGroupId,
              bubblePolygon: region.bubblePolygon,
              bubbleCandidatePolygon: region.bubbleCandidatePolygon,
              frameSpan: region.frameSpan,
            );
          }).toList();
          final artifact = ComicTranslationArtifact(
            contentDigest: input.contentDigest,
            ocrDigest: digest,
            engineId: engineIdentity.id,
            modelVersion: translationModelVersion,
            sourceLanguage: sourceOcr.sourceLanguage,
            targetLanguage: targetLanguage,
            contextDigest: contextDigest,
            imageWidth: sourceOcr.imageWidth,
            imageHeight: sourceOcr.imageHeight,
            mediaKind: sourceOcr.mediaKind,
            animatedMode: sourceOcr.animatedMode,
            regions: regions,
          );
          await ComicTranslationStore.instance.storeTranslation(artifact);
          return artifact;
        });
      }
      // Once a remote request has completed, publish its immutable result even
      // if page-retention bookkeeping changed while the request was in flight.
      // Generation still prevents disabled/disposed sessions from being revived.
      if (!_isCurrentGeneration(ticket)) return;
      _readyPages.putIfAbsent(identity.chapterId, () => {})[identity.pageIndex] =
          translation;
      if (_current.any((page) => page.key == identity.key)) _updateFontScale(translation);
      _setStateIfCurrentGeneration(
        identity,
        ticket,
        ComicTranslationPageState(
          ComicTranslationPhase.ready,
          artifact: translation,
          cleanOverlayPng: policy.useCleanOverlay ? sourceOcr.cleanOverlayPng : null,
        ),
      );
      _diagnose(identity, {'stage': 'ready', 'cached': translationCached,
        'elapsedMicros': watch.elapsedMicroseconds});
      // Publish first so portable persistence cannot delay the visible result.
      // The input lease and close barrier still cover this optional write.
      if (input.archive?.write case final write?) {
        try {
          final bytes = await ComicTranslationStore.instance.exportPage(input.contentDigest);
          if (bytes != null) await write(bytes);
          _diagnose(identity, {'stage': 'archive-saved', 'available': bytes != null});
        } on Object catch (error) {
          _diagnose(identity, {'stage': 'archive-write-failed', 'errorType': error.runtimeType.toString()});
        }
      }
    } finally {
      await input.release();
    }
  }

  void _diagnose(ComicTranslationPageIdentity identity, Map<String, Object?> details) {
    onDiagnostic?.call(identity, details);
  }

  Future<ComicTranslationArtifact> _joinTranslationWork(
    ComicTranslationPageIdentity identity, _ProcessTicket ticket, String key,
    Future<ComicTranslationArtifact> Function() run,
  ) async {
    final work = _translationTasks.putIfAbsent(key, _SharedTranslationWork.new);
    void changed(ComicTranslationRetryState? retry) {
      if (!_isCurrentGeneration(ticket)) return;
      _setState(identity, ComicTranslationPageState(ComicTranslationPhase.translating,
        retry: retry));
      if (retry != null) _diagnose(identity, {'stage': 'translation-retry',
        'attempt': retry.attempt, 'maxRetries': retry.maxRetries,
        'delayMillis': retry.delay.inMilliseconds, 'errorType': retry.errorType,
        'statusCode': retry.statusCode});
    }
    final consumer = (active: () => _isActive(ticket), changed: changed);
    work.consumers.add(consumer);
    _translationWork.add(work);
    if (work.scope.retryState != null) changed(work.scope.retryState);
    final result = work.result ??= work.scope.run(run).whenComplete(() {
      if (identical(_translationTasks[key], work)) _translationTasks.remove(key);
    });
    try {
      return await result;
    } finally {
      work.consumers.remove(consumer);
      _translationWork.remove(work);
      work.scope.activityChanged();
    }
  }

  void _notifyTranslationActivity() {
    for (final work in _translationWork.toList()) work.scope.activityChanged();
  }

  void _updateFontScale(ComicTranslationArtifact artifact) {
    if (_fontScaleResolved) return;
    final samples = artifact.regions
        .where((region) =>
            region.kind != ComicTextKind.soundEffect &&
            region.sourceText.isNotEmpty &&
            region.translatedText.isNotEmpty)
        .map((region) {
          final sourceLength = math.max(1, region.sourceText.runes.length);
          final targetLength = math.max(
            1,
            region.translatedText
                .replaceAll(comicTranslationBreakMarker, '')
                .runes
                .length,
          );
          return math.sqrt(sourceLength / targetLength).clamp(0.92, 1.10);
        })
        .toList();
    _fontScale.value = samples.isEmpty
        ? 1
        : samples.reduce((sum, value) => sum + value) / samples.length;
    _fontScaleResolved = true;
  }

  List<ComicTranslationContextEntry> _translationContext(
    String chapterId,
    int pageIndex,
  ) {
    final chapter = _readyPages[chapterId] ?? const {};
    final pages = chapter.keys
        .where((page) => page < pageIndex && page >= pageIndex - policy.contextPages)
        .toList()
      ..sort();
    return pages.map((page) {
      final artifact = chapter[page]!;
      final regions = artifact.regions
          .where((region) => region.translatedText.trim().isNotEmpty)
          .toList();
      final grouping = ComicTextGrouping(
        imageWidth: artifact.imageWidth,
        imageHeight: artifact.imageHeight,
        sourceLanguage: artifact.sourceLanguage,
      );
      final ordered = grouping.resolve(regions.map((region) => ComicTextRegion(
        value: region,
        id: region.ocrRegionId,
        text: region.sourceText,
        polygon: region.polygon,
        sourceMaskPolygons: region.sourceMaskPolygons,
        orientation: region.orientation,
        backgroundArgb: region.backgroundArgb,
        bubbleGroupId: region.bubbleGroupId,
        bubblePolygon: region.bubblePolygon,
      )).toList()).expand((group) =>
          group.regions.map((region) => region.value)).toList();
      return ComicTranslationContextEntry(
        pageIndex: page,
        sourceTexts: ordered.map((region) => region.sourceText).toList(),
        translatedTexts:
            ordered.map((region) => region.translatedText).toList(),
      );
    }).toList();
  }

  bool _isCurrentGeneration(_ProcessTicket ticket) =>
      !_disposed && _enabled && !engines.workPaused.value && ticket.generation == _generation;

  bool _isActive(_ProcessTicket ticket) =>
      _isCurrentGeneration(ticket) &&
      _retainedKeys.contains(ticket.identityKey);

  void _setStateIfActive(
    ComicTranslationPageIdentity identity,
    _ProcessTicket ticket,
    ComicTranslationPageState value,
  ) {
    if (!_isActive(ticket)) return;
    _setState(identity, value);
  }

  void _setStateIfCurrentGeneration(
    ComicTranslationPageIdentity identity,
    _ProcessTicket ticket,
    ComicTranslationPageState value,
  ) {
    if (!_isCurrentGeneration(ticket)) return;
    _setState(identity, value);
  }

  void _setState(
    ComicTranslationPageIdentity identity,
    ComicTranslationPageState value,
  ) {
    _states.putIfAbsent(
      identity.key,
      () => ValueNotifier(ComicTranslationPageState.disabled),
    ).value = value;
  }

  void dispose() => unawaited(close());

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    if (_disposed) return;
    _disposed = true;
    _enabled = false;
    _generation++;
    _notifyTranslationActivity();
    _submissionTimer?.cancel();
    engines.workPaused.removeListener(_availabilityChanged);
    await _cacheSubscription?.cancel();
    _queue.clear();
    for (final state in _states.values) {
      state.dispose();
    }
    _fontScale.dispose();
    _detectedLanguage.dispose();
    if (_running) await _pumpDone?.future;
    await Future.wait(_cacheProbes.values);
    await _releaseEngines();
  }

  Future<void> _releaseEngines() async {
    await _acquiringEngines;
    final pair = _enginePair;
    _enginePair = null;
    _acquiringEngines = null;
    if (pair != null) await engines.release(pair);
  }

  Future<ComicTranslationEnginePair> _acquireEngines() {
    final pair = _enginePair;
    if (pair != null) return Future.value(pair);
    return _acquiringEngines ??= engines.acquire()
        .then((pair) => _enginePair = pair)
        .whenComplete(() => _acquiringEngines = null);
  }

  Future<void> _releaseDisabledEngines() async {
    if (_running) await _pumpDone?.future;
    await Future.wait(_cacheProbes.values);
    if (!_enabled && !_disposed) await _releaseEngines();
  }
}

final class _SharedTranslationWork {
  final consumers = <({bool Function() active,
    void Function(ComicTranslationRetryState?) changed})>{};
  Future<ComicTranslationArtifact>? result;
  late final scope = ComicTranslationHttpRetryScope(
    isActive: () => consumers.any((consumer) => consumer.active()),
    onChanged: (state) {
      for (final consumer in consumers.toList()) {
        if (consumer.active()) consumer.changed(state);
      }
    },
  );
}

final class _ProcessTicket {
  final int generation;
  final String identityKey;

  const _ProcessTicket({
    required this.generation,
    required this.identityKey,
  });
}

final class _QueuedTranslation {
  final ComicTranslationPageIdentity identity;
  final int priority;

  const _QueuedTranslation(this.identity, this.priority);
}
