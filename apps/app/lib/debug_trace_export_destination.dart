const defaultDebugTraceExportDirectory = 'Debug';

String normalizeDebugTraceExportDirectory(String value) {
  final segments = value
      .replaceAll('\\', '/')
      .split('/')
      .map((segment) => segment.trim())
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
  if (segments.isEmpty ||
      segments.any((segment) => segment == '.' || segment == '..')) {
    return defaultDebugTraceExportDirectory;
  }
  return segments.join('/');
}

String debugTraceExportDisplayPath(String relativeDirectory) =>
    'Download/${normalizeDebugTraceExportDirectory(relativeDirectory)}';
