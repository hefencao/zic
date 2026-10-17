import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'models.dart';

final class ResolvedComicTranslationInput {
  final File file;
  final FutureOr<void> Function() release;
  final int size;
  final int modifiedMilliseconds;
  final String contentDigest;
  final ComicTranslationMediaKind mediaKind;

  const ResolvedComicTranslationInput({
    required this.file,
    required this.release,
    required this.size,
    required this.modifiedMilliseconds,
    required this.contentDigest,
    required this.mediaKind,
  });
}

/// A pinned, complete encoded image. The caller retains storage authority.
final class ComicTranslationInputFile {
  const ComicTranslationInputFile({required this.path, required this.release});
  final String path;
  final FutureOr<void> Function() release;

  static Future<ComicTranslationInputFile?> openLocalUri(Uri uri) async {
    if (uri.scheme != 'file') return null;
    final file = File.fromUri(uri);
    if (!await file.exists()) return null;
    return ComicTranslationInputFile(path: file.path, release: () {});
  }
}

final class ComicTranslationInputResolver {
  const ComicTranslationInputResolver({this.openFile});

  final Future<ComicTranslationInputFile?> Function(
    ComicTranslationPageIdentity identity,
  )? openFile;

  static final Map<String, Future<({String digest, ComicTranslationMediaKind mediaKind})>>
      _analysisTasks = {};

  Future<ResolvedComicTranslationInput?> resolve(
    ComicTranslationPageIdentity identity,
  ) async {
    final lease = await (openFile?.call(identity) ?? _openLocalFile(identity));
    if (lease == null) return null;
    final file = File(lease.path);
    var transferred = false;
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file || stat.size <= 0) return null;
      final modified = stat.modified.millisecondsSinceEpoch;
      // Digest the actual pinned body; URL/length/mtime are not content proof.
      final analysis = await _analyze(file, stat.size, modified);
      final verified = await file.stat();
      if (verified.size != stat.size ||
          verified.modified.millisecondsSinceEpoch != modified) {
        throw StateError('Comic image changed while preparing translation input');
      }
      transferred = true;
      return ResolvedComicTranslationInput(
        file: file,
        release: lease.release,
        size: stat.size,
        modifiedMilliseconds: modified,
        contentDigest: analysis.digest,
        mediaKind: identity.mediaKind == ComicTranslationMediaKind.animatedImage
            ? identity.mediaKind : analysis.mediaKind,
      );
    } finally {
      if (!transferred) await lease.release();
    }
  }

  Future<ComicTranslationInputFile?> _openLocalFile(
    ComicTranslationPageIdentity identity,
  ) async {
    final uri = Uri.tryParse(identity.imageKey);
    if (uri == null || uri.scheme != 'file') return null;
    final file = File.fromUri(uri);
    if (!await file.exists()) return null;
    return ComicTranslationInputFile(path: file.path, release: () {});
  }

  static Future<({String digest, ComicTranslationMediaKind mediaKind})> _analyze(
    File file, int size, int modified,
  ) {
    final key = '${file.path}\u0000$size\u0000$modified';
    final existing = _analysisTasks[key];
    if (existing != null) return existing;
    late final Future<({String digest, ComicTranslationMediaKind mediaKind})> task;
    task = Isolate.run(() async => (
        digest: (await sha256.bind(File(file.path).openRead()).first).toString(),
        mediaKind: _detectMediaKind(file.path),
      ))
      .whenComplete(() {
        if (identical(_analysisTasks[key], task)) _analysisTasks.remove(key);
      });
    _analysisTasks[key] = task;
    return task;
  }
}

ComicTranslationMediaKind _detectMediaKind(String path) {
  final file = File(path).openSync();
  try {
    final length = file.lengthSync();
    if (length < 6) return ComicTranslationMediaKind.staticImage;
    final header = file.readSync(_minInt(12, length));
    final signature = String.fromCharCodes(header.take(6));
    if (signature == 'GIF87a' || signature == 'GIF89a') {
      return ComicTranslationMediaKind.animatedImage;
    }
    if (header.length < 12 ||
        String.fromCharCodes(header.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(header.sublist(8, 12)) != 'WEBP') {
      return ComicTranslationMediaKind.staticImage;
    }
    var offset = 12;
    while (offset + 8 <= length) {
      file.setPositionSync(offset);
      final chunk = file.readSync(8);
      if (chunk.length < 8) break;
      final type = String.fromCharCodes(chunk.sublist(0, 4));
      final size = ByteData.sublistView(chunk, 4).getUint32(0, Endian.little);
      final dataStart = offset + 8;
      if (size > length - dataStart) break;
      if (type == 'ANIM' || type == 'ANMF') {
        return ComicTranslationMediaKind.animatedImage;
      }
      if (type == 'VP8X' && size > 0) {
        file.setPositionSync(dataStart);
        final flags = file.readByteSync();
        if ((flags & 0x02) != 0) {
          return ComicTranslationMediaKind.animatedImage;
        }
      }
      offset = dataStart + size + (size.isOdd ? 1 : 0);
    }
    return ComicTranslationMediaKind.staticImage;
  } finally {
    file.closeSync();
  }
}

int _minInt(int a, int b) => a < b ? a : b;
