const String chapterDownloadSafDirectoryPrefix = 'saf://';
const String chapterDownloadReplicaMigrationProtocolV1 =
    'replica-direct-v1';

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

/// Returns whether an explicit existing-download migration can be performed by
/// the direct-root replica migration protocol. SAF cross-root moves remain an
/// intentionally separate future operation because they require provider-side
/// destination semantics rather than POSIX path relocation.
bool chapterDownloadDirectoryMigrationSupported(
  String source,
  String destination,
) =>
    chapterDownloadSafTreeUri(source) == null &&
    chapterDownloadSafTreeUri(destination) == null;
