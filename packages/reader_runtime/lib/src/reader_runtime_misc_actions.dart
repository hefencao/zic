part of 'reader_runtime_screen.dart';

extension _ReaderRuntimeMiscActions on _ReaderRuntimeScreenState {
  Future<void> _editTapSettings(ReaderController reader) async {
    final writer = widget.onModeSettingsChanged;
    if (writer == null) return;
    final mode = _readerMode(reader.direction);
    final saved = await showReaderGestureSettingsSheet(
      context,
      mode: mode,
      initialSettings: _settings.modeSettingsFor(mode),
    );
    if (saved == null || !mounted) return;
    try {
      await Future<void>.sync(() => writer(mode, saved));
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          _copyableReaderErrorSnackBar('保存点击设置失败：$error'),
        );
      }
      return;
    }
    if (!mounted) return;
    _replaceModeSettings(mode, saved);
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
        await _editTapSettings(reader);
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
