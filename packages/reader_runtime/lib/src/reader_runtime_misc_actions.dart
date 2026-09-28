part of 'reader_runtime_screen.dart';

extension _ReaderRuntimeMiscActions on _ReaderRuntimeScreenState {
  void _replaceModeSettings(
    ReaderMode mode,
    ReaderModeSettings settings,
  ) {
    _updateRuntimeState(() {
      _settings = mode == ReaderMode.continuous
          ? _settings.copyWith(continuous: settings)
          : _settings.copyWith(paged: settings);
    });
  }

  void _activateTapRegionEditor(ReaderMode mode) {
    _tapRegionRestoreControlsVisible = _controlsVisible;
    final editSession = Object();
    _updateRuntimeState(() {
      _tapRegionEditSession = editSession;
      _tapRegionMode = mode;
      _tapRegionDraft = _settings.modeSettingsFor(mode);
      _controlsVisible = false;
    });
  }

  void _dismissTapRegionEditor() {
    final restoreControls = _tapRegionRestoreControlsVisible;
    _updateRuntimeState(() {
      _tapRegionEditSession = null;
      _tapRegionMode = null;
      _tapRegionDraft = null;
      _tapRegionSaveInFlight = false;
      _controlsVisible = restoreControls;
    });
  }

  void _adoptSettingsSnapshot(ReaderSessionSettings settings) {
    _updateRuntimeState(() {
      _settings = settings;
      _adaptiveProfile = _initialAdaptiveProfile(_settings);
      if (_settings.effectiveAdaptiveEnabled &&
          _adaptiveProfile != _settings.adaptiveProfile) {
        _settings = _settings.copyWith(adaptiveProfile: _adaptiveProfile);
      }
    });
    _reader?.setDirection(_resolveInitialDirection(_matchingInitialProgress()));
    _syncExternalPresentationFit();
    _syncTouchResampling();
    _syncPlatformFrameCadenceProbe();
  }

  void _beginTapRegionEditor(ReaderController reader) {
    if (widget.onModeSettingsChanged == null || _tapRegionDraft != null) {
      return;
    }
    final mode = _readerMode(reader.direction);
    _activateTapRegionEditor(mode);
    _systemUiTransitionGate.applyNow();
  }

  void _closeTapRegionEditor() {
    if (_tapRegionDraft == null) return;
    _dismissTapRegionEditor();
    _systemUiTransitionGate.applyNow();
  }

  Future<void> _saveTapRegionEditor(ReaderModeSettings saved) async {
    final mode = _tapRegionMode;
    final editSession = _tapRegionEditSession;
    final writer = widget.onModeSettingsChanged;
    if (mode == null ||
        editSession == null ||
        writer == null ||
        _tapRegionSaveInFlight) {
      return;
    }
    _tapRegionSaveInFlight = true;
    try {
      await Future<void>.sync(() => writer(mode, saved));
    } on Object catch (error) {
      if (!mounted || !identical(_tapRegionEditSession, editSession)) return;
      ScaffoldMessenger.of(context).showSnackBar(
        _copyableReaderErrorSnackBar('保存点击设置失败：$error'),
      );
      _tapRegionSaveInFlight = false;
      return;
    }
    if (!mounted || !identical(_tapRegionEditSession, editSession)) return;
    _replaceModeSettings(mode, saved);
    _closeTapRegionEditor();
  }

  Widget _buildTapRegionOverlay() {
    final mode = _tapRegionMode;
    final draft = _tapRegionDraft;
    if (mode == null || draft == null) {
      return const SizedBox.shrink();
    }
    return ReaderTapRegionOverlay(
      mode: mode,
      initialSettings: draft,
      onCancel: _closeTapRegionEditor,
      onSave: (saved) => unawaited(_saveTapRegionEditor(saved)),
    );
  }

  Future<bool> _handleReaderBack() async {
    if (_tapRegionDraft != null) {
      _closeTapRegionEditor();
      return false;
    }
    return _flushProgressBeforePop();
  }

  Future<void> _handleMiscCommand(
    _ReaderMiscCommand command,
    ReaderController reader,
  ) async {
    switch (command) {
      case _ReaderMiscCommand.globalSettings:
        final open = widget.onOpenGlobalReadingSettings;
        if (open == null) return;
        final refreshed = await Future<ReaderSessionSettings?>.sync(open);
        if (refreshed != null && mounted) {
          _adoptSettingsSnapshot(refreshed);
        }
        return;
      case _ReaderMiscCommand.tapSettings:
        _beginTapRegionEditor(reader);
        return;
      case _ReaderMiscCommand.openWebView:
        await _runExternalReaderAction(
          widget.onOpenSourceWebView,
          label: '在 WebView 中打开',
        );
        return;
      case _ReaderMiscCommand.openBrowser:
        await _runExternalReaderAction(
          widget.onOpenExternalBrowser,
          label: '在浏览器中打开',
        );
        return;
    }
  }

  Future<void> _runExternalReaderAction(
    ReaderExternalAction? action, {
    required String label,
  }) async {
    if (action == null) return;
    try {
      await Future<void>.sync(action);
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          _copyableReaderErrorSnackBar('$label失败：$error'),
        );
      }
    }
  }

  Future<void> _editComicSettings() async {
    final saved = await showReaderComicSettingsSheet(
      context,
      initialSettings: _settings,
      adaptiveProfile: _adaptiveProfile,
    );
    if (saved == null || !mounted) return;
    _adoptSettingsSnapshot(saved);
    final writer = widget.onSettingsChanged;
    if (writer != null) {
      try {
        await Future<void>.sync(() => writer(_settings));
      } on Object catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            _copyableReaderErrorSnackBar('保存本漫画阅读设置失败：$error'),
          );
        }
      }
    }
  }
}
