import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _debugTraceExportChannel = MethodChannel(
  'dev.zic.zic/debug_trace_export',
);

Future<String?> exportDebugTraceDocument({
  required String suggestedName,
  required Uint8List bytes,
}) async {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return _debugTraceExportChannel.invokeMethod<String>(
      'saveJsonl',
      <String, Object?>{
        'suggestedName': suggestedName,
        'bytes': bytes,
      },
    );
  }
  final location = await getSaveLocation(suggestedName: suggestedName);
  if (location == null) {
    return null;
  }
  final mimeType = suggestedName.endsWith('.txt') || suggestedName.endsWith('.log')
      ? 'text/plain'
      : 'application/x-ndjson';
  await XFile.fromData(
    bytes,
    mimeType: mimeType,
    name: suggestedName,
  ).saveTo(location.path);
  return location.path;
}
