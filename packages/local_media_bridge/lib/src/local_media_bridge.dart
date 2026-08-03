import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const String localMediaBridgeChannelName = 'dev.zic/local_media';
const int localMediaBridgeProtocolVersion = 5;
const int localMediaBridgeChunkBytes = 1024 * 1024;

@immutable
final class LocalMediaDocument {
  const LocalMediaDocument({
    required this.sourceUri,
    required this.displayName,
    required this.format,
    required this.recognition,
    this.byteLength,
  });

  final String sourceUri;
  final String displayName;
  final String format;
  final String recognition;
  final int? byteLength;
}

@immutable
final class LocalMediaDocumentResponse {
  const LocalMediaDocumentResponse({
    required this.bytes,
    required this.rangeStart,
    required this.totalLength,
    required this.revision,
    required this.rangeSupported,
    required this.partial,
    required this.close,
  });

  final Stream<List<int>> bytes;
  final int rangeStart;
  final int? totalLength;
  final String revision;
  final bool rangeSupported;
  final bool partial;
  final Future<void> Function() close;
}

@immutable
final class LocalMediaDirectory {
  const LocalMediaDirectory({
    required this.treeUri,
    required this.displayName,
    required this.documents,
    required this.scannedFiles,
    required this.unreadableFiles,
    required this.headerRecognizedFiles,
    required this.metadataRecognizedFiles,
  });

  final String treeUri;
  final String displayName;
  final List<LocalMediaDocument> documents;
  final int scannedFiles;
  final int unreadableFiles;
  final int headerRecognizedFiles;
  final int metadataRecognizedFiles;

  int get unrecognizedFiles {
    final count = scannedFiles - unreadableFiles - documents.length;
    return count < 0 ? 0 : count;
  }
}

final class LocalMediaBridge {
  const LocalMediaBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(localMediaBridgeChannelName);

  final MethodChannel _channel;

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<LocalMediaDirectory?> pickImageDirectory() async {
    final response = await _channel.invokeMapMethod<String, Object?>(
      'pickImageDirectory',
    );
    return response == null ? null : _parseDirectory(response);
  }

  Future<LocalMediaDirectory> scanImageDirectory(String treeUri) async {
    final normalized = treeUri.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(treeUri, 'treeUri', 'must not be empty');
    }
    final response = await _channel.invokeMapMethod<String, Object?>(
      'scanImageDirectory',
      <String, Object?>{'treeUri': normalized},
    );
    if (response == null) {
      throw StateError('Android directory rescan returned no result');
    }
    return _parseDirectory(response);
  }

  Future<LocalMediaDocumentResponse> openDocument(
    String sourceUri, {
    int start = 0,
    int? endExclusive,
    String? expectedRevision,
  }) async {
    final normalized = sourceUri.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(sourceUri, 'sourceUri', 'must not be empty');
    }
    if (start < 0 || (endExclusive != null && endExclusive < start)) {
      throw ArgumentError('invalid local document byte range');
    }
    final response = await _channel.invokeMapMethod<String, Object?>(
      'openDocument',
      <String, Object?>{
        'sourceUri': normalized,
        'start': start,
        if (endExclusive != null) 'endExclusive': endExclusive,
        if (expectedRevision != null) 'expectedRevision': expectedRevision,
      },
    );
    if (response == null) {
      throw StateError('Android document open returned no response');
    }
    final handleId = _requiredString(response, 'handleId');
    final rangeStart = _requiredInt(response, 'rangeStart');
    final totalLength = response['totalLength'];
    if (totalLength != null && (totalLength is! int || totalLength < 0)) {
      throw const FormatException('Android document length is invalid');
    }
    final revision = _requiredString(response, 'revision');
    final rangeSupported = response['rangeSupported'];
    if (rangeSupported is! bool) {
      throw const FormatException('Android document range support is invalid');
    }
    final partial = response['partial'];
    if (partial is! bool) {
      throw const FormatException('Android document range response is invalid');
    }
    final directPath = response['directPath'];
    final directStart = response['directStart'];
    final directEndExclusive = response['directEndExclusive'];
    final hasDirectDescriptor = directPath is String &&
        directPath.isNotEmpty &&
        directStart is int &&
        directStart >= 0 &&
        (directEndExclusive == null ||
            (directEndExclusive is int && directEndExclusive >= directStart));
    return LocalMediaDocumentResponse(
      bytes: _readDocumentStream(
        handleId,
        directPath: hasDirectDescriptor ? directPath : null,
        directStart: hasDirectDescriptor ? directStart : null,
        directEndExclusive:
            hasDirectDescriptor ? directEndExclusive as int? : null,
      ),
      rangeStart: rangeStart,
      totalLength: totalLength as int?,
      revision: revision,
      rangeSupported: rangeSupported,
      partial: partial,
      close: () => _closeDocumentHandle(handleId),
    );
  }

  Stream<List<int>> _readDocumentStream(
    String handleId, {
    String? directPath,
    int? directStart,
    int? directEndExclusive,
  }) async* {
    try {
      if (directPath != null && directStart != null) {
        RandomAccessFile? reader;
        var yielded = false;
        try {
          reader = await File(directPath).open();
          await reader.setPosition(directStart);
          var remaining = directEndExclusive == null
              ? null
              : directEndExclusive - directStart;
          while (remaining == null || remaining > 0) {
            final requested = remaining == null
                ? localMediaBridgeChunkBytes
                : remaining < localMediaBridgeChunkBytes
                    ? remaining
                    : localMediaBridgeChunkBytes;
            final chunk = await reader.read(requested);
            if (chunk.isEmpty) {
              break;
            }
            yielded = true;
            remaining = remaining == null ? null : remaining - chunk.length;
            yield chunk;
          }
          return;
        } on FileSystemException {
          // Some providers expose a descriptor that Android can seek but Dart
          // cannot reopen through /proc/self/fd. Fall back before publishing
          // bytes; a mid-stream failure remains authoritative and is retried
          // by the existing range/session layer.
          if (yielded) {
            rethrow;
          }
        } finally {
          await reader?.close();
        }
      }
      while (true) {
        final chunk = await _channel.invokeMethod<Uint8List>(
          'readDocumentChunk',
          <String, Object?>{
            'handleId': handleId,
            'maxBytes': localMediaBridgeChunkBytes,
          },
        );
        if (chunk == null || chunk.isEmpty) {
          break;
        }
        yield chunk;
      }
    } finally {
      await _closeDocumentHandle(handleId);
    }
  }

  Future<void> _closeDocumentHandle(String handleId) async {
    try {
      await _channel.invokeMethod<void>(
        'closeDocument',
        <String, Object?>{'handleId': handleId},
      );
    } on PlatformException catch (error) {
      if (error.code != 'invalid_handle' && error.code != 'detached') {
        rethrow;
      }
    }
  }

  Future<Uint8List> readDocument(String sourceUri) async {
    final normalized = sourceUri.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(sourceUri, 'sourceUri', 'must not be empty');
    }
    final bytes = await _channel.invokeMethod<Uint8List>(
      'readDocument',
      <String, Object?>{'sourceUri': normalized},
    );
    if (bytes == null) {
      throw StateError('Android document read returned no bytes');
    }
    return bytes;
  }

  LocalMediaDirectory _parseDirectory(Map<String, Object?> response) {
    final protocolVersion = _optionalInt(
      response,
      'protocolVersion',
      fallback: 0,
    );
    if (protocolVersion < localMediaBridgeProtocolVersion) {
      throw StateError(
        'Android 本地媒体桥版本过旧（native=$protocolVersion，'
        'Dart=$localMediaBridgeProtocolVersion）。请运行 ./tool/clean.sh 后重新编译。',
      );
    }
    final treeUri = _requiredString(response, 'treeUri');
    final displayName = _requiredString(response, 'displayName');
    final scannedFiles = _requiredInt(response, 'scannedFiles');
    final unreadableFiles = _requiredInt(response, 'unreadableFiles');
    final headerRecognizedFiles = _optionalInt(
      response,
      'headerRecognizedFiles',
      fallback: 0,
    );
    final metadataRecognizedFiles = _optionalInt(
      response,
      'metadataRecognizedFiles',
      fallback: 0,
    );
    final rawDocuments = response['documents'];
    if (rawDocuments is! List<Object?>) {
      throw const FormatException(
        'Android image directory response has no document list',
      );
    }
    final documents = rawDocuments.map((raw) {
      if (raw is! Map<Object?, Object?>) {
        throw const FormatException(
          'Android image directory contains an invalid document',
        );
      }
      final normalized = <String, Object?>{
        for (final entry in raw.entries)
          if (entry.key is String) (entry.key as String): entry.value,
      };
      final byteLength = normalized['byteLength'];
      return LocalMediaDocument(
        sourceUri: _requiredString(normalized, 'sourceUri'),
        displayName: _requiredString(normalized, 'displayName'),
        format: _requiredString(normalized, 'format'),
        recognition: _optionalString(
          normalized,
          'recognition',
          fallback: 'header',
        ),
        byteLength: byteLength == null
            ? null
            : byteLength is int
                ? byteLength
                : throw const FormatException(
                    'Android image directory returned an invalid byte length',
                  ),
      );
    }).toList(growable: false);
    return LocalMediaDirectory(
      treeUri: treeUri,
      displayName: displayName,
      documents: List<LocalMediaDocument>.unmodifiable(documents),
      scannedFiles: scannedFiles,
      unreadableFiles: unreadableFiles,
      headerRecognizedFiles: headerRecognizedFiles,
      metadataRecognizedFiles: metadataRecognizedFiles,
    );
  }
}

String _requiredString(Map<String, Object?> values, String key) {
  final value = values[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Android image directory response has invalid $key');
  }
  return value;
}

int _requiredInt(Map<String, Object?> values, String key) {
  final value = values[key];
  if (value is! int || value < 0) {
    throw FormatException('Android image directory response has invalid $key');
  }
  return value;
}

String _optionalString(
  Map<String, Object?> values,
  String key, {
  required String fallback,
}) {
  final value = values[key];
  if (value == null) {
    return fallback;
  }
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Android image directory response has invalid $key');
  }
  return value;
}

int _optionalInt(
  Map<String, Object?> values,
  String key, {
  required int fallback,
}) {
  final value = values[key];
  if (value == null) {
    return fallback;
  }
  if (value is! int || value < 0) {
    throw FormatException('Android image directory response has invalid $key');
  }
  return value;
}
