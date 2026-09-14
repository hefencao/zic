const String chapterDownloadSafDirectoryPrefix = 'saf://';

/// Extracts the Android SAF tree URI from the persisted chapter-download
/// directory preference.
///
/// The persisted wrapper is `saf://<tree-uri>` while the platform bridge must
/// receive the exact underlying `content://...` URI. Keep this conversion in
/// one place so the wrapper length cannot drift from individual call sites.
String? chapterDownloadSafTreeUri(String directory) {
  if (!directory.startsWith(chapterDownloadSafDirectoryPrefix)) return null;
  final treeUri = directory.substring(chapterDownloadSafDirectoryPrefix.length);
  return treeUri.isEmpty ? null : treeUri;
}
