import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const String localMediaBridgeChannelName = 'dev.zic/local_media';
const int localMediaBridgeProtocolVersion = 3;

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
