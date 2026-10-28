part of 'home_shell.dart';

extension _HomeSyncComposition on _HomeShellState {
  Future<void> _refreshExternalSourcesWithSettings(ExternalPluginController controller) async {
    final sources = controller.activeSources;
    await _restoreExternalSourceSettings(sources);
    await _sourceProjection.refreshExternalSources(sources);
  }

  Future<void> _restoreExternalSourceSettings(List<BrowsableComicSource> sources) async {
    for (final source in sources) {
      try {
        await _portableSettingsOwner.restorePluginSettings(source);
      } on Object catch (error) {
        debugPrint('Pending plugin settings retained (${error.runtimeType})');
      }
    }
  }

  void _openSettings() {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SettingsScreen(
            preferences: widget.preferences,
            downloadPolicy: WholeComicPolicySettingsBinding(
              changes: _librarySession.downloadProjectionChanges,
              readSnapshot: () => _librarySession.wholeComicQueueSnapshot,
              updatePolicy: _downloadCommands.updateWholeComicPolicy,
            ),
            dataRuntime: DataSettingsRuntimeBinding(
              changes:
                  _serviceHandoff ?? _librarySession.downloadProjectionChanges,
              readStorageRoot: () => _storageRoot,
              canChangeChapterDownloadDirectory: () =>
                  _serviceHandoff?.chapterDownloadRelay != null,
              changeChapterDownloadDirectory:
                  _changeSettingsChapterDownloadDirectory,
              inspectCache: _inspectSettingsCache,
              clearCache: _clearSettingsCache,
              updateCachePolicyAndTrim: _updateSettingsCachePolicyAndTrim,
            ),
            exportBackup: (sections) => exportImportedLibraryBackup(_library,
              readRecords: () => _webDavController.exportRecords(sections: sections)),
            backupImportBuilder: (_) => LibraryBackupImportScreen(controller: _webDavController),
            webDavBuilder: (_) => WebDavSyncScreen(controller: _webDavController),
          ),
        ),
      ),
    );
  }


  PortableSettingsOwner get _portableSettingsOwner => _portableSettings ??= PortableSettingsOwner(
    preferences: widget.preferences,
    loadTranslation: loadComicTranslationSettings,
    sources: () async {
      await _externalSources.ensureSourcesPublished();
      return _sourceProjection.sources;
    },
    readPluginState: () async => readJsonObjectFile(await _portablePluginStatePath()),
    writePluginState: (data) async => writeJsonObjectFile(await _portablePluginStatePath(), data),
    readDownloadPolicy: () => _wholeComicQueueSnapshot.policy,
    updateDownloadPolicy: _downloadCommands.updateWholeComicPolicy,
  );

  Future<String> _portablePluginStatePath() async => (_storageRoot ??
    await getDefaultZicStorageRoot(applicationSupportPath: getStartupApplicationSupportPath)) +
      '/portable_settings/plugins.json';

  WebDavSyncController get _webDavController => _webDavSync ??=
      WebDavSyncController(
        client: WebDavClient(defaultDownloadResourceCoordinator.networkLane),
        preferences: widget.preferences,
        storageRoot: () async => _storageRoot ?? await getDefaultZicStorageRoot(
          applicationSupportPath: getStartupApplicationSupportPath,
        ),
        readLibrary: _librarySession.readLibrarySyncSnapshot,
        applyLibrary: _librarySession.applyLibrarySync,
        portableSettings: _portableSettingsOwner,
      );
}
