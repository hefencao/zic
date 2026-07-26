import 'dart:convert';
import 'dart:io';

import 'package:domain/domain.dart';

import 'artifact.dart';

final class CacheLayout {
  const CacheLayout(this.root);

  final String root;

  String get partialDir => '${Directory(root).path}${Platform.pathSeparator}partial';
  String get finalDir => '${Directory(root).path}${Platform.pathSeparator}final';
  String get dbPath => '${Directory(root).path}${Platform.pathSeparator}cache.sqlite';

  Artifact artifactFor(DownloadId id) {
    final token = tokenFor(id);
    return Artifact(
      partialPath: '$partialDir${Platform.pathSeparator}$token.part',
      finalPath: '$finalDir${Platform.pathSeparator}$token.bin',
    );
  }

  String tokenFor(DownloadId id) => _fnv64(id.key);
}

String _fnv64(String value) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(value)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
