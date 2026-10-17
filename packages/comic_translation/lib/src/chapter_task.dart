part of 'session.dart';

enum ComicTranslationChapterPhase { running, cancelling, complete, cancelled, failed }

final class ComicTranslationChapterState {
  const ComicTranslationChapterState({
    required this.phase,
    required this.totalPages,
    this.completedPages = 0,
    this.skippedPages = 0,
    this.pageIndex = 0,
    this.pagePhase = ComicTranslationPhase.queued,
    this.error,
  });

  final ComicTranslationChapterPhase phase;
  final int totalPages;
  final int completedPages;
  final int skippedPages;
  final int pageIndex;
  final ComicTranslationPhase pagePhase;
  final Object? error;

  bool get isActive => phase == ComicTranslationChapterPhase.running ||
      phase == ComicTranslationChapterPhase.cancelling;
}

/// Sequential chapter work, owned by the application rather than a Reader.
/// Input acquisition stays with the supplied complete-file resolver. OCR and
/// translation share the ordinary registry; cancellation drains actual work.
final class ComicTranslationChapterTask {
  ComicTranslationChapterTask({
    required List<ComicTranslationPageIdentity> pages,
    required String sourceLanguage,
    required String targetLanguage,
    required ComicTranslationInputResolver inputResolver,
    ComicTranslationPolicy policy = const ComicTranslationPolicy(),
    ComicTranslationEngineRegistry? engines,
    String? detectedSourceLanguage,
    Future<void> Function(String language)? onSourceLanguageDetected,
    void Function(ComicTranslationPageIdentity, Map<String, Object?>)? onDiagnostic,
  }) : _pages = List.unmodifiable(pages),
       _session = ComicTranslationSession(
         enabled: true, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
         detectedSourceLanguage: detectedSourceLanguage,
         onSourceLanguageDetected: onSourceLanguageDetected, onDiagnostic: onDiagnostic,
         inputResolver: inputResolver, engines: engines,
         policy: policy.withPrefetch(pages: 0, cachedPages: 0),
       ),
       state = ValueNotifier(ComicTranslationChapterState(
         phase: ComicTranslationChapterPhase.running, totalPages: pages.length,
       )) {
    completion = _run();
  }

  final List<ComicTranslationPageIdentity> _pages;
  final ComicTranslationSession _session;
  final ValueNotifier<ComicTranslationChapterState> state;
  final Completer<void> _cancellation = Completer<void>();
  late final Future<void> completion;
  bool _cancelled = false;

  Future<void> cancel() async {
    if (!state.value.isActive) return completion;
    _cancelled = true;
    _publish(ComicTranslationChapterPhase.cancelling);
    _session.setEnabled(false);
    if (!_cancellation.isCompleted) _cancellation.complete();
    await completion;
  }

  void _publish(ComicTranslationChapterPhase phase, {
    int? completedPages, int? skippedPages, int? pageIndex,
    ComicTranslationPhase? pagePhase, Object? error,
  }) {
    final previous = state.value;
    state.value = ComicTranslationChapterState(
      phase: phase, totalPages: _pages.length,
      completedPages: completedPages ?? previous.completedPages,
      skippedPages: skippedPages ?? previous.skippedPages,
      pageIndex: pageIndex ?? previous.pageIndex,
      pagePhase: pagePhase ?? previous.pagePhase, error: error,
    );
  }

  Future<void> _run() async {
    Object? failure;
    try {
      for (var index = 0; index < _pages.length && !_cancelled; index++) {
        final identity = _pages[index];
        final output = _session.listenable(identity);
        final terminal = Completer<ComicTranslationPageState>();
        void changed() {
          final page = output.value;
          if (!_cancelled) _publish(ComicTranslationChapterPhase.running,
            pageIndex: index, pagePhase: page.phase);
          if (switch (page.phase) {
            ComicTranslationPhase.ready || ComicTranslationPhase.failed ||
            ComicTranslationPhase.unavailable || ComicTranslationPhase.waitingForImage ||
            ComicTranslationPhase.unsupportedMedia => true,
            _ => false,
          }) {
            if (!terminal.isCompleted) terminal.complete(page);
          }
        }
        output.addListener(changed);
        try {
          _session.reportPages(current: [identity], interaction: ComicTranslationInteraction.idle);
          changed();
          final page = await Future.any<ComicTranslationPageState?>([
            terminal.future, _cancellation.future.then((_) => null),
          ]);
          if (_cancelled || page == null) break;
          if (page.phase != ComicTranslationPhase.ready &&
              page.phase != ComicTranslationPhase.unsupportedMedia) {
            throw page.error ?? StateError(page.phase == ComicTranslationPhase.waitingForImage
                ? '本章图片尚未下载完整' : '翻译引擎不可用');
          }
          // Reader publishes before optional archive IO. A chapter must also
          // drain that page's file/model leases before advancing, otherwise
          // consecutive cache hits can retain an entire chapter of inputs.
          await _session._cacheProbes[identity.key];
          if (_session._running) await _session._pumpDone?.future;
          if (_cancelled) break;
          _publish(ComicTranslationChapterPhase.running,
            completedPages: state.value.completedPages + 1,
            skippedPages: state.value.skippedPages +
                (page.phase == ComicTranslationPhase.unsupportedMedia ? 1 : 0));
        } finally {
          output.removeListener(changed);
        }
        // Only this task consumes these notifiers. Keep the current page and
        // the configured context window, not a chapter's worth of clean PNGs.
        final keep = _pages.skip(math.max(0, index - _session.policy.contextPages))
            .take(_session.policy.contextPages + 1).map((page) => page.key).toSet();
        for (final key in _session._states.keys.toList()) {
          if (!keep.contains(key)) {
            _session._states.remove(key)?.dispose();
            _session._identities.remove(key);
          }
        }
        for (final chapter in _session._readyPages.values) {
          chapter.removeWhere((page, _) => page < identity.pageIndex - _session.policy.contextPages);
        }
      }
    } on Object catch (error) {
      failure = error;
    } finally {
      await _session.close();
      _publish(_cancelled ? ComicTranslationChapterPhase.cancelled
          : failure != null ? ComicTranslationChapterPhase.failed
          : ComicTranslationChapterPhase.complete, error: failure);
    }
  }

  Future<void> close() async {
    await cancel();
    state.dispose();
  }
}
