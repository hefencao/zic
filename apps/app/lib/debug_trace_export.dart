import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:telemetry/telemetry.dart';

import 'debug_trace_export_destination.dart';

export 'debug_trace_export_destination.dart';

const _debugTraceExportChunkSize = 128;

const _debugTraceExportChannel = MethodChannel(
  'dev.zic.zic/debug_trace_export',
);

typedef DebugTraceExportWriter = Future<String?> Function({
  required String suggestedName,
  required Uint8List bytes,
  required String relativeDirectory,
});

final class DebugTraceExportResult {
  const DebugTraceExportResult({
    required this.path,
    required this.eventCount,
    required this.relativeDirectory,
  });

  final String path;
  final int eventCount;
  final String relativeDirectory;
}

Future<Uint8List> encodeDebugTraceEvents(Iterable<TraceEvent> events) async {
  final bytes = BytesBuilder(copy: false);
  var index = 0;
  for (final event in events) {
    if (index > 0) bytes.addByte(0x0a);
    bytes.add(utf8.encode(event.toJsonLine()));
    index++;
    if (index % _debugTraceExportChunkSize == 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }
  return bytes.takeBytes();
}

Future<DebugTraceExportResult?> exportDebugTraceEvents({
  required Iterable<TraceEvent> events,
  required String relativeDirectory,
  DebugTraceExportWriter? writeFile,
}) async {
  final snapshot = events.toList(growable: false);
  final stamp = DateTime.now()
      .toUtc()
      .toIso8601String()
      .replaceAll(':', '-')
      .split('.').first;
  final suggestedName = 'zic-debug-trace-$stamp.jsonl';
  final bytes = await encodeDebugTraceEvents(snapshot);
  final directory = normalizeDebugTraceExportDirectory(relativeDirectory);
  final path = await (writeFile ?? exportDebugTraceFile)(
    suggestedName: suggestedName,
    bytes: bytes,
    relativeDirectory: directory,
  );
  if (path == null) return null;
  return DebugTraceExportResult(
    path: path,
    eventCount: snapshot.length,
    relativeDirectory: directory,
  );
}

Future<String?> exportDebugTraceFile({
  required String suggestedName,
  required Uint8List bytes,
  required String relativeDirectory,
}) async {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    try {
      return await _debugTraceExportChannel.invokeMethod<String>(
        'saveJsonlToDownloadsDirectory',
        <String, Object?>{
          'suggestedName': suggestedName,
          'bytes': bytes,
          'relativeDirectory':
              normalizeDebugTraceExportDirectory(relativeDirectory),
        },
      );
    } on PlatformException catch (error) {
      if (error.code != 'trace-export-direct-unsupported') rethrow;
    }
  }
  return _exportDebugTraceDocument(
    suggestedName: suggestedName,
    bytes: bytes,
  );
}

Future<String?> _exportDebugTraceDocument({
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
  if (location == null) return null;
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
